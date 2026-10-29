--
-- Backplane de Periféricos Principais do Sistema PLC do Reator
--

local log     = require("scada-common.log")
local network = require("scada-common.network")
local ppm     = require("scada-common.ppm")
local util    = require("scada-common.util")

local databus = require("reactor-plc.databus")

local println = util.println

---@class plc_backplane
local backplane = {}

local _bp = {
    smem = nil,     ---@type plc_shared_memory

    wlan_pref = true,
    lan_iface = "",

    act_nic = nil,  ---@type nic
    wd_nic = nil,   ---@type nic|nil
    wl_nic = nil,   ---@type nic|nil
    nic_map = {}    ---@type nic[] connected nics
}

local multi_reactor_warn = "BKPLN: NAO compartilhe conexoes de reator entre multiplos PLCs! eles podem nao estar todos protegidos e usados conforme configurado"

-- interfaces de rede indexadas por nomes de periféricos
backplane.nics = _bp.nic_map

-- inicializa o backplane de periféricos do sistema<br>
---@param config plc_config
---@param __shared_memory plc_shared_memory
--- EVENT_CONSUMER: this function consumes events
function backplane.init(config, __shared_memory)
    _bp.smem      = __shared_memory
    _bp.wlan_pref = config.PreferWireless
    _bp.lan_iface = config.WiredModem

    local plc_dev   = __shared_memory.plc_dev
    local plc_state = __shared_memory.plc_state

    plc_state.degraded = false

    -- Inicialização do Modem

    if _bp.smem.networked then
        -- inicializa a NIC cabeada
        if type(_bp.lan_iface) == "string" then
            local modem  = ppm.get_modem(_bp.lan_iface)
            local wd_nic = network.nic(modem, config.SVR_Channel)

            log.info("BKPLN: WIRED PHY_" .. util.trinary(modem, "UP ", "DOWN ") .. _bp.lan_iface)

            _bp.wd_nic  = wd_nic
            _bp.act_nic = wd_nic -- define esta como ativa por enquanto
            _bp.nic_map[_bp.lan_iface] = wd_nic

            wd_nic.closeAll()
            wd_nic.open(config.PLC_Channel)

            plc_state.wd_modem = wd_nic.is_connected()
        end

        -- inicializa a(s) NIC(s) sem fio
        if config.WirelessModem then
            local modem, iface = ppm.get_wireless_modem()
            local wl_nic       = network.nic(modem, config.SVR_Channel)

            log.info("BKPLN: WIRELESS PHY_" .. util.trinary(modem, "UP ", "DOWN") .. (iface or ""))

            -- define esta como ativa se estiver conectada ou se ambos os modems estiverem desconectados e esta for a preferida
            if (modem and _bp.wlan_pref) or not (_bp.act_nic and _bp.act_nic.is_connected()) then
                _bp.act_nic = wl_nic
                log.info("BKPLN: alternou ativa para sem fio preferida")
            end

            _bp.wl_nic = wl_nic
            if iface then _bp.nic_map[iface] = wl_nic end

            wl_nic.closeAll()
            wl_nic.open(config.PLC_Channel)

            plc_state.wl_modem = wl_nic.is_connected()
        end

        -- modem de comunicação é obrigatório se estiver em rede
        if not (plc_state.wd_modem or plc_state.wl_modem) then
            println("startup> nenhum modem de comunicacao encontrado")
            log.warning("BKPLN: nenhum modem de comunicacao na inicializacao")

            plc_state.degraded = true
        end
    end

    -- Inicialização do Reator

---@diagnostic disable-next-line: assign-type-mismatch
    plc_dev.reactor      = ppm.get_fission_reactor()
    plc_state.no_reactor = plc_dev.reactor == nil

    -- precisamos de um reator, mas pelo menos podemos fazer algumas coisas mesmo que não esteja formado
    if plc_state.no_reactor then
        log.info("BKPLN: REACTOR LINK_DOWN")

        println("startup> reator de fissao nao encontrado")
        log.warning("BKPLN: nenhum reator na inicializacao")

        plc_state.degraded = true
        plc_state.reactor_formed = false

        -- monta um periférico virtual para inicializar o RPS
        local _, dev = ppm.mount_virtual()
---@diagnostic disable-next-line: assign-type-mismatch
        plc_dev.reactor = dev

        log.info("BKPLN: montou dispositivo virtual como reator")
    else
        log.info("BKPLN: REACTOR LINK_UP " .. ppm.get_iface(plc_dev.reactor))

        if not plc_dev.reactor.isFormed() then
            println("startup> reator de fissao nao esta formado")
            log.warning("BKPLN: adaptador logico do reator detectado, mas o reator nao esta formado")

            plc_state.degraded = true
            plc_state.reactor_formed = false
        end
    end

    -- detecta e avisa sobre múltiplos reatores
    if #ppm.get_all_devices("fissionReactorLogicAdapter") > 1 then
        println("startup> !! PERIGO !! mais de um reator foi detectado! nao compartilhe conexoes de reator entre multiplos PLCs! eles podem nao estar todos protegidos e usados conforme configurado")

        log.warning("BKPLN: !! PERIGO !! mais de um reator foi detectado na inicializacao!")
        log.warning(multi_reactor_warn)

        databus.tx_multi_reactor(true)
    end
