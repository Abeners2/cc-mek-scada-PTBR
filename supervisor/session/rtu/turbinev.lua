local log          = require("scada-common.log")
local mqueue       = require("scada-common.mqueue")
local types        = require("scada-common.types")
local util         = require("scada-common.util")

local qtypes       = require("supervisor.session.rtu.qtypes")
local unit_session = require("supervisor.session.rtu.unit_session")

local turbinev = {}

local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE
local DUMPING_MODE = types.DUMPING_MODE
local MODBUS_FCODE = types.MODBUS_FCODE

local TBV_RTU_S_CMDS = qtypes.TBV_RTU_S_CMDS
local TBV_RTU_S_DATA = qtypes.TBV_RTU_S_DATA

local TXN_TYPES = {
    FORMED = 1,
    BUILD = 2,
    STATE = 3,
    TANKS = 4,
    INC_DUMP = 5,
    DEC_DUMP = 6,
    SET_DUMP = 7
}

local TXN_TAGS = {
    "turbinev.formed",
    "turbinev.build",
    "turbinev.state",
    "turbinev.tanks",
    "turbinev.inc_dump",
    "turbinev.dec_dump",
    "turbinev.set_dump"
}

local PERIODICS = {
    FORMED = 2000,
    BUILD = 1000,
    STATE = 500,
    TANKS = 1000
}

local WRITE_BUSY_WAIT = 1000

