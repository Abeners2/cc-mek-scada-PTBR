--
-- Backplane de Periféricos Principais do Sistema Coordenador
--

local log         = require("scada-common.log")
local network     = require("scada-common.network")
local ppm         = require("scada-common.ppm")
local util        = require("scada-common.util")

local coordinator = require("coordinator.coordinator")
local ioctl       = require("coordinator.ioctl")
local sounder     = require("coordinator.sounder")

local println = util.println

local log_sys    = coordinator.log_sys
local log_boot   = coordinator.log_boot
local log_comms  = coordinator.log_comms

---@class crd_backplane
local backplane = {}

local _bp = {
    smem = nil,     ---@type crd_shared_memory

    wlan_pref = true,
    lan_iface = "",

    act_nic = nil,  ---@type nic
    wd_nic = nil,   ---@type nic|nil
    wl_nic = nil,   ---@type nic|nil
    nic_map = {},   ---@type nic[] connected nics

    speaker = nil,  ---@type Speaker|nil

    ---@class crd_displays
    displays = {
        main = nil,         ---@type Monitor|nil
        main_iface = "",
        flow = nil,         ---@type Monitor|nil
        flow_iface = "",
        unit_displays = {}, ---@type Monitor[]
        unit_ifaces = {}    ---@type string[]
    }
}

-- interfaces de rede indexadas por nomes de periféricos
backplane.nics = _bp.nic_map

