--
-- Gerenciamento de Controle de Processo
--

local comms = require("scada-common.comms")
local log   = require("scada-common.log")
local util  = require("scada-common.util")

local F_CMD = comms.FAC_COMMAND
local U_CMD = comms.UNIT_COMMAND

---@class pocket_process_controller
local process = {}

local self = {
    io = nil,   ---@type crd_io
    comms = nil ---@type pocket_comms
}

-- inicializa o controlador de processo
---@param ioctl pkt_io sistema de controle de E/S
---@param pocket_comms pocket_comms comunicacoes do pocket
function process.init(ioctl, pocket_comms)
    self.io = ioctl
    self.comms = pocket_comms
end

------------------------------
--#region FACILITY COMMANDS --

-- comando de SCRAM da instalacao
function process.fac_scram()
    self.comms.send_fac_command(F_CMD.SCRAM_ALL)
    log.debug("PROCESS: FAC SCRAM ALL")
end

-- comando de reconhecimento de alarmes da instalacao
function process.fac_ack_alarms()
    self.comms.send_fac_command(F_CMD.ACK_ALL_ALARMS)
    log.debug("PROCESS: FAC ACK ALL ALARMS")
end

--#endregion
------------------------------

--------------------------
--#region UNIT COMMANDS --

-- inicia o reator
---@param id integer ID da unidade
function process.start(id)
    self.io.units[id].control_state = true
    self.comms.send_unit_command(U_CMD.START, id)
    log.debug(util.c("PROCESS: UNIT[", id, "] START"))
end

-- SCRAM do reator
---@param id integer ID da unidade
function process.scram(id)
    self.io.units[id].control_state = false
    self.comms.send_unit_command(U_CMD.SCRAM, id)
    log.debug(util.c("PROCESS: UNIT[", id, "] SCRAM"))
end

-- redefine o sistema de protecao do reator
---@param id integer ID da unidade
function process.reset_rps(id)
    self.comms.send_unit_command(U_CMD.RESET_RPS, id)
    log.debug(util.c("PROCESS: UNIT[", id, "] RESET RPS"))
end

-- define a taxa de queima
---@param id integer ID da unidade
---@param rate number taxa de queima
function process.set_rate(id, rate)
    self.comms.send_unit_command(U_CMD.SET_BURN, id, rate)
    log.debug(util.c("PROCESS: UNIT[", id, "] SET BURN ", rate))
end

-- atribui uma unidade a um grupo
---@param unit_id integer ID da unidade
---@param group_id integer|0 ID do grupo ou 0 para independente
function process.set_group(unit_id, group_id)
    self.comms.send_unit_command(U_CMD.SET_GROUP, unit_id, group_id)
    log.debug(util.c("PROCESS: UNIT[", unit_id, "] SET GROUP ", group_id))
end

-- define o modo de rejeito
---@param id integer ID da unidade
---@param mode integer modo de rejeito
function process.set_unit_waste(id, mode)
    self.comms.send_unit_command(U_CMD.SET_WASTE, id, mode)
    log.debug(util.c("PROCESS: UNIT[", id, "] SET WASTE ", mode))
end

-- reconhece todos os alarmes
---@param id integer ID da unidade
function process.ack_all_alarms(id)
    self.comms.send_unit_command(U_CMD.ACK_ALL_ALARMS, id)
    log.debug(util.c("PROCESS: UNIT[", id, "] ACK ALL ALARMS"))
end

-- reconhece um alarme
---@param id integer ID da unidade
---@param alarm integer ID do alarme
function process.ack_alarm(id, alarm)
    self.comms.send_unit_command(U_CMD.ACK_ALARM, id, alarm)
    log.debug(util.c("PROCESS: UNIT[", id, "] ACK ALARM ", alarm))
end

-- redefine um alarme
---@param id integer ID da unidade
---@param alarm integer ID do alarme
function process.reset_alarm(id, alarm)
    self.comms.send_unit_command(U_CMD.RESET_ALARM, id, alarm)
    log.debug(util.c("PROCESS: UNIT[", id, "] RESET ALARM ", alarm))
end

-- #endregion
--------------------------

---------------------------------
--#region AUTO PROCESS CONTROL --

-- comando de inicio de processo
---@param mode PROCESS modo de controle de processo
---@param burn_target number meta de taxa de queima
---@param range_start integer limite de ativacao do controle por faixa
---@param range_stop integer limite de desativacao do controle por faixa
---@param charge_target number meta de nivel de carga
---@param gen_target number meta de taxa de geracao
---@param limits number[] limites de taxa de queima das unidades
function process.process_start(mode, burn_target, range_start, range_stop, charge_target, gen_target, limits)
    self.comms.send_auto_start({ mode, burn_target, range_start, range_stop, charge_target, gen_target, limits })
    log.debug("PROCESS: START AUTO CTRL")
end

-- comando de parada de processo
function process.process_stop()
    self.comms.send_fac_command(F_CMD.STOP)
    log.debug("PROCESS: STOP AUTO CTRL")
end

-- define o modo de rejeito do controle automatico de processo
---@param product WASTE_PRODUCT produto de rejeito para controle automatico
function process.set_process_waste(product)
    self.comms.send_fac_command(F_CMD.SET_WASTE_MODE, product)
    log.debug(util.c("PROCESS: SET WASTE ", product))
end

-- define o fallback de plutonio do controle automatico de processo
---@param enabled boolean se deve ativar o fallback de plutonio
function process.set_pu_fallback(enabled)
    self.comms.send_fac_command(F_CMD.SET_PU_FB, enabled)
    log.debug(util.c("PROCESS: SET PU FALLBACK ", enabled))
end

-- define o uso da SPS em baixa energia no controle automatico de processo
---@param enabled boolean se deve ativar o uso da SPS em baixa energia
function process.set_sps_low_power(enabled)
    self.comms.send_fac_command(F_CMD.SET_SPS_LP, enabled)
    log.debug(util.c("PROCESS: SET SPS LOW POWER ", enabled))
end

-- #endregion
---------------------------------

return process
