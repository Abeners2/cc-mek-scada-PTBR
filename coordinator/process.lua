--
-- Gerenciamento de Controle de Processo
--

local comms = require("scada-common.comms")
local log   = require("scada-common.log")
local types = require("scada-common.types")
local util  = require("scada-common.util")

local F_CMD = comms.FAC_COMMAND
local U_CMD = comms.UNIT_COMMAND

local PROCESS = types.PROCESS
local PRODUCT = types.WASTE_PRODUCT

local REQUEST_TIMEOUT_MS = 10000

---@class process_controller
local process = {}

local pctl = {
    io = nil,    ---@type crd_io
    comms = nil, ---@type coord_comms
    ---@class sys_control_states
    control_states = {
        ---@class sys_auto_config
        process = {
            mode = PROCESS.INACTIVE,           ---@type PROCESS
            alt_mode = false,
            burn_target = 0.0,
            range_start = 10,
            range_stop = 90,
            charge_target = 0.0,
            gen_target = 0.0,
            limits = {},                       ---@type number[]
            waste_product = PRODUCT.PLUTONIUM, ---@type WASTE_PRODUCT
            pu_fallback = false,
            sps_low_power = false
        },
        waste_modes = {},    ---@type WASTE_MODE[]
        priority_groups = {} ---@type AUTO_GROUP[]
    },
    commands = {
        unit = {}, ---@type process_command_state[][]
        fac = {}   ---@type process_command_state[]
    }
}

---@class process_command_state
---@field active boolean if this command is live
---@field timeout integer expiration time of this command request
---@field requestors function[] list of callbacks from the requestors

-- grava o controle de processo automático no arquivo de configuração
---@return boolean saved
local function _write_auto_config()
    -- salva a configuração
    settings.set("ControlStates", pctl.control_states)
    local saved = settings.save("/coordinator.settings")
    if not saved then
        log.warning("process._write_auto_config(): failed to save coordinator settings file")
    end

    return saved
end

--#region Core

