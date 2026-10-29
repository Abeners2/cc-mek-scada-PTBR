--
-- Handlers de Recebimento de Dados (Rx) do Controle de E/S
--

local comms = require("scada-common.comms")
local const = require("scada-common.constants")
local types = require("scada-common.types")
local util  = require("scada-common.util")

local DEV_TYPE = comms.DEVICE_TYPE

local ALARM = types.ALARM
local ALARM_STATE = types.ALARM_STATE

local BLR_STATE = types.BOILER_STATE
local TRB_STATE = types.TURBINE_STATE
local TNK_STATE = types.TANK_STATE
local ESS_STATE = types.ESS_STATE
local SPS_STATE = types.SPS_STATE

local io        ---@type pkt_io
local iorx = {} ---@class iorx

local function tripped(state) return state == ALARM_STATE.TRIPPED or state == ALARM_STATE.ACKED end

local function _record_multiblock_build(id, build, data, ps)
    data[id].build = build

    for k, v in pairs(data[id].build) do ps[id].publish(k, v) end
end

local function _record_multiblock_status(faulted, data, ps)
    ps.publish("formed", data.formed)
    ps.publish("faulted", faulted)

    if data.build then
        for k, v in pairs(data.build) do ps.publish(k, v) end
    end

    for k, v in pairs(data.state) do ps.publish(k, v) end
    for k, v in pairs(data.tanks) do ps.publish(k, v) end
end

-- popula dados da instalacao a partir de API_GET_FAC
---@param data table
---@return boolean valid
function iorx.record_facility_data(data)
    local valid = true

    local fac = io.facility

    fac.all_sys_ok = data[1]
    fac.rtu_count = data[2]
    fac.radiation = data[3]

    -- controle automatico
    if type(data[4]) == "table" and #data[4] == 4 then
        fac.auto_ready = data[4][1]
        fac.auto_active = data[4][2]
        fac.auto_ramping = data[4][3]
        fac.auto_saturated = data[4][4]
    end

    -- rejeitos
    if type(data[5]) == "table" and #data[5] == 2 then
        fac.auto_current_waste_product = data[5][1]
        fac.auto_pu_fallback_active = data[5][2]
    end

    fac.num_tanks = data[6]

    return valid
end

