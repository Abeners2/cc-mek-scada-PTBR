--
-- Controlador Lógico Programável (PLC) de Reator de Fissão
--

require("/initenv").init_env()

local comms     = require("scada-common.comms")
local crash     = require("scada-common.crash")
local log       = require("scada-common.log")
local mqueue    = require("scada-common.mqueue")
local network   = require("scada-common.network")
local ppm       = require("scada-common.ppm")
local util      = require("scada-common.util")

local backplane = require("reactor-plc.backplane")
local configure = require("reactor-plc.configure")
local databus   = require("reactor-plc.databus")
local plc       = require("reactor-plc.plc")
local renderer  = require("reactor-plc.renderer")
local threads   = require("reactor-plc.threads")

local R_PLC_VERSION = "1.12.20"

local println = util.println
local println_ts = util.println_ts

----------------------------------------
-- get configuration
----------------------------------------

if not plc.load_config() then
    -- tenta reconfigurar (ação do usuário)
    local success, error = configure.configure(true)
    if success then
        if not plc.load_config() then
            println("falha ao carregar uma configuracao valida, por favor reconfigure")
            return
        end
    else
        println("erro de configuracao: " .. error)
        return
    end
end

local config = plc.config

----------------------------------------
-- log init
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("INICIANDO reactor-plc.startup v" .. R_PLC_VERSION)
log.info("========================================")
println(">> PLC do Reator de Fissao v" .. R_PLC_VERSION .. " <<")

crash.set_env("reactor-plc", R_PLC_VERSION)
crash.dbg_log_env()

----------------------------------------
-- main application
----------------------------------------

local function main()
    ----------------------------------------
    -- startup
    ----------------------------------------

    -- reporta versões e ID
    databus.tx_versions(R_PLC_VERSION, comms.version)
    databus.tx_id(config.UnitID)

    -- monta dispositivos conectados
    ppm.mount_all()

    -- inicialização de autenticação de mensagens
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        network.init_mac(config.AuthKey)
    end

    -- memória compartilhada entre threads
    ---@class plc_shared_memory
    local __shared_memory = {
        -- configuração em rede
        networked = config.Networked,

        -- sinalizadores de estado do sistema do PLC
        ---@class plc_state
        plc_state = {
            fp_ok = false,
            shutdown = false,
            degraded = true,
            no_reactor = true,
            reactor_formed = true,
            auto_ctl = false,
            limit_force_ramp = false,
            wd_modem = true,
            wl_modem = true
        },

        -- pontos de ajuste (setpoints) de controle
        ---@class plc_setpoints
        setpoints = {
            burn_rate_en = false,
            burn_rate = 0.0
        },

        -- limites/restrições de controle
        ---@class plc_limits
        limits = {
            -- usa false em vez de math.huge para transmissão
            reportable_max_burn = false, ---@type number|false
            -- taxa máxima de queima para evitar perda de nível de combustível
            fuel_max_burn = math.huge
        },

        -- dispositivos globais do PLC, ainda inicializados pelo backplane
        ---@class plc_dev
        plc_dev = {
            reactor = nil       ---@type FissionReactor
        },

        -- objetos do sistema
        ---@class plc_sys
        plc_sys = {
            rps = nil,          ---@type rps
            plc_comms = nil,    ---@type plc_comms
            conn_watchdog = nil ---@type watchdog
        },

        -- filas de mensagens
        q = {
            mq_rps = mqueue.new(),
            mq_comms_tx = mqueue.new(),
            mq_comms_rx = mqueue.new()
        },

        -- tipos de mensagens da fila de mensagens
        q_types = {
            MQ__RPS_CMD = {
                SCRAM = 1,
                DEGRADED_SCRAM = 2,
                TRIP_TIMEOUT = 3,
                RESET_REATTACH = 4
            },
            MQ__COMM_CMD = {
                SEND_STATUS = 1
            }
        }
    }

    local smem_dev = __shared_memory.plc_dev
    local smem_sys = __shared_memory.plc_sys

    local plc_state = __shared_memory.plc_state

    -- inicialização do reator e modem
    backplane.init(config, __shared_memory)

    -- scram na inicialização se estiver em rede, caso contrário deixa o reator como está
    if __shared_memory.networked and (not plc_state.no_reactor) and plc_state.reactor_formed and smem_dev.reactor.getStatus() then
        log.debug("startup> SCRAM ao ligar")
        smem_dev.reactor.scram()
    end

    -- configura o painel frontal
    local message
    plc_state.fp_ok, message = renderer.try_start_ui(config)

    -- ...ou não
    if not plc_state.fp_ok then
        println_ts(util.c("Erro de UI: ", message))
        println("startup> executando sem painel frontal")
        log.error(util.c("renderizacao da GUI do painel frontal falhou com erro ", message))
        log.info("startup> executando em modo headless sem painel frontal")
    end

    -- imprime uma mensagem de log no terminal enquanto a UI não estiver em execução
    local function _println_no_fp(msg) if not plc_state.fp_ok then println(msg) end end

    ----------------------------------------
    -- initialize PLC
    ----------------------------------------

    -- inicializa o sistema de proteção do reator (RPS)
    smem_sys.rps = plc.rps_init(smem_dev.reactor, plc_state)
    log.debug("startup> rps inicializado")

    -- notifica o usuário sobre o status da configuração do refrigerante de emergência
    if config.EmerCoolEnable then
        _println_no_fp("startup> controle de refrigerante de emergencia pronto")
        log.info("startup> controle de refrigerante de emergencia disponivel")
    end

    -- inicializa comunicações condicionalmente
    if __shared_memory.networked then
        -- watchdog de comunicações
        smem_sys.conn_watchdog = util.new_watchdog(config.ConnTimeout)
        log.debug("startup> watchdog de conexao iniciado")

        -- cria interface de rede e configura comunicações
        smem_sys.plc_comms = plc.comms(R_PLC_VERSION, backplane.active_nic(), __shared_memory)
        log.debug("startup> comunicacoes inicializadas")
    else
        _println_no_fp("startup> iniciando em modo fora de rede")
        log.info("startup> iniciando sem rede")
    end

    databus.tx_hw_status(plc_state)

    _println_no_fp("startup> concluido")
    log.info("startup> concluido")

    -- inicializa threads
    local main_thread = threads.thread__main(__shared_memory)
    local rps_thread  = threads.thread__rps(__shared_memory)

    if __shared_memory.networked then
        -- inicializa threads de comunicação
        local comms_thread_tx = threads.thread__comms_tx(__shared_memory)
        local comms_thread_rx = threads.thread__comms_rx(__shared_memory)

        -- controle de setpoint necessário apenas quando em rede
        local sp_ctrl_thread = threads.thread__setpoint_control(__shared_memory)

        -- executa threads
        parallel.waitForAll(main_thread.p_exec, rps_thread.p_exec, comms_thread_tx.p_exec, comms_thread_rx.p_exec, sp_ctrl_thread.p_exec)

        -- envia o status uma última vez após o desligamento do RPS
        smem_sys.plc_comms.send_status(plc_state.no_reactor, plc_state.reactor_formed)
        smem_sys.plc_comms.send_rps_status()

        -- fecha a conexão
        smem_sys.plc_comms.close()
    else
        -- executa threads, excluindo comunicações
        parallel.waitForAll(main_thread.p_exec, rps_thread.p_exec)
    end

    renderer.close_ui()

    println_ts("encerrado")
    log.info("encerrado")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    crash.exit()
else
    log.close()
end