-- inicializa o controlador de processo
---@param crd_io crd_io iocontrol system
---@param coord_comms coord_comms coordinator communications
function process.init(crd_io, coord_comms)
    pctl.io = crd_io
    pctl.comms = coord_comms

    -- cria objetos de gerenciamento de comandos
    for _, v in pairs(F_CMD) do pctl.commands.fac[v]  = { active = false, timeout = 0, requestors = {} } end
    for i = 1, pctl.io.facility.num_units do
        pctl.commands.unit[i] = {}
        for _, v in pairs(U_CMD) do pctl.commands.unit[i][v] = { active = false, timeout = 0, requestors = {} } end
    end

    local ctl_proc = pctl.control_states.process

    for i = 1, pctl.io.facility.num_units do
        ctl_proc.limits[i] = 0.1
    end

    local ctrl_states = settings.get("ControlStates", {})   ---@type sys_control_states
    local config = ctrl_states.process
    local f_ps = crd_io.facility.ps

    -- configuração de controle automático da instalação
    if type(config) == "table" then
        -- atualiza cada campo se estiver presente na configuração
        for key, _ in pairs(ctl_proc) do
            ctl_proc[key] = config[key] or ctl_proc[key]
        end

        log.info("PROCESS: loaded auto control settings")

        -- notifica o supervisor sobre a configuração automática de rejeitos
        pctl.comms.send_fac_command(F_CMD.SET_WASTE_MODE, ctl_proc.waste_product)
        pctl.comms.send_fac_command(F_CMD.SET_PU_FB, ctl_proc.pu_fallback)
        pctl.comms.send_fac_command(F_CMD.SET_SPS_LP, ctl_proc.sps_low_power)
    end

    f_ps.publish("process_mode", ctl_proc.mode)
    f_ps.publish("process_alt_mode", ctl_proc.alt_mode)
    f_ps.publish("process_burn_target", ctl_proc.burn_target)
    f_ps.publish("process_range_start", ctl_proc.range_start)
    f_ps.publish("process_range_stop", ctl_proc.range_stop)
    f_ps.publish("process_charge_target", pctl.io.energy_convert_from_fe(ctl_proc.charge_target))
    f_ps.publish("process_gen_target", pctl.io.energy_convert_from_fe(ctl_proc.gen_target))
    f_ps.publish("process_waste_product", ctl_proc.waste_product)
    f_ps.publish("process_pu_fallback", ctl_proc.pu_fallback)
    f_ps.publish("process_sps_low_power", ctl_proc.sps_low_power)

    for id = 1, math.min(#ctl_proc.limits, pctl.io.facility.num_units) do
        local unit = pctl.io.units[id]
        unit.unit_ps.publish("burn_limit", ctl_proc.limits[id])
    end

    -- estados de rejeito das unidades
    local waste_modes = ctrl_states.waste_modes
    if type(waste_modes) == "table" then
        for id, mode in pairs(waste_modes) do
            pctl.control_states.waste_modes[id] = mode
            pctl.comms.send_unit_command(U_CMD.SET_WASTE, id, mode)
        end

        log.info("PROCESS: loaded unit waste mode settings")
    end

    -- grupos de prioridade das unidades
    local prio_groups = ctrl_states.priority_groups
    if type(prio_groups) == "table" then
        for id, group in pairs(prio_groups) do
            pctl.control_states.priority_groups[id] = group
            pctl.comms.send_unit_command(U_CMD.SET_GROUP, id, group)
        end

        log.info("PROCESS: loaded priority groups settings")
    end

    -- informa ao supervisor que todos os dados de configuração inicial foram enviados
    -- a retomada de inicialização pode ocorrer se necessário
    local p    = ctl_proc
    local mode = util.trinary(p.alt_mode and p.mode == PROCESS.CHARGE, PROCESS.RANGE_CONTROL, p.mode)
    pctl.comms.send_ready({ mode, p.burn_target, p.range_start, p.range_stop, p.charge_target, p.gen_target, p.limits })
end

-- cria um manipulador para o controle de processo para uso de comandos que recebem confirmações
function process.create_handle()
    ---@class process_handle
    local handle = {}

    -- adiciona este manipulador aos solicitantes e ativa o comando se estiver inativo
    ---@param cmd process_command_state
    ---@param ack function
    local function request(cmd, ack)
        local new = not cmd.active

        if new then
            cmd.active = true
            cmd.timeout = util.time_ms() + REQUEST_TIMEOUT_MS
        end

        table.insert(cmd.requestors, ack)

        return new
    end

    local function u_request(u_id, cmd_id, ack) return request(pctl.commands.unit[u_id][cmd_id], ack) end
    local function f_request(cmd_id, ack) return request(pctl.commands.fac[cmd_id], ack) end

    --#region Facility Commands

    -- comando SCRAM da instalação
    function handle.fac_scram()
        if f_request(F_CMD.SCRAM_ALL, handle.fac_ack.on_scram) then
            pctl.comms.send_fac_command(F_CMD.SCRAM_ALL)
            log.debug("PROCESS: FAC SCRAM ALL")
        end
    end

    -- comando de reconhecimento de alarmes da instalação
    function handle.fac_ack_alarms()
        if f_request(F_CMD.ACK_ALL_ALARMS, handle.fac_ack.on_ack_alarms) then
            pctl.comms.send_fac_command(F_CMD.ACK_ALL_ALARMS)
            log.debug("PROCESS: FAC ACK ALL ALARMS")
        end
    end

    -- inicia o controle de processo automático com as configurações atuais
    function handle.process_start()
        if f_request(F_CMD.START, handle.fac_ack.on_start) then
            local p    = pctl.control_states.process
            local mode = util.trinary(p.alt_mode and p.mode == PROCESS.CHARGE, PROCESS.RANGE_CONTROL, p.mode)

            pctl.comms.send_auto_start({ mode, p.burn_target, p.range_start, p.range_stop, p.charge_target, p.gen_target, p.limits })
            log.debug("PROCESS: START AUTO CTRL")
        end
    end

    -- inicia o controle de processo automático com configurações remotas que ainda não foram definidas no coordenador
    ---@param settings auto_ctl_cfg auto control settings
    function handle.process_start_remote(settings)
        if f_request(F_CMD.START, handle.fac_ack.on_start) then
            pctl.comms.send_auto_start(settings)
            log.debug("PROCESS: START AUTO CTRL")
        end
    end

    -- para o controle de processo
    function handle.process_stop()
        if f_request(F_CMD.STOP, handle.fac_ack.on_stop) then
            pctl.comms.send_fac_command(F_CMD.STOP)
            log.debug("PROCESS: STOP AUTO CTRL")
        end
    end

    handle.fac_ack = {}

    -- luacheck: no unused args

    -- confirmação de SCRAM da instalação, sobrescreva para implementar
    ---@param success boolean
    ---@diagnostic disable-next-line: unused-local
    function handle.fac_ack.on_scram(success) end

    -- confirmação de reconhecer todos os alarmes da instalação, sobrescreva para implementar
    ---@param success boolean
    ---@diagnostic disable-next-line: unused-local
    function handle.fac_ack.on_ack_alarms(success) end

    -- confirmação de início de controle automático da instalação, sobrescreva para implementar
    ---@param success boolean
    ---@diagnostic disable-next-line: unused-local
    function handle.fac_ack.on_start(success) end

    -- confirmação de parada de controle automático da instalação, sobrescreva para implementar
    ---@param success boolean
    ---@diagnostic disable-next-line: unused-local
    function handle.fac_ack.on_stop(success) end

    -- luacheck: unused args

    --#endregion

    --#region Unit Commands

    -- inicia um reator
    ---@param id integer unit ID
    function handle.start(id)
        if u_request(id, U_CMD.START, handle.unit_ack[id].on_start) then
            pctl.io.units[id].control_state = true
            pctl.comms.send_unit_command(U_CMD.START, id)
            log.debug(util.c("PROCESS: UNIT[", id, "] START"))
        end
    end

    -- executa SCRAM no reator
    ---@param id integer unit ID
    function handle.scram(id)
        if u_request(id, U_CMD.SCRAM, handle.unit_ack[id].on_scram) then
            pctl.io.units[id].control_state = false
            pctl.comms.send_unit_command(U_CMD.SCRAM, id)
            log.debug(util.c("PROCESS: UNIT[", id, "] SCRAM"))
        end
    end

    -- redefine o sistema de proteção do reator (RPS)
    ---@param id integer unit ID
    function handle.reset_rps(id)
        if u_request(id, U_CMD.RESET_RPS, handle.unit_ack[id].on_rps_reset) then
            pctl.comms.send_unit_command(U_CMD.RESET_RPS, id)
            log.debug(util.c("PROCESS: UNIT[", id, "] RESET RPS"))
        end
    end

    -- reconhece todos os alarmes
    ---@param id integer unit ID
    function handle.ack_all_alarms(id)
        if u_request(id, U_CMD.ACK_ALL_ALARMS, handle.unit_ack[id].on_ack_alarms) then
            pctl.comms.send_unit_command(U_CMD.ACK_ALL_ALARMS, id)
            log.debug(util.c("PROCESS: UNIT[", id, "] ACK ALL ALARMS"))
        end
    end

    -- callbacks de confirmação de comandos de unidade, indexados por ID de unidade
    ---@type process_unit_ack[]
    handle.unit_ack = {}

    for u = 1, pctl.io.facility.num_units do
---@diagnostic disable-next-line: missing-fields
        handle.unit_ack[u] = {}

        ---@class process_unit_ack
        local u_ack = handle.unit_ack[u]

        -- luacheck: no unused args

        -- confirmação de início da unidade, sobrescreva para implementar
        ---@param success boolean
        ---@diagnostic disable-next-line: unused-local
        function u_ack.on_start(success) end

        -- confirmação de SCRAM da unidade, sobrescreva para implementar
        ---@param success boolean
        ---@diagnostic disable-next-line: unused-local
        function u_ack.on_scram(success) end

        -- confirmação de redefinição do RPS da unidade, sobrescreva para implementar
        ---@param success boolean
        ---@diagnostic disable-next-line: unused-local
        function u_ack.on_rps_reset(success) end

        -- confirmação de reconhecer todos os alarmes da unidade, sobrescreva para implementar
        ---@param success boolean
        ---@diagnostic disable-next-line: unused-local
        function u_ack.on_ack_alarms(success) end

        -- luacheck: unused args
    end

    --#endregion

    return handle
end

-- limpa comandos de processo pendentes cujo tempo limite expirou
function process.clear_timed_out()
    local now = util.time_ms()
    local objs = { pctl.commands.fac, table.unpack(pctl.commands.unit) }

    for _, obj in pairs(objs) do
        -- cancela solicitações expiradas
        for _, cmd in pairs(obj) do
            if cmd.active and now > cmd.timeout then
                cmd.active = false
                cmd.requestors = {}
            end
        end
    end
end

-- obtém a tabela de estados de controle
---@nodiscard
function process.get_control_states() return pctl.control_states end

--#endregion

--#region Command Handling

-- processa a confirmação de um comando
---@param cmd_state process_command_state
---@param success boolean if the command was successful
local function cmd_ack(cmd_state, success)
    if cmd_state.active then
        cmd_state.active = false

        -- chama todas as funções de callback de confirmação
        for i = 1, #cmd_state.requestors do
            cmd_state.requestors[i](success)
        end

        cmd_state.requestors = {}
    end
end

-- processa a confirmação de um comando da instalação
---@param command FAC_COMMAND command
---@param success boolean if the command was successful
function process.fac_ack(command, success)
    cmd_ack(pctl.commands.fac[command], success)
end

-- processa a confirmação de um comando de unidade
---@param unit integer unit ID
---@param command UNIT_COMMAND command
---@param success boolean if the command was successful
function process.unit_ack(unit, command, success)
    cmd_ack(pctl.commands.unit[unit][command], success)
end

--#region One-Way Commands (no acknowledgements)

-- define a taxa de queima
---@param id integer unit ID
---@param rate number burn rate
function process.set_rate(id, rate)
    pctl.comms.send_unit_command(U_CMD.SET_BURN, id, rate)
    log.debug(util.c("PROCESS: UNIT[", id, "] SET BURN ", rate))
end

-- atribui uma unidade a um grupo
---@param unit_id integer unit ID
---@param group_id integer|0 group ID or 0 for independent
function process.set_group(unit_id, group_id)
    pctl.comms.send_unit_command(U_CMD.SET_GROUP, unit_id, group_id)
    log.debug(util.c("PROCESS: UNIT[", unit_id, "] SET GROUP ", group_id))

    pctl.control_states.priority_groups[unit_id] = group_id
    settings.set("ControlStates", pctl.control_states)

    if not settings.save("/coordinator.settings") then
        log.error("process.set_group(): failed to save coordinator settings file")
    end
end

-- define o modo de rejeito
---@param id integer unit ID
---@param mode integer waste mode
function process.set_unit_waste(id, mode)
    -- publica para que, se falhar, seja redefinido
    pctl.io.units[id].unit_ps.publish("U_WasteMode", mode)

    pctl.comms.send_unit_command(U_CMD.SET_WASTE, id, mode)
    log.debug(util.c("PROCESS: UNIT[", id, "] SET WASTE ", mode))

    pctl.control_states.waste_modes[id] = mode
    settings.set("ControlStates", pctl.control_states)

    if not settings.save("/coordinator.settings") then
        log.error("process.set_unit_waste(): failed to save coordinator settings file")
    end
end

-- reconhece um alarme
---@param id integer unit ID
---@param alarm integer alarm ID
function process.ack_alarm(id, alarm)
    pctl.comms.send_unit_command(U_CMD.ACK_ALARM, id, alarm)
    log.debug(util.c("PROCESS: UNIT[", id, "] ACK ALARM ", alarm))
end

-- redefine um alarme
---@param id integer unit ID
---@param alarm integer alarm ID
function process.reset_alarm(id, alarm)
    pctl.comms.send_unit_command(U_CMD.RESET_ALARM, id, alarm)
    log.debug(util.c("PROCESS: UNIT[", id, "] RESET ALARM ", alarm))
end

--#endregion

--------------------------
-- CONTROLE AUTOMÁTICO  --
--------------------------

-- define o modo de rejeito do controle de processo automático
---@param product WASTE_PRODUCT waste product for auto control
function process.set_process_waste(product)
    pctl.comms.send_fac_command(F_CMD.SET_WASTE_MODE, product)
    log.debug(util.c("PROCESS: SET WASTE ", product))
end

-- define o fallback de plutônio do controle de processo automático
---@param enabled boolean whether to enable plutonium fallback
function process.set_pu_fallback(enabled)
    pctl.comms.send_fac_command(F_CMD.SET_PU_FB, enabled)
    log.debug(util.c("PROCESS: SET PU FALLBACK ", enabled))
end

-- define o uso do SPS em baixa energia no controle de processo automático
---@param enabled boolean whether to enable SPS usage at low power
function process.set_sps_low_power(enabled)
    pctl.comms.send_fac_command(F_CMD.SET_SPS_LP, enabled)
    log.debug(util.c("PROCESS: SET SPS LOW POWER ", enabled))
end

-- salva as configurações do controle de processo
---@param mode PROCESS process control mode
---@param alt_mode boolean true if using range control instead of charge control
---@param burn_target number burn rate target
---@param range_start integer range control activation threshold
---@param range_stop integer range control deactivation threshold
---@param charge_target number charge level target
---@param gen_target number generation rate target
---@param limits number[] unit burn rate limits
function process.save(mode, alt_mode, burn_target, range_start, range_stop, charge_target, gen_target, limits)
    log.debug("PROCESS: SAVE")

    -- atualiza a tabela de configuração
    local p = pctl.control_states.process
    p.mode = mode
    p.alt_mode = alt_mode
    p.burn_target = burn_target
    p.range_start = range_start
    p.range_stop = range_stop
    p.charge_target = charge_target
    p.gen_target = gen_target
    p.limits = limits

    -- salva a configuração
    pctl.io.facility.save_cfg_ack(_write_auto_config())
end

-- processa uma confirmação de comando de início
---@param response auto_start_ack ack and configuration reply
function process.start_ack_handle(response)
    local ack = response[1]

    local p = pctl.control_states.process
    p.mode = response[2]
    p.burn_target = response[3]
    p.range_start = response[4]
    p.range_stop = response[5]
    p.charge_target = response[6]
    p.gen_target = response[7]

    for i = 1, math.min(#response[8], pctl.io.facility.num_units) do
        p.limits[i] = response[8][i]
        pctl.io.units[i].unit_ps.publish("burn_limit", p.limits[i])
    end

    if p.mode == PROCESS.RANGE_CONTROL then
        p.mode = PROCESS.CHARGE
        p.alt_mode = true
    elseif p.mode == PROCESS.CHARGE then
        p.alt_mode = false
    end

    local f_ps = pctl.io.facility.ps

    f_ps.publish("process_mode", p.mode)
    f_ps.publish("process_alt_mode", p.alt_mode)
    f_ps.publish("process_burn_target", p.burn_target)
    f_ps.publish("process_range_start", p.range_start)
    f_ps.publish("process_range_stop", p.range_stop)
    f_ps.publish("process_charge_target", pctl.io.energy_convert_from_fe(p.charge_target))
    f_ps.publish("process_gen_target", pctl.io.energy_convert_from_fe(p.gen_target))

    _write_auto_config()

    process.fac_ack(F_CMD.START, ack)
end

-- registra a configuração de produto de rejeito após tentar alterá-la
---@param response WASTE_PRODUCT supervisor waste product settting
function process.waste_ack_handle(response)
    -- atualiza a tabela de configuração e salva
    pctl.control_states.process.waste_product = response
    _write_auto_config()

    pctl.io.facility.ps.publish("process_waste_product", response)
end

-- registra a configuração de fallback de plutônio após tentar alterá-la
---@param response boolean supervisor plutonium fallback settting
function process.pu_fb_ack_handle(response)
    -- atualiza a tabela de configuração e salva
    pctl.control_states.process.pu_fallback = response
    _write_auto_config()

    pctl.io.facility.ps.publish("process_pu_fallback", response)
end

-- registra a configuração de baixa energia do SPS após tentar alterá-la
---@param response boolean supervisor SPS low power settting
function process.sps_lp_ack_handle(response)
    -- atualiza a tabela de configuração e salva
    pctl.control_states.process.sps_low_power = response
    _write_auto_config()

    pctl.io.facility.ps.publish("process_sps_low_power", response)
end

--#endregion

return process
