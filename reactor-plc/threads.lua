local log       = require("scada-common.log")
local mqueue    = require("scada-common.mqueue")
local ppm       = require("scada-common.ppm")
local tcd       = require("scada-common.tcd")
local util      = require("scada-common.util")

local backplane = require("reactor-plc.backplane")
local databus   = require("reactor-plc.databus")
local renderer  = require("reactor-plc.renderer")
local spctl     = require("reactor-plc.spctl")

local core      = require("graphics.core")

local threads = {}

local MAIN_CLOCK    = 0.5 -- 2Hz,   10 ticks
local RPS_SLEEP     = 250 -- 250ms, 5 ticks
local COMMS_SLEEP   = 150 -- 150ms, 3 ticks
local SP_CTRL_SLEEP = 100 -- 100ms, 2 ticks

-- thread principal
---@nodiscard
---@param smem plc_shared_memory
function threads.thread__main(smem)
    -- imprime uma mensagem de log no terminal enquanto a UI não estiver em execução
    local function println_ts(message) if not smem.plc_state.fp_ok then util.println_ts(message) end end

    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        databus.tx_rt_status("main", true)
        log.debug("OS: thread principal iniciada")

        local LINK_TICKS = 2
        local ticks_to_update = 0

        local loop_clock = util.new_clock(MAIN_CLOCK)

        -- carrega da memória compartilhada
        local networked     = smem.networked
        local plc_state     = smem.plc_state

        local rps           = smem.plc_sys.rps
        local plc_comms     = smem.plc_sys.plc_comms
        local conn_watchdog = smem.plc_sys.conn_watchdog

        local MQ__RPS_CMD   = smem.q_types.MQ__RPS_CMD
        local MQ__COMM_CMD  = smem.q_types.MQ__COMM_CMD

        -- tarefas periódicas do loop principal
        local function loop_tick()
            -- pisca o indicador de heartbeat
            databus.heartbeat()

            -- inicia o próximo temporizador do relógio
            loop_clock.start()

            -- tarefas periódicas de hardware
            backplane.periodic()

            -- envia dados atualizados ou tenta vincular
            if networked then
                if plc_comms.is_linked() then
                    smem.q.mq_comms_tx.push_command(MQ__COMM_CMD.SEND_STATUS)

                    plc_comms.manage_failover(backplane.active_nic())
                elseif ticks_to_update == 0 then
                    local a_nic, s_nic = backplane.active_nic(), backplane.standby_nic()

                    if a_nic.is_network_up() then
                        plc_comms.send_link_req(a_nic)
                    elseif s_nic and s_nic.is_network_up() then
                        plc_comms.send_link_req(s_nic)
                    end

                    ticks_to_update = LINK_TICKS
                else
                    ticks_to_update = ticks_to_update - 1
                end
            end

            -- verifica mudança no estado de formação
            if (not plc_state.reactor_formed) and rps.is_formed() then
                -- reator agora formado
                plc_state.reactor_formed = true

                println_ts("reator agora esta formado")
                log.info("reator agora esta formado")

                -- determina se ainda estamos em um estado degradado
                if (not networked) or backplane.active_nic().is_connected() then
                    plc_state.degraded = false
                end

                -- redefinição parcial do RPS, específica para quando se torna formado
                -- sem isso, o controle automático não pode retomar ao carregar o chunk
                smem.q.mq_rps.push_command(MQ__RPS_CMD.RESET_REATTACH)
            elseif plc_state.reactor_formed and (rps.is_formed() == false) then
                -- reator não está mais formado
                println_ts("reator nao esta mais formado")
                log.info("reator nao esta mais formado")

                plc_state.reactor_formed = false
                plc_state.degraded = true
            end

            -- atualiza os indicadores
            databus.tx_hw_status(plc_state)
        end

        -- inicia o relógio
        loop_clock.start()

        -- loop de eventos
        while true do
            local event, param1, param2, param3, param4, param5 = util.pull_event()

            -- trata o evento
            if event == "modem_message" and networked then
                -- recebeu um pacote
                local packet = plc_comms.parse_packet(param1, param2, param3, param4, param5)
                if packet ~= nil then
                    -- passa o pacote para a fila de mensagens de comunicação
                    smem.q.mq_comms_rx.push_network(packet)
                end
            elseif event == "timer" then
                -- passa este evento de temporizador para o manipulador correto
                if loop_clock.is_clock(param1) then
                    -- tick do loop principal
                    loop_tick()
                elseif networked and conn_watchdog.is_timer(param1) then
                    -- tempo limite da conexão do supervisor esgotado
                    plc_comms.close()
                    smem.q.mq_rps.push_command(MQ__RPS_CMD.TRIP_TIMEOUT)
                else
                    -- notifica o despachante de callbacks de temporizador, nenhum outro manipulador reivindicou este evento
                    tcd.handle(param1)
                end
            elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or
                   event == "double_click" then
                -- trata um evento de mouse
                renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
            elseif event == "peripheral" then
                -- conexão de periférico
                local type, device = ppm.mount(param1)
                if type ~= nil and device ~= nil then
                    backplane.attach(param1, type, device, println_ts)
                end

                -- atualiza os indicadores
                databus.tx_hw_status(plc_state)
            elseif event == "peripheral_detach" then
                -- desconexão de periférico
                local type, device = ppm.handle_unmount(param1)
                if type ~= nil and device ~= nil then
                    backplane.detach(param1, type, device, println_ts)
                end

                -- atualiza os indicadores
                databus.tx_hw_status(plc_state)
            end

            -- verifica solicitação de encerramento
            if event == "terminate" or ppm.should_terminate() then
                log.info("OS: encerramento solicitado, thread principal saindo")
                -- o rps trata o desligamento do reator
                plc_state.shutdown = true
                break
            end
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local plc_state = smem.plc_state

        while not plc_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("main", false)

            -- se o status for true, provavelmente estamos saindo, então isso não importará
            -- se não, precisamos reiniciar o relógio
            -- esta thread não pode dormir porque perderá eventos (especialmente "terminate", caso contrário)
            if not plc_state.shutdown then
                log.info("OS: thread principal reiniciando agora...")
            end
        end
    end

    return public