-- atualiza o app de instalacao com dados da instalacao e unidades a partir de API_GET_FAC_DTL
---@param data table
function iorx.record_fac_detail_data(data)
    local fac = io.facility
    local f_ps = fac.ps

    local tank_statuses = data[5]
    local next_t_stat = 1

    -- anunciador

    fac.all_sys_ok = data[1]
    fac.rtu_count = data[2]
    fac.auto_scram = data[3]
    fac.ascram_status = data[4]

    f_ps.publish("all_sys_ok", fac.all_sys_ok)
    f_ps.publish("rtu_count", fac.rtu_count)
    f_ps.publish("auto_scram", fac.auto_scram)
    f_ps.publish("as_ess_fault", fac.ascram_status.ess_fault)
    f_ps.publish("as_ess_fill", fac.ascram_status.ess_fill)
    f_ps.publish("as_crit_alarm", fac.ascram_status.crit_alarm)
    f_ps.publish("as_radiation", fac.ascram_status.radiation)
    f_ps.publish("as_gen_fault", fac.ascram_status.gen_fault)

    -- dados da unidade

    local units = data[12]

    for i = 1, io.facility.num_units do
        local unit = io.units[i]
        local u_rx = units[i]

        unit.connected    = u_rx[1]
        unit.annunciator  = u_rx[2]
        unit.reactor_data = u_rx[3]

        local control_status = 1
        if unit.connected then
            if unit.reactor_data.rps_tripped then control_status = 2 end
            if unit.reactor_data.mek_status.status then
                control_status = util.trinary(unit.annunciator.AutoControl, 4, 3)
            end
        end

        unit.unit_ps.publish("U_ControlStatus", control_status)

        unit.tank_data_tbl = u_rx[4]

        for id = 1, #unit.tank_data_tbl do
            local tank   = unit.tank_data_tbl[id]
            local ps     = unit.tank_ps_tbl[id]
            local c_stat = tank_statuses[next_t_stat]

            local tank_status = 1

            if c_stat ~= TNK_STATE.OFFLINE then
                if c_stat == TNK_STATE.FAULT then
                    tank_status = 3
                elseif tank.formed then
                    tank_status = 4
                else
                    tank_status = 2
                end
            end

            ps.publish("DynamicTankStatus", tank_status)
            ps.publish("DynamicTankStateStatus", c_stat)

            next_t_stat = next_t_stat + 1
        end
    end

    -- dados de tanques dinamicos da instalacao

    fac.tank_data_tbl = data[6]

    for id = 1, #fac.tank_data_tbl do
        local tank   = fac.tank_data_tbl[id]
        local ps     = fac.tank_ps_tbl[id]
        local c_stat = tank_statuses[next_t_stat]

        local tank_status = 1

        if c_stat ~= TNK_STATE.OFFLINE then
            if c_stat == TNK_STATE.FAULT then
                tank_status = 3
            elseif tank.formed then
                tank_status = 4
            else
                tank_status = 2
            end

            _record_multiblock_status(c_stat == TNK_STATE.FAULT, tank, ps)
        end

        ps.publish("DynamicTankStatus", tank_status)
        ps.publish("DynamicTankStateStatus", c_stat)

        next_t_stat = next_t_stat + 1
    end

    -- dados de ess

    local ess_ps

    if fac.ess_type == types.ESS.ENERGY_CORE then
        fac.ecore_data_tbl[1] = data[8]

        ess_ps = fac.ecore_ps_tbl[1]

        local e_data = fac.ecore_data_tbl[1]
        local e_stat = data[7]

        local ecr_status = 1

        if e_stat ~= ESS_STATE.OFFLINE then
            if e_stat == ESS_STATE.FAULT then
                ecr_status = 3
            elseif e_data.formed then
                ecr_status = 4
            else
                ecr_status = 2
            end

            ess_ps.publish("faulted", e_stat == ESS_STATE.FAULT)

            if e_data.build then
                for key, val in pairs(e_data.build) do ess_ps.publish(key, val) end
            end

            for key, val in pairs(e_data.state) do ess_ps.publish(key, val) end
            for key, val in pairs(e_data.virtual) do ess_ps.publish(key, val) end
        end

        ess_ps.publish("EnergyCoreStatus", ecr_status)
        ess_ps.publish("EnergyCoreStateStatus", e_stat)
    else
        fac.induction_data_tbl[1] = data[8]

        ess_ps = fac.induction_ps_tbl[1]

        local m_data = fac.induction_data_tbl[1]
        local m_stat = data[7]

        local mtx_status = 1

        if m_stat ~= ESS_STATE.OFFLINE then
            if m_stat == ESS_STATE.FAULT then
                mtx_status = 3
            elseif m_data.formed then
                mtx_status = 4
            else
                mtx_status = 2
            end

            _record_multiblock_status(m_stat == ESS_STATE.FAULT, m_data, ess_ps)
        end

        ess_ps.publish("InductionMatrixStatus", mtx_status)
        ess_ps.publish("InductionMatrixStateStatus", m_stat)
    end

    ess_ps.publish("eta_string", data[9][1])
    ess_ps.publish("avg_charge", data[9][2])
    ess_ps.publish("avg_inflow", data[9][3])
    ess_ps.publish("avg_outflow", data[9][4])
    ess_ps.publish("is_charging", data[9][5])
    ess_ps.publish("is_discharging", data[9][6])
    ess_ps.publish("at_max_io", data[9][7])

    -- dados de sps

    fac.sps_data_tbl[1] = data[11]

    local sps    = fac.sps_data_tbl[1]
    local s_ps   = fac.sps_ps_tbl[1]
    local s_stat = data[10]

    local sps_status = 1

    if s_stat ~= SPS_STATE.OFFLINE then
        if s_stat == SPS_STATE.FAULT then
            sps_status = 3
        elseif sps.formed then
            sps_status = 4
        else
            sps_status = 2
        end

        _record_multiblock_status(s_stat == SPS_STATE.FAULT, sps, s_ps)
    end

    s_ps.publish("SPSStatus", sps_status)
    s_ps.publish("SPSStateStatus", s_stat)
end

