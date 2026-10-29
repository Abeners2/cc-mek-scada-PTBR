--
-- Acesso ao Sistema SCADA em um Pocket Computer
--

---@diagnostic disable-next-line: lowercase-global
pocket = pocket or periphemu    -- luacheck: ignore pocket

local _is_pocket_env = pocket   -- luacheck: ignore pocket

require("/initenv").init_env()

local crash     = require("scada-common.crash")
local log       = require("scada-common.log")
local mqueue    = require("scada-common.mqueue")
local network   = require("scada-common.network")
local ppm       = require("scada-common.ppm")
local util      = require("scada-common.util")

local configure = require("pocket.configure")
local ioctl     = require("pocket.ioctl")
local pocket    = require("pocket.pocket")
local renderer  = require("pocket.renderer")
local threads   = require("pocket.threads")

local POCKET_VERSION = "1.5.1"

local println = util.println
local println_ts = util.println_ts

-- verifica o ambiente (permite Pocket ou CraftOS-PC)
if not _is_pocket_env then
    println("Voce so pode usar este aplicativo em um pocket computer.")
    return
end

----------------------------------------
-- obtem a configuracao
----------------------------------------

if not pocket.load_config() then
    -- tenta reconfigurar (acao do usuario)
    local success, error = configure.configure(true)
    if success then
        if not pocket.load_config() then
            println("falha ao carregar uma configuracao valida, por favor reconfigure")
            return
        end
    else
        println("erro de configuracao: " .. error)
        return
    end
end

local config = pocket.config

----------------------------------------
-- inicializacao do log
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("INICIANDO pocket.startup v" .. POCKET_VERSION)
log.info("========================================")

crash.set_env("pocket", POCKET_VERSION)
crash.dbg_log_env()

----------------------------------------
-- aplicacao principal
----------------------------------------

local function main()
    ----------------------------------------
    -- inicializacao do sistema
    ----------------------------------------

    -- monta dispositivos conectados
    ppm.mount_all()

    -- registra a versao para a GUI
    ioctl.get_db().version = POCKET_VERSION

    ----------------------------------------
    -- alocacao de memoria
    ----------------------------------------

    -- memoria compartilhada entre threads
    ---@class pkt_shared_memory
    local __shared_memory = {
        -- flags de estado do sistema pocket
        ---@class pkt_state
        pkt_state = {
            ui_ok = false,
            ui_error = nil,
            shutdown = false
        },

        -- dispositivos principais do pocket
        pkt_dev = {
            modem = ppm.get_wireless_modem()
        },

        -- objetos do sistema
        pkt_sys = {
            nic = nil,          ---@type nic
            pocket_comms = nil, ---@type pocket_comms
            sv_wd = nil,        ---@type watchdog
            api_wd = nil,       ---@type watchdog
            nav = nil           ---@type pocket_nav
        },

        -- filas de mensagens
        q = {
            mq_render = mqueue.new()
        }
    }

    local smem_dev = __shared_memory.pkt_dev
    local smem_sys = __shared_memory.pkt_sys

    local pkt_state = __shared_memory.pkt_state

    ----------------------------------------
    -- configura o sistema
    ----------------------------------------

    smem_sys.nav = pocket.init_nav(__shared_memory)

    -- inicializacao de autenticacao de mensagens
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        network.init_mac(config.AuthKey)
    end

    ioctl.report_link_state(ioctl.LINK_STATE.UNLINKED)

    -- obtem o modem de comunicacao
    if smem_dev.modem == nil then
        println("inicializacao> modem sem fio nao encontrado: crie o pocket computer com um modem sem fio")
        log.fatal("startup> no wireless modem on startup")
        return
    end

    -- cria watchdogs de conexao
    smem_sys.sv_wd = util.new_watchdog(config.ConnTimeout)
    smem_sys.sv_wd.cancel()
    smem_sys.api_wd = util.new_watchdog(config.ConnTimeout)
    smem_sys.api_wd.cancel()
    log.debug("startup> conn watchdogs created")

    -- cria interface de rede e configura comunicacoes
    smem_sys.nic = network.nic(smem_dev.modem)
    smem_sys.pocket_comms = pocket.comms(POCKET_VERSION, smem_sys.nic, smem_sys.sv_wd, smem_sys.api_wd, smem_sys.nav)
    log.debug("startup> comms init")

    -- inicializa controle de E/S
    ioctl.init_core(smem_sys.pocket_comms, smem_sys.nav, config)

    ----------------------------------------
    -- inicia a UI
    ----------------------------------------

    local ui_message
    pkt_state.ui_ok, ui_message = renderer.try_start_ui()
    if not pkt_state.ui_ok then
        println(util.c("Erro de UI: ", ui_message))
        log.error(util.c("startup> GUI render failed with error ", ui_message))
    end

    ----------------------------------------
    -- inicia o sistema
    ----------------------------------------

    if pkt_state.ui_ok then
        -- inicializa as threads
        local main_thread   = threads.thread__main(__shared_memory)
        local render_thread = threads.thread__render(__shared_memory)

        log.info("startup> completed")

        -- executa as threads
        parallel.waitForAll(main_thread.p_exec, render_thread.p_exec)

        renderer.close_ui()

        if not pkt_state.ui_ok then
            println(util.c("UI travou com erro: ", pkt_state.ui_error))
        end
    else
        println_ts("Falha na criacao da UI")
    end

    println_ts("encerrado")
    log.info("exited")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    crash.exit()
else
    log.close()
end