end

-- obtém a NIC ativa
function backplane.active_nic() return _bp.act_nic end

-- obtém a NIC de espera (standby)
---@return nic|nil
function backplane.standby_nic() return util.trinary(_bp.act_nic == _bp.wl_nic, _bp.wd_nic, _bp.wl_nic) end

-- tarefas periódicas de periféricos do backplane
function backplane.periodic()
    if _bp.wd_nic then databus.tx_wd_net(_bp.wd_nic.periodic()) end
    if _bp.wl_nic then databus.tx_wl_net(_bp.wl_nic.periodic()) end
end

-- trata a conexão de um periférico ao backplane
---@param iface string
---@param type string
---@param device ppm_generic
---@param print_no_fp function
function backplane.attach(iface, type, device, print_no_fp)
    local MQ__RPS_CMD = _bp.smem.q_types.MQ__RPS_CMD

    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local networked = _bp.smem.networked
    local state     = _bp.smem.plc_state
    local dev       = _bp.smem.plc_dev
    local sys       = _bp.smem.plc_sys

    if type ~= nil and device ~= nil then
        if type == "fissionReactorLogicAdapter" then
            ---@cast device FissionReactor

            if not state.no_reactor then
                log.warning("BKPLN: !! PERIGO !! um reator adicional (" .. iface .. ") foi conectado e nao sera usado!")
                log.warning(multi_reactor_warn)

                databus.tx_multi_reactor(true)
                return
            end

            -- reator reconectado
            log.info("BKPLN: REACTOR LINK_UP " .. iface)

            dev.reactor = device
            state.no_reactor = false

            print_no_fp("reator conectado")
            log.info("BKPLN: reator conectado")

            -- precisamos assumir que está formado aqui, pois não podemos verificar neste loop principal
            -- o RPS identificará se não estiver e isso será definido como false mais tarde
            state.reactor_formed = true

            -- determina se ainda estamos em um estado degradado
            if ((not networked) or (state.wd_modem or state.wl_modem)) and state.reactor_formed then
                state.degraded = false
            end

            sys.rps.reconnect_reactor(dev.reactor)
            if networked then
                sys.plc_comms.reconnect_reactor(dev.reactor)
            end

            -- redefinição parcial do RPS, específica para quando se torna formado/reconectado
            -- sem isso, o controle automático não pode retomar ao carregar o chunk
            _bp.smem.q.mq_rps.push_command(MQ__RPS_CMD.RESET_REATTACH)
        elseif networked and type == "modem" then
            ---@cast device Modem

            local m_is_wl = device.isWireless()

            log.info(util.c("BKPLN: ", util.trinary(m_is_wl, "WIRELESS", "WIRED"), " PHY_ATTACH ", iface))

            if wd_nic and (_bp.lan_iface == iface) then
                -- conecta este como a NIC cabeada
                wd_nic.connect(device)
                _bp.nic_map[iface] = wd_nic

                log.info("BKPLN: WIRED PHY_UP " .. iface)
                print_no_fp("modem de comunicacao cabeado conectado")

                state.wd_modem = true

                if (_bp.act_nic ~= wd_nic) and not _bp.wlan_pref then
                    -- volta para o cabeado preferido
                    _bp.act_nic = wd_nic

                    sys.plc_comms.switch_nic(_bp.act_nic)
                    log.info("BKPLN: alternou comunicacoes para modem cabeado (preferido)")
                end
            elseif wl_nic and (not wl_nic.is_connected()) and m_is_wl then
                -- conecta este como a NIC sem fio
                wl_nic.connect(device)
                _bp.nic_map[iface] = wl_nic

                log.info("BKPLN: WIRELESS PHY_UP " .. iface)
                print_no_fp("modem de comunicacao sem fio conectado")

                state.wl_modem = true

                if (_bp.act_nic ~= wl_nic) and _bp.wlan_pref then
                    -- volta para o sem fio preferido
                    _bp.act_nic = wl_nic

                    sys.plc_comms.switch_nic(_bp.act_nic)
                    log.info("BKPLN: alternou comunicacoes para modem sem fio (preferido)")
                end
            elseif wl_nic and m_is_wl then
                -- a NIC sem fio já possui um modem
                device.closeAll()

                print_no_fp("modem sem fio de espera conectado")
                log.info("BKPLN: modem sem fio de espera conectado")
            else
                device.closeAll()

                print_no_fp("modem nao atribuido conectado")
                log.warning("BKPLN: modem nao atribuido conectado")
            end

            -- determina se ainda estamos em um estado degradado
            if (state.wd_modem or state.wl_modem) and state.reactor_formed and not state.no_reactor then
                state.degraded = false
            end
        end
    end
