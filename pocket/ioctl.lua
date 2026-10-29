--
-- Controle de E/S para Integracao do Pocket com Supervisor e Coordenador
--

local psil    = require("scada-common.psil")
local types   = require("scada-common.types")
local util    = require("scada-common.util")

local iorx    = require("pocket.iorx")
local process = require("pocket.process")

local ALARM = types.ALARM
local ALARM_STATE = types.ALARM_STATE

local ENERGY_SCALE = types.ENERGY_SCALE
local ENERGY_UNITS = types.ENERGY_SCALE_UNITS
local TEMP_SCALE = types.TEMP_SCALE
local TEMP_UNITS = types.TEMP_SCALE_UNITS

local WARN_TT = 40
local HIGH_TT = 80

local ioctl = {}

---@enum POCKET_LINK_STATE
local LINK_STATE = {
    UNLINKED = 0,
    SV_LINK_ONLY = 1,
    API_LINK_ONLY = 2,
    LINKED = 3
}

ioctl.LINK_STATE = LINK_STATE

---@class pkt_io
local io = {
    version = "unknown", -- versao do pocket
    ps = psil.create(),  -- PSIL do pocket
    loader_require = { sv = false, api = false }
}

local config = nil  ---@type pkt_config
local comms  = nil  ---@type pocket_comms

-- inicializa componentes independentes de instalacao do controle de E/S do pocket
---@param pkt_comms pocket_comms
---@param nav pocket_nav
---@param cfg pkt_config
function ioctl.init_core(pkt_comms, nav, cfg)
    comms = pkt_comms
    config = cfg

    ioctl.rx = iorx(io)

    io.nav = nav

    ---@class pocket_ioctl_diag
    io.diag = {}

    -- teste de alarmes
    io.diag.tone_test = {
        test_1 = function (state) comms.diag__set_alarm_tone(1, state) end,
        test_2 = function (state) comms.diag__set_alarm_tone(2, state) end,
        test_3 = function (state) comms.diag__set_alarm_tone(3, state) end,
        test_4 = function (state) comms.diag__set_alarm_tone(4, state) end,
        test_5 = function (state) comms.diag__set_alarm_tone(5, state) end,
        test_6 = function (state) comms.diag__set_alarm_tone(6, state) end,
        test_7 = function (state) comms.diag__set_alarm_tone(7, state) end,
        test_8 = function (state) comms.diag__set_alarm_tone(8, state) end,
        stop_tones = function () comms.diag__set_alarm_tone(0, false) end,

        test_breach = function (state) comms.diag__set_alarm(ALARM.ContainmentBreach, state) end,
        test_rad = function (state) comms.diag__set_alarm(ALARM.ContainmentRadiation, state) end,
        test_lost = function (state) comms.diag__set_alarm(ALARM.ReactorLost, state) end,
        test_crit = function (state) comms.diag__set_alarm(ALARM.CriticalDamage, state) end,
        test_dmg = function (state) comms.diag__set_alarm(ALARM.ReactorDamage, state) end,
        test_overtemp = function (state) comms.diag__set_alarm(ALARM.ReactorOverTemp, state) end,
        test_hightemp = function (state) comms.diag__set_alarm(ALARM.ReactorHighTemp, state) end,
        test_wasteleak = function (state) comms.diag__set_alarm(ALARM.ReactorWasteLeak, state) end,
        test_highwaste = function (state) comms.diag__set_alarm(ALARM.ReactorHighWaste, state) end,
        test_rps = function (state) comms.diag__set_alarm(ALARM.RPSTransient, state) end,
        test_rcs = function (state) comms.diag__set_alarm(ALARM.RCSTransient, state) end,
        test_turbinet = function (state) comms.diag__set_alarm(ALARM.TurbineTrip, state) end,
        stop_alarms = function () comms.diag__set_alarm(0, false) end,

        get_tone_states = function () comms.diag__get_alarm_tones() end,

        tone_buttons = {}, ---@type SwitchButton[]
        alarm_buttons = {} ---@type Checkbox[]
    }

    -- lista de computadores
    io.diag.get_comps = function () comms.diag__get_computers() end

    -- acesso a API
    ---@class pocket_ioctl_api
    io.api = {
        get_fac   = function () comms.api__get_facility() end,
        get_unit  = function (unit) comms.api__get_unit(unit) end,
        get_ctrl  = function () comms.api__get_control() end,
        get_proc  = function () comms.api__get_process() end,
        get_waste = function () comms.api__get_waste() end,
        get_rad   = function () comms.api__get_rad() end,
        get_build = function () comms.api__get_build() end
    }
