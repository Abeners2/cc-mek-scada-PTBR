local audio   = require("scada-common.audio")
local comms   = require("scada-common.comms")
local ppm     = require("scada-common.ppm")
local log     = require("scada-common.log")
local types   = require("scada-common.types")
local util    = require("scada-common.util")

local themes  = require("graphics.themes")

local databus = require("rtu.databus")
local modbus  = require("rtu.modbus")

local rtu = {}

local PROTOCOL = comms.PROTOCOL
local DEVICE_TYPE = comms.DEVICE_TYPE
local ESTABLISH_ACK = comms.ESTABLISH_ACK
local MGMT_TYPE = comms.MGMT_TYPE
local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE

-- aguardar 5 segundos após iniciar uma solicitação de troca de rede antes de permitir o envio de mais,
-- o que evita solicitações duplicadas repetidas
local FAILOVER_GRACE_PERIOD_MS = 5000

---@type rtu_config
---@diagnostic disable-next-line: missing-fields
local config = {}

rtu.config = config

-- carregar a configuração da RTU
function rtu.load_config()
    if not settings.load("/rtu.settings") then return false end

    config.Peripherals = settings.get("Peripherals")
    config.Redstone = settings.get("Redstone")

    config.SpeakerVolume = settings.get("SpeakerVolume")

    config.WirelessModem = settings.get("WirelessModem")
    config.WiredModem = settings.get("WiredModem")
    config.PreferWireless = settings.get("PreferWireless")
    config.SVR_Channel = settings.get("SVR_Channel")
    config.RTU_Channel = settings.get("RTU_Channel")
    config.ConnTimeout = settings.get("ConnTimeout")
    config.TrustedRange = settings.get("TrustedRange")
    config.AuthKey = settings.get("AuthKey")

    config.LogMode = settings.get("LogMode")
    config.LogPath = settings.get("LogPath")
    config.LogDebug = settings.get("LogDebug")

    config.FrontPanelTheme = settings.get("FrontPanelTheme")
    config.ColorMode = settings.get("ColorMode")

    return rtu.validate_config(config)
end

-- validar uma configuração de gateway RTU
---@param cfg rtu_config
function rtu.validate_config(cfg)
    local cfv = util.new_validator()

    cfv.assert_type_num(cfg.SpeakerVolume)
    cfv.assert_range(cfg.SpeakerVolume, 0, 3)

    cfv.assert_type_bool(cfg.WirelessModem)
    cfv.assert((cfg.WiredModem == false) or (type(cfg.WiredModem) == "string"))
    cfv.assert(cfg.WirelessModem or (type(cfg.WiredModem) == "string"))
    cfv.assert_type_bool(cfg.PreferWireless)
    cfv.assert_channel(cfg.SVR_Channel)
    cfv.assert_channel(cfg.RTU_Channel)
    cfv.assert_type_num(cfg.ConnTimeout)
    cfv.assert_min(cfg.ConnTimeout, 2)
    cfv.assert_type_num(cfg.TrustedRange)
    cfv.assert_min(cfg.TrustedRange, 0)
    cfv.assert_type_str(cfg.AuthKey)

    if type(cfg.AuthKey) == "string" then
        local len = string.len(cfg.AuthKey)
        cfv.assert(len == 0 or len >= 8)
    end

    cfv.assert_type_int(cfg.LogMode)
    cfv.assert_range(cfg.LogMode, 0, 1)
    cfv.assert_type_str(cfg.LogPath)
    cfv.assert_type_bool(cfg.LogDebug)

    cfv.assert_type_int(cfg.FrontPanelTheme)
    cfv.assert_range(cfg.FrontPanelTheme, 1, 2)
    cfv.assert_type_int(cfg.ColorMode)
    cfv.assert_range(cfg.ColorMode, 1, themes.COLOR_MODE.NUM_MODES)

    cfv.assert_type_table(cfg.Peripherals)
    cfv.assert_type_table(cfg.Redstone)

    return cfv.valid()