end

-- trata a desconexão de um periférico do backplane
---@param iface string
---@param type string
---@param device ppm_generic
---@param print_no_fp function
function backplane.detach(iface, type, device, print_no_fp)
    local MQ__RPS_CMD = _bp.smem.q_types.MQ__RPS_CMD

    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local state = _bp.smem.plc_state
    local dev   = _bp.smem.plc_dev
    local sys   = _bp.smem.plc_sys

    if type == "fissionReactorLogicAdapter" then
        ---@cast device FissionReactor

        log.info("BKPLN: REACTOR LINK_DOWN " .. iface)

        -- detecta e avisa sobre múltiplos reatores
        if #ppm.get_all_devices("fissionReactorLogicAdapter") > 1 then
            log.warning("BKPLN: !! PERIGO !! mais de um reator ainda esta presente!")
            log.warning(multi_reactor_warn)

            databus.tx_multi_reactor(true)
        else databus.tx_multi_reactor(false) end

        -- se este for o reator ativo, trata isso
        if device == dev.reactor then
            print_no_fp("reator desconectado")
            log.warning("BKPLN: reator desconectado")

            state.no_reactor = true
            state.degraded = true

            -- tenta encontrar outro reator (isso não deve funcionar a menos que múltiplos tenham sido conectados incorretamente)
            local reactor, r_iface = ppm.get_fission_reactor()
            if reactor and r_iface then
                log.info("BKPLN: encontrou outro adaptador logico de reator de fissao")

                backplane.attach(r_iface, type, reactor, print_no_fp)
            end
        end
    elseif _bp.smem.networked and type == "modem" then
        ---@cast device Modem

        log.info(util.c("BKPLN: PHY_DETACH ", iface))

        _bp.nic_map[iface] = nil

        if wd_nic and wd_nic.is_modem(device) then
            wd_nic.disconnect()
            log.info("BKPLN: WIRED PHY_DOWN " .. iface)

            state.wd_modem = false
        elseif wl_nic and wl_nic.is_modem(device) then
            wl_nic.disconnect()
            log.info("BKPLN: WIRELESS PHY_DOWN " .. iface)

            state.wl_modem = false
        end

        -- só nos importamos se este for o nosso modem de comunicação ativo
        if _bp.act_nic.is_modem(device) then
            print_no_fp("modem de comunicacao ativo desconectado")
            log.warning("BKPLN: modem de comunicacao ativo desconectado")

            -- executa failover e tenta encontrar um novo modem de comunicação
            if _bp.act_nic == wl_nic then
                -- sem fio ativo desconectado
                -- tenta encontrar outro modem sem fio, caso contrário alterna para cabeado
                local modem, m_iface = ppm.get_wireless_modem()
                if wl_nic and modem then
                    log.info("BKPLN: encontrou outro modem sem fio, usando-o para comunicacoes")

                    wl_nic.connect(modem)

                    log.info("BKPLN: WIRELESS PHY_UP " .. m_iface)

                    state.wl_modem = true
                elseif wd_nic and wd_nic.is_connected() then
                    _bp.act_nic = wd_nic

                    sys.plc_comms.switch_nic(_bp.act_nic)
                    log.info("BKPLN: alternou comunicacoes para modem cabeado")
                else
                    -- nenhum outro modem sem fio, cabeado indisponível
                    state.degraded = true
                    _bp.smem.q.mq_rps.push_command(MQ__RPS_CMD.DEGRADED_SCRAM)
                end
            elseif wl_nic and wl_nic.is_connected() then
                -- cabeado ativo desconectado, sem fio disponível
                _bp.act_nic = wl_nic

                sys.plc_comms.switch_nic(_bp.act_nic)
                log.info("BKPLN: alternou comunicacoes para modem sem fio")
            else
                -- cabeado ativo desconectado, sem fio indisponível
                state.degraded = true
                _bp.smem.q.mq_rps.push_command(MQ__RPS_CMD.DEGRADED_SCRAM)
            end
        elseif wd_nic and wd_nic.is_modem(device) then
            -- cabeado, mas não ativo
            print_no_fp("modem cabeado de espera desconectado")
            log.info("BKPLN: modem cabeado de espera desconectado")
        elseif wl_nic and wl_nic.is_modem(device) then
            -- sem fio, mas não ativo
            print_no_fp("modem sem fio de espera desconectado")
            log.info("BKPLN: modem sem fio de espera desconectado")
        else
            print_no_fp("modem nao atribuido desconectado")
            log.warning("BKPLN: modem nao atribuido desconectado")
        end
    end
end

return backplane