end

-- inicializa componentes dependentes de instalacao do controle de E/S do pocket
---@param conf facility_conf configuracao da instalacao
function ioctl.init_fac(conf)
    local temp_scale, energy_scale = config.TempScale, config.EnergyScale
    io.temp_label = TEMP_UNITS[temp_scale]
    io.energy_label = ENERGY_UNITS[energy_scale]

    -- rotulo de unidade de temperatura e funcao de conversao (de Kelvin)
    if temp_scale == TEMP_SCALE.CELSIUS then
        io.temp_convert = function (t) return t - 273.15 end
    elseif temp_scale == TEMP_SCALE.FAHRENHEIT then
        io.temp_convert = function (t) return (1.8 * (t - 273.15)) + 32 end
    elseif temp_scale == TEMP_SCALE.RANKINE then
        io.temp_convert = function (t) return 1.8 * t end
    else
        io.temp_label = "K"
        io.temp_convert = function (t) return t end
    end

    -- rotulo de unidade de energia e funcao de conversao (de Joules, a menos que especificado de outra forma)
    if energy_scale == ENERGY_SCALE.FE or energy_scale == ENERGY_SCALE.RF then
        io.energy_convert = util.joules_to_fe_rf
        io.energy_convert_from_fe = function (t) return t end
        io.energy_convert_to_fe = function (t) return t end
    else
        io.energy_label = "J"
        io.energy_convert = function (t) return t end
        io.energy_convert_from_fe = util.fe_rf_to_joules
        io.energy_convert_to_fe = util.joules_to_fe_rf
    end

    -- estrutura de dados da instalacao
    ---@class pkt_io_facility
    io.facility = {
        num_units = conf.num_units,
        tank_mode = conf.cooling.fac_tank_mode,
        tank_defs = conf.cooling.fac_tank_defs,
        tank_list = conf.cooling.fac_tank_list,
        tank_conns = conf.cooling.fac_tank_conns,
        tank_fluid_types = conf.cooling.tank_fluid_types,
        combined_waste = conf.com_waste,
        ess_type = conf.ess,
        all_sys_ok = false,
        rtu_count = 0,

        status_lines = { "", "" },

        auto_ready = false,
        auto_active = false,
        auto_ramping = false,
        auto_saturated = false,

        auto_scram = false,
        ---@type ascram_status
        ascram_status = {
            ess_fault = false,
            ess_fill = false,
            crit_alarm = false,
            radiation = false,
            gen_fault = false
        },

        ---@type WASTE_PRODUCT
        auto_current_waste_product = types.WASTE_PRODUCT.PLUTONIUM,
        auto_pu_fallback_active = false,
        auto_sps_disabled = false,
        waste_stats = { 0, 0, 0, 0, 0, 0 }, -- rejeito entrada, pu, po, pastilhas po, am, rejeito esgotado

        num_snas = 0,
        sna_peak_rate_in = 0.0,
        sna_peak_rate_out = 0.0,
        sna_max_rate_in = 0.0,
        sna_max_rate_out = 0.0,
        sna_in_rate = 0.0,
        sna_out_rate = 0.0,

        radiation = types.new_zero_radiation_reading(),

        start_ack = nil,         ---@type fun(success: boolean)
        stop_ack = nil,          ---@type fun(success: boolean)
        scram_ack = nil,         ---@type fun(success: boolean)
        ack_alarms_ack = nil,    ---@type fun(success: boolean)

        ps = psil.create(),

        induction_ps_tbl = {},   ---@type psil[]
        induction_data_tbl = {}, ---@type imatrix_session_db[]

        ecore_ps_tbl = {},       ---@type psil[]
        ecore_data_tbl = {},     ---@type ecore_session_db[]

        sps_ps_tbl = {},         ---@type psil[]
        sps_data_tbl = {},       ---@type sps_session_db[]

        tank_ps_tbl = {},        ---@type psil[]
        tank_data_tbl = {},      ---@type dynamicv_session_db[]

        rad_monitors = {}        ---@type { radiation: radiation_reading, raw: number }[]
    }

    -- cria tabelas de ESS e SPS (atualmente apenas 1 de cada e suportado)
    table.insert(io.facility.induction_ps_tbl, psil.create())
    table.insert(io.facility.induction_data_tbl, types.new_induction_db())
    table.insert(io.facility.ecore_ps_tbl, psil.create())
    table.insert(io.facility.ecore_data_tbl, types.new_ecore_db())
    table.insert(io.facility.sps_ps_tbl, psil.create())
    table.insert(io.facility.sps_data_tbl, types.new_sps_db())

    -- cria tabelas de tanques da instalacao
    for i = 1, #io.facility.tank_list do
        if io.facility.tank_list[i] == 2 then
            table.insert(io.facility.tank_ps_tbl, psil.create())
            table.insert(io.facility.tank_data_tbl, types.new_tank_db())
        end
    end

    -- cria estruturas de dados das unidades
    io.units = {}   ---@type pkt_io_unit[]
    for i = 1, conf.num_units do
        ---@class pkt_io_unit
        local entry = {
            unit_id = i,
            connected = false,

            num_boilers = 0,
            num_turbines = 0,
            num_snas = 0,
            has_tank = conf.cooling.r_cool[i].TankConnection,

            status_lines = { "", "" },

            auto_ready = false,
            auto_degraded = false,

            control_state = false,
            burn_rate_cmd = 0.0,
            radiation = types.new_zero_radiation_reading(),

            sna_peak_rate_in = 0.0,
            sna_peak_rate_out = 0.0,
            sna_max_rate_in = 0.0,
            sna_max_rate_out = 0.0,
            sna_in_rate = 0.0,
            sna_out_rate = 0.0,

            waste_mode = types.WASTE_MODE.MANUAL_PLUTONIUM,
            waste_product = types.WASTE_PRODUCT.PLUTONIUM,

            last_rate_change_ms = 0,
            turbine_flow_stable = false,
            fuel_burn_rate_limited = false,
            waste_stats = { 0, 0, 0 },  -- plutonio, polonio, pastilhas po

            -- grupo de controle automatico
            a_group = types.AUTO_GROUP.MANUAL,

            start = function () process.start(i) end,
            scram = function () process.scram(i) end,
            reset_rps = function () process.reset_rps(i) end,
            ack_alarms = function () process.ack_all_alarms(i) end,
            set_burn = function (rate) process.set_rate(i, rate) end,   ---@param rate number taxa de queima

            start_ack = nil,        ---@type fun(success: boolean)
            scram_ack = nil,        ---@type fun(success: boolean)
            reset_rps_ack = nil,    ---@type fun(success: boolean)
            ack_alarms_ack = nil,   ---@type fun(success: boolean)

            ---@type { [ALARM]: ALARM_STATE }
            alarms = { ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE, ALARM_STATE.INACTIVE },

---@diagnostic disable-next-line: missing-fields
            annunciator = {},       ---@type annunciator

            ---@type unit_properties
            properties = {
                flow_perf = {}, ---@type number[] desempenho de fluxo da turbina
                generators = {} ---@type generator_properties[] propriedades do gerador da turbina
            },

            unit_ps = psil.create(),
            reactor_data = types.new_reactor_db(),

            boiler_ps_tbl = {},     ---@type psil[]
            boiler_data_tbl = {},   ---@type boilerv_session_db[]

            turbine_ps_tbl = {},    ---@type psil[]
            turbine_data_tbl = {},  ---@type turbinev_session_db[]

            tank_ps_tbl = {},       ---@type psil[]
            tank_data_tbl = {},     ---@type dynamicv_session_db[]

            rad_monitors = {}       ---@type { radiation: radiation_reading, raw: number }[]
        }

        -- em outros modos de instalacao, sobrescreve a opcao TANK da unidade com as definicoes de tanques da instalacao
        if io.facility.tank_mode ~= 0 then
            entry.has_tank = conf.cooling.fac_tank_defs[i] > 0
        end

        -- cria tabelas de caldeiras
        for _ = 1, conf.cooling.r_cool[i].BoilerCount do
            table.insert(entry.boiler_ps_tbl, psil.create())
            table.insert(entry.boiler_data_tbl, types.new_boiler_db())
        end

        -- cria tabelas de turbinas
        for _ = 1, conf.cooling.r_cool[i].TurbineCount do
            table.insert(entry.properties.generators, { { multiplier = 0, efficiency = 0 } })
            table.insert(entry.turbine_ps_tbl, psil.create())
            table.insert(entry.turbine_data_tbl, types.new_turbine_db())
        end

        -- cria tabelas de tanques
        if io.facility.tank_defs[i] == 1 then
            table.insert(entry.tank_ps_tbl, psil.create())
            table.insert(entry.tank_data_tbl, types.new_tank_db())
        end

        entry.num_boilers = #entry.boiler_data_tbl
        entry.num_turbines = #entry.turbine_data_tbl

        table.insert(io.units, entry)
    end

    -- passa o controle de E/S aqui, pois nao pode ser importado com require devido a loop de require
    process.init(io, comms)