-- criar um novo executor de sessão RTU turbinev
---@nodiscard
---@param session_id integer RTU gateway session ID
---@param unit_id integer RTU ID
---@param advert rtu_advertisement RTU advertisement table
---@param out_queue mqueue RTU message out queue
function turbinev.new(session_id, unit_id, advert, out_queue)
    -- verificações
    if advert.type ~= RTU_UNIT_TYPE.TURBINE_VALVE then
        log.error("tentativa de instanciar RTU turbinev para o tipo " .. types.rtu_type_to_string(advert.type))
        return nil
    elseif not util.is_int(advert.index) then
        log.error("tentativa de instanciar RTU turbinev sem índice")
        return nil
    end

    local log_tag = util.c("session.rtu(", session_id, ").turbinev(", advert.index, ")[@", unit_id, "]: ")

    local self = {
        session = unit_session.new(session_id, unit_id, advert, out_queue, log_tag, TXN_TAGS),
        has_build = false,
        mode_cmd = nil, ---@type dumping_mode|nil
        resend_mode = false,
        periodics = {
            next_formed_req = 0,
            next_build_req = 0,
            next_state_req = 0,
            next_tanks_req = 0
        },
        db = types.new_turbine_db()
    }

    ---@class turbinev_session:unit_session
    local public = self.session.get()

    -- PRIVATE FUNCTIONS --

    -- incrementar o modo de descarte
    local function _inc_dump_mode()
        -- comando de definir modo
        if self.mode_cmd == "IDLE" then self.mode_cmd = "DUMPING_EXCESS"
        elseif self.mode_cmd == "DUMPING_EXCESS" then self.mode_cmd = "DUMPING"
        elseif self.mode_cmd == "DUMPING" then self.mode_cmd = "IDLE"
        end

        -- escrever bobina 1 com valor não usado 0
        if self.session.send_request(TXN_TYPES.INC_DUMP, MODBUS_FCODE.WRITE_SINGLE_COIL, { 1, 0 }, WRITE_BUSY_WAIT) == false then
            self.resend_mode = true
        end
    end

    -- decrementar o modo de descarte
    local function _dec_dump_mode()
        -- comando de definir modo
        if self.mode_cmd == "IDLE" then self.mode_cmd = "DUMPING"
        elseif self.mode_cmd == "DUMPING_EXCESS" then self.mode_cmd = "IDLE"
        elseif self.mode_cmd == "DUMPING" then self.mode_cmd = "DUMPING_EXCESS"
        end

        -- escrever bobina 2 com valor não usado 0
        if self.session.send_request(TXN_TYPES.DEC_DUMP, MODBUS_FCODE.WRITE_SINGLE_COIL, { 2, 0 }, WRITE_BUSY_WAIT) == false then
            self.resend_mode = true
        end
    end

    -- definir o modo de descarte
    ---@param mode dumping_mode
    local function _set_dump_mode(mode)
        self.mode_cmd = mode

        -- escrever registrador de retenção 1
        if self.session.send_request(TXN_TYPES.SET_DUMP, MODBUS_FCODE.WRITE_SINGLE_HOLD_REG, { 1, mode }, WRITE_BUSY_WAIT) == false then
            self.resend_mode = true
        end
    end

    -- consultar se o multibloco está formado
    ---@param time_now integer
    local function _request_formed(time_now)
        -- ler entrada discreta 1 (início = 1, quantidade = 1)
        if self.session.send_request(TXN_TYPES.FORMED, MODBUS_FCODE.READ_DISCRETE_INPUTS, { 1, 1 }) ~= false then
            self.periodics.next_formed_req = time_now + PERIODICS.FORMED
        end
    end

    -- consultar o build do dispositivo
    ---@param time_now integer
    local function _request_build(time_now)
        -- ler registradores de entrada 1 a 15 (início = 1, quantidade = 15)
        if self.session.send_request(TXN_TYPES.BUILD, MODBUS_FCODE.READ_INPUT_REGS, { 1, 15 }) ~= false then
            self.periodics.next_build_req = time_now + PERIODICS.BUILD
        end
    end

    -- consultar o estado do dispositivo
    ---@param time_now integer
    local function _request_state(time_now)
        -- ler registradores de entrada 16 a 19 (início = 16, quantidade = 4)
        if self.session.send_request(TXN_TYPES.STATE, MODBUS_FCODE.READ_INPUT_REGS, { 16, 4 }) ~= false then
            self.periodics.next_state_req = time_now + PERIODICS.STATE
        end
    end

    -- consultar os tanques do dispositivo
    ---@param time_now integer
    local function _request_tanks(time_now)
        -- ler registradores de entrada 20 a 25 (início = 20, quantidade = 6)
        if self.session.send_request(TXN_TYPES.TANKS, MODBUS_FCODE.READ_INPUT_REGS, { 20, 6 }) ~= false then
            self.periodics.next_tanks_req = time_now + PERIODICS.TANKS
        end
    end

    -- PUBLIC FUNCTIONS --

    -- tratar uma ADU
    ---@param adu modbus_adu
    function public.handle_adu(adu)
        local txn_type = self.session.try_resolve(adu)
        if txn_type == false then
            -- nada a fazer
        elseif txn_type == TXN_TYPES.FORMED then
            -- resposta de formado
            -- carregar dados se o tamanho estiver correto
            if adu.length == 1 then
                self.db.formed = adu.data[1]

                if not self.db.formed then self.has_build = false end
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.BUILD then
            -- resposta de build
            if adu.length == 15 then
                self.db.build.last_update      = util.time_ms()
                self.db.build.length           = adu.data[1]
                self.db.build.width            = adu.data[2]
                self.db.build.height           = adu.data[3]
                self.db.build.min_pos          = adu.data[4]
                self.db.build.max_pos          = adu.data[5]
                self.db.build.blades           = adu.data[6]
                self.db.build.coils            = adu.data[7]
                self.db.build.vents            = adu.data[8]
                self.db.build.dispersers       = adu.data[9]
                self.db.build.condensers       = adu.data[10]
                self.db.build.steam_cap        = adu.data[11]
                self.db.build.max_energy       = adu.data[12]
                self.db.build.max_flow_rate    = adu.data[13]
                self.db.build.max_production   = adu.data[14]
                self.db.build.max_water_output = adu.data[15]
                self.has_build = true

                out_queue.push_data(unit_session.RTU_US_DATA.BUILD_CHANGED, { unit = advert.reactor, type = advert.type })
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.STATE then
            -- resposta de estado
            if adu.length == 4 then
                self.db.state.last_update      = util.time_ms()
                self.db.state.flow_rate        = adu.data[1]
                self.db.state.prod_rate        = adu.data[2]
                self.db.state.steam_input_rate = adu.data[3]
                self.db.state.dumping_mode     = adu.data[4]

                if self.mode_cmd == nil then
                    self.mode_cmd = self.db.state.dumping_mode
                end
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.TANKS then
            -- resposta de tanques
            if adu.length == 6 then
                self.db.tanks.last_update = util.time_ms()
                self.db.tanks.steam       = adu.data[1]
                self.db.tanks.steam_need  = adu.data[2]
                self.db.tanks.steam_fill  = adu.data[3]
                self.db.tanks.energy      = adu.data[4]
                self.db.tanks.energy_need = adu.data[5]
                self.db.tanks.energy_fill = adu.data[6]
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.INC_DUMP or txn_type == TXN_TYPES.DEC_DUMP or txn_type == TXN_TYPES.SET_DUMP then
            -- confirmação bem-sucedida
        else self.session.log_resolve_fail(txn_type) end
    end

    -- atualizar este executor
    ---@param time_now integer milliseconds
    function public.update(time_now)
        -- verificar fila de comandos
        while self.session.in_q.ready() do
            -- obter uma nova mensagem para processar
            local msg = self.session.in_q.pop()

            if msg ~= nil then
                if msg.qtype == mqueue.TYPE.COMMAND then
                    -- instrução
                    local cmd = msg.message

                    if cmd == TBV_RTU_S_CMDS.INC_DUMP_MODE then
                        _inc_dump_mode()
                    elseif cmd == TBV_RTU_S_CMDS.DEC_DUMP_MODE then
                        _dec_dump_mode()
                    else
                        log.debug(util.c(log_tag, "comando da fila não reconhecido ", cmd))
                    end
                elseif msg.qtype == mqueue.TYPE.DATA then
                    -- instrução com corpo
                    local cmd = msg.message ---@type queue_data
                    if cmd.key == TBV_RTU_S_DATA.SET_DUMP_MODE then
                        if cmd.val == DUMPING_MODE.IDLE or
                           cmd.val == DUMPING_MODE.DUMPING_EXCESS or
                           cmd.val == DUMPING_MODE.DUMPING then
                            _set_dump_mode(cmd.val)
                        else
                            log.debug(util.c(log_tag, "modo de descarte não reconhecido \"", cmd.val, "\""))
                        end
                    else
                        log.debug(util.c(log_tag, "dado da fila não reconhecido ", cmd.key))
                    end
                end
            end

            -- máximo de 100ms gastos processando a fila
            if util.time() - time_now > 100 then
                log.warning(log_tag .. "limite de 100ms de processamento da fila excedido")
                break
            end
        end

        -- tentar reenviar o modo se necessário
        if self.resend_mode then
            self.resend_mode = false
            _set_dump_mode(self.mode_cmd)
        end

        time_now = util.time()

        -- tratar periódicos

        if self.periodics.next_formed_req <= time_now then _request_formed(time_now) end

        if self.db.formed then
            if not self.has_build and self.periodics.next_build_req <= time_now then _request_build(time_now) end
            if self.periodics.next_state_req <= time_now then _request_state(time_now) end
            if self.periodics.next_tanks_req <= time_now then _request_tanks(time_now) end
        end

        self.session.post_update()
    end

    -- invalidar cache de build
    function public.invalidate_cache()
        self.periodics.next_formed_req = 0
        self.periodics.next_build_req = 0
        self.has_build = false
    end

    -- obter o banco de dados da sessão da unidade
    ---@nodiscard
    function public.get_db() return self.db end

    return public
end

return turbinev
