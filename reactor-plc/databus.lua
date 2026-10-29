--
-- Barramento de Dados (Data Bus) - Vinculação Central de Comunicação para o Painel Frontal do PLC
--

local log  = require("scada-common.log")
local psil = require("scada-common.psil")
local util = require("scada-common.util")

local databus = {}

-- PSIL do barramento de dados
databus.ps = psil.create()

-- sinalizador de ativação de diagnósticos
databus.en_diag = false

local _dbus = {
    rps_scram = function () log.debug("DBUS: rps_scram() nao definido chamado") end,
    rps_reset = function () log.debug("DBUS: rps_reset() nao definido chamado") end,

    degraded = false,
    wd_modem = true,
    wl_modem = true,
    coroutines = {}
}

-- avalia e publica o status de integridade do sistema
local function eval_status()
    local ok = (not _dbus.degraded) and _dbus.wd_modem and _dbus.wl_modem
    for _, v in pairs(_dbus.coroutines) do ok = ok and v end

    databus.ps.publish("status", ok)
end

-- chama para alternar o sinal de heartbeat
function databus.heartbeat() databus.ps.toggle("heartbeat") end

-- vincula as funções de comando do RPS
---@param scram function reactor SCRAM function
---@param reset function RPS reset function
function databus.link_rps(scram, reset)
    _dbus.rps_scram = scram
    _dbus.rps_reset = reset
end

-- transmite um comando para o RPS executar SCRAM
function databus.rps_scram() _dbus.rps_scram() end

-- transmite um comando para o RPS redefinir
function databus.rps_reset() _dbus.rps_reset() end

-- transmite as versões de firmware
---@param plc_v string PLC version
---@param comms_v string comms version
function databus.tx_versions(plc_v, comms_v)
    databus.ps.publish("version", plc_v)
    databus.ps.publish("comms_version", comms_v)
end

-- transmite o ID da unidade
---@param id integer unit ID
function databus.tx_id(id)
    databus.ps.publish("unit_id", id)
end

-- transmite o status do hardware
---@param plc_state plc_state
function databus.tx_hw_status(plc_state)
    databus.ps.publish("reactor_dev_state", util.trinary(plc_state.no_reactor, 1, util.trinary(plc_state.reactor_formed, 3, 2)))
    databus.ps.publish("has_wd_modem", plc_state.wd_modem)
    databus.ps.publish("has_wl_modem", plc_state.wl_modem)

    _dbus.degraded = plc_state.degraded
    _dbus.wd_modem = plc_state.wd_modem
    _dbus.wl_modem = plc_state.wl_modem
    eval_status()
end

-- transmite se a rede cabeada está ativa
---@param up boolean
function databus.tx_wd_net(up)
    databus.ps.publish("has_wd_net", up)
end

-- transmite se a rede sem fio está ativa
---@param up boolean
function databus.tx_wl_net(up)
    databus.ps.publish("has_wl_net", up)
end

-- transmite se o reator possui perigosamente múltiplos adaptadores lógicos de reator de fissão
---@param multi boolean has multiple reactors
function databus.tx_multi_reactor(multi)
    databus.ps.publish("has_multi_reactor", multi)
end

-- transmite os status das threads (rotinas)
---@param thread string thread name
---@param ok boolean thread state
function databus.tx_rt_status(thread, ok)
    local name = util.c("routine__", thread)

    databus.ps.publish(name, ok)

    _dbus.coroutines[name] = ok
    eval_status()
end

-- transmite o estado do link do supervisor
---@param state integer
function databus.tx_link_state(state)
    databus.ps.publish("link_state", state)
end

-- transmite o estado de ativação do reator
---@param active any reactor active
function databus.tx_reactor_state(active)
    databus.ps.publish("reactor_active", active == true)
end

-- transmite dados do RPS
---@param tripped boolean RPS tripped
---@param status boolean[] RPS status
---@param emer_cool_active boolean RPS activated the emergency coolant
function databus.tx_rps(tripped, status, emer_cool_active)
    databus.ps.publish("rps_scram", tripped)
    databus.ps.publish("rps_damage", status[1])
    databus.ps.publish("rps_high_temp", status[2])
    databus.ps.publish("rps_low_ccool", status[3])
    databus.ps.publish("rps_high_waste", status[4])
    databus.ps.publish("rps_high_hcool", status[5])
    databus.ps.publish("rps_fault", status[6])
    databus.ps.publish("rps_timeout", status[7])
    databus.ps.publish("rps_manual", status[8])
    databus.ps.publish("rps_automatic", status[9])
    databus.ps.publish("rps_sysfail", status[10])
    databus.ps.publish("emer_cool", emer_cool_active)
end

-- transmite o estado do controle automático
---@param auto boolean if auto control is active
function databus.tx_auto_state(auto)
    databus.ps.publish("auto_control", auto)
end

return databus
