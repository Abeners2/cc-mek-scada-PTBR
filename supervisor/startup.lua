--
-- Supervisor SCADA da Instalação de Geração Nuclear
--

require("/initenv").init_env()

local crash      = require("scada-common.crash")
local comms      = require("scada-common.comms")
local constants  = require("scada-common.constants")
local log        = require("scada-common.log")
local network    = require("scada-common.network")
local ppm        = require("scada-common.ppm")
local tcd        = require("scada-common.tcd")
local types      = require("scada-common.types")
local util       = require("scada-common.util")

local core       = require("graphics.core")

local backplane  = require("supervisor.backplane")
local configure  = require("supervisor.configure")
local databus    = require("supervisor.databus")
local facility   = require("supervisor.facility")
local renderer   = require("supervisor.renderer")
local supervisor = require("supervisor.supervisor")

local svsessions = require("supervisor.session.svsessions")

local SUPERVISOR_VERSION = "1.12.10"

local println = util.println
local println_ts = util.println_ts

----------------------------------------
-- obter configuração
----------------------------------------

if not supervisor.load_config() then
    -- tentar reconfigurar (ação do usuário)
    local success, error = configure.configure(true)
    if success then
        if not supervisor.load_config() then
            println("falha ao carregar uma configuração válida, por favor reconfigure")
            return
        end
    else
        println("erro de configuração: " .. error)
        return
    end
end

local config = supervisor.config

local cfv = util.new_validator()