end

-- define o estado do link de rede
---@param state POCKET_LINK_STATE
---@param sv_addr integer|false|nil endereco do supervisor se conectado, nil se inalterado, false se desconectado
---@param api_addr integer|false|nil endereco do coordenador se conectado, nil se inalterado, false se desconectado
function ioctl.report_link_state(state, sv_addr, api_addr)
    io.ps.publish("link_state", state)

    if state == LINK_STATE.API_LINK_ONLY or state == LINK_STATE.UNLINKED then
        io.ps.publish("svr_conn_quality", 0)
    end

    if state == LINK_STATE.SV_LINK_ONLY or state == LINK_STATE.UNLINKED then
        io.ps.publish("crd_conn_quality", 0)
    end

    if sv_addr then
        io.ps.publish("sv_addr", util.c(sv_addr, ":", config.SVR_Channel))
    elseif sv_addr == false then
        io.ps.publish("sv_addr", "desconhecido (s/ link)")
    end

    if api_addr then
        io.ps.publish("api_addr", util.c(api_addr, ":", config.CRD_Channel))
    elseif api_addr == false then
        io.ps.publish("api_addr", "desconhecido (s/ link)")
    end
end

-- mostra o motivo pelo qual a conexao com o supervisor nao esta conectando
function ioctl.report_svr_link_error(msg) io.ps.publish("svr_link_msg", msg) end

-- mostra o motivo pelo qual a conexao com a API do coordenador nao esta conectando
function ioctl.report_crd_link_error(msg) io.ps.publish("api_link_msg", msg) end

-- determina a qualidade da conexao do supervisor (tempo de viagem)
---@param trip_time integer
function ioctl.report_svr_tt(trip_time)
    local state = 3
    if trip_time > HIGH_TT then
        state = 1
    elseif trip_time > WARN_TT then
        state = 2
    end

    io.ps.publish("svr_conn_quality", state)
end

-- determina a qualidade da conexao do coordenador (tempo de viagem)
---@param trip_time integer
function ioctl.report_crd_tt(trip_time)
    local state = 3
    if trip_time > HIGH_TT then
        state = 1
    elseif trip_time > WARN_TT then
        state = 2
    end

    io.ps.publish("crd_conn_quality", state)
end

-- obtem o banco de dados do controlador de E/S
function ioctl.get_db() return io end

return ioctl
