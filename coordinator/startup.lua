--
-- Coordenador SCADA da Instalação de Geração Nuclear
--

require("/initenv").init_env()

local comms       = require("scada-common.comms")
local crash       = require("scada-common.crash")
local log         = require("scada-common.log")
local mqueue      = require("scada-common.mqueue")
local network     = require("scada-common.network")
local ppm         = require("scada-common.ppm")
local util        = require("scada-common.util")

local backplane   = require("coordinator.backplane")
local configure   = require("coordinator.configure")
local coordinator = require("coordinator.coordinator")
local ioctl       = require("coordinator.ioctl")
local renderer    = require("coordinator.renderer")
local sounder     = require("coordinator.sounder")
local threads     = require("coordinator.threads")

local COORDINATOR_VERSION = "1.13.0"

local CHUNK_LOAD_DELAY_S = 30.0

local println    = util.println
local println_ts = util.println_ts

local log_render = coordinator.log_render
local log_sys    = coordinator.log_sys
local log_boot   = coordinator.log_boot
local log_comms  = coordinator.log_comms
local log_crypto = coordinator.log_crypto

----------------------------------------
-- obtém configuração
----------------------------------------

-- verificação inicial de configuração antes de validar os monitores
if not coordinator.load_config() then
    -- tenta reconfigurar (ação do usuário)
    local success, error = configure.configure(1)
    if success then
        if not coordinator.load_config() then
            println("falha ao carregar uma configuração válida, por favor reconfigure")
            return
        end
    else
        println("erro de configuração: " .. error)
        return
    end
end

local config = coordinator.config

----------------------------------------
-- inicialização de log
----------------------------------------

log.init(config.LogPath, config.LogMode, config.LogDebug)

log.info("========================================")
log.info("BOOTING coordinator.startup v" .. COORDINATOR_VERSION)
log.info("========================================")
println(">> Coordenador SCADA v" .. COORDINATOR_VERSION .. " <<")

crash.set_env("coordinator", COORDINATOR_VERSION)
crash.dbg_log_env()

----------------------------------------
-- inicialização de monitores
----------------------------------------

-- monta dispositivos conectados (necessário para configuração de monitores)
ppm.mount_all()

local wait_on_load = true

local disp_ok, disp_err = backplane.init_displays(config)

-- se o computador acabou de iniciar, sua chunk pode ter acabado de carregar (...ou o usuário reiniciou)
-- se a config. de monitor falhou, talvez uma chunk adjacente contendo parte de um monitor ainda não tenha carregado, então continua tentando
while wait_on_load and (not disp_ok) and os.clock() < CHUNK_LOAD_DELAY_S do
    term.clear()
    term.setCursorPos(1, 1)
    println("Houve um problema na configuração de monitores ao iniciar.\n")
    println("A inicialização continuará tentando a cada 2s em caso de atrasos no carregamento de chunks.\n")
    println(util.sprintf("O configurador será iniciado em %ds se todas as tentativas falharem.\n", math.max(0, CHUNK_LOAD_DELAY_S - os.clock())))
    println("(clique para pular para o configurador)")

    local timer_id = util.start_timer(2)

    while true do
        local event, param1 = util.pull_event()
        if event == "timer" and param1 == timer_id then
            -- remonta e tenta novamente
            ppm.mount_all()
            disp_ok, disp_err = backplane.init_displays(config)
            break
        elseif event == "mouse_click" or event == "terminate" then
            wait_on_load = false
            break
        end
    end
end

if not disp_ok then
    -- tenta reconfigurar (ação do usuário)
    local success, error = configure.configure(2, disp_err)
    if success then
        if not coordinator.load_config() then
            println("falha ao carregar uma configuração válida, por favor reconfigure")
            return
        else
            disp_ok, disp_err = backplane.init_displays(config)

            if not disp_ok then
                println(disp_err)
                println("por favor reconfigure")
                return
            end
        end
    else
        println("erro de configuração: " .. error)
        return
    end
end

----------------------------------------
-- aplicação principal
----------------------------------------