cfv.assert_eq(#config.CoolingConfig, config.UnitCount)
assert(cfv.valid(), "startup> o número de configurações de resfriamento do reator é diferente do número de unidades")

for i = 1, config.UnitCount do
    cfv.assert_type_table(config.CoolingConfig[i])
    assert(cfv.valid(), "startup> entrada de resfriamento ausente para a unidade de reator " .. i)
    cfv.assert_type_int(config.CoolingConfig[i].BoilerCount)
    cfv.assert_type_int(config.CoolingConfig[i].TurbineCount)
    cfv.assert_type_bool(config.CoolingConfig[i].TankConnection)
    assert(cfv.valid(), "startup> campos de caldeira/turbina/tanque ausentes para a unidade de reator " .. i)
    cfv.assert_range(config.CoolingConfig[i].BoilerCount, 0, 2)
    cfv.assert_range(config.CoolingConfig[i].TurbineCount, 1, 3)
    assert(cfv.valid(), "startup> número de caldeiras e/ou turbinas fora do intervalo fornecido para a unidade de reator " .. i)
end

if config.FacilityTankMode > 0 then
    assert(config.UnitCount == #config.FacilityTankDefs, "startup> o número de definições de tanques da instalação deve ser igual ao número de unidades no modo de tanque da instalação")

    for i = 1, config.UnitCount do
        local def = config.FacilityTankDefs[i]
        cfv.assert_type_int(def)
        cfv.assert_range(def, 0, 2)
        assert(cfv.valid(), "startup> definição de tanque da instalação inválida para a unidade de reator " .. i)

        local entry = config.FacilityTankList[i]
        cfv.assert_type_int(entry)
        cfv.assert_range(entry, 0, 2)
        assert(cfv.valid(), "startup> entrada da lista de tanques da instalação inválida para o tanque " .. i)

        local conn = config.FacilityTankConns[i]
        cfv.assert_type_int(conn)
        cfv.assert_range(conn, 0, #config.FacilityTankDefs)
        assert(cfv.valid(), "startup> conexão de tanque da instalação inválida para a unidade de reator " .. i)

        local type = config.TankFluidTypes[i]
        cfv.assert_type_int(type)
        cfv.assert_range(type, 0, types.COOLANT_TYPE.SODIUM)
        assert(cfv.valid(), "startup> tipo de fluido de tanque inválido para o tanque " .. i)
    end
end

----------------------------------------
-- inicialização do log
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("INICIANDO supervisor.startup v" .. SUPERVISOR_VERSION)
log.info("========================================")
println(">> Supervisor SCADA v" .. SUPERVISOR_VERSION .. " <<")

crash.set_env("supervisor", SUPERVISOR_VERSION)
crash.dbg_log_env()

----------------------------------------
-- aplicação principal
----------------------------------------

local function main()
    ----------------------------------------
    -- inicialização
    ----------------------------------------

    -- reportar versões
    databus.tx_versions(SUPERVISOR_VERSION, comms.version)

    -- reportar configuração do Mekanism
    log.debug("MekanismConfig: JOULES_PER_MB = " .. constants.mek.JOULES_PER_MB)
    log.debug("MekanismConfig: TURBINE_DISPERSER_FLOW = " .. constants.mek.TURBINE_DISPERSER_FLOW)
    log.debug("MekanismConfig: TURBINE_VENT_FLOW = " .. constants.mek.TURBINE_VENT_FLOW)
    log.debug("MekanismConfig: TURBINE_GAS_PER_TANK = " .. constants.mek.TURBINE_GAS_PER_TANK)

    -- montar dispositivos conectados
    ppm.mount_all()

    -- inicialização de autenticação de mensagens
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        network.init_mac(config.AuthKey)
    end

    -- inicialização do modem
    if not backplane.init(config) then return end

    -- iniciar UI
    local fp_ok, message = renderer.try_start_ui(config)

    if not fp_ok then
        println_ts(util.c("Erro de UI: ", message))
        log.error(util.c("renderização da GUI do painel frontal falhou com erro ", message))
    else
        -- redefinir println_ts local para não imprimir já que o painel frontal está rodando
        println_ts = function (_) end
    end

    -- criar objetos de instalação e unidade
    local sv_facility = facility.new(config)

    -- criar interface de rede e configurar comunicações
    local superv_comms = supervisor.comms(SUPERVISOR_VERSION, fp_ok, sv_facility)

    -- relógio base do loop (6.67Hz, 3 ticks)
    local MAIN_CLOCK = 0.15
    local loop_clock = util.new_clock(MAIN_CLOCK)

    -- reduzir pela metade a taxa de piscada do LED de pulso (heartbeat)
    local heartbeat_toggle = true

    -- local counters = {}

    -- tarefas periódicas do loop principal
    local function loop_tick()
        -- piscar indicador de pulso na metade da taxa do loop principal devido à rapidez com que roda
        if heartbeat_toggle then databus.heartbeat() end
        heartbeat_toggle = not heartbeat_toggle

        -- iterar sessões
        svsessions.iterate_all()

        -- liberar quaisquer sessões fechadas
        svsessions.free_all_closed()

        -- reportar incompatibilidades de energia
        databus.tx_energy_mismatch(sv_facility.has_energy_mismatch())

        -- iniciar próximo temporizador do relógio
        loop_clock.start()

        -- log.debug(textutils.serialize(counters, { compact = true })); counters = {}
    end

    -- iniciar relógio
    loop_clock.start()

    -- inicializar recuperação de inicialização
    sv_facility.boot_recovery_init(supervisor.boot_state)

    -- loop de eventos
    while true do
        local event, param1, param2, param3, param4, param5 = util.pull_event()

        -- counters[event] = (counters[event] or 0) + 1

        -- tratar evento
        if event == "modem_message" then
            -- recebeu um pacote
            local packet = superv_comms.parse_packet(param1, param2, param3, param4, param5)
            if packet then superv_comms.handle_packet(packet) end
        elseif event == "timer" then
            -- passar este evento de temporizador para o manipulador correto
            if loop_clock.is_clock(param1) then
                -- tick do loop principal
                loop_tick()
            elseif not svsessions.check_all_watchdogs(param1) then  -- verificar watchdogs de sessão
                -- notificar despachante de callback de temporizador, nenhum outro manipulador reivindicou este evento
                tcd.handle(param1)
            end
        elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or
               event == "double_click" then
            -- tratar um evento de mouse
            renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
        elseif event == "peripheral" then
            local type, device = ppm.mount(param1)
            if type ~= nil and device ~= nil then
                backplane.attach(param1, type, device, println_ts)
            end
        elseif event == "peripheral_detach" then
            local type, device = ppm.handle_unmount(param1)
            if type ~= nil and device ~= nil then
                backplane.detach(param1, type, device, println_ts)
            end
        end

        -- verificar solicitação de encerramento
        if event == "terminate" or ppm.should_terminate() then
            println_ts("fechando sessões...")
            log.info("encerramento solicitado, fechando sessões...")
            svsessions.close_all()
            log.info("sessões fechadas")
            break
        end
    end

    sv_facility.clear_boot_state()

    renderer.close_ui()

    util.println_ts("encerrado")
    log.info("encerrado")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    crash.exit()
else
    log.close()
end
