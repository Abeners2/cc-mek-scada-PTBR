local log         = require("scada-common.log")
local mqueue      = require("scada-common.mqueue")
local ppm         = require("scada-common.ppm")
local tcd         = require("scada-common.tcd")
local util        = require("scada-common.util")

local backplane   = require("coordinator.backplane")
local coordinator = require("coordinator.coordinator")
local ioctl       = require("coordinator.ioctl")
local process     = require("coordinator.process")
local renderer    = require("coordinator.renderer")
local sounder     = require("coordinator.sounder")

local apisessions = require("coordinator.session.apisessions")

local core        = require("graphics.core")

local log_render = coordinator.log_render
local log_sys    = coordinator.log_sys
local log_comms  = coordinator.log_comms

local threads = {}

local MAIN_CLOCK   = 0.5 -- 2Hz,   10 ticks
local RENDER_SLEEP = 100 -- 100ms, 2 ticks

-- thread principal
---@nodiscard
---@param smem crd_shared_memory
function threads.thread__main(smem)
    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        ioctl.fp_rt_status("main", true)
        log.debug("OS: main thread start")

        local loop_clock = util.new_clock(MAIN_CLOCK)

        -- inicia o relógio
        loop_clock.start()

        log_sys("sistema iniciado com sucesso")

        ioctl.sys_splash_main_msg(nil, "Conectando ao Supervisor...")
        ioctl.sys_splash_disp_msg(true, "Conectando...")

        -- carrega da memória compartilhada
        local crd_state       = smem.crd_state
        local coord_comms     = smem.crd_sys.coord_comms
        local conn_watchdog   = smem.crd_sys.conn_watchdog

        local MQ__RENDER_CMD  = smem.q_types.MQ__RENDER_CMD
        local MQ__RENDER_DATA = smem.q_types.MQ__RENDER_DATA

        -- tarefas periódicas do loop principal
        ---@return boolean exit if the application should exit
        local function loop_tick()
            -- alterna o pulso (heartbeat)
            ioctl.heartbeat()

            -- tarefas periódicas de hardware
            backplane.periodic()

            -- mantém a conexão
            local ok, start_ui = coord_comms.manage_link()
            if not ok then
                crd_state.link_fail = true
                crd_state.shutdown = true
                log_sys("falha na conexão ao supervisor, desligando...")
                log.fatal("failed to connect to supervisor")
                return true
            elseif start_ui then
                log_sys("supervisor conectado, iniciando interface principal")
                smem.q.mq_render.push_command(MQ__RENDER_CMD.START_MAIN_UI)
            end

            -- itera sessões e libera as fechadas
            apisessions.iterate_all()
            apisessions.free_all_closed()

            -- limpa comandos de processo com tempo esgotado
            process.clear_timed_out()

            if renderer.ui_ready() then
                -- atualiza o relógio usado nos monitores principal e de fluxo
                ioctl.get_db().os_ps.publish("date_time", os.date(smem.date_format))
            end

            -- inicia o próximo temporizador do relógio
            loop_clock.start()

            return false
        end

        -- loop de eventos
        while true do
            local event, param1, param2, param3, param4, param5 = util.pull_event()

            -- processa o evento
            if event == "modem_message" then
                -- pacote recebido
                local packet = coord_comms.parse_packet(param1, param2, param3, param4, param5)

                -- processa e verifica se houve desconexão
                if coord_comms.handle_packet(packet) then
                    log_comms("supervisor fechou a conexão")

                    ioctl.sys_splash_main_msg("Conexão Perdida", "Reconectando...")
                    ioctl.sys_splash_disp_msg(true, "Reconectando...")

                    -- fecha a UI principal, a conexão e para o alarme sonoro
                    smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                    coord_comms.close()
                    sounder.stop()
                end
            elseif event == "timer" then
                -- repassa este evento de temporizador para o manipulador correto
                if loop_clock.is_clock(param1) then
                    -- tick do loop principal
                    if loop_tick() then break end
                elseif conn_watchdog.is_timer(param1) then
                    -- tempo limite da conexão ao supervisor esgotado
                    log_comms("tempo limite do servidor supervisor esgotado")

                    -- fecha a UI principal, a conexão e para o alarme sonoro
                    smem.q.mq_render.push_command(MQ__RENDER_CMD.CLOSE_MAIN_UI)
                    coord_comms.close()
                    sounder.stop()
                elseif not apisessions.check_all_watchdogs(param1) then -- verifica watchdogs da API
                    -- notifica o despachante de callback de temporizador, nenhum outro manipulador reivindicou este evento
                    tcd.handle(param1)
                end
            elseif event == "speaker_audio_empty" then
                -- processa esvaziamento do buffer do alto-falante
                sounder.continue()
            elseif event == "monitor_touch" or event == "mouse_click" or event == "mouse_up" or
                   event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
                -- processa um evento de mouse
                renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
            elseif event == "monitor_resize" then
                smem.q.mq_render.push_data(MQ__RENDER_DATA.MON_RESIZE, param1)
            elseif event == "peripheral" then
                local type, device = ppm.mount(param1)
                if type ~= nil and device ~= nil then
                    backplane.attach(type, device, param1)
                end
            elseif event == "peripheral_detach" then
                local type, device = ppm.handle_unmount(param1)
                if type ~= nil and device ~= nil then
                    backplane.detach(type, device, param1)
                end
            end

            -- verifica solicitação de encerramento ou falha da UI
            if event == "terminate" or ppm.should_terminate() then
                crd_state.shutdown = true
                log.info("OS: terminate requested, main thread exiting")
            elseif not crd_state.ui_ok then
                crd_state.shutdown = true
                log.info("OS: terminating due to fatal UI error")
            end

            if crd_state.shutdown then
                -- gerencia o fechamento da conexão ao supervisor
                coord_comms.manage_link(true)

                if coord_comms.is_linked() then
                    log_comms("fechando conexão com o supervisor...")
                else crd_state.link_fail = true end

                coord_comms.close()
                log_comms("conexão com o supervisor fechada")

                -- gerencia sessões de API
                log_comms("fechando sessões de api...")
                apisessions.close_all()
                log_comms("sessões de api fechadas")
                break
            end
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local crd_state = smem.crd_state

        while not crd_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            ioctl.fp_rt_status("main", false)

            -- se status for true, provavelmente estamos saindo, então isso não importará
            -- esta thread não pode dormir pois perderá eventos (especialmente "terminate")
            if not crd_state.shutdown then
                log.info("OS: main thread restarting now...")
            end
        end
    end

    return public