local function main()
    ----------------------------------------
    -- inicialização do sistema
    ----------------------------------------

    -- reporta versões
    ioctl.fp_versions(COORDINATOR_VERSION, comms.version)

    -- inicializa o renderizador
    renderer.configure(config)
    renderer.init_displays(backplane.displays())
    renderer.init_dmesg()

    -- vamos começar!
    log.info("monitors ready, dmesg output incoming...")

    log_render("monitores conectados e redefinidos")
    log_sys("sistema iniciado em " .. os.date("%c"))
    log_boot("iniciando " .. COORDINATOR_VERSION)

    -- alterna para a tela de abertura por *estética*
    if config.SplashScreen then
        log_render("iniciando telas de abertura")
        renderer.init_splash()
    end

    -- inicialização de autenticação de mensagens
    if type(config.AuthKey) == "string" and string.len(config.AuthKey) > 0 then
        local init_time = network.init_mac(config.AuthKey)
        log_crypto("inicialização do HMAC levou " .. init_time .. "ms")
    end

    ----------------------------------------
    -- alocação de memória
    ----------------------------------------

    -- memória compartilhada entre threads
    ---@class crd_shared_memory
    local __shared_memory = {
        -- formato de data e hora para exibição
        date_format = util.trinary(config.Time24Hour, "%X \x04 %A, %B %d %Y", "%r \x04 %A, %B %d %Y"),

        -- flags de estado do sistema coordenador
        ---@class crd_state
        crd_state = {
            fp_ok = false,
            ui_ok = true,       -- padrão true, usado para abortar em caso de falha
            link_fail = false,
            shutdown = false
        },

        -- objetos do sistema
        ---@class crd_sys
        crd_sys = {
            coord_comms = nil,  ---@type coord_comms
            conn_watchdog = nil ---@type watchdog
        },

        -- filas de mensagens
        q = {
            mq_render = mqueue.new()
        },

        -- tipos de mensagens da fila de mensagens
        q_types = {
            MQ__RENDER_CMD = {
                START_MAIN_UI = 1,
                CLOSE_MAIN_UI = 2
            },
            MQ__RENDER_DATA = {
                MON_CONNECT = 1,
                MON_DISCONNECT = 2,
                MON_RESIZE = 3
            }
        }
    }

    local smem_sys  = __shared_memory.crd_sys
    local crd_state = __shared_memory.crd_state

    ----------------------------------------
    -- inicialização de subsistemas
    ----------------------------------------

    -- inicialização de modem e alto-falante
    if not backplane.init(config, __shared_memory) then return end

    -- inicia o painel frontal
    log_render("iniciando interface do painel frontal...")

    local fp_message
    crd_state.fp_ok, fp_message = renderer.try_start_fp()
    if not crd_state.fp_ok then
        log_render(util.c("erro na UI do painel frontal: ", fp_message))
        println_ts("falha na criação da interface do painel frontal")
        log.fatal(util.c("front panel GUI render failed with error ", fp_message))
        return
    else log_render("painel frontal pronto") end

    -- cria watchdog de conexão
    smem_sys.conn_watchdog = util.new_watchdog(config.SVR_Timeout)
    smem_sys.conn_watchdog.cancel()
    log.debug("startup> conn watchdog created")

    -- configura comunicações
    smem_sys.coord_comms = coordinator.comms(COORDINATOR_VERSION, backplane, smem_sys.conn_watchdog)
    log.debug("startup> comms init")
    log_comms("comunicações inicializadas")

    ----------------------------------------
    -- inicia o sistema
    ----------------------------------------

    -- inicializa threads
    local main_thread   = threads.thread__main(__shared_memory)
    local render_thread = threads.thread__render(__shared_memory)

    log.info("startup> completed")

    -- executa threads
    parallel.waitForAll(main_thread.p_exec, render_thread.p_exec)

    renderer.shutdown(crd_state.link_fail)
    sounder.stop()
    log_sys("sistema encerrado")

    if crd_state.link_fail then println_ts("falha ao conectar ao supervisor") end
    if not crd_state.ui_ok then println_ts("falha na criação da interface principal") end

    -- fecha ao sair com erro (como erro de UI)
    if smem_sys.coord_comms.is_linked() then smem_sys.coord_comms.close() end

    println_ts("encerrado")
    log.info("exited")
end

if not xpcall(main, crash.handler) then
    pcall(renderer.close_ui)
    pcall(renderer.close_fp)
    pcall(sounder.stop)
    crash.exit()
else
    log.close()
end
