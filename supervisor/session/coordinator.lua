local comms    = require("scada-common.comms")
local log      = require("scada-common.log")
local mqueue   = require("scada-common.mqueue")
local types    = require("scada-common.types")
local util     = require("scada-common.util")

local databus  = require("supervisor.databus")

local svqtypes = require("supervisor.session.svqtypes")

local coordinator = {}

local PROTOCOL = comms.PROTOCOL
local MGMT_TYPE = comms.MGMT_TYPE
local CRDN_TYPE = comms.CRDN_TYPE
local UNIT_COMMAND = comms.UNIT_COMMAND
local FAC_COMMAND = comms.FAC_COMMAND

local AUTO_GROUP = types.AUTO_GROUP
local WASTE_MODE = types.WASTE_MODE

local SV_Q_DATA = svqtypes.SV_Q_DATA

-- constantes de tempo de repetição em ms
-- local INITIAL_WAIT = 1500
local RETRY_PERIOD = 1000
local PARTIAL_RETRY_PERIOD = 2000

local CRD_S_CMDS = {
}

local CRD_S_DATA = {
    CMD_ACK = 1,
    RESEND_PLC_BUILD = 2,
    RESEND_RTU_BUILD = 3
}

coordinator.CRD_S_CMDS = CRD_S_CMDS
coordinator.CRD_S_DATA = CRD_S_DATA

local PERIODICS = {
    KEEP_ALIVE = 2000,
    STATUS = 500
}