end

-- thread de operação do RPS
---@nodiscard
---@param smem plc_shared_memory
function threads.thread__rps(smem)
    -- imprime uma mensagem de log no terminal enquanto a UI não estiver em execução
    local function println_ts(message) if not smem.plc_state.fp_ok then util.println_ts(message) end end

    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        databus.tx_rt_status("rps", true)
        log.debug("OS: thread rps iniciada")

        -- carrega da memória compartilhada
        local networked   = smem.networked
        local plc_state   = smem.plc_state

        local rps         = smem.plc_sys.rps
        local plc_comms   = smem.plc_sys.plc_comms

        local rps_queue   = smem.q.mq_rps

        local MQ__RPS_CMD = smem.q_types.MQ__RPS_CMD

        local was_linked  = false
        local last_update = util.time()

        -- loop da thread
        while true do
            -- SCRAM se não houver conexão aberta
            if networked and not plc_comms.is_linked() then
                if was_linked then
                    was_linked = false
                    rps.trip_timeout()
                end
            else was_linked = true end

            -- verifica o status do reator
            if (not plc_state.no_reactor) and rps.is_formed() then
                local active = rps.check_active()

                databus.tx_reactor_state(active)

                -- se tentamos dar SCRAM mas falhou, continua tentando
                -- nesse caso, o SCRAM não será chamado até que se reconecte (este é o uso esperado desta verificação)
                if rps.is_tripped() and active then rps.scram() end
            end

            -- se estivermos no modo autônomo e o painel frontal não estiver funcionando, redefine continuamente o RPS
            -- o RPS desarmará novamente se houver falhas, mas se não for limpo, o usuário não poderá reativar
            if not (networked or smem.plc_state.fp_ok) then rps.reset(true) end

            -- verifica a segurança (o SCRAM ocorre se desarmado)
            local rps_tripped, rps_status_string, rps_first = rps.check(not plc_state.no_reactor)
            if rps_tripped and rps_first then
                println_ts("RPS: SCRAM em desarme de seguranca (" .. rps_status_string .. ")")
                if networked then plc_comms.send_rps_alarm(rps_status_string) end
            end

            -- verifica mensagens na fila de mensagens
            while rps_queue.ready() and not plc_state.shutdown do
                local msg = rps_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.COMMAND then
                        -- recebeu um comando
                        if msg.message == MQ__RPS_CMD.SCRAM then
                            -- SCRAM
                            log.info("RPS: SO solicitou SCRAM")
                            rps.scram()
                        elseif msg.message == MQ__RPS_CMD.DEGRADED_SCRAM then
                            -- perdeu periférico(s)
                            log.info("RPS: recebeu alerta de PLC degradado")
                            rps.trip_fault()
                        elseif msg.message == MQ__RPS_CMD.TRIP_TIMEOUT then
                            -- watchdog desarmou
                            println_ts("RPS: tempo esgotado do supervisor")
                            log.warning("RPS: recebeu alerta de tempo esgotado do supervisor")
                            rps.trip_timeout()
                        elseif msg.message == MQ__RPS_CMD.RESET_REATTACH then
                            -- redefine ao reconectar o reator
                            rps.reset_reattach()
                        end
                    end
                end

                -- yield rápido
                util.nop()
            end

            -- verifica solicitação de encerramento
            if plc_state.shutdown then
                -- saída segura
                log.info("OS: desligamento da thread rps iniciado")

                if rps.scram() then
                    println_ts("saindo, reator desativado")
                    log.info("OS: SCRAM do reator da thread rps OK ao sair")
                else
                    println_ts("saindo, falha ao desativar o reator")
                    log.error("OS: thread rps falhou ao dar SCRAM no reator ao sair")
                end

                log.info("OS: thread rps saindo")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(RPS_SLEEP, last_update)
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local plc_state = smem.plc_state

        while not plc_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("rps", false)

            if not plc_state.shutdown then
                smem.plc_sys.rps.scram()
                log.info("OS: thread rps reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

-- thread de envio de comunicações
---@nodiscard
---@param smem plc_shared_memory
function threads.thread__comms_tx(smem)
    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        databus.tx_rt_status("comms_tx", true)
        log.debug("OS: thread comms tx iniciada")

        -- carrega da memória compartilhada
        local plc_state    = smem.plc_state
        local plc_comms    = smem.plc_sys.plc_comms

        local comms_queue  = smem.q.mq_comms_tx

        local MQ__COMM_CMD = smem.q_types.MQ__COMM_CMD

        local last_update = util.time()

        -- loop da thread
        while true do
            -- verifica mensagens na fila de mensagens
            while comms_queue.ready() and not plc_state.shutdown do
                local msg = comms_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.COMMAND then
                        -- recebeu um comando
                        if msg.message == MQ__COMM_CMD.SEND_STATUS then
                            -- envia status do PLC/RPS
                            plc_comms.send_status(plc_state.no_reactor, plc_state.reactor_formed)
                            plc_comms.send_rps_status()
                        end
                    end
                end

                -- yield rápido
                util.nop()
            end

            -- verifica solicitação de encerramento
            if plc_state.shutdown then
                log.info("OS: thread comms tx saindo")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(COMMS_SLEEP, last_update)
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local plc_state = smem.plc_state

        while not plc_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("comms_tx", false)

            if not plc_state.shutdown then
                log.info("OS: thread comms tx reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

-- thread de manipulação de comunicações
---@nodiscard
---@param smem plc_shared_memory
function threads.thread__comms_rx(smem)
    -- imprime uma mensagem de log no terminal enquanto a UI não estiver em execução
    local function println_ts(message) if not smem.plc_state.fp_ok then util.println_ts(message) end end

    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        databus.tx_rt_status("comms_rx", true)
        log.debug("OS: thread comms rx iniciada")

        -- carrega da memória compartilhada
        local plc_state   = smem.plc_state

        local plc_comms   = smem.plc_sys.plc_comms

        local comms_queue = smem.q.mq_comms_rx

        local last_update = util.time()

        -- loop da thread
        while true do
            -- verifica mensagens na fila de mensagens
            while comms_queue.ready() and not plc_state.shutdown do
                local msg = comms_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.NETWORK then
                        -- recebeu um pacote, trata o pacote
                        plc_comms.handle_packet(msg.message, println_ts)
                    end
                end

                -- yield rápido
                util.nop()
            end

            -- verifica solicitação de encerramento
            if plc_state.shutdown then
                log.info("OS: thread comms rx saindo")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(COMMS_SLEEP, last_update)
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local plc_state = smem.plc_state

        while not plc_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("comms_rx", false)

            if not plc_state.shutdown then
                log.info("OS: thread comms rx reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

-- controla as saídas em rampa para os setpoints desejados
---@nodiscard
---@param smem plc_shared_memory
function threads.thread__setpoint_control(smem)
    ---@class parallel_thread
    local public = {}

    -- executa a thread
    function public.exec()
        databus.tx_rt_status("spctl", true)
        log.debug("OS: thread de controle de setpoint iniciada")

        -- carrega da memória compartilhada
        local plc_state = smem.plc_state
        local plc_dev   = smem.plc_dev

        local last_update = util.time()

        -- não usa o tempo decorrido real, pois pode ter picos
        -- não queremos grandes saltos, pois é exatamente isso que estamos tentando evitar
        local nom_elapsed_s = SP_CTRL_SLEEP / 1000.0

        local tick = 0

        -- inicializa o controlador
        spctl.init(smem)

        -- loop da thread
        while true do
            if not plc_state.no_reactor then
                tick = tick + 1

                spctl.update(plc_dev.reactor, tick, nom_elapsed_s)
            end

            -- verifica solicitação de encerramento
            if plc_state.shutdown then
                log.info("OS: thread de controle de setpoint saindo")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(SP_CTRL_SLEEP, last_update)
        end
    end

    -- executa a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local plc_state = smem.plc_state

        while not plc_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("spctl", false)

            if not plc_state.shutdown then
                log.info("OS: thread de controle de setpoint reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

return threads