end

-- criar uma nova unidade RTU<br>
-- se isto for para um periférico PPM, a limpeza automática de falhas DEVE permanecer ativada assim que o acesso começar
---@nodiscard
---@param device ppm_generic|nil dispositivo periférico, se aplicável
function rtu.init_unit(device)
    local self = {
        discrete_inputs = {},
        coils = {},
        input_regs = {},
        holding_regs = {},
        io_count_cache = { 0, 0, 0, 0 }
    }

    local insert = table.insert

    local stub = function () log.warning("tentativa de chamar um stub de função da RTU") end

    ---@class rtu_device
    local public = {}

    ---@class rtu
    local protected = {}

    -- função para verificar se o periférico (se existir) está com falha
    local function _is_faulted() return false end
    if device then _is_faulted = device.__p_is_faulted end

    -- atualizar contagem de E/S
    local function _count_io()
        self.io_count_cache = { #self.discrete_inputs, #self.coils, #self.input_regs, #self.holding_regs }
    end

    -- retornar contagem de E/S
    ---@return integer discrete_inputs, integer coils, integer input_regs, integer holding_regs
    function public.io_count()
        return self.io_count_cache[1], self.io_count_cache[2], self.io_count_cache[3], self.io_count_cache[4]
    end

    -- passar uma função adiante ou gerar uma para chamar uma função pelo nome a partir do dispositivo
    ---@param f function|string função ou nome da função do dispositivo
    local function _as_func(f)
        if type(f) == "string" then
            local name = f
            if device then
                f = function (...) return device[name](...) end
            else f = stub end
        end

        return f
    end

    -- entradas discretas: bit único somente leitura

    -- conectar entrada discreta
    ---@param f function|string função ou nome da função
    ---@return integer count quantidade de entradas discretas
    function protected.connect_di(f)
        insert(self.discrete_inputs, { read = _as_func(f) })
        _count_io()
        return #self.discrete_inputs
    end

    -- ler entrada discreta
    ---@param di_addr integer
    ---@return any value, boolean access_fault
    function public.read_di(di_addr)
        local value = self.discrete_inputs[di_addr].read()
        return value, _is_faulted()
    end

    -- bobinas: bit único leitura-escrita

    -- conectar bobina
    ---@param f_read function|string função ou nome da função
    ---@param f_write function|string função ou nome da função
    ---@return integer count quantidade de bobinas
    function protected.connect_coil(f_read, f_write)
        insert(self.coils, { read = _as_func(f_read), write = _as_func(f_write) })
        _count_io()
        return #self.coils
    end

    -- ler bobina
    ---@param coil_addr integer
    ---@return any value, boolean access_fault
    function public.read_coil(coil_addr)
        local value = self.coils[coil_addr].read()
        return value, _is_faulted()
    end

    -- escrever na bobina
    ---@param coil_addr integer
    ---@param value any
    ---@return boolean access_fault
    function public.write_coil(coil_addr, value)
        self.coils[coil_addr].write(value)
        return _is_faulted()
    end

    -- registradores de entrada: múltiplos bits somente leitura

    -- conectar registrador de entrada
    ---@param f function|string função ou nome da função
    ---@return integer count quantidade de registradores de entrada
    function protected.connect_input_reg(f)
        insert(self.input_regs, { read = _as_func(f) })
        _count_io()
        return #self.input_regs
    end

    -- ler registrador de entrada
    ---@param reg_addr integer
    ---@return any value, boolean access_fault
    function public.read_input_reg(reg_addr)
        local value = self.input_regs[reg_addr].read()
        return value, _is_faulted()
    end

    -- registradores de retenção: múltiplos bits leitura-escrita

    -- conectar registrador de retenção
    ---@param f_read function|string função ou nome da função
    ---@param f_write function|string função ou nome da função
    ---@return integer count quantidade de registradores de retenção
    function protected.connect_holding_reg(f_read, f_write)
        insert(self.holding_regs, { read = _as_func(f_read), write = _as_func(f_write) })
        _count_io()
        return #self.holding_regs
    end

    -- ler registrador de retenção
    ---@param reg_addr integer
    ---@return any value, boolean access_fault
    function public.read_holding_reg(reg_addr)
        local value = self.holding_regs[reg_addr].read()
        return value, _is_faulted()
    end

    -- escrever no registrador de retenção
    ---@param reg_addr integer
    ---@param value any
    ---@return boolean access_fault
    function public.write_holding_reg(reg_addr, value)
        self.holding_regs[reg_addr].write(value)
        return _is_faulted()
    end

    -- acesso público ao dispositivo RTU

    -- obter a interface pública para esta RTU
    function protected.interface() return public end

    return protected
end

-- criar um sinalizador sonoro de alto-falante de alarme
---@param speaker Speaker periférico do dispositivo
function rtu.init_sounder(speaker)
    ---@class rtu_speaker_sounder
    local spkr_ctl = {
        speaker = speaker,
        name = ppm.get_iface(speaker),
        playing = false,
        stream = audio.new_stream(),
        play = function () end,
        stop = function () end,
        continue = function () end
    }

    -- continuar fluxo de áudio se estiver reproduzindo
    function spkr_ctl.continue()
        if spkr_ctl.playing then
            if spkr_ctl.speaker ~= nil and spkr_ctl.stream.has_next_block() then
                local success = spkr_ctl.speaker.playAudio(spkr_ctl.stream.get_next_block(), config.SpeakerVolume)
                if not success then log.error(util.c("rtu_sounder(", spkr_ctl.name, "): erro ao reproduzir áudio")) end
            end
        end
    end

    -- iniciar reprodução do fluxo de áudio
    function spkr_ctl.play()
        if not spkr_ctl.playing then
            spkr_ctl.playing = true
            return spkr_ctl.continue()
        end
    end

    -- parar reprodução do fluxo de áudio
    function spkr_ctl.stop()
        spkr_ctl.playing = false
        spkr_ctl.speaker.stop()
        spkr_ctl.stream.stop()
    end

    return spkr_ctl
end

-- Comunicações da RTU
---@nodiscard
---@param version string versão da RTU
---@param backplane rtu_backplane backplane da RTU
---@param conn_watchdog watchdog referência do watchdog
function rtu.comms(version, backplane, conn_watchdog)
    local self = {
        sv_addr = comms.BROADCAST,
        seq_num = util.time_ms() * 10, -- único por par, reiniciar não reutilizará números de sequência devido à taxa de mensagens
        r_seq_num = nil,               ---@type nil|integer
        txn_id = 0,
        failover_init = 0,
        last_est_ack = ESTABLISH_ACK.ALLOW
    }

    local insert = table.insert

    local tx_nic = backplane.active_nic()

    if config.WirelessModem then
        comms.set_trusted_range(config.TrustedRange)
    end

    --#region FUNÇÕES PRIVADAS --

    -- enviar um pacote de gerenciamento SCADA
    ---@param msg_type MGMT_TYPE
    ---@param msg table
    local function _send(msg_type, msg)
        local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

        mgmt.make(msg_type, msg)
        frame.make(self.sv_addr, self.seq_num, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

        tx_nic.transmit(config.SVR_Channel, config.RTU_Channel, frame)
        self.seq_num = self.seq_num + 1
    end

    -- confirmação de manutenção de conexão (keep alive ack)
    ---@param srv_time integer
    local function _send_keep_alive_ack(srv_time)
        _send(MGMT_TYPE.KEEP_ALIVE, { srv_time, util.time() })
    end

    -- gerar tabela de anúncio de dispositivos
    ---@nodiscard
    ---@param units rtu_registry_entry[]
    ---@return rtu_advert_msg advertisement
    local function _generate_advertisement(units)
        local advertisement = {}

        for i = 1, #units do
            local unit = units[i]

            if unit.type ~= nil then
                insert(advertisement, { unit.type, unit.index, unit.reactor or -1, unit.rs_conns })
            end
        end

        return advertisement
    end

    --#endregion

    --#region FUNÇÕES PÚBLICAS --

    ---@class rtu_comms
    local public = {}

    -- trocar a NIC ativa atual
    ---@param new_nic nic
    ---@param rtu_state rtu_state
    function public.switch_nic(new_nic, rtu_state)
        if tx_nic.is_connected() then
            -- tentar trocar graciosamente, temos uma conexão contínua intacta
            log.info(util.c("alternando link para a interface reconectada ", new_nic.phy_name(), " de ", tx_nic.phy_name()))

            tx_nic = new_nic
            _send(MGMT_TYPE.SWITCH_NET, {})
        else
            -- não é possível trocar graciosamente, a outra NIC foi perdida
            log.info(util.c("fechando link em ", tx_nic.phy_name(), ", alternando para ", new_nic.phy_name()))

            tx_nic = new_nic
            conn_watchdog.cancel()
            public.unlink(rtu_state)
        end
    end

    -- verificar se a NIC fornecida está ativa no momento e, se não estiver, voltar para ela
    ---@param act_nic nic
    function public.manage_failover(act_nic)
        if (act_nic ~= tx_nic) and act_nic.is_network_up() and ((util.time_ms() - self.failover_init) > FAILOVER_GRACE_PERIOD_MS) then
            log.info(util.c("interface primária ", act_nic.phy_name(), " está ativa, solicitando troca de link"))

            tx_nic = act_nic
            _send(MGMT_TYPE.SWITCH_NET, {})

            self.failover_init = util.time_ms()
        end
    end

    -- desvincular do servidor
    ---@param rtu_state rtu_state
    function public.unlink(rtu_state)
        rtu_state.linked = false
        self.sv_addr = comms.BROADCAST
        self.r_seq_num = nil
        databus.tx_link_state(types.PANEL_LINK_STATE.DISCONNECTED)
    end

    -- fechar a conexão com o servidor
    ---@param rtu_state rtu_state
    function public.close(rtu_state)
        conn_watchdog.cancel()
        _send(MGMT_TYPE.CLOSE, {})
        public.unlink(rtu_state)
    end

    -- enviar um pacote MODBUS TCP
    ---@param m_cnt modbus_container
    function public.send_modbus(m_cnt)
        local frame = comms.scada_frame()

        frame.make(self.sv_addr, self.seq_num, PROTOCOL.MODBUS_TCP, m_cnt.raw_packet())

        tx_nic.transmit(config.SVR_Channel, config.RTU_Channel, frame)
        self.seq_num = self.seq_num + 1
    end

    -- enviar solicitação de estabelecimento (inclui anúncio)
    ---@param units rtu_registry_entry[]
    function public.send_establish(nic, units)
        local ini_nic = tx_nic
        tx_nic = nic

        self.r_seq_num = nil
        _send(MGMT_TYPE.ESTABLISH, { comms.version, version, DEVICE_TYPE.RTU, _generate_advertisement(units) })

        tx_nic = ini_nic
    end

    -- enviar anúncio de capacidades
    ---@param units rtu_registry_entry[]
    function public.send_advertisement(units)
        _send(MGMT_TYPE.RTU_ADVERT, _generate_advertisement(units))
    end

    -- notificar que um periférico foi remontado
    ---@param unit_index integer ID da unidade RTU
    function public.send_remounted(unit_index)
        _send(MGMT_TYPE.RTU_DEV_REMOUNT, { unit_index })
    end

    -- analisar um pacote MODBUS/SCADA
    ---@nodiscard
    ---@param side string
    ---@param sender integer
    ---@param reply_to integer
    ---@param message any
    ---@param distance integer
    ---@return modbus_adu|mgmt_packet|nil packet
    function public.parse_packet(side, sender, reply_to, message, distance)
        local pkt, nic = nil, backplane.nics[side]

        if nic then
            local frame = nic.receive(side, sender, reply_to, message, distance)

            if frame then
                if frame.protocol() == PROTOCOL.MODBUS_TCP then
                    pkt = comms.modbus_container().decode(frame)
                elseif frame.protocol() == PROTOCOL.SCADA_MGMT then
                    pkt = comms.mgmt_container().decode(frame)
                else
                    log.debug("tipo de pacote ilegal " .. frame.protocol(), true)
                end
            end
        else
            log.error("parse_packet(" .. side .. "): pacote recebido de uma interface sem uma nic?")
        end

        return pkt
    end

    -- tratar um pacote MODBUS/SCADA
    ---@param packet modbus_adu|mgmt_packet
    ---@param units rtu_registry_entry[] entradas da RTU
    ---@param rtu_state rtu_state
    ---@param sounders rtu_speaker_sounder[] sinalizadores sonoros de alarme
    function public.handle_packet(packet, units, rtu_state, sounders)
        -- imprimir uma mensagem de log no terminal desde que a UI não esteja em execução
        local function println_ts(message) if not rtu_state.fp_ok then util.println_ts(message) end end

        local protocol = packet.scada_frame.protocol()
        local l_chan   = packet.scada_frame.local_channel()
        local src_addr = packet.scada_frame.src_addr()

        if l_chan == config.RTU_Channel then
            -- verificar número de sequência
            if self.r_seq_num == nil then
                self.r_seq_num = packet.scada_frame.seq_num() + 1
            elseif self.r_seq_num ~= packet.scada_frame.seq_num() then
                log.warning("sequência fora de ordem: próximo = " .. self.r_seq_num .. ", novo = " .. packet.scada_frame.seq_num())
                return
            elseif rtu_state.linked and (src_addr ~= self.sv_addr) then
                log.debug("pacote recebido de computador desconhecido " .. src_addr .. " enquanto vinculado (esperado " .. self.sv_addr ..
                            "); canal em uso por outro sistema?")
                return
            else
                self.r_seq_num = packet.scada_frame.seq_num() + 1
            end

            -- alimentar watchdog no número de sequência válido
            conn_watchdog.feed()

            -- tratar pacote
            if protocol == PROTOCOL.MODBUS_TCP then
                ---@cast packet modbus_adu
                if rtu_state.linked then
                    local return_code   ---@type boolean
                    local reply         ---@type modbus_container

                    -- tratar instrução MODBUS
                    if packet.unit_id <= #units then
                        local unit = units[packet.unit_id]
                        local unit_dbg_tag = " (unidade " .. packet.unit_id .. ")"

                        if unit.type == RTU_UNIT_TYPE.REDSTONE then
                            -- executar imediatamente solicitações de RTU de redstone
                            return_code, reply = unit.modbus_io.handle_adu(packet)

                            if not return_code then
                                log.warning("operação MODBUS solicitada falhou" .. unit_dbg_tag)
                            end
                        else
                            -- verificar validade e depois passar para a thread de comunicação da unidade
                            return_code, reply = unit.modbus_io.check_request(packet)
                            if return_code then
                                -- verificar se há mais de 3 transações ativas, o que será tratado como ocupado
                                if unit.pkt_queue.length() > 3 then
                                    reply = modbus.reply__srv_device_busy(packet)
                                    log.warning("dispositivo ocupado, descartando nova solicitação" .. unit_dbg_tag)
                                else
                                    -- enfileirar o comando se não estiver ocupado
                                    unit.pkt_queue.push_network(packet)
                                end
                            else
                                log.warning("operação MODBUS solicitada falhou" .. unit_dbg_tag)
                            end
                        end
                    else
                        -- ID da unidade fora do intervalo?
                        reply = modbus.reply__gw_unavailable(packet)
                        log.debug("pacote MODBUS recebido para unidade inexistente")
                    end

                    public.send_modbus(reply)
                else
                    log.debug("descartando pacote MODBUS antes de vincular")
                end
            elseif protocol == PROTOCOL.SCADA_MGMT then
                ---@cast packet mgmt_packet
                -- pacote de gerenciamento SCADA
                if rtu_state.linked then
                    if packet.type == MGMT_TYPE.KEEP_ALIVE then
                        -- solicitação de manutenção de conexão recebida, ecoar de volta
                        if packet.length == 1 and type(packet.data[1]) == "number" then
                            local timestamp = packet.data[1]
                            local trip_time = util.time() - timestamp

                            if trip_time > 750 then
                                log.warning("tempo de viagem KEEP_ALIVE da RTU > 750ms (" .. trip_time .. "ms)")
                            end

                            -- log.debug("RTT da RTU = " .. trip_time .. "ms")

                            _send_keep_alive_ack(timestamp)
                        else
                            log.debug("incompatibilidade de tamanho/tipo no pacote keep alive SCADA_MGMT")
                        end
                    elseif packet.type == MGMT_TYPE.CLOSE then
                        -- fechar conexão
                        conn_watchdog.cancel()
                        public.unlink(rtu_state)
                        println_ts("conexão com o servidor fechada pelo host remoto")
                        log.warning("conexão com o servidor fechada pelo host remoto")
                    elseif packet.type == MGMT_TYPE.RTU_ADVERT then
                        -- solicitação de capacidades novamente
                        public.send_advertisement(units)
                    elseif packet.type == MGMT_TYPE.RTU_TONE_ALARM then
                        -- atualização de tom de alarme do supervisor
                        if (packet.length == 1) and type(packet.data[1] == "table") and (#packet.data[1] == 8) then
                            local states = packet.data[1]

                            -- definir estados de tom
                            for i = 1, #sounders do
                                for id = 1, #states do sounders[i].stream.set_active(id, states[id] == true) end
                            end
                        end
                    else
                        -- não suportado
                        log.debug("tipo de mensagem SCADA_MGMT não suportado recebido " .. packet.type)
                    end
                elseif packet.type == MGMT_TYPE.ESTABLISH then
                    if packet.length == 1 then
                        local est_ack = packet.data[1]

                        if est_ack == ESTABLISH_ACK.ALLOW then
                            -- estabelecimento permitido
                            tx_nic = backplane.nics[packet.scada_frame.interface()]

                            rtu_state.linked = true
                            self.sv_addr = packet.scada_frame.src_addr()

                            println_ts("conexão com o supervisor estabelecida")
                            log.info(util.c("conexão com o supervisor estabelecida, vinculado ao SV (CID#", src_addr, ") em ", tx_nic.phy_name()))
                        else
                            -- estabelecimento negado
                            if est_ack ~= self.last_est_ack then
                                if est_ack == ESTABLISH_ACK.BAD_VERSION then
                                    -- incompatibilidade de versão
                                    println_ts("incompatibilidade de versão de comunicação do supervisor (tente atualizar), tentando novamente...")
                                    log.warning("conexão com o supervisor negada devido à incompatibilidade de versão de comunicação, tentando novamente")
                                else
                                    println_ts("conexão com o supervisor negada, tentando novamente...")
                                    log.warning("conexão com o supervisor negada, tentando novamente")
                                end
                            end

                            -- desvincular
                            self.sv_addr = comms.BROADCAST
                            rtu_state.linked = false
                        end

                        self.last_est_ack = est_ack

                        -- relatar estado do link
                        databus.tx_link_state(est_ack + 1)
                    else
                        log.debug("incompatibilidade de tamanho no pacote establish SCADA_MGMT")
                    end
                else
                    log.debug("descartando pacote SCADA_MGMT que não é de vinculação antes de estar vinculado")
                end
            else
                -- deve ser inalcançável assumindo que o pacote é de parse_packet()
                log.error("tipo de pacote ilegal " .. protocol, true)
            end
        else
            log.debug("pacote recebido em canal não configurado " .. l_chan, true)
        end
    end

    --#endregion

    return public
end

return rtu