-- inicializa o backplane de periféricos de exibição
---@param config crd_config
---@return boolean success, string error_msg
function backplane.init_displays(config)
    local displays = _bp.displays

    local w, h, _

    log.info("BKPLN: DISPLAY INIT")

    -- verificação de configuração dos monitores

    local mon_cfv = util.new_validator()

    mon_cfv.assert_type_str(config.MainDisplay)
    mon_cfv.assert_type_str(config.FlowDisplay)

    mon_cfv.assert_eq(#config.UnitDisplays, config.UnitCount)
    for i = 1, #config.UnitDisplays do
        mon_cfv.assert_type_str(config.UnitDisplays[i])
    end

    if not mon_cfv.valid() then
        return false, "Configuração de monitores inválida."
    end

    -- configura e verifica periféricos de exibição

    -- monitor principal

    local disp, iface = ppm.get_periph(config.MainDisplay), config.MainDisplay

    ---@cast disp Monitor
    displays.main = disp
    displays.main_iface = iface

    log.info("BKPLN: DISPLAY LINK_" .. util.trinary(disp, "UP", "DOWN") .. " MAIN/" .. iface)

    ioctl.fp_monitor_state("main", util.trinary(disp, 2, 1))

    if not disp then
        return false, "O monitor principal não está conectado."
    end

    disp.setTextScale(0.5)
    w, _ = ppm.monitor_block_size(disp.getSize())
    if w ~= 8 then
        log.info("BKPLN: DISPLAY MAIN/" .. iface .. " BAD RESOLUTION")
        return false, util.c("A largura do monitor principal está incorreta (era ", w, ", deve ser 8).")
    end

    -- monitor de fluxo

    disp, iface = ppm.get_periph(config.FlowDisplay), config.FlowDisplay

    ---@cast disp Monitor
    displays.flow = disp
    displays.flow_iface = iface

    log.info("BKPLN: DISPLAY LINK_" .. util.trinary(disp, "UP", "DOWN") .. " FLOW/" .. iface)

    ioctl.fp_monitor_state("flow", util.trinary(disp, 2, 1))

    if not disp then
        return false, "O monitor de fluxo não está conectado."
    end

    disp.setTextScale(0.5)
    w, _ = ppm.monitor_block_size(disp.getSize())
    if w ~= 8 then
        log.info("BKPLN: DISPLAY FLOW/" .. iface .. " BAD RESOLUTION")
        return false, util.c("A largura do monitor de fluxo está incorreta (era ", w, ", deve ser 8).")
    end

    -- monitor(es) de unidade

    for i = 1, config.UnitCount do
        disp, iface = ppm.get_periph(config.UnitDisplays[i]), config.UnitDisplays[i]

        ---@cast disp Monitor
        displays.unit_displays[i] = disp
        displays.unit_ifaces[i] = iface

        log.info("BKPLN: DISPLAY LINK_" .. util.trinary(disp, "UP", "DOWN") .. " UNIT_" .. i .. "/" .. iface)

        ioctl.fp_monitor_state(i, util.trinary(disp, 2, 1))

        if not disp then
            return false, "O monitor da Unidade " .. i .. " não está conectado."
        end

        disp.setTextScale(0.5)
        w, h = ppm.monitor_block_size(disp.getSize())
        if w ~= 4 or h ~= 4 then
            log.info("BKPLN: DISPLAY UNIT_" .. i .. "/" .. iface .. " BAD RESOLUTION")
            return false, util.c("O tamanho do monitor da Unidade ", i, " está incorreto (era ", w, " por ", h,", deve ser 4 por 4).")
        end
    end

    log.info("BKPLN: DISPLAY INIT OK")

    return true, ""
end

-- inicializa o backplane de periféricos do sistema
---@param config crd_config
---@param __shared_memory crd_shared_memory
---@return boolean success
function backplane.init(config, __shared_memory)
    _bp.smem      = __shared_memory
    _bp.wlan_pref = config.PreferWireless
    _bp.lan_iface = config.WiredModem

    -- Inicialização de Modems

    -- inicializa NIC cabeada
    if type(_bp.lan_iface) == "string" then
        local modem  = ppm.get_modem(_bp.lan_iface)
        local wd_nic = network.nic(modem, config.SVR_Channel)

        log.info("BKPLN: WIRED PHY_" .. util.trinary(modem, "UP ", "DOWN ") .. _bp.lan_iface)
        log_comms("modem de comunic. cabeado " .. util.trinary(modem, "conectado", "não encontrado"))

        _bp.wd_nic  = wd_nic
        _bp.act_nic = wd_nic -- define este como ativo por enquanto
        _bp.nic_map[_bp.lan_iface] = wd_nic

        wd_nic.closeAll()
        wd_nic.open(config.CRD_Channel)

        ioctl.fp_has_wd_modem(modem ~= nil)
    end

    -- inicializa NIC(s) sem fio
    if config.WirelessModem then
        local modem, iface = ppm.get_wireless_modem()
        local wl_nic       = network.nic(modem, config.SVR_Channel)

        log.info("BKPLN: WIRELESS PHY_" .. util.trinary(modem, "UP ", "DOWN") .. (iface or ""))
        log_comms("modem de comunic. sem fio " .. util.trinary(modem, "conectado", "não encontrado"))

        -- define este como ativo se conectado ou se ambos estiverem desconectados e este for o preferencial
        if (modem and _bp.wlan_pref) or not (_bp.act_nic and _bp.act_nic.is_connected()) then
            _bp.act_nic = wl_nic
            log.info("BKPLN: switched active to preferred wireless")
        end

        _bp.wl_nic = wl_nic
        if iface then _bp.nic_map[iface] = wl_nic end

        wl_nic.closeAll()
        wl_nic.open(config.CRD_Channel)

        ioctl.fp_has_wl_modem(modem ~= nil)
    end

    -- pelo menos um modem de comunicação é necessário
    if not ((_bp.wd_nic and _bp.wd_nic.is_connected()) or (_bp.wl_nic and _bp.wl_nic.is_connected())) then
        log_comms("nenhum modem de comunicação encontrado")
        println("startup> nenhum modem de comunicação encontrado")
        log.warning("BKPLN: no comms modem on startup")
        return false
    end

    -- Inicialização do Alto-falante

    local speaker = ppm.get_device("speaker")

    ---@cast speaker Speaker|nil
    _bp.speaker = speaker

    if not _bp.speaker then
        log_boot("alto-falante de alarme do anunciador não encontrado")

        println("startup> alto-falante não encontrado")
        log.fatal("BKPLN: no annunciator alarm speaker found")

        return false
    else
        log.info("BKPLN: SPEAKER LINK_UP " .. ppm.get_iface(_bp.speaker))
        log_boot("alto-falante de alarme do anunciador conectado")

        local sounder_start = util.time_ms()
        sounder.init(_bp.speaker, config.SpeakerVolume)

        log_boot("geração de tons levou " .. (util.time_ms() - sounder_start) .. "ms")
        log_sys("alarme do anunciador configurado")

        ioctl.fp_has_speaker(true)
    end

    return true
end

-- obtém a NIC ativa
function backplane.active_nic() return _bp.act_nic end

-- obtém a NIC de espera (standby)
---@return nic|nil
function backplane.standby_nic() return util.trinary(_bp.act_nic == _bp.wl_nic, _bp.wd_nic, _bp.wl_nic) end

-- obtém a NIC sem fio
function backplane.wireless_nic() return _bp.wl_nic end

-- obtém os monitores configurados
function backplane.displays() return _bp.displays end

-- tarefas periódicas de periféricos do backplane
function backplane.periodic()
    if _bp.wd_nic then ioctl.fp_has_wd_net(_bp.wd_nic.periodic()) end
    if _bp.wl_nic then ioctl.fp_has_wl_net(_bp.wl_nic.periodic()) end
end

-- processa a conexão de um periférico ao backplane
---@param type string
---@param device ppm_generic
---@param iface string
function backplane.attach(type, device, iface)
    local MQ__RENDER_DATA = _bp.smem.q_types.MQ__RENDER_DATA

    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local comms = _bp.smem.crd_sys.coord_comms

    if type == "modem" then
        ---@cast device Modem

        local m_is_wl = device.isWireless()

        log.info(util.c("BKPLN: ", util.trinary(m_is_wl, "WIRELESS", "WIRED"), " PHY_ATTACH ", iface))

        if wd_nic and (_bp.lan_iface == iface) then
            -- conecta este como a NIC cabeada
            wd_nic.connect(device)
            _bp.nic_map[iface] = wd_nic

            log.info("BKPLN: WIRED PHY_UP " .. iface)
            log_sys("modem de comunic. cabeado reconectado")

            ioctl.fp_has_wd_modem(true)

            if (_bp.act_nic ~= wd_nic) and not _bp.wlan_pref then
                -- volta para o cabeado preferencial
                _bp.act_nic = wd_nic

                comms.switch_nic(_bp.act_nic)
                log.info("BKPLN: switched comms to wired modem (preferred)")
            end
        elseif wl_nic and (not wl_nic.is_connected()) and m_is_wl then
            -- conecta este como a NIC sem fio
            wl_nic.connect(device)
            _bp.nic_map[iface] = wl_nic

            log.info("BKPLN: WIRELESS PHY_UP " .. iface)
            log_sys("modem de comunic. sem fio reconectado")

            ioctl.fp_has_wl_modem(true)

            if (_bp.act_nic ~= wl_nic) and _bp.wlan_pref then
                -- volta para o sem fio preferencial
                _bp.act_nic = wl_nic

                comms.switch_nic(_bp.act_nic)
                log.info("BKPLN: switched comms to wireless modem (preferred)")
            end
        elseif wl_nic and m_is_wl then
            -- a NIC sem fio já possui um modem
            device.closeAll()

            log_sys("modem sem fio de espera conectado")
            log.info("BKPLN: standby wireless modem connected")
        else
            device.closeAll()

            log_sys("modem não atribuído conectado")
            log.warning("BKPLN: unassigned modem connected")
        end
    elseif type == "monitor" then
        ---@cast device Monitor

        local is_used = false

        log.info("BKPLN: DISPLAY LINK_UP " .. iface)

        if _bp.displays.main_iface == iface then
            is_used = true

            _bp.displays.main = device

            log.info("BKPLN: main display reconnected")
            ioctl.fp_monitor_state("main", 2)
        elseif _bp.displays.flow_iface == iface then
            is_used = true

            _bp.displays.flow = device

            log.info("BKPLN: flow display reconnected")
            ioctl.fp_monitor_state("flow", 2)
        else
            for idx, monitor in ipairs(_bp.displays.unit_ifaces) do
                if monitor == iface then
                    is_used = true

                    _bp.displays.unit_displays[idx] = device

                    log.info("BKPLN: unit " .. idx .. " display reconnected")
                    ioctl.fp_monitor_state(idx, 2)
                    break
                end
            end
        end

        -- notifica o renderizador se estiver usando o monitor
        if is_used then
            log_sys(util.c("monitor configurado ", iface, " reconectado"))
            _bp.smem.q.mq_render.push_data(MQ__RENDER_DATA.MON_CONNECT, iface)
        else
            log_sys(util.c("monitor não utilizado ", iface, " conectado"))
        end
    elseif type == "speaker" then
        ---@cast device Speaker

        log.info("BKPLN: SPEAKER LINK_UP " .. iface)

        sounder.reconnect(device)

        log_sys("alto-falante do alarme sonoro reconectado")

        ioctl.fp_has_speaker(true)
    end
end

-- processa a desconexão de um periférico do backplane
---@param type string
---@param device ppm_generic
---@param iface string
function backplane.detach(type, device, iface)
    local MQ__RENDER_CMD  = _bp.smem.q_types.MQ__RENDER_CMD
    local MQ__RENDER_DATA = _bp.smem.q_types.MQ__RENDER_DATA

    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local comms = _bp.smem.crd_sys.coord_comms

    if type == "modem" then
        ---@cast device Modem

        log.info(util.c("BKPLN: PHY_DETACH ", iface))

        _bp.nic_map[iface] = nil

        if wd_nic and wd_nic.is_modem(device) then
            wd_nic.disconnect()
            log.info("BKPLN: WIRED PHY_DOWN " .. iface)

            ioctl.fp_has_wd_modem(false)
        elseif wl_nic and wl_nic.is_modem(device) then
            wl_nic.disconnect()
            log.info("BKPLN: WIRELESS PHY_DOWN " .. iface)

            ioctl.fp_has_wl_modem(false)
        end

        -- só importa se este for nosso modem de comunicação ativo
        if _bp.act_nic.is_modem(device) then
            log_sys("modem de comunicação ativo desconectado")
            log.warning("BKPLN: active comms modem disconnected")

            -- executa failover e tenta encontrar um novo modem de comunicação
            if _bp.act_nic == wl_nic then
                -- sem fio ativo desconectado
                -- tenta encontrar outro modem sem fio, caso contrário alterna para cabeado
                local modem, m_iface = ppm.get_wireless_modem()
                if wl_nic and modem then
                    log_sys("outro modem sem fio encontrado, usando-o para comunic.")
                    log.info("BKPLN: found another wireless modem, using it for comms")

                    wl_nic.connect(modem)

                    log.info("BKPLN: WIRELESS PHY_UP " .. m_iface)

                    ioctl.fp_has_wl_modem(true)
                elseif wd_nic and wd_nic.is_connected() then
                    _bp.act_nic = wd_nic

                    _bp.smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                    comms.switch_nic(_bp.act_nic)
                    log.info("BKPLN: switched comms to wired modem")
                else
                    -- fecha a UI principal
                    _bp.smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                    comms.close()

                    -- alerta o usuário sobre o status
                    log_sys("aguardando reconexão de modem de comunic....")
                end
            elseif wl_nic and wl_nic.is_connected() then
                -- cabeado ativo desconectado, sem fio disponível
                _bp.act_nic = wl_nic

                _bp.smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                comms.switch_nic(_bp.act_nic)
                log.info("BKPLN: switched comms to wireless modem")
            else
                -- cabeado ativo desconectado, sem fio indisponível
                _bp.smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                comms.close()
            end
        elseif wd_nic and wd_nic.is_modem(device) then
            -- cabeado, mas não ativo
            log_sys("modem cabeado de espera desconectado")
            log.info("BKPLN: standby wired modem disconnected")
        elseif wl_nic and wl_nic.is_modem(device) then
            -- sem fio, mas não ativo
            log_sys("modem sem fio de espera desconectado")
            log.info("BKPLN: standby wireless modem disconnected")
        else
            log_sys("modem não atribuído desconectado")
            log.warning("BKPLN: unassigned modem disconnected")
        end
    elseif type == "monitor" then
        ---@cast device Monitor

        local is_used = false

        log.info("BKPLN: DISPLAY LINK_DOWN " .. iface)

        if _bp.displays.main == device then
            is_used = true

            log.info("BKPLN: main display disconnected")
            ioctl.fp_monitor_state("main", 1)
        elseif _bp.displays.flow == device then
            is_used = true

            log.info("BKPLN: flow display disconnected")
            ioctl.fp_monitor_state("flow", 1)
        else
            for idx, monitor in pairs(_bp.displays.unit_displays) do
                if monitor == device then
                    is_used = true

                    log.info("BKPLN: unit " .. idx .. " display disconnected")
                    ioctl.fp_monitor_state(idx, 1)
                    break
                end
            end
        end

        -- notifica o renderizador se estava usando o monitor
        if is_used then
            log_sys("monitor configurado perdido")
            _bp.smem.q.mq_render.push_data(MQ__RENDER_DATA.MON_DISCONNECT, iface)
        else
            log_sys("monitor não utilizado perdido")
        end
    elseif type == "speaker" then
        ---@cast device Speaker

        log.info("BKPLN: SPEAKER LINK_DOWN " .. iface)

        log_sys("alto-falante do alarme sonoro desconectado")

        ioctl.fp_has_speaker(false)
    end
end


return backplane
