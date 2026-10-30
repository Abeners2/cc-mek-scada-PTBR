local log          = require("scada-common.log")
local types        = require("scada-common.types")
local util         = require("scada-common.util")

local unit_session = require("supervisor.session.rtu.unit_session")

local boilerv = {}

local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE
local MODBUS_FCODE = types.MODBUS_FCODE

local TXN_TYPES = {
    FORMED = 1,
    BUILD = 2,
    STATE = 3,
    TANKS = 4
}

local TXN_TAGS = {
    "boilerv.formed",
    "boilerv.build",
    "boilerv.state",
    "boilerv.tanks"
}

local PERIODICS = {
    FORMED = 2000,
    BUILD = 1000,
    STATE = 500,
    TANKS = 1000
}

-- criar um novo executor de sessão RTU boilerv
---@nodiscard
---@param session_id integer RTU gateway session ID
---@param unit_id integer RTU ID
---@param advert rtu_advertisement RTU advertisement table
---@param out_queue mqueue RTU message out queue
function boilerv.new(session_id, unit_id, advert, out_queue)
    -- verificações
    if advert.type ~= RTU_UNIT_TYPE.BOILER_VALVE then
        log.error("tentativa de instanciar RTU boilerv para o tipo " .. types.rtu_type_to_string(advert.type))
        return nil
    elseif not util.is_int(advert.index) then
        log.error("tentativa de instanciar RTU boilerv sem índice")
        return nil
    end

    local log_tag = util.c("session.rtu(", session_id, ").boilerv(", advert.index, ")[@", unit_id, "]: ")

    local self = {
        session = unit_session.new(session_id, unit_id, advert, out_queue, log_tag, TXN_TAGS),
        has_build = false,
        periodics = {
            next_formed_req = 0,
            next_build_req = 0,
            next_state_req = 0,
            next_tanks_req = 0
        },
        db = types.new_boiler_db()
    }

    ---@class boilerv_session:unit_session
    local public = self.session.get()

    -- PRIVATE FUNCTIONS --

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
        -- ler registradores de entrada 1 a 11 (início = 1, quantidade = 11)
        if self.session.send_request(TXN_TYPES.BUILD, MODBUS_FCODE.READ_INPUT_REGS, { 1, 11 }) ~= false then
            self.periodics.next_build_req = time_now + PERIODICS.BUILD
        end
    end

    -- consultar o estado do dispositivo
    ---@param time_now integer
    local function _request_state(time_now)
        -- ler registradores de entrada 12 a 15 (início = 12, quantidade = 4)
        if self.session.send_request(TXN_TYPES.STATE, MODBUS_FCODE.READ_INPUT_REGS, { 12, 4 }) ~= false then
            self.periodics.next_state_req = time_now + PERIODICS.STATE
        end
    end

    -- consultar os tanques do dispositivo
    ---@param time_now integer
    local function _request_tanks(time_now)
        -- ler registradores de entrada 16 a 27 (início = 16, quantidade = 12)
        if self.session.send_request(TXN_TYPES.TANKS, MODBUS_FCODE.READ_INPUT_REGS, { 16, 12 }) ~= false then
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
            -- carregar dados se o tamanho estiver correto
            if adu.length == 11 then
                self.db.build.last_update  = util.time_ms()
                self.db.build.length       = adu.data[1]
                self.db.build.width        = adu.data[2]
                self.db.build.height       = adu.data[3]
                self.db.build.min_pos      = adu.data[4]
                self.db.build.max_pos      = adu.data[5]
                self.db.build.boil_cap     = adu.data[6]
                self.db.build.steam_cap    = adu.data[7]
                self.db.build.water_cap    = adu.data[8]
                self.db.build.hcool_cap    = adu.data[9]
                self.db.build.ccool_cap    = adu.data[10]
                self.db.build.superheaters = adu.data[11]
                self.has_build = true

                out_queue.push_data(unit_session.RTU_US_DATA.BUILD_CHANGED, { unit = advert.reactor, type = advert.type })
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.STATE then
            -- resposta de estado
            -- carregar dados se o tamanho estiver correto
            if adu.length == 4 then
                self.db.state.last_update   = util.time_ms()
                self.db.state.temperature   = adu.data[1]
                self.db.state.boil_rate     = adu.data[2]
                self.db.state.max_boil_rate = adu.data[3]
                self.db.state.env_loss      = adu.data[4]
            else self.session.log_length_mismatch(txn_type) end
        elseif txn_type == TXN_TYPES.TANKS then
            -- resposta de tanques
            -- carregar dados se o tamanho estiver correto
            if adu.length == 12 then
                self.db.tanks.last_update = util.time_ms()
                self.db.tanks.steam       = adu.data[1]
                self.db.tanks.steam_need  = adu.data[2]
                self.db.tanks.steam_fill  = adu.data[3]
                self.db.tanks.water       = adu.data[4]
                self.db.tanks.water_need  = adu.data[5]
                self.db.tanks.water_fill  = adu.data[6]
                self.db.tanks.hcool       = adu.data[7]
                self.db.tanks.hcool_need  = adu.data[8]
                self.db.tanks.hcool_fill  = adu.data[9]
                self.db.tanks.ccool       = adu.data[10]
                self.db.tanks.ccool_need  = adu.data[11]
                self.db.tanks.ccool_fill  = adu.data[12]
            else self.session.log_length_mismatch(txn_type) end
        else self.session.log_resolve_fail(txn_type) end
    end

    -- atualizar este executor
    ---@param time_now integer milliseconds
    function public.update(time_now)
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

return boilerv