-- atualiza dados de status da unidade a partir de API_GET_UNIT
---@param data table
function iorx.record_unit_data(data)
    local unit = io.units[data[1]]
    local u_ps = unit.unit_ps

    unit.connected = data[2]
    local comp_statuses = data[3]
    unit.a_group = data[4]
    unit.alarms = data[5]

    local next_c_stat = 1

    u_ps.publish("auto_group_id", unit.a_group)
    u_ps.publish("auto_group", types.AUTO_GROUP_NAMES[unit.a_group + 1])

    --#region Annunciator

    unit.annunciator = data[6]

    local rcs_disconn, rcs_warn, rcs_hazard = false, false, false

    for key, val in pairs(unit.annunciator) do
        if key == "BoilerOnline" or key == "TurbineOnline" then
            local every = true

            -- divide arrays de online
            for id = 1, #val do
                every = every and val[id]

                if key == "BoilerOnline" then
                    unit.boiler_ps_tbl[id].publish(key, val[id])
                else
                    unit.turbine_ps_tbl[id].publish(key, val[id])
                end
            end

            if not every then rcs_disconn = true end

            u_ps.publish("U_" .. key, every)
        elseif key == "HeatingRateLow" or key == "WaterLevelLow" then
            -- divide array para todas as caldeiras
            local any = false
            for id = 1, #val do
                any = any or val[id]
                unit.boiler_ps_tbl[id].publish(key, val[id])
            end

            if key == "HeatingRateLow" and any then
                rcs_warn = true
            elseif key == "WaterLevelLow" and any then
                rcs_hazard = true
            end

            u_ps.publish("U_" .. key, any)
        elseif key == "SteamDumpOpen" or key == "TurbineOverSpeed" or key == "GeneratorTrip" or key == "TurbineTrip" then
            -- divide array para todas as turbinas
            local any = false
            for id = 1, #val do
                any = any or val[id]
                unit.turbine_ps_tbl[id].publish(key, val[id])
            end

            if key == "GeneratorTrip" and any then
                rcs_warn = true
            elseif (key == "TurbineOverSpeed" or key == "TurbineTrip") and any then
                rcs_hazard = true
            end

            u_ps.publish("U_" .. key, any)
        else
            -- campos que nao sao tabelas
            u_ps.publish(key, val)
        end
    end

    local anc = unit.annunciator
    rcs_hazard = rcs_hazard or anc.RCPTrip
    rcs_warn = rcs_warn or anc.RCSFlowLow or anc.CoolantLevelLow or anc.RCSFault or anc.MaxWaterReturnFeed or
                anc.CoolantFeedMismatch or anc.BoilRateMismatch or anc.SteamFeedMismatch

    local rcs_status = 4
    if rcs_hazard then
        rcs_status = 2
    elseif rcs_warn then
        rcs_status = 3
    elseif rcs_disconn then
        rcs_status = 1
    end

    u_ps.publish("U_RCS", rcs_status)

    --#endregion

    --#region Reactor Data

    unit.reactor_data = data[7]

    local control_status = 1
    local reactor_status = 1
    local rps_status = 1

    if unit.connected then
        -- atualiza status do RPS
        if unit.reactor_data.rps_tripped then
            control_status = 2
            rps_status = util.trinary(unit.reactor_data.rps_trip_cause == "manual", 3, 2)
        else
            rps_status = 4
        end

        reactor_status = 4  -- ok, ate que se prove o contrario

        -- atualiza status do reator/controle
        if unit.reactor_data.mek_status.status then
            control_status = util.trinary(unit.annunciator.AutoControl, 4, 3)
        else
            if unit.reactor_data.no_reactor then
                reactor_status = 2
            elseif (not unit.reactor_data.formed) or unit.reactor_data.rps_status.force_dis then
                reactor_status = 3
            end
        end

        for key, val in pairs(unit.reactor_data) do
            if key ~= "rps_status" and key ~= "mek_struct" and key ~= "mek_status" then
                u_ps.publish(key, val)
            end
        end

        for key, val in pairs(unit.reactor_data.rps_status) do
            u_ps.publish(key, val)
        end

        for key, val in pairs(unit.reactor_data.mek_struct) do
            u_ps.publish(key, val)
        end

        for key, val in pairs(unit.reactor_data.mek_status) do
            u_ps.publish(key, val)
        end
    end

    u_ps.publish("U_ControlStatus", control_status)
    u_ps.publish("U_ReactorStatus", reactor_status)
    u_ps.publish("U_ReactorStateStatus", comp_statuses[next_c_stat])
    u_ps.publish("U_RPS", rps_status)

    next_c_stat = next_c_stat + 1

    --#endregion

    --#region RTU Devices

    unit.boiler_data_tbl = data[8]

    for id = 1, #unit.boiler_data_tbl do
        local boiler = unit.boiler_data_tbl[id]
        local ps     = unit.boiler_ps_tbl[id]
        local c_stat = comp_statuses[next_c_stat]

        local boiler_status = 1

        if c_stat ~= BLR_STATE.OFFLINE then
            if c_stat == BLR_STATE.FAULT then
                boiler_status = 3
            elseif c_stat ~= BLR_STATE.UNFORMED then
                boiler_status = 4
            else
                boiler_status = 2
            end

            _record_multiblock_status(c_stat == BLR_STATE.FAULT, boiler, ps)
        end

        ps.publish("BoilerStatus", boiler_status)
        ps.publish("BoilerStateStatus", c_stat)

        next_c_stat = next_c_stat + 1
    end

    unit.turbine_data_tbl = data[9]

    for id = 1, #unit.turbine_data_tbl do
        local turbine = unit.turbine_data_tbl[id]
        local ps      = unit.turbine_ps_tbl[id]
        local c_stat  = comp_statuses[next_c_stat]

        local turbine_status = 1

        if c_stat ~= TRB_STATE.OFFLINE then
            if c_stat == TRB_STATE.FAULT then
                turbine_status = 3
            elseif turbine.formed then
                turbine_status = 4
            else
                turbine_status = 2
            end

            _record_multiblock_status(c_stat == TRB_STATE.FAULT, turbine, ps)
        end

        ps.publish("TurbineStatus", turbine_status)
        ps.publish("TurbineStateStatus", c_stat)

        next_c_stat = next_c_stat + 1
    end

    unit.tank_data_tbl = data[10]

    for id = 1, #unit.tank_data_tbl do
        local tank   = unit.tank_data_tbl[id]
        local ps     = unit.tank_ps_tbl[id]
        local c_stat = comp_statuses[next_c_stat]

        local tank_status = 1

        if c_stat ~= TNK_STATE.OFFLINE then
            if c_stat == TNK_STATE.FAULT then
                tank_status = 3
            elseif tank.formed then
                tank_status = 4
            else
                tank_status = 2
            end

            _record_multiblock_status(c_stat == TNK_STATE.FAULT, tank, ps)
        end

        ps.publish("DynamicTankStatus", tank_status)
        ps.publish("DynamicTankStateStatus", c_stat)

        next_c_stat = next_c_stat + 1
    end

    unit.last_rate_change_ms = data[11]
    unit.turbine_flow_stable = data[12]
    unit.fuel_burn_rate_limited = data[13]

    --#endregion

    --#region Status Information Display

    local ecam = {} -- referencia de aviacao :)

    local annunc = unit.annunciator

    -- local function red(text) return { text = text, color = colors.red } end
    local function white(text) return { text = text, color = colors.white } end
    local function blue(text) return { text = text, color = colors.blue } end

    -- if unit.reactor_data.rps_status then
    --     for k, _ in pairs(unit.alarms) do
    --         unit.alarms[k] = ALARM_STATE.TRIPPED
    --     end
    -- end

    if tripped(unit.alarms[ALARM.ContainmentBreach]) then
        local items = { white("COLAPSO DO REATOR"), blue("USAR TRAJE HAZMAT") }
        table.insert(ecam, { color = colors.red, text = "QUEBRA DE CONTENCAO", help = "ContainmentBreach", items = items })
    end

    if tripped(unit.alarms[ALARM.ContainmentRadiation]) then
        local items = {
            white("RADIACAO DETECTADA"),
            blue("USAR TRAJE HAZMAT"),
            blue("CONTER VAZAMENTO"),
            blue("AGUARDAR NIVEIS SEG")
        }

        table.insert(ecam, { color = colors.red, text = "VAZAMENTO RADIACAO", help = "ContainmentRadiation", items = items })
    end

    if tripped(unit.alarms[ALARM.CriticalDamage]) then
        local items = { white("COLAPSO IMINENTE"), blue("EVACUAR") }
        table.insert(ecam, { color = colors.red, text = "DANO CRITICO REATOR", help = "CriticalDamage", items = items })
    end

    if tripped(unit.alarms[ALARM.ReactorLost]) then
        local items = { white("REATOR OFF-LINE"), blue("VERIFICAR CLP") }
        table.insert(ecam, { color = colors.red, text = "CONEX REATOR PERDIDA", help = "ReactorLost", items = items })
    end

    if tripped(unit.alarms[ALARM.ReactorDamage]) then
        local items = { white("REATOR DANIFICADO"), blue("VERIFICAR RCS"), blue("AGUARDAR REDUCAO") }
        table.insert(ecam, { color = colors.red, text = "DANO NO REATOR", help = "ReactorDamage", items = items })
    end

    if tripped(unit.alarms[ALARM.ReactorOverTemp]) then
        local items = { white("TEMP CAUSANDO DANO"), blue("VERIFICAR RCS"), blue("AGUARDAR RESFRIAM.") }
        table.insert(ecam, { color = colors.red, text = "SOBRETEMP DO REATOR", help = "ReactorOverTemp", items = items })
    end

    if tripped(unit.alarms[ALARM.ReactorHighTemp]) then
        local items = { white("ACIMA TEMP ESPERADA"), blue("VERIFICAR RCS") }
        table.insert(ecam, { color = colors.yellow, text = "TEMP ALTA DO REATOR", help = "ReactorHighTemp", items = items})
    end

    if tripped(unit.alarms[ALARM.ReactorWasteLeak]) then
        local items = { white("REJEITO NO LIMITE"), blue("VER SAIDA REJEITOS"), blue("MANTER REATOR DESL.") }
        table.insert(ecam, { color = colors.red, text = "VAZAM REJEITO REATOR", help = "ReactorWasteLeak", items = items})
    end

    if tripped(unit.alarms[ALARM.ReactorHighWaste]) then
        local items = { blue("VER SAIDA REJEITOS") }
        table.insert(ecam, { color = colors.yellow, text = "REJEITO ALTO REATOR", help = "ReactorHighWaste", items = items})
    end

    if tripped(unit.alarms[ALARM.RPSTransient]) then
        local items = {}
        local stat = unit.reactor_data.rps_status

        -- for k, _ in pairs(stat) do stat[k] = true end

        local function insert(cond, key, text, color) if cond[key] then table.insert(items, { text = text, help = key, color = color }) end end

        table.insert(items, white("SCRAM NO REATOR"))
        insert(stat, "high_dmg", "DANO ALTO", colors.red)
        insert(stat, "high_temp", "TEMPERATURA ALTA", colors.red)
        insert(stat, "low_cool", "REFRIG CRIT BAIXO")
        insert(stat, "ex_waste", "EXCESSO DE REJEITO")
        insert(stat, "ex_hcool", "EXCESSO REFRIG QUEN")
        insert(stat, "fault", "FALHA DE HARDWARE")
        insert(stat, "timeout", "SUPERVISOR DESCONEC")
        insert(stat, "manual", "SCRAM MANUAL", colors.white)
        insert(stat, "automatic", "SCRAM AUTOMATICO")
        insert(stat, "sys_fail", "NAO FORMADO", colors.red)
        insert(stat, "force_dis", "DESATIVADO FORCADO", colors.red)
        table.insert(items, blue("RESOLVER PROBLEMA"))
        table.insert(items, blue("REARMAR RPS"))

        table.insert(ecam, { color = colors.yellow, text = "TRANSIENTE DO RPS", help = "RPSTransient", items = items})
    end

    if tripped(unit.alarms[ALARM.RCSTransient]) then
        local items = {}

        -- for k, v in pairs(annunc) do
        --     if type(v) == "boolean" then annunc[k] = true end
        --     if type(v) == "table" then
        --         for a, _ in pairs(v) do
        --             v[a] = true
        --         end
        --     end
        -- end

        local function insert(cond, key, text, color)
            if cond == true or (type(cond) == "table" and cond[key]) then table.insert(items, { text = text, help = key, color = color }) end
        end

        table.insert(items, white("PROBLEMA NO REFRIG"))

        insert(annunc, "RCPTrip", "TRIP DA RCP", colors.red)
        insert(annunc, "CoolantLevelLow", "REFRIGERANTE BAIXO")

        if unit.num_boilers == 0 then
            if (util.time_ms() - unit.last_rate_change_ms) > const.FLOW_STABILITY_DELAY_MS then
                insert(annunc, "BoilRateMismatch", "DESCOMP TAXA FERV.")
            end

            if unit.turbine_flow_stable then
                insert(annunc, "RCSFlowLow", "FLUXO BAIXO NO RCS")
                insert(annunc, "CoolantFeedMismatch", "DESCOMP ALIM REFRIG")
                insert(annunc, "SteamFeedMismatch", "DESCOMP ALIM VAPOR")
            end
        else
            if (util.time_ms() - unit.last_rate_change_ms) > const.FLOW_STABILITY_DELAY_MS then
                insert(annunc, "RCSFlowLow", "FLUXO BAIXO NO RCS")
                insert(annunc, "BoilRateMismatch", "DESCOMP TAXA FERV.")
                insert(annunc, "CoolantFeedMismatch", "DESCOMP ALIM REFRIG")
            end

            if unit.turbine_flow_stable then
                insert(annunc, "SteamFeedMismatch", "DESCOMP ALIM VAPOR")
            end
        end

        insert(annunc, "MaxWaterReturnFeed", "RETORNO MAX DE AGUA")

        for k, v in ipairs(annunc.WaterLevelLow) do insert(v, "WaterLevelLow", "CALDEIRA " .. k .. " AGUA BXA", colors.red) end
        for k, v in ipairs(annunc.HeatingRateLow) do insert(v, "HeatingRateLow", "CALDEIRA " .. k .. " TX AQUEC") end
        for k, v in ipairs(annunc.TurbineOverSpeed) do insert(v, "TurbineOverSpeed", "TURBINA " .. k .. " SOBREVEL", colors.red) end
        for k, v in ipairs(annunc.GeneratorTrip) do insert(v, "GeneratorTrip", "TURBINA " .. k .. " TRIP GER") end

        table.insert(items, blue("VER SIST RESFRIAM."))

        table.insert(ecam, { color = colors.yellow, text = "TRANSIENTE DO RCS", help = "RCSTransient", items = items})
    end

    if tripped(unit.alarms[ALARM.TurbineTrip]) then
        local items = {}

        for k, v in ipairs(annunc.TurbineTrip) do
            if v then table.insert(items, { text = "TRIP TURBINA " .. k, help = "TurbineTrip" }) end
        end

        table.insert(items, blue("VER SAIDA ENERGIA"))
        table.insert(ecam, { color = colors.red, text = "TRIP DE TURBINA", help = "TurbineTripAlarm", items = items})
    end

    if not (tripped(unit.alarms[ALARM.ReactorLost]) or unit.connected) then
        local items = { blue("VERIFICAR CLP") }
        table.insert(ecam, { color = colors.yellow, text = "REATOR OFF-LINE", items = items })
    end

    if annunc.FuelInputRateLow then
        table.insert(ecam, { color = colors.yellow, text = "ENTRADA COMB BAIXA", help = "FuelInputRateLow", items = { blue("VER ENTRADA COMB.") } })
    end

    if unit.fuel_burn_rate_limited then
        table.insert(ecam, { color = colors.yellow, text = "QUEIMA MAX LIMITADA", items = { white("TAXA DE INJECAO DE"), white("COMB. INSUFICIENTE"), blue("VER ENTRADA COMB.") } })
    end

    if annunc.WasteLineOcclusion then
        table.insert(ecam, { color = colors.yellow, text = "OCLUSAO LINHA REJ.", help = "WasteLineOcclusion", items = { blue("VER SAIDA REJEITOS") } })
    end

    for k, v in ipairs(annunc.BoilerOnline) do
        if not v then
            local items = { blue("VERIFICAR RTU") }
            table.insert(ecam, { color = colors.yellow, text = "CALDEIRA " .. k .. " OFF-LINE", items = items})
        end
    end

    for k, v in ipairs(annunc.TurbineOnline) do
        if not v then
            local items = { blue("VERIFICAR RTU") }
            table.insert(ecam, { color = colors.yellow, text = "TURBINA " .. k .. " OFF-LINE", items = items})
        end
    end

    -- se nao houver alarmes, adiciona mensagens basicas de status
    if #ecam == 0 then
        table.insert(ecam, { color = colors.green, text = "REATOR " .. util.trinary(unit.reactor_data.mek_status.status, "NOMINAL", "OCIOSO"), items = {}})

        if (not unit.reactor_data.mek_status.status) and annunc.HighStartupRate then
            table.insert(ecam, { color = colors.yellow, text = "TAXA PARTIDA ALTA", help = "HighStartupRate", items = {}})
        end

        local plural = util.trinary(unit.num_turbines > 1, "S", "")
        local stable = util.trinary(unit.num_turbines > 1, " ESTAVEIS", " ESTAVEL")
        table.insert(ecam, { color = colors.green, text = "TURBINA" .. plural .. util.trinary(unit.turbine_flow_stable, stable, " ESTABILIZ."), items = {}})
    end

    u_ps.publish("U_ECAM", textutils.serialize(ecam))

    --#endregion