-- sessão do supervisor do coordenador
---@nodiscard
---@param id integer session ID
---@param s_addr integer device source address
---@param i_seq_num integer initial sequence number
---@param in_queue mqueue in message queue
---@param out_queue mqueue out message queue
---@param timeout number communications timeout
---@param facility facility facility data table
---@param fp_ok boolean if the front panel UI is running
function coordinator.new_session(id, s_addr, i_seq_num, in_queue, out_queue, timeout, facility, fp_ok)
    -- imprimir uma mensagem de log no terminal enquanto a UI não estiver em execução
    local function println(message) if not fp_ok then util.println_ts(message) end end

    local log_tag = "crdn_session(" .. id .. "): "

    local self = {
        units = facility.get_units(),
        -- propriedades da conexão
        seq_num = i_seq_num + 2, -- próximo após o envio da aprovação de estabelecimento
        r_seq_num = i_seq_num + 1,
        connected = true,
        conn_watchdog = util.new_watchdog(timeout),
        establish_time = util.time_s(),
        last_rtt = 0,
        -- mensagens periódicas
        periodics = {
            last_update = 0,
            keep_alive = 0,
            status_packet = 0
        },
        -- quando tentar novamente uma dessas mensagens
        retry_times = {
            builds_packet = 0,
            f_builds_packet = 0,
            u_builds_packet = 0
        },
        -- confirmações de mensagens
        acks = {
            builds = false,
            fac_builds = false,
            unit_builds = false
        }
    }

    -- marcar esta sessão do coordenador como fechada, parar o watchdog
    local function _close()
        self.conn_watchdog.cancel()
        self.connected = false
        databus.tx_crd_disconnected()
    end

    -- enviar um pacote CRDN
    ---@param msg_type CRDN_TYPE
    ---@param msg table
    local function _send(msg_type, msg)
        local frame, crdn = comms.scada_frame(), comms.crdn_container()

        crdn.make(msg_type, msg)
        frame.make(s_addr, self.seq_num, PROTOCOL.SCADA_CRDN, crdn.raw_packet())

        out_queue.push_network(frame)
        self.seq_num = self.seq_num + 1
    end

    -- enviar um pacote de gerenciamento SCADA
    ---@param msg_type MGMT_TYPE
    ---@param msg table
    local function _send_mgmt(msg_type, msg)
        local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

        mgmt.make(msg_type, msg)
        frame.make(s_addr, self.seq_num, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

        out_queue.push_network(frame)
        self.seq_num = self.seq_num + 1
    end

    -- enviar as builds da instalação e das unidades
    local function _send_all_builds()
        local unit_builds = {}

        for i = 1, #self.units do
            local unit = self.units[i]
            unit_builds[unit.get_id()] = unit.get_build()
        end

        _send(CRDN_TYPE.INITIAL_BUILDS, { facility.get_build(), unit_builds })
    end

    -- enviar as builds da instalação
    local function _send_fac_builds()
        _send(CRDN_TYPE.FAC_BUILDS, { facility.get_build() })
    end

    -- enviar as builds das unidades
    local function _send_unit_builds()
        local builds = {}

        for i = 1, #self.units do
            local unit = self.units[i]
            builds[unit.get_id()] = unit.get_build()
        end

        _send(CRDN_TYPE.UNIT_BUILDS, { builds })
    end

    -- enviar o status da instalação
    local function _send_fac_status()
        local status = {
            facility.get_control_status(),
            facility.get_rtu_statuses(),
            facility.get_alarm_tones(),
            facility.get_valves()
        }

        _send(CRDN_TYPE.FAC_STATUS, status)
    end

    -- enviar os status das unidades
    local function _send_unit_statuses()
        local status = {}

        for i = 1, #self.units do
            local unit = self.units[i]

            status[unit.get_id()] = {
                unit.get_reactor_status(),
                unit.get_rtu_statuses(),
                unit.get_annunciator(),
                unit.get_alarms(),
                unit.get_state(),
                unit.get_valves()
            }
        end

        _send(CRDN_TYPE.UNIT_STATUSES, status)
    end

    -- tratar um pacote
    ---@param pkt mgmt_packet|crdn_packet
    local function _handle_packet(pkt)
        -- verificar o número de sequência
        if self.r_seq_num ~= pkt.scada_frame.seq_num() then
            log.warning(log_tag .. "sequência fora de ordem: próximo =  " .. self.r_seq_num .. ", novo = " .. pkt.scada_frame.seq_num())
            return
        else
            self.r_seq_num = pkt.scada_frame.seq_num() + 1
        end

        -- alimentar o watchdog
        self.conn_watchdog.feed()

        -- processar pacote
        if pkt.scada_frame.protocol() == PROTOCOL.SCADA_MGMT then
            ---@cast pkt mgmt_packet
            if pkt.type == MGMT_TYPE.KEEP_ALIVE then
                -- resposta de keep alive
                if pkt.length == 2 then
                    local srv_start = pkt.data[1]
                    -- local crd_send = pkt.data[2]
                    local srv_now = util.time()
                    self.last_rtt = srv_now - srv_start

                    if self.last_rtt > 750 then
                        log.warning(log_tag .. "CRD KEEP_ALIVE tempo de ida e volta > 750ms (" .. self.last_rtt .. "ms)")
                    end

                    -- log.debug(log_tag .. "CRD RTT = " .. self.last_rtt .. "ms")
                    -- log.debug(log_tag .. "CRD TT  = " .. (srv_now - crd_send) .. "ms")

                    databus.tx_crd_rtt(self.last_rtt)
                else
                    log.debug(log_tag .. "tamanho do pacote de keep alive SCADA incompatível")
                end
            elseif pkt.type == MGMT_TYPE.CLOSE then
                -- fechar a sessão
                _close()
            elseif pkt.type == MGMT_TYPE.SWITCH_NET then
                -- solicitação para trocar a rede, passou na verificação do ID de sequência
                log.debug(log_tag .. "solicitação válida de troca de conexão recebida")
            elseif pkt.type == MGMT_TYPE.ESTABLISH then
                -- algo está errado, encerrar a sessão
                _close()
                log.warning(log_tag .. "sessão encerrada devido a um pacote ESTABLISH inesperado")
            else
                log.debug(log_tag .. "tratador recebeu tipo de pacote SCADA_MGMT não suportado " .. pkt.type)
            end
        elseif pkt.scada_frame.protocol() == PROTOCOL.SCADA_CRDN then
            ---@cast pkt crdn_packet
            if pkt.type == CRDN_TYPE.INITIAL_BUILDS then
                -- confirmação de que o coordenador recebeu as builds
                self.acks.builds = true
            elseif pkt.type == CRDN_TYPE.PROCESS_READY then
                if pkt.length == 7 then
                    -- o coordenador enviou todos os dados iniciais do processo, a recuperação ao ligar agora é possível

                    ---@type start_auto_config
                    local config = {
                        mode = pkt.data[1],
                        burn_target = pkt.data[2],
                        range_start = pkt.data[3],
                        range_stop = pkt.data[4],
                        charge_target = pkt.data[5],
                        gen_target = pkt.data[6],
                        limits = pkt.data[7]
                    }

                    facility.boot_recovery_start(config)
                else
                    log.debug(log_tag .. "tamanho do pacote CRDN de processo pronto incompatível")
                end
            elseif pkt.type == CRDN_TYPE.FAC_BUILDS then
                -- confirmação de que o coordenador recebeu as builds
                self.acks.fac_builds = true
            elseif pkt.type == CRDN_TYPE.FAC_CMD then
                if pkt.length >= 1 then
                    local cmd = pkt.data[1]

                    if cmd == FAC_COMMAND.SCRAM_ALL then
                        facility.scram_all()
                        facility.cancel_recovery()
                        _send(CRDN_TYPE.FAC_CMD, { cmd, true })
                    elseif cmd == FAC_COMMAND.STOP then
                        facility.cancel_recovery()

                        local was_active = facility.auto_is_active()

                        if was_active then
                            facility.auto_stop()
                        end

                        _send(CRDN_TYPE.FAC_CMD, { cmd, was_active })
                    elseif cmd == FAC_COMMAND.START then
                        facility.cancel_recovery()

                        if pkt.length == 8 then
                            ---@class start_auto_config
                            local config = {
                                mode = pkt.data[2],          ---@type PROCESS
                                burn_target = pkt.data[3],   ---@type number
                                range_start = pkt.data[4],   ---@type integer
                                range_stop = pkt.data[5],    ---@type integer
                                charge_target = pkt.data[6], ---@type number
                                gen_target = pkt.data[7],    ---@type number
                                limits = pkt.data[8]         ---@type number[]
                            }

                            _send(CRDN_TYPE.FAC_CMD, { cmd, table.unpack(facility.auto_start(config)) })
                        else
                            log.debug(log_tag .. "tamanho do pacote CRDN de início automático (com configuração) incompatível")
                        end
                    elseif cmd == FAC_COMMAND.ACK_ALL_ALARMS then
                        facility.ack_all()
                        _send(CRDN_TYPE.FAC_CMD, { cmd, true })
                    elseif cmd == FAC_COMMAND.SET_WASTE_MODE then
                        if pkt.length == 2 then
                            _send(CRDN_TYPE.FAC_CMD, { cmd, facility.set_waste_product(pkt.data[2]) })
                        else
                            log.debug(log_tag .. "tamanho do pacote CRDN de definir modo de resíduos incompatível")
                        end
                    elseif cmd == FAC_COMMAND.SET_PU_FB then
                        if pkt.length == 2 then
                            _send(CRDN_TYPE.FAC_CMD, { cmd, facility.set_pu_fallback(pkt.data[2] == true) })
                        else
                            log.debug(log_tag .. "tamanho do pacote CRDN de definir fallback de Pu incompatível")
                        end
                    elseif cmd == FAC_COMMAND.SET_SPS_LP then
                        if pkt.length == 2 then
                            _send(CRDN_TYPE.FAC_CMD, { cmd, facility.set_sps_low_power(pkt.data[2] == true) })
                        else
                            log.debug(log_tag .. "tamanho do pacote CRDN de definir baixa energia do SPS incompatível")
                        end
                    else
                        log.debug(log_tag .. "comando de instalação CRDN desconhecido")
                    end
                else
                    log.debug(log_tag .. "tamanho do pacote de comando de instalação CRDN incompatível")
                end
            elseif pkt.type == CRDN_TYPE.UNIT_BUILDS then
                -- confirmação de que o coordenador recebeu as builds
                self.acks.unit_builds = true
            elseif pkt.type == CRDN_TYPE.UNIT_CMD then
                if pkt.length >= 2 then
                    -- obter comando e ID da unidade
                    local cmd = pkt.data[1]
                    local uid = pkt.data[2]

                    -- pkt.data[3] será nil, exceto para alguns comandos
                    local data = { uid, pkt.data[3] }

                    -- continuar se o ID da unidade for válido
                    if util.is_int(uid) and uid > 0 and uid <= #self.units then
                        local unit   = self.units[uid]
                        local manual = facility.get_group(uid) == AUTO_GROUP.MANUAL

                        if cmd == UNIT_COMMAND.SCRAM then
                            facility.cancel_recovery()
                            out_queue.push_data(SV_Q_DATA.SCRAM, data)
                        elseif cmd == UNIT_COMMAND.START then
                            facility.cancel_recovery()

                            if manual then
                                out_queue.push_data(SV_Q_DATA.START, data)
                            else
                                -- negado
                                _send(CRDN_TYPE.UNIT_CMD, { cmd, uid, false })
                            end
                        elseif cmd == UNIT_COMMAND.RESET_RPS then
                            out_queue.push_data(SV_Q_DATA.RESET_RPS, data)
                        elseif cmd == UNIT_COMMAND.SET_BURN then
                            facility.cancel_recovery()

                            if pkt.length == 3 then
                                if manual then
                                    out_queue.push_data(SV_Q_DATA.SET_BURN, data)
                                end
                            else
                                log.debug(log_tag .. "comando de unidade CRDN de taxa de queima sem opção")
                            end
                        elseif cmd == UNIT_COMMAND.SET_WASTE then
                            if (pkt.length == 3) and (type(pkt.data[3]) == "number") and
                               (pkt.data[3] >= WASTE_MODE.AUTO) and (pkt.data[3] <= WASTE_MODE.MANUAL_ANTI_MATTER) then
                                unit.set_waste_mode(pkt.data[3])
                            else
                                log.debug(log_tag .. "comando de unidade CRDN de definir resíduos com opção ausente/inválida")
                            end
                        elseif cmd == UNIT_COMMAND.ACK_ALL_ALARMS then
                            unit.ack_all()
                            _send(CRDN_TYPE.UNIT_CMD, { cmd, uid, true })
                        elseif cmd == UNIT_COMMAND.ACK_ALARM then
                            if pkt.length == 3 then
                                unit.ack_alarm(pkt.data[3])
                            else
                                log.debug(log_tag .. "comando de unidade CRDN de confirmar alarme sem ID do alarme")
                            end
                        elseif cmd == UNIT_COMMAND.RESET_ALARM then
                            if pkt.length == 3 then
                                unit.reset_alarm(pkt.data[3])
                            else
                                log.debug(log_tag .. "comando de unidade CRDN de resetar alarme sem ID do alarme")
                            end
                        elseif cmd == UNIT_COMMAND.SET_GROUP then
                            facility.cancel_recovery()

                            if (pkt.length == 3) and (type(pkt.data[3]) == "number") and
                               (pkt.data[3] >= AUTO_GROUP.MANUAL) and (pkt.data[3] <= AUTO_GROUP.BACKUP) then
                                facility.set_group(unit.get_id(), pkt.data[3])
                            else
                                log.debug(log_tag .. "comando de unidade CRDN de definir grupo sem ID do grupo")
                            end
                        else
                            log.debug(log_tag .. "comando de unidade CRDN desconhecido")
                        end
                    else
                        log.debug(log_tag .. "comando de unidade CRDN inválido")
                    end
                else
                    log.debug(log_tag .. "tamanho do pacote de comando de unidade CRDN incompatível")
                end
            else
                log.debug(log_tag .. "tratador recebeu tipo de pacote SCADA_CRDN inesperado " .. pkt.type)
            end
        end
    end

    ---@class crd_session
    local public = {}

    -- obter o ID da sessão
    ---@nodiscard
    function public.get_id() return id end

    -- verificar se um timer corresponde ao watchdog desta sessão
    ---@nodiscard
    function public.check_wd(timer)
        return self.conn_watchdog.is_timer(timer) and self.connected
    end

    -- fechar a conexão
    function public.close()
        _close()
        _send_mgmt(MGMT_TYPE.CLOSE, {})
        println("conexão com o coordenador " .. id .. " fechada pelo servidor")
        log.info(log_tag .. "sessão fechada pelo servidor")
    end

    -- iterar a sessão
    ---@nodiscard
    ---@return boolean connected
    function public.iterate()
        if self.connected then
            ------------------
            -- tratar fila --
            ------------------

            local handle_start = util.time()

            while in_queue.ready() and self.connected do
                -- obter uma nova mensagem para processar
                local message = in_queue.pop()

                if message ~= nil then
                    if message.qtype == mqueue.TYPE.NETWORK then
                        -- tratar um pacote
                        _handle_packet(message.message)
                    elseif message.qtype == mqueue.TYPE.DATA then
                        -- instrução com corpo
                        local cmd = message.message ---@type queue_data

                        if cmd.key == CRD_S_DATA.CMD_ACK then
                            local ack = cmd.val ---@type coord_ack
                            _send(CRDN_TYPE.UNIT_CMD, { ack.cmd, ack.unit, ack.ack })
                        elseif cmd.key == CRD_S_DATA.RESEND_PLC_BUILD then
                            -- reenviar build do PLC
                            -- a lógica de repetição será mantida como está, então, desde que nenhuma repetição seja necessária, esta será uma pequena atualização
                            self.retry_times.builds_packet = util.time() + PARTIAL_RETRY_PERIOD
                            self.acks.unit_builds = false

                            local unit_id = cmd.val
                            local builds = {}

                            builds[unit_id] = self.units[unit_id].get_build(-1)

                            _send(CRDN_TYPE.UNIT_BUILDS, { builds })
                        elseif cmd.key == CRD_S_DATA.RESEND_RTU_BUILD then
                            local unit_id = cmd.val.unit
                            if unit_id > 0 then
                                -- reenviar builds das RTUs das unidades
                                -- a lógica de repetição será mantida como está, então, desde que nenhuma repetição seja necessária, esta será uma pequena atualização
                                self.retry_times.u_builds_packet = util.time() + PARTIAL_RETRY_PERIOD
                                self.acks.unit_builds = false

                                local builds = {}

                                builds[unit_id] = self.units[unit_id].get_build(cmd.val.type)

                                _send(CRDN_TYPE.UNIT_BUILDS, { builds })
                            else
                                -- reenviar builds das RTUs da instalação
                                -- a lógica de repetição será mantida como está, então, desde que nenhuma repetição seja necessária, esta será uma pequena atualização
                                self.retry_times.f_builds_packet = util.time() + PARTIAL_RETRY_PERIOD
                                self.acks.fac_builds = false

                                _send(CRDN_TYPE.FAC_BUILDS, { facility.get_build(cmd.val.type) })
                            end
                        else
                            log.error(log_tag .. "comando de dados não suportado recebido em in_queue (isto é um bug)", true)
                        end
                    end
                end

                -- máximo de 100ms gastos processando a fila
                if util.time() - handle_start > 100 then
                    log.warning(log_tag .. "limite de 100ms de processamento da fila excedido")
                    break
                end
            end

            -- sair se a conexão foi fechada
            if not self.connected then
                println("conexão com o coordenador fechada pelo host remoto")
                log.info(log_tag .. "sessão fechada pelo host remoto")
                return self.connected
            end

            ----------------------
            -- atualizar periódicos --
            ----------------------

            local elapsed = util.time() - self.periodics.last_update

            local periodics = self.periodics

            -- keep alive

            periodics.keep_alive = periodics.keep_alive + elapsed
            if periodics.keep_alive >= PERIODICS.KEEP_ALIVE then
                _send_mgmt(MGMT_TYPE.KEEP_ALIVE, { util.time() })
                periodics.keep_alive = 0
            end

            -- status para o coordenador

            periodics.status_packet = periodics.status_packet + elapsed
            if periodics.status_packet >= PERIODICS.STATUS then
                _send_fac_status()
                _send_unit_statuses()
                periodics.status_packet = 0
            end

            self.periodics.last_update = util.time()

            ---------------------
            -- tentar repetições --
            ---------------------

            local rtimes = self.retry_times

            -- repetições de pacotes de builds

            if not self.acks.builds then
                if rtimes.builds_packet - util.time() <= 0 then
                    _send_all_builds()
                    rtimes.builds_packet = util.time() + RETRY_PERIOD
                end
            end

            if not self.acks.fac_builds then
                if rtimes.f_builds_packet - util.time() <= 0 then
                    _send_fac_builds()
                    rtimes.f_builds_packet = util.time() + RETRY_PERIOD
                end
            end

            if not self.acks.unit_builds then
                if rtimes.u_builds_packet - util.time() <= 0 then
                    _send_unit_builds()
                    rtimes.u_builds_packet = util.time() + RETRY_PERIOD
                end
            end
        end

        return self.connected
    end

    return public
end

return coordinator
