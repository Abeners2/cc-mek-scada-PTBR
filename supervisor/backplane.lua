--
-- Backplane de Periféricos do Núcleo do Sistema Supervisor
--

local log     = require("scada-common.log")
local network = require("scada-common.network")
local ppm     = require("scada-common.ppm")
local util    = require("scada-common.util")

local databus = require("supervisor.databus")

local println = util.println

---@class supervisor_backplane
local backplane = {}

local _bp = {
    config = nil,       ---@type svr_config
    lan_iface = false,  ---@type string|false nome do modem de comunicações cabeado

    wd_nic = nil,       ---@type nic|nil nic cabeada
    wl_nic = nil,       ---@type nic|nil nic sem fio
    nic_map = {}        ---@type nic[] nics conectadas
}

-- interfaces de rede indexadas por nomes de periféricos
backplane.nics = _bp.nic_map

-- inicializar o backplane de periféricos do sistema
---@param config svr_config
---@return boolean success
function backplane.init(config)
    _bp.lan_iface = config.WiredModem

    -- configurar o modem cabeado, se configurado
    if type(_bp.lan_iface) == "string" then
        local modem  = ppm.get_modem(_bp.lan_iface)
        local wd_nic = network.nic(modem)

        log.info("BKPLN: WIRED PHY_" .. util.trinary(modem, "UP ", "DOWN ") .. _bp.lan_iface)

        if not (modem and _bp.lan_iface) then
            println("startup> modem de comunicações cabeado não encontrado")
            log.fatal("BKPLN: sem modem de comunicações cabeado na inicialização")
            return false
        end

        _bp.wd_nic = wd_nic
        _bp.nic_map[_bp.lan_iface] = wd_nic

        wd_nic.closeAll()
        wd_nic.open(config.SVR_Channel)

        databus.tx_hw_wd_modem(true)
    end

    -- configurar o modem sem fio, se configurado
    if config.WirelessModem then
        local modem, iface = ppm.get_wireless_modem()
        local wl_nic       = network.nic(modem)

        log.info("BKPLN: WIRELESS PHY_" .. util.trinary(modem, "UP ", "DOWN") .. (iface or ""))

        if not (modem and iface) then
            println("startup> modem de comunicações sem fio não encontrado")
            log.fatal("BKPLN: sem modem de comunicações sem fio na inicialização")
            return false
        end

        _bp.wl_nic = wl_nic
        _bp.nic_map[iface] = wl_nic

        wl_nic.closeAll()
        wl_nic.open(config.SVR_Channel)

        databus.tx_hw_wl_modem(true)
    end

    return true
end

-- tratar uma conexão de periférico no backplane
---@param iface string
---@param type string
---@param device ppm_generic
---@param print_no_fp function
function backplane.attach(iface, type, device, print_no_fp)
    if type == "modem" then
        ---@cast device Modem

        local m_is_wl = device.isWireless()

        log.info(util.c("BKPLN: ", util.trinary(m_is_wl, "WIRELESS", "WIRED"), " PHY_ATTACH ", iface))

        if _bp.wd_nic and (_bp.lan_iface == iface) then
            -- conectar isto como a NIC cabeada
            _bp.wd_nic.connect(device)
            _bp.nic_map[iface] = _bp.wd_nic

            log.info("BKPLN: WIRED PHY_UP " .. iface)
            print_no_fp("modem de comunicações cabeado reconectado")

            databus.tx_hw_wd_modem(true)
        elseif _bp.wl_nic and (not _bp.wl_nic.is_connected()) and m_is_wl then
            -- conectar isto como a NIC sem fio
            _bp.wl_nic.connect(device)
            _bp.nic_map[iface] = _bp.wl_nic

            log.info("BKPLN: WIRELESS PHY_UP " .. iface)
            print_no_fp("modem de comunicações sem fio reconectado")

            databus.tx_hw_wl_modem(true)
        elseif _bp.wl_nic and m_is_wl then
            -- a NIC sem fio já possui um modem
            device.closeAll()

            print_no_fp("modem sem fio de reserva conectado")
            log.info("BKPLN: modem sem fio de reserva conectado")
        else
            device.closeAll()

            print_no_fp("modem não atribuído conectado")
            log.warning("BKPLN: modem não atribuído conectado")
        end
    end
end

-- tratar uma desconexão de periférico no backplane
---@param iface string
---@param type string
---@param device ppm_generic
---@param print_no_fp function
function backplane.detach(iface, type, device, print_no_fp)
    if type == "modem" then
        ---@cast device Modem

        log.info(util.c("BKPLN: PHY_DETACH ", iface))

        _bp.nic_map[iface] = nil

        if _bp.wd_nic and _bp.wd_nic.is_modem(device) then
            _bp.wd_nic.disconnect()
            log.info("BKPLN: WIRED PHY_DOWN " .. iface)

            print_no_fp("modem cabeado desconectado")
            log.warning("BKPLN: modem de comunicações cabeado desconectado")

            databus.tx_hw_wd_modem(false)
        elseif _bp.wl_nic and _bp.wl_nic.is_modem(device) then
            _bp.wl_nic.disconnect()
            log.info("BKPLN: WIRELESS PHY_DOWN " .. iface)

            print_no_fp("modem de comunicações sem fio desconectado")
            log.warning("BKPLN: modem de comunicações sem fio desconectado")

            local modem, m_iface = ppm.get_wireless_modem()
            if modem then
                log.info("BKPLN: outro modem sem fio encontrado, usando-o para comunicações")

                _bp.wl_nic.connect(modem)
                log.info("BKPLN: WIRELESS PHY_UP " .. m_iface)
            else
                databus.tx_hw_wl_modem(false)
            end
        else
            print_no_fp("modem não atribuído desconectado")
            log.warning("BKPLN: modem não atribuído desconectado")
        end
    end
end

return backplane
