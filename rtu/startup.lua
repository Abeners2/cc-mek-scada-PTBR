--
-- Gateway RTU: Gateway de Unidade Terminal Remota
--

require("/initenv").init_env()

local audio     = require("scada-common.audio")
local comms     = require("scada-common.comms")
local crash     = require("scada-common.crash")
local log       = require("scada-common.log")
local mqueue    = require("scada-common.mqueue")
local network   = require("scada-common.network")
local ppm       = require("scada-common.ppm")
local util      = require("scada-common.util")

local backplane = require("rtu.backplane")
local configure = require("rtu.configure")
local databus   = require("rtu.databus")
local renderer  = require("rtu.renderer")
local rtu       = require("rtu.rtu")
local threads   = require("rtu.threads")
local uinit     = require("rtu.uinit")

local RTU_VERSION = "1.15.3"

local println = util.println
local println_ts = util.println_ts

----------------------------------------
-- obter configuração
----------------------------------------

if not rtu.load_config() then
    -- tentar reconfigurar (ação do usuário)
    local success, error = configure.configure(true)
    if success then
        if not rtu.load_config() then
            println("falha ao carregar uma configuração válida, por favor reconfigure")
            return
        end
    else
        println("erro de configuração: " .. error)
        return
    end
end

local config = rtu.config

----------------------------------------
-- inicialização do log
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("INICIANDO rtu.startup v" .. RTU_VERSION)
log.info("========================================")
println(">> GATEWAY RTU v" .. RTU_VERSION .. " <<")

crash.set_env("rtu", RTU_VERSION)
crash.dbg_log_env()

----------------------------------------
-- aplicação principal
----------------------------------------

local function main()
    ----------------------------------------
    -- inicialização
    ----------------------------------------

    -- relatar versões
    databus.tx_versions(RTU_VERSION, comms.version)

    -- montar dispositivos conectados
    ppm.mount_all()

    -- inicialização de autenticação de mensagens
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        network.init_mac(config.AuthKey)
    end

    -- gerar tons de alarme
    audio.generate_tones()

    ---@class rtu_shared_memory
    local __shared_memory = {
        -- sinalizadores de estado do sistema da RTU
        ---@class rtu_state
        rtu_state = {
            fp_ok = false,
            linked = false,
            shutdown = false
        },

        -- objetos do sistema
        ---@class rtu_sys
        rtu_sys = {
            rtu_comms = nil,     ---@type rtu_comms
            conn_watchdog = nil, ---@type watchdog
            units = {}           ---@type rtu_registry_entry[]
        },

        -- filas de mensagens
        q = {
            mq_comms = mqueue.new()
        }
    }

    local smem_sys  = __shared_memory.rtu_sys
    local rtu_state = __shared_memory.rtu_state
    local units     = __shared_memory.rtu_sys.units

    ----------------------------------------
    -- inicializar e iniciar sistema
    ----------------------------------------

    -- inicialização de modem e alto-falante
    if not backplane.init(config, __shared_memory) then return end

    log.debug("startup> executando uinit()")

    if uinit(config, __shared_memory) then
        -- iniciar UI
        local message
        rtu_state.fp_ok, message = renderer.try_start_ui(config, units)

        if not rtu_state.fp_ok then
            println_ts(util.c("Erro de UI: ", message))
            println("startup> executando sem painel frontal")
            log.error(util.c("falha na renderização da GUI do painel frontal com erro ", message))
            log.info("startup> executando em modo headless sem painel frontal")
        end

        -- iniciar watchdog de conexão
        smem_sys.conn_watchdog = util.new_watchdog(config.ConnTimeout)
        log.debug("startup> watchdog de conexão iniciado")

        -- configurar comunicações
        smem_sys.rtu_comms = rtu.comms(RTU_VERSION, backplane, smem_sys.conn_watchdog)
        log.debug("startup> comunicações inicializadas")

        -- inicializar threads
        local main_thread  = threads.thread__main(__shared_memory)
        local comms_thread = threads.thread__comms(__shared_memory)

        -- montar lista de threads
        local _threads = { main_thread.p_exec, comms_thread.p_exec }
        for i = 1, #units do
            if units[i].thread ~= nil then
                table.insert(_threads, units[i].thread.p_exec)
            end
        end

        log.info("startup> concluído")

        -- executar threads
        parallel.waitForAll(table.unpack(_threads))
    else
        println("falha na inicialização do sistema, saindo...")
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