end

-- thread renderizadora do coordenador, encarregada de desenhos de longa duração
---@nodiscard
---@param smem crd_shared_memory
function threads.thread__render(smem)
    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        ioctl.fp_rt_status("render", true)
        log.debug("OS: render thread start")

        -- carrega da memória compartilhada
        local crd_state       = smem.crd_state
        local render_queue    = smem.q.mq_render

        local MQ__RENDER_CMD  = smem.q_types.MQ__RENDER_CMD
        local MQ__RENDER_DATA = smem.q_types.MQ__RENDER_DATA

        local last_update = util.time()

        -- loop da thread
        while true do
            -- verifica mensagens na fila de mensagens
            while render_queue.ready() and not crd_state.shutdown do
                local msg = render_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.COMMAND then
                        -- comando recebido
                        if msg.message == MQ__RENDER_CMD.START_MAIN_UI then
                            -- para a UI se já tiver sido iniciada
                            -- isso pode ocorrer em uma rápida desconexão -> conexão do supervisor
                            if renderer.ui_ready() then
                                log_render("fechando a UI principal antes de executar nova solicitação de início")
                                renderer.close_ui()
                            end

                            -- inicia a UI principal
                            log_render("iniciando UI principal...")

                            ioctl.sys_splash_main_msg("Preparando a Interface", "Iniciando a interface SCADA...")
                            ioctl.sys_splash_disp_msg(true, "Inicializando...")

                            local draw_start = util.time_ms()

                            local ui_message
                            crd_state.ui_ok, ui_message = renderer.try_start_ui()
                            if not crd_state.ui_ok then
                                log_render(util.c("erro na UI principal: ", ui_message))
                                log.fatal(util.c("main GUI render failed with error ", ui_message))
                            else
                                log_render("desenho da UI principal levou " .. (util.time_ms() - draw_start) .. "ms")
                            end
                        elseif msg.message == MQ__RENDER_CMD.CLOSE_MAIN_UI then
                            -- fecha a UI principal se tiver sido desenhada
                            if renderer.ui_ready() then
                                log_render("fechando UI principal...")
                                renderer.close_ui()
                                log_render("UI principal fechada")
                            end
                        end
                    elseif msg.qtype == mqueue.TYPE.DATA then
                        -- dados recebidos
                        local cmd = msg.message ---@type queue_data

                        if cmd.key == MQ__RENDER_DATA.MON_CONNECT then
                            -- monitor conectado
                            renderer.handle_reconnect(cmd.val)
                        elseif cmd.key == MQ__RENDER_DATA.MON_DISCONNECT then
                            -- monitor desconectado
                            renderer.handle_disconnect(cmd.val)
                        elseif cmd.key == MQ__RENDER_DATA.MON_RESIZE then
                            -- monitor redimensionado
                            local is_used, is_ok = renderer.handle_resize(cmd.val)
                            if is_used then
                                log_sys(util.c("monitor configurado ", cmd.val, " redimensionado, ", util.trinary(is_ok, "a tela cabe", "a tela não cabe")))
                            end
                        end
                    end
                end

                -- yield rápido
                util.nop()
            end

            -- verifica solicitação de encerramento
            if crd_state.shutdown then
                log.info("OS: render thread exiting")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(RENDER_SLEEP, last_update)
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local crd_state = smem.crd_state

        while not crd_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            ioctl.fp_rt_status("render", false)

            if not crd_state.shutdown then
                log.info("OS: render thread restarting in 5 seconds...")
                util.psleep(5)
            end
        end
    end

    return public
end

return threads
