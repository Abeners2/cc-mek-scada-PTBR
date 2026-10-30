local comms   = require("scada-common.comms")
local log     = require("scada-common.log")
local mqueue  = require("scada-common.mqueue")
local types   = require("scada-common.types")
local util    = require("scada-common.util")

local txnctrl = require("supervisor.session.rtu.txnctrl")

local unit_session = {}

local PROTOCOL = comms.PROTOCOL
local MODBUS_FCODE = types.MODBUS_FCODE
local MODBUS_EXCODE = types.MODBUS_EXCODE

local RTU_US_CMDS = {
}

local RTU_US_DATA = {
    BUILD_CHANGED = 1
}

unit_session.RTU_US_CMDS = RTU_US_CMDS
unit_session.RTU_US_DATA = RTU_US_DATA

local DEFAULT_BUSY_WAIT = 3000

-- criar um novo executor de sessão de unidade
---@nodiscard
---@param session_id integer RTU gateway session ID
---@param unit_id integer MODBUS unit ID
---@param advert rtu_advertisement RTU advertisement for this unit
---@param out_queue mqueue send queue
---@param log_tag string logging tag
---@param txn_tags string[] transaction log tags
function unit_session.new(session_id, unit_id, advert, out_queue, log_tag, txn_tags)
    local self = {
        device_index = advert.index,
        reactor = advert.reactor,
        transaction_controller = txnctrl.new(),
        connected = true,
        device_fail = false,
        last_busy = 0
    }

    ---@class _unit_session
    local protected = {
        in_q = mqueue.new()
    }

    ---@class unit_session
    local public = {}

    -- PROTECTED FUNCTIONS --

    -- enviar uma mensagem MODBUS, criando uma transação no processo
    ---@param txn_type integer transaction type
    ---@param f_code MODBUS_FCODE function code
    ---@param register_param (number|string)[] register range or register and values
    ---@param busy_wait integer|nil milliseconds to wait (>0), or uses the default
    ---@return integer|false txn_id transaction ID of this transaction or false if not sent due to being busy
    function protected.send_request(txn_type, f_code, register_param, busy_wait)
        local txn_id = false ---@type integer|false

        busy_wait = busy_wait or DEFAULT_BUSY_WAIT

        if (util.time_ms() - self.last_busy) >= busy_wait then
            local modbus = comms.modbus_container()
            txn_id = self.transaction_controller.create(txn_type)

            modbus.make(txn_id, unit_id, f_code, register_param)

            out_queue.push_network(modbus)
        end

        return txn_id
    end

    -- tentar resolver uma transação MODBUS
    ---@nodiscard
    ---@param adu modbus_adu MODBUS ADU
    ---@return integer|false txn_type, integer txn_id transaction type or false on error/busy, transaction ID
    function protected.try_resolve(adu)
        if adu.scada_frame.protocol() == PROTOCOL.MODBUS_TCP then
            if adu.unit_id == unit_id then
                local txn_type = self.transaction_controller.resolve(adu.txn_id)
                local txn_tag = util.c(" (", txn_tags[txn_type], ")")

                if txn_type == nil then
                    -- não foi possível encontrar esta transação
                    log.debug(log_tag .. "MODBUS: resposta de transação expirada ou espúria (txn_id " .. adu.txn_id .. ")")
                    return false, adu.txn_id
                end

                if bit.band(adu.func_code, MODBUS_FCODE.ERROR_FLAG) ~= 0 then
                    -- transação incompleta ou falhou
                    local ex = adu.data[1]
                    if ex == MODBUS_EXCODE.ILLEGAL_FUNCTION then
                        log.error(log_tag .. "MODBUS: função ilegal" .. txn_tag)
                    elseif ex == MODBUS_EXCODE.ILLEGAL_DATA_ADDR then
                        log.error(log_tag .. "MODBUS: endereço de dados ilegal" .. txn_tag)
                    elseif ex == MODBUS_EXCODE.SERVER_DEVICE_FAIL then
                        if self.device_fail then
                            log.debug(log_tag .. "MODBUS: falha repetida do dispositivo" .. txn_tag)
                        else
                            self.device_fail = true
                            log.warning(log_tag .. "MODBUS: falha do dispositivo" .. txn_tag)
                        end
                    elseif ex == MODBUS_EXCODE.ACKNOWLEDGE then
                        -- será necessário aguardar a resposta, renovar a transação
                        self.transaction_controller.renew(adu.txn_id, txn_type)
                    elseif ex == MODBUS_EXCODE.SERVER_DEVICE_BUSY then
                        -- será necessário tentar novamente mais tarde
                        self.last_busy = util.time_ms()
                        log.warning(log_tag .. "MODBUS: dispositivo ocupado" .. txn_tag)
                    elseif ex == MODBUS_EXCODE.NEG_ACKNOWLEDGE then
                        -- falha geral
                        log.error(log_tag .. "MODBUS: confirmação negativa (requisição inválida)" .. txn_tag)
                    elseif ex == MODBUS_EXCODE.GATEWAY_PATH_UNAVAILABLE then
                        -- o gateway RTU não possui unidade conhecida com o ID informado
                        log.error(log_tag .. "MODBUS: caminho do gateway indisponível (unidade desconhecida)" .. txn_tag)
                    elseif ex ~= nil then
                        -- código de exceção não suportado
                        log.debug(log_tag .. "MODBUS: erro não suportado " .. ex .. txn_tag)
                    else
                        -- código de exceção nulo
                        log.debug(log_tag .. "MODBUS: código de exceção nulo" .. txn_tag)
                    end
                else
                    -- limpar flag de falha do dispositivo
                    self.device_fail = false

                    -- sem erro, retornar o tipo da transação
                    return txn_type, adu.txn_id
                end
            else
                log.error(log_tag .. "ID de unidade incorreto: " .. adu.unit_id, true)
            end
        else
            log.error(log_tag .. "tipo de pacote ilegal " .. adu.scada_frame.protocol(), true)
        end

        -- erro ou transação em andamento, retornar false
        return false, adu.txn_id
    end

    -- tarefas pós-atualização
    function protected.post_update()
        self.transaction_controller.cleanup()
    end

    -- registrar divergência no tamanho da resposta de uma transação
    ---@param txn_type integer transaction type
    function protected.log_length_mismatch(txn_type)
        log.debug(log_tag .. "divergência no tamanho da resposta da transação MODBUS (" .. txn_tags[txn_type] .. ")")
    end

    -- registrar falha na resolução de uma transação
    ---@param txn_type integer? transaction type
    function protected.log_resolve_fail(txn_type)
        log.error(log_tag .. "transação desconhecida " .. util.trinary(txn_type == nil, "reply", util.c("type ", txn_type)))
    end

    -- obter a interface pública
    ---@nodiscard
    function protected.get() return public end

    -- PUBLIC FUNCTIONS --

    -- obter o ID de sessão do gateway RTU
    ---@nodiscard
    function public.get_session_id() return session_id end
    -- obter o ID da unidade
    ---@nodiscard
    function public.get_unit_id() return unit_id end
    -- obter o tipo de RTU
    ---@nodiscard
    function public.get_unit_type() return advert.type end
    -- obter o índice do dispositivo
    ---@nodiscard
    function public.get_device_idx() return self.device_index or 0 end
    -- obter o ID do reator
    ---@nodiscard
    function public.get_reactor() return self.reactor end
    -- obter a fila de comandos
    ---@nodiscard
    function public.get_cmd_queue() return protected.in_q end

    -- fechar esta unidade
    function public.close() self.connected = false end
    -- verificar se esta unidade está conectada
    ---@nodiscard
    function public.is_connected() return self.connected end
    -- verificar se esta unidade está com falha
    ---@nodiscard
    function public.is_faulted() return self.device_fail end

    -- PUBLIC TEMPLATE FUNCTIONS --

-- luacheck: no unused args

    -- tratar uma ADU MODBUS
    ---@param adu modbus_adu
---@diagnostic disable-next-line: unused-local
    function public.handle_adu(adu)
        log.debug("modelo unit_session.handle_adu() chamado", true)
    end

    -- atualizar este executor
    ---@param time_now integer milliseconds
---@diagnostic disable-next-line: unused-local
    function public.update(time_now)
        log.debug("modelo unit_session.update() chamado", true)
    end

-- luacheck: unused args

    -- invalidar cache de build
    function public.invalidate_cache()
        log.debug("modelo unit_session.invalidate_cache() chamado", true)
    end

    -- obter o banco de dados da sessão da unidade
    ---@nodiscard
    function public.get_db()
        log.debug("modelo unit_session.get_db() chamado", true)
        return {}
    end

    return protected
end

return unit_session
