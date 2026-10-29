--
-- Barramento de Dados - Vinculação Central de Comunicação para o Painel Frontal da RTU
--

local psil = require("scada-common.psil")
local util = require("scada-common.util")

local databus = {}

local _dbus = {
    wd_modem = true,
    wl_modem = true,
    coroutines = {}
}

-- avaliar e publicar status de integridade do sistema
local function eval_status()
    local ok = _dbus.wd_modem and _dbus.wl_modem
    for _, v in pairs(_dbus.coroutines) do ok = ok and v end

    databus.ps.publish("status", ok)
end

-- PSIL do barramento de dados
databus.ps = psil.create()

---@enum RTU_HW_STATE
local RTU_HW_STATE = {
    OFFLINE = 1,
    FAULTED = 2,
    UNFORMED = 3,
    OK = 4
}

databus.RTU_HW_STATE = RTU_HW_STATE

-- chamar para alternar sinal de pulso (heartbeat)
function databus.heartbeat() databus.ps.toggle("heartbeat") end

-- transmitir versões de firmware
---@param rtu_v string versão da RTU
---@param comms_v string versão de comunicações
function databus.tx_versions(rtu_v, comms_v)
    databus.ps.publish("version", rtu_v)
    databus.ps.publish("comms_version", comms_v)
end

-- transmitir status de hardware para o modem de comunicação cabeado
---@param has_modem boolean
function databus.tx_hw_wd_modem(has_modem)
    databus.ps.publish("has_wd_modem", has_modem)

    _dbus.wd_modem = has_modem
    eval_status()
end

-- transmitir status de hardware para o modem de comunicação sem fio
---@param has_modem boolean
function databus.tx_hw_wl_modem(has_modem)
    databus.ps.publish("has_wl_modem", has_modem)

    _dbus.wl_modem = has_modem
    eval_status()
end

-- transmitir se a rede cabeada está ativa
---@param up boolean
function databus.tx_wd_net(up)
    databus.ps.publish("has_wd_net", up)
end

-- transmitir se a rede sem fio está ativa
---@param up boolean
function databus.tx_wl_net(up)
    databus.ps.publish("has_wl_net", up)
end

-- transmitir o número de alto-falantes conectados
---@param count integer
function databus.tx_hw_spkr_count(count)
    databus.ps.publish("speaker_count", count)
end

-- transmitir tipo de hardware da unidade
---@param uid integer ID da unidade
---@param type RTU_UNIT_TYPE
function databus.tx_unit_hw_type(uid, type)
    databus.ps.publish("unit_type_" .. uid, type)
end

-- transmitir status de hardware da unidade
---@param uid integer ID da unidade
---@param status RTU_HW_STATE
function databus.tx_unit_hw_status(uid, status)
    databus.ps.publish("unit_hw_" .. uid, status)
end

-- transmitir status de threads (rotinas)
---@param thread string nome da thread
---@param ok boolean estado da thread
function databus.tx_rt_status(thread, ok)
    local name = util.c("routine__", thread)

    databus.ps.publish(name, ok)

    _dbus.coroutines[name] = ok
    eval_status()
end

-- transmitir estado de conexão com o supervisor
---@param state integer
function databus.tx_link_state(state)
    databus.ps.publish("link_state", state)
end

return databus
