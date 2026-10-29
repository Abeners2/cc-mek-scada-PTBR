--
-- Barramento de Dados - Vinculação Central de Comunicação para o Painel Frontal do Supervisor
--

local const = require("scada-common.constants")
local psil  = require("scada-common.psil")
local util  = require("scada-common.util")

local pgi   = require("supervisor.panel.pgi")

local databus = {}

local _dbus = {
    wd_modem = true,
    wl_modem = true
}

-- avaliar e publicar o status de integridade do sistema
local function eval_status()
    databus.ps.publish("status", _dbus.wd_modem and _dbus.wl_modem)
end

-- PSIL do barramento de dados
databus.ps = psil.create()

-- chamar para alternar o sinal de pulso (heartbeat)
function databus.heartbeat() databus.ps.toggle("heartbeat") end

-- transmitir versões de firmware
---@param sv_v string versão do supervisor
---@param comms_v string versão de comms
function databus.tx_versions(sv_v, comms_v)
    databus.ps.publish("version", sv_v)
    databus.ps.publish("comms_version", comms_v)
end

-- transmitir status de hardware para o modem de comunicações cabeado
---@param has_modem boolean
function databus.tx_hw_wd_modem(has_modem)
    databus.ps.publish("has_wd_modem", has_modem)

    _dbus.wd_modem = has_modem
    eval_status()
end

-- transmitir status de hardware para o modem de comunicações sem fio
---@param has_modem boolean
function databus.tx_hw_wl_modem(has_modem)
    databus.ps.publish("has_wl_modem", has_modem)

    _dbus.wl_modem = has_modem
    eval_status()
end

-- transmitir condição de incompatibilidade de energia
---@param mismatch boolean
function databus.tx_energy_mismatch(mismatch)
    databus.ps.publish("energy_mismatch", mismatch)
end

-- transmitir versão de firmware do CLP e estado de conexão da sessão
---@param reactor_id integer ID da unidade do reator
---@param fw string versão do firmware
---@param s_addr integer ID do computador do CLP
function databus.tx_plc_connected(reactor_id, fw, s_addr)
    databus.ps.publish("plc_" .. reactor_id .. "_fw", fw)
    databus.ps.publish("plc_" .. reactor_id .. "_conn", true)
    databus.ps.publish("plc_" .. reactor_id .. "_addr", util.sprintf("@% 4d", s_addr))
end

-- transmitir CLP desconectado
---@param reactor_id integer ID da unidade do reator
function databus.tx_plc_disconnected(reactor_id)
    databus.ps.publish("plc_" .. reactor_id .. "_fw", " ------- ")
    databus.ps.publish("plc_" .. reactor_id .. "_conn", false)
    databus.ps.publish("plc_" .. reactor_id .. "_addr", " --- ")
    databus.ps.publish("plc_" .. reactor_id .. "_rtt", 0)
    databus.ps.publish("plc_" .. reactor_id .. "_rtt_color", colors.lightGray)
end

-- transmitir RTT da sessão do CLP
---@param reactor_id integer ID da unidade do reator
---@param rtt integer tempo de ida e volta (RTT)
function databus.tx_plc_rtt(reactor_id, rtt)
    databus.ps.publish("plc_" .. reactor_id .. "_rtt", rtt)

    if rtt > const.HIGH_RTT then
        databus.ps.publish("plc_" .. reactor_id .. "_rtt_color", colors.red)
    elseif rtt > const.WARN_RTT then
        databus.ps.publish("plc_" .. reactor_id .. "_rtt_color", colors.yellow_hc)
    else
        databus.ps.publish("plc_" .. reactor_id .. "_rtt_color", colors.green_hc)
    end
end

-- transmitir versão de firmware da RTU e estado de conexão da sessão
---@param session_id integer sessão da RTU
---@param fw string versão do firmware
---@param s_addr integer ID do computador da RTU
function databus.tx_rtu_connected(session_id, fw, s_addr)
    databus.ps.publish("rtu_" .. session_id .. "_fw", fw)
    databus.ps.publish("rtu_" .. session_id .. "_addr", util.sprintf("@ C% 3d", s_addr))
    pgi.create_rtu_entry(session_id)