end

-- atualiza o app de construcoes com dados de construcao a partir de API_GET_BUILD
---@param data table
function iorx.record_build_data(data)
    -- construcoes das unidades

    for u_id = 1, #io.units do
        local unit = io.units[u_id]

        local u_data = data[u_id]
        local rct_build, blr_build, tbn_build, tnk_build = table.unpack(u_data)

        -- construcao do reator
        local r_data = unit.reactor_data

        r_data.mek_struct = rct_build[1]
        r_data.max_op_temp_H2O = rct_build[2]
        r_data.max_op_temp_Na = rct_build[3]

        for k, v in pairs(r_data.mek_struct) do
            unit.unit_ps.publish(k, v)
        end

        unit.unit_ps.publish("max_op_temp_H2O", r_data.max_op_temp_H2O)
        unit.unit_ps.publish("max_op_temp_Na", r_data.max_op_temp_Na)

        -- construcoes das caldeiras
        for b = 1, #unit.boiler_data_tbl do
            _record_multiblock_build(b, blr_build[b], unit.boiler_data_tbl, unit.boiler_ps_tbl)
        end

        -- construcoes das turbinas
        for t = 1, #unit.turbine_data_tbl do
            _record_multiblock_build(t, tbn_build[t][1], unit.turbine_data_tbl, unit.turbine_ps_tbl)

            local ps, props = unit.turbine_ps_tbl[t], unit.properties

            props.flow_perf[t] = tbn_build[t][2]
            props.generators[t] = tbn_build[t][3]

            ps.publish("flow_perf", props.flow_perf[t])
            ps.publish("gen_mult", props.generators[t].multiplier)
            ps.publish("gen_eff", props.generators[t].efficiency)
        end

        -- construcoes dos tanques
        for t = 1, #unit.tank_data_tbl do
            _record_multiblock_build(t, tnk_build[t], unit.tank_data_tbl, unit.tank_ps_tbl)
        end
    end

    -- construcoes da instalacao

    local fac = io.facility

    local tnk_build, sps_build, ess_build = table.unpack(data[#io.units + 1])

    for t = 1, #fac.tank_data_tbl do
        _record_multiblock_build(t, tnk_build[t], fac.tank_data_tbl, fac.tank_ps_tbl)
    end

    for s = 1, #fac.sps_data_tbl do
        _record_multiblock_build(s, sps_build[s], fac.sps_data_tbl, fac.sps_ps_tbl)
    end

    if fac.ess_type == types.ESS.ENERGY_CORE then
        for e = 1, #fac.ecore_data_tbl do
            _record_multiblock_build(e, ess_build[e][1], fac.ecore_data_tbl, fac.ecore_ps_tbl)

            fac.ecore_data_tbl[e].virtual = ess_build[e][2]
            for k, v in pairs(fac.ecore_data_tbl[e].virtual) do fac.ecore_ps_tbl[e].publish(k, v) end
        end
    else
        for i = 1, #fac.induction_data_tbl do
            _record_multiblock_build(i, ess_build[i], fac.induction_data_tbl, fac.induction_ps_tbl)
        end
    end
end

-- atualiza o app de controle com dados das unidades a partir de API_GET_CTRL
---@param data table
function iorx.record_control_data(data)
    for u_id = 1, #data do
        local unit = io.units[u_id]
        local u_ps = unit.unit_ps
        local u_data = data[u_id]
        local rct = unit.reactor_data

        unit.connected = u_data[1]

        rct.rps_tripped = u_data[2]
        u_ps.publish("rps_tripped", u_data[2])
        rct.mek_status.status = u_data[3]
        u_ps.publish("status", u_data[3])
        rct.mek_status.temp = u_data[4]
        u_ps.publish("temp", u_data[4])
        rct.mek_status.burn_rate = u_data[5]
        u_ps.publish("burn_rate", u_data[5])
        rct.mek_status.act_burn_rate = u_data[6]
        u_ps.publish("act_burn_rate", u_data[6])
        rct.mek_struct.max_burn = u_data[7]
        u_ps.publish("max_burn", u_data[7])

        unit.annunciator.AutoControl = u_data[8]
        u_ps.publish("AutoControl", u_data[8])

        unit.a_group = u_data[9]
        u_ps.publish("auto_group_id", unit.a_group)
        u_ps.publish("auto_group", types.AUTO_GROUP_NAMES[unit.a_group + 1])

        local control_status = 1

        if unit.connected then
            if rct.rps_tripped then
                control_status = 2
            end

            if rct.mek_status.status then
                control_status = util.trinary(unit.annunciator.AutoControl, 4, 3)
            end
        end

        u_ps.publish("U_ControlStatus", control_status)
    end
end

-- atualiza o app de processo com dados das unidades a partir de API_GET_PROC
---@param data table
function iorx.record_process_data(data)
    -- obtem dados das unidades
    for u_id = 1, #io.units do
        local unit = io.units[u_id]
        local u_ps = unit.unit_ps
        local u_data = data[u_id]

        unit.reactor_data.mek_status.status = u_data[1]
        unit.reactor_data.mek_struct.max_burn = u_data[2]
        unit.annunciator.AutoControl = u_data[6]
        unit.a_group = u_data[7]

        u_ps.publish("status", u_data[1])
        u_ps.publish("max_burn", u_data[2])
        u_ps.publish("burn_limit", u_data[3])
        u_ps.publish("U_AutoReady", u_data[4])
        u_ps.publish("U_AutoDegraded", u_data[5])
        u_ps.publish("AutoControl", u_data[6])
        u_ps.publish("auto_group_id", unit.a_group)
        u_ps.publish("auto_group", types.AUTO_GROUP_NAMES[unit.a_group + 1])
    end

    -- obtem dados da instalacao
    local fac = io.facility
    local f_ps = fac.ps
    local f_data = data[#io.units + 1]

    fac.status_lines = f_data[1]

    fac.auto_ready = f_data[2][1]
    fac.auto_active = f_data[2][2]
    fac.auto_ramping = f_data[2][3]
    fac.auto_saturated = f_data[2][4]

    fac.auto_scram = f_data[3]
    fac.ascram_status = f_data[4]

    f_ps.publish("status_line_1", fac.status_lines[1])
    f_ps.publish("status_line_2", fac.status_lines[2])

    f_ps.publish("auto_ready", fac.auto_ready)
    f_ps.publish("auto_active", fac.auto_active)
    f_ps.publish("auto_ramping", fac.auto_ramping)
    f_ps.publish("auto_saturated", fac.auto_saturated)

    f_ps.publish("auto_scram", fac.auto_scram)
    f_ps.publish("as_ess_fault", fac.ascram_status.ess_fault)
    f_ps.publish("as_ess_fill", fac.ascram_status.ess_fill)
    f_ps.publish("as_crit_alarm", fac.ascram_status.crit_alarm)
    f_ps.publish("as_radiation", fac.ascram_status.radiation)
    f_ps.publish("as_gen_fault", fac.ascram_status.gen_fault)

    f_ps.publish("process_mode", f_data[5][1])
    f_ps.publish("process_burn_target", f_data[5][2])
    f_ps.publish("process_range_start", f_data[5][3])
    f_ps.publish("process_range_stop", f_data[5][4])
    f_ps.publish("process_charge_target", f_data[5][5])
    f_ps.publish("process_gen_target", f_data[5][6])
end

-- atualiza o app de rejeitos com dados das unidades a partir de API_GET_WASTE
---@param data table
function iorx.record_waste_data(data)
    local com_waste = io.facility.combined_waste

    if not com_waste then
        -- obtem dados das unidades
        for u_id = 1, #io.units do
            local unit = io.units[u_id]
            local u_ps = unit.unit_ps
            local u_data = data[u_id]

            unit.waste_mode = u_data[1]
            unit.waste_product = u_data[2]
            unit.num_snas = u_data[3]
            unit.sna_peak_rate_in = u_data[4]
            unit.sna_peak_rate_out = u_data[5]
            unit.sna_max_rate_in = u_data[6]
            unit.sna_max_rate_out = u_data[7]
            unit.sna_in_rate = u_data[8]
            unit.sna_out_rate = u_data[9]
            unit.waste_stats = u_data[10]

            u_ps.publish("U_AutoWaste", unit.waste_mode == types.WASTE_MODE.AUTO)
            u_ps.publish("U_WasteMode", unit.waste_mode)
            u_ps.publish("U_WasteProduct", unit.waste_product)

            u_ps.publish("sna_count", unit.num_snas)
            u_ps.publish("sna_peak_rate_in", unit.sna_peak_rate_in)
            u_ps.publish("sna_peak_rate_out", unit.sna_peak_rate_out)
            u_ps.publish("sna_max_rate_in", unit.sna_max_rate_in)
            u_ps.publish("sna_max_rate_out", unit.sna_max_rate_out)
            u_ps.publish("sna_in_rate", unit.sna_in_rate)
            u_ps.publish("sna_out_rate", unit.sna_out_rate)

            u_ps.publish("pu_rate", unit.waste_stats[1])
            u_ps.publish("po_rate", unit.waste_stats[2])
            u_ps.publish("po_pl_rate", unit.waste_stats[3])
        end
    end

    -- obtem dados da instalacao
    local fac = io.facility
    local f_ps = fac.ps
    local f_data = data[#io.units + 1]

    fac.auto_current_waste_product = f_data[1]
    fac.auto_pu_fallback_active = f_data[2]
    fac.auto_sps_disabled = f_data[3]

    f_ps.publish("current_waste_product", fac.auto_current_waste_product)
    f_ps.publish("pu_fallback_active", fac.auto_pu_fallback_active)
    f_ps.publish("sps_disabled_low_power", fac.auto_sps_disabled)

    f_ps.publish("process_waste_product", f_data[4])
    f_ps.publish("process_pu_fallback", f_data[5])
    f_ps.publish("process_sps_low_power", f_data[6])

    fac.waste_stats = f_data[7]

    f_ps.publish("burn_sum", fac.waste_stats[1])
    f_ps.publish("pu_rate", fac.waste_stats[2])
    f_ps.publish("po_rate", fac.waste_stats[3])
    f_ps.publish("po_pl_rate", fac.waste_stats[4])
    f_ps.publish("po_am_rate", fac.waste_stats[5])
    f_ps.publish("spent_waste_rate", fac.waste_stats[6])

    fac.sps_ps_tbl[1].publish("SPSStateStatus", f_data[8])
    f_ps.publish("sps_process_rate", f_data[9])

    if com_waste and type(f_data[10]) == "table" then
        local sna = f_data[10]

        fac.num_snas = sna[1]
        fac.sna_peak_rate_in = sna[2]
        fac.sna_peak_rate_out = sna[3]
        fac.sna_max_rate_in = sna[4]
        fac.sna_max_rate_out = sna[5]
        fac.sna_in_rate = sna[6]
        fac.sna_out_rate = sna[7]

        f_ps.publish("sna_count", fac.num_snas)
        f_ps.publish("sna_peak_rate_in", fac.sna_peak_rate_in)
        f_ps.publish("sna_peak_rate_out", fac.sna_peak_rate_out)
        f_ps.publish("sna_max_rate_in", fac.sna_max_rate_in)
        f_ps.publish("sna_max_rate_out", fac.sna_max_rate_out)
        f_ps.publish("sna_in_rate", fac.sna_in_rate)
        f_ps.publish("sna_out_rate", fac.sna_out_rate)
    end
end

-- atualiza o app de monitor de radiacao com dados dos monitores a partir de API_GET_RAD
---@param data table
function iorx.record_radiation_data(data)
    -- monitores de radiacao das unidades

    for u_id = 1, #io.units do
        local unit      = io.units[u_id]
        local max_rad   = 0
        local connected = {}

        unit.radiation = types.new_zero_radiation_reading()
        unit.rad_monitors = data[u_id]

        for id, mon in pairs(unit.rad_monitors) do
            table.insert(connected, id)

            unit.unit_ps.publish("radiation@" .. id, mon.radiation)

            if mon.raw > max_rad then
                max_rad = mon.raw
                unit.radiation = mon.radiation
            end
        end

        unit.unit_ps.publish("radiation", unit.radiation)
        unit.unit_ps.publish("radiation_monitors", textutils.serialize(connected))
    end

    -- monitores de radiacao da instalacao

    local fac = io.facility

    fac.radiation = types.new_zero_radiation_reading()
    fac.rad_monitors = data[#io.units + 1]

    local max_rad = 0
    local connected = {}

    for id, mon in pairs(fac.rad_monitors) do
        table.insert(connected, id)

        fac.ps.publish("radiation@" .. id, mon.radiation)

        if mon.raw > max_rad then
            max_rad = mon.raw
            fac.radiation = mon.radiation
        end
    end

    fac.ps.publish("radiation", fac.radiation)
    fac.ps.publish("radiation_monitors", textutils.serialize(connected))
end

local comp_record = {}

-- atualiza o app de computadores com os dados de rede a partir de INFO_LIST_CMP
---@param data table
function iorx.record_network_data(data)
    local ps        = io.ps
    local connected = {}
    local crd_online = false

    ps.publish("comp_online", #data)

    -- adiciona/atualiza computadores conectados
    for i = 1, #data do
        local entry = data[i]
        local type  = entry[1]
        local id    = entry[2]
        local pfx   = "comp_" .. id

        connected[id] = true

        if type == DEV_TYPE.SVR then
            ps.publish("comp_svr_addr", id)
            ps.publish("comp_svr_fw", entry[3])
        elseif type == DEV_TYPE.CRD then
            crd_online = true
            ps.publish("comp_crd_addr", id)
            ps.publish("comp_crd_fw", entry[3])
            ps.publish("comp_crd_rtt", entry[4])
        else
            ps.publish(pfx .. "_type", entry[1])
            ps.publish(pfx .. "_addr", id)
            ps.publish(pfx .. "_fw", entry[3])
            ps.publish(pfx .. "_rtt", entry[4])

            if type == DEV_TYPE.PLC then
                ps.publish(pfx .. "_unit", entry[5])
            end

            if not comp_record[id] then
                comp_record[id] = true

                -- aciona o app para criar o novo elemento
                ps.publish("comp_connect", id)
            end
        end
    end

    -- trata se o coordenador esta online ou nao
    -- nao e preciso se preocupar com o supervisor pois estes dados vem dele, entao deve estar 'online' se recebido
    ps.publish("comp_crd_online", crd_online)
    if not crd_online then
        ps.publish("comp_crd_addr", "---")
        ps.publish("comp_crd_fw", "---")
        ps.publish("comp_crd_rtt", "---")
    end

    -- redefine o valor publicado
    ps.publish("comp_connect", false)

    -- remove computadores desconectados
    for id, state in pairs(comp_record) do
        if state and not connected[id] then
            comp_record[id] = false

            -- aciona o app para excluir o elemento
            ps.publish("comp_disconnect", id)
        end
    end

    -- redefine o valor publicado
    ps.publish("comp_disconnect", false)
end

-- limpa o registro de computadores conectados rastreados
function iorx.clear_comp_record() comp_record = {} end

return function (io_obj)
    io = io_obj
    return iorx
end
