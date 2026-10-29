--
-- Backplane de Periféricos Principais do Sistema Gateway RTU
--

local log     = require("scada-common.log")
local network = require("scada-common.network")
local ppm     = require("scada-common.ppm")
local util    = require("scada-common.util")

local databus = require("rtu.databus")
local rtu     = require("rtu.rtu")

local println = util.println

---@class rtu_backplane
local backplane = {}

local _bp = {
    smem = nil,     ---@type rtu_shared_memory

    wlan_pref = true,
    lan_iface = "",

    act_nic = nil,  ---@type nic
    wd_nic = nil,   ---@type nic|nil
    wl_nic = nil,   ---@type nic|nil
    nic_map = {},   ---@type nic[] nics conectadas

    sounders = {}   ---@type rtu_speaker_sounder[]
}

-- interfaces de rede indexadas por nomes de periféricos
backplane.nics = _bp.nic_map

-- inicializar o backplane de periféricos do sistema
---@param config rtu_config
---@param __shared_memory rtu_shared_memory
---@return boolean success
function backplane.init(config, __shared_memory)
    _bp.smem      = __shared_memory
    _bp.wlan_pref = config.PreferWireless
    _bp.lan_iface = config.WiredModem

    -- Inicialização de Modem

    -- inicializar NIC cabeada
    if type(_bp.lan_iface) == "string" then
        local modem  = ppm.get_modem(_bp.lan_iface)
        local wd_nic = network.nic(modem, config.SVR_Channel)

        log.info("BKPLN: WIRED PHY_" .. util.trinary(modem, "UP ", "DOWN ") .. _bp.lan_iface)

        _bp.wd_nic  = wd_nic
        _bp.act_nic = wd_nic -- definir esta como ativa por enquanto
        _bp.nic_map[_bp.lan_iface] = wd_nic

        wd_nic.closeAll()
        wd_nic.open(config.RTU_Channel)

        databus.tx_hw_wd_modem(modem ~= nil)
    end

    -- inicializar NIC(s) sem fio
    if config.WirelessModem then
        local modem, iface = ppm.get_wireless_modem()
        local wl_nic       = network.nic(modem, config.SVR_Channel)

        log.info("BKPLN: WIRELESS PHY_" .. util.trinary(modem, "UP ", "DOWN") .. (iface or ""))

        -- definir esta como ativa se conectada ou se ambos os modems estiverem desconectados e este for o preferido
        if (modem and _bp.wlan_pref) or not (_bp.act_nic and _bp.act_nic.is_connected()) then
            _bp.act_nic = wl_nic
        end

        _bp.wl_nic = wl_nic
        if iface then _bp.nic_map[iface] = wl_nic end

        wl_nic.closeAll()
        wl_nic.open(config.RTU_Channel)

        databus.tx_hw_wl_modem(modem ~= nil)
    end

    -- pelo menos um modem de comunicação é necessário
    if not ((_bp.wd_nic and _bp.wd_nic.is_connected()) or (_bp.wl_nic and _bp.wl_nic.is_connected())) then
        println("startup> nenhum modem de comunicação encontrado")
        log.warning("BKPLN: nenhum modem de comunicação na inicialização")
        return false
    end

    -- Inicialização de Alto-falantes

    -- encontrar e configurar todos os alto-falantes
    local speakers = ppm.get_all_devices("speaker")
    for _, s in pairs(speakers) do
        log.info("BKPLN: SPEAKER LINK_UP " .. ppm.get_iface(s))

        ---@cast s Speaker
        local sounder = rtu.init_sounder(s)
        table.insert(_bp.sounders, sounder)

        log.debug(util.c("BKPLN: sinalizador sonoro adicionado, anexado como ", sounder.name))
    end

    databus.tx_hw_spkr_count(#_bp.sounders)

    return true
end

-- obter a NIC ativa
function backplane.active_nic() return _bp.act_nic end

-- obter a NIC de reserva (standby)
---@return nic|nil
function backplane.standby_nic() return util.trinary(_bp.act_nic == _bp.wl_nic, _bp.wd_nic, _bp.wl_nic) end

-- obter as interfaces de sinalizadores sonoros
function backplane.sounders() return _bp.sounders end

-- tarefas periódicas de periféricos do backplane
function backplane.periodic()
    if _bp.wd_nic then databus.tx_wd_net(_bp.wd_nic.periodic()) end
    if _bp.wl_nic then databus.tx_wl_net(_bp.wl_nic.periodic()) end
end

-- tratar conexão de periférico no backplane
---@param type string
---@param device ppm_generic
---@param iface string
---@param print_no_fp function
function backplane.attach(type, device, iface, print_no_fp)
    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local comms = _bp.smem.rtu_sys.rtu_comms

    if type == "modem" then
        ---@cast device Modem

        local m_is_wl = device.isWireless()

        log.info(util.c("BKPLN: ", util.trinary(m_is_wl, "WIRELESS", "WIRED"), " PHY_ATTACH ", iface))

        if wd_nic and (_bp.lan_iface == iface) then
            -- conectar este como a NIC cabeada
            wd_nic.connect(device)
            _bp.nic_map[iface] = wd_nic

            log.info("BKPLN: WIRED PHY_UP " .. iface)
            print_no_fp("modem de comunicação cabeado reconectado")

            databus.tx_hw_wd_modem(true)

            if (_bp.act_nic ~= wd_nic) and not _bp.wlan_pref then
                -- voltar para o cabeado preferido
                _bp.act_nic = wd_nic

                comms.switch_nic(_bp.act_nic, _bp.smem.rtu_state)
                log.info("BKPLN: comunicações alteradas para o modem cabeado (preferido)")
            end
        elseif wl_nic and (not wl_nic.is_connected()) and m_is_wl then
            -- conectar este como a NIC sem fio
            wl_nic.connect(device)
            _bp.nic_map[iface] = wl_nic

            log.info("BKPLN: WIRELESS PHY_UP " .. iface)
            print_no_fp("modem de comunicação sem fio reconectado")

            databus.tx_hw_wl_modem(true)

            if (_bp.act_nic ~= wl_nic) and _bp.wlan_pref then
                -- voltar para o sem fio preferido
                _bp.act_nic = wl_nic

                comms.switch_nic(_bp.act_nic, _bp.smem.rtu_state)
                log.info("BKPLN: comunicações alteradas para o modem sem fio (preferido)")
            end
        elseif wl_nic and m_is_wl then
            -- a NIC sem fio já possui um modem
            device.closeAll()

            print_no_fp("modem sem fio de reserva conectado")
            log.info("BKPLN: modem sem fio de reserva conectado")
        else
            device.closeAll()

            print_no_fp("modem não atribuído conectado")
            log.warning("BKPLN: modem não atribuído conectado")
        end
    elseif type == "speaker" then
        ---@cast device Speaker

        log.info("BKPLN: SPEAKER LINK_UP " .. iface)

        table.insert(_bp.sounders, rtu.init_sounder(device))

        print_no_fp("um alto-falante foi conectado")
        log.info("BKPLN: sinalizador sonoro configurado para o alto-falante " .. iface)

        databus.tx_hw_spkr_count(#_bp.sounders)
    end
end

-- tratar desconexão de periférico no backplane
---@param type string
---@param device ppm_generic
---@param iface string
---@param print_no_fp function
function backplane.detach(type, device, iface, print_no_fp)
    local wl_nic, wd_nic = _bp.wl_nic, _bp.wd_nic

    local comms = _bp.smem.rtu_sys.rtu_comms

    if type == "modem" then
        ---@cast device Modem

        log.info(util.c("BKPLN: PHY_DETACH ", iface))

        _bp.nic_map[iface] = nil

        if wd_nic and wd_nic.is_modem(device) then
            wd_nic.disconnect()
            log.info("BKPLN: WIRED PHY_DOWN " .. iface)

            databus.tx_hw_wd_modem(false)
        elseif wl_nic and wl_nic.is_modem(device) then
            wl_nic.disconnect()
            log.info("BKPLN: WIRELESS PHY_DOWN " .. iface)

            databus.tx_hw_wl_modem(false)
        end

        -- só nos importamos se este for nosso modem de comunicação ativo
        if _bp.act_nic.is_modem(device) then
            print_no_fp("modem de comunicação ativo desconectado")
            log.warning("BKPLN: modem de comunicação ativo desconectado")

            -- alternar em caso de falha (failover) e tentar encontrar um novo modem de comunicação
            if _bp.act_nic == wl_nic then
                -- sem fio ativo desconectado
                -- tentar encontrar outro modem sem fio, caso contrário alternar para cabeado
                local modem, m_iface = ppm.get_wireless_modem()
                if wl_nic and modem then
                    log.info("BKPLN: outro modem sem fio encontrado, usando-o para comunicações")

                    wl_nic.connect(modem)

                    log.info("BKPLN: WIRELESS PHY_UP " .. m_iface)

                    databus.tx_hw_wl_modem(true)
                elseif wd_nic and wd_nic.is_connected() then
                    _bp.act_nic = wd_nic

                    comms.switch_nic(_bp.act_nic, _bp.smem.rtu_state)
                    log.info("BKPLN: comunicações alteradas para o modem cabeado")
                else
                    -- sem outros modems sem fio, cabeado indisponível
                    comms.close(_bp.smem.rtu_state)
                end
            elseif wl_nic and wl_nic.is_connected() then
                -- cabeado ativo desconectado, sem fio disponível
                _bp.act_nic = wl_nic

                comms.switch_nic(_bp.act_nic, _bp.smem.rtu_state)
                log.info("BKPLN: comunicações alteradas para o modem sem fio")
            else
                -- cabeado ativo desconectado, sem fio indisponível
                comms.close(_bp.smem.rtu_state)
            end
        elseif wd_nic and wd_nic.is_modem(device) then
            -- cabeado, mas não ativo
            print_no_fp("modem cabeado de reserva desconectado")
            log.info("BKPLN: modem cabeado de reserva desconectado")
        elseif wl_nic and wl_nic.is_modem(device) then
            -- sem fio, mas não ativo
            print_no_fp("modem sem fio de reserva desconectado")
            log.info("BKPLN: modem sem fio de reserva desconectado")
        else
            print_no_fp("modem não atribuído desconectado")
            log.warning("BKPLN: modem não atribuído desconectado")
        end
    elseif type == "speaker" then
        ---@cast device Speaker

        log.info("BKPLN: SPEAKER LINK_DOWN " .. iface)

        for i = 1, #_bp.sounders do
            if _bp.sounders[i].speaker == device then
                table.remove(_bp.sounders, i)

                print_no_fp("um alto-falante foi desconectado")
                log.warning("BKPLN: sinalizador sonoro " .. iface .. " desconectado")

                databus.tx_hw_spkr_count(#_bp.sounders)
                break
            end
        end
    end
end

return backplane