end

-- transmitir RTU desconectada
---@param session_id integer sessão da RTU
function databus.tx_rtu_disconnected(session_id)
    pgi.delete_rtu_entry(session_id)
end

-- transmitir RTT da sessão da RTU
---@param session_id integer sessão da RTU
---@param rtt integer tempo de ida e volta (RTT)
function databus.tx_rtu_rtt(session_id, rtt)
    databus.ps.publish("rtu_" .. session_id .. "_rtt", rtt)

    if rtt > const.HIGH_RTT then
        databus.ps.publish("rtu_" .. session_id .. "_rtt_color", colors.red)
    elseif rtt > const.WARN_RTT then
        databus.ps.publish("rtu_" .. session_id .. "_rtt_color", colors.yellow_hc)
    else
        databus.ps.publish("rtu_" .. session_id .. "_rtt_color", colors.green_hc)
    end
end

-- transmitir contagem de unidades da sessão da RTU
---@param session_id integer sessão da RTU
---@param units integer contagem de unidades
function databus.tx_rtu_units(session_id, units)
    databus.ps.publish("rtu_" .. session_id .. "_units", units)
end

-- transmitir versão de firmware do coordenador e estado de conexão da sessão
---@param fw string versão do firmware
---@param s_addr integer ID do computador do coordenador
function databus.tx_crd_connected(fw, s_addr)
    databus.ps.publish("crd_fw", fw)
    databus.ps.publish("crd_conn", true)
    databus.ps.publish("crd_addr", tostring(s_addr))
end

-- transmitir coordenador desconectado
function databus.tx_crd_disconnected()
    databus.ps.publish("crd_fw", " ------- ")
    databus.ps.publish("crd_conn", false)
    databus.ps.publish("crd_addr", "---")
    databus.ps.publish("crd_rtt", 0)
    databus.ps.publish("crd_rtt_color", colors.lightGray)
end

-- transmitir RTT da sessão do coordenador
---@param rtt integer tempo de ida e volta (RTT)
function databus.tx_crd_rtt(rtt)
    databus.ps.publish("crd_rtt", rtt)

    if rtt > const.HIGH_RTT then
        databus.ps.publish("crd_rtt_color", colors.red)
    elseif rtt > const.WARN_RTT then
        databus.ps.publish("crd_rtt_color", colors.yellow_hc)
    else
        databus.ps.publish("crd_rtt_color", colors.green_hc)
    end
end

-- transmitir versão de firmware do PKT e estado de conexão da sessão PDG
---@param session_id integer sessão PDG
---@param fw string versão do firmware
---@param s_addr integer ID do computador PDG
function databus.tx_pdg_connected(session_id, fw, s_addr)
    databus.ps.publish("pdg_" .. session_id .. "_fw", fw)
    databus.ps.publish("pdg_" .. session_id .. "_addr", util.sprintf("@ C% 3d", s_addr))
    pgi.create_pdg_entry(session_id)
end

-- transmitir sessão PDG desconectada
---@param session_id integer sessão PDG
function databus.tx_pdg_disconnected(session_id)
    pgi.delete_pdg_entry(session_id)
end

-- transmitir RTT da sessão PDG
---@param session_id integer sessão PDG
---@param rtt integer tempo de ida e volta (RTT)
function databus.tx_pdg_rtt(session_id, rtt)
    databus.ps.publish("pdg_" .. session_id .. "_rtt", rtt)

    if rtt > const.HIGH_RTT then
        databus.ps.publish("pdg_" .. session_id .. "_rtt_color", colors.red)
    elseif rtt > const.WARN_RTT then
        databus.ps.publish("pdg_" .. session_id .. "_rtt_color", colors.yellow_hc)
    else
        databus.ps.publish("pdg_" .. session_id .. "_rtt_color", colors.green_hc)
    end
end

return databus
