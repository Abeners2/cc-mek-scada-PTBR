local log          = require("scada-common.log")
local mqueue       = require("scada-common.mqueue")
local ppm          = require("scada-common.ppm")
local tcd          = require("scada-common.tcd")
local types        = require("scada-common.types")
local util         = require("scada-common.util")

local backplane    = require("rtu.backplane")
local databus      = require("rtu.databus")
local modbus       = require("rtu.modbus")
local renderer     = require("rtu.renderer")

local boilerv_rtu  = require("rtu.dev.boilerv_rtu")
local dynamicv_rtu = require("rtu.dev.dynamicv_rtu")
local ecore_rtu    = require("rtu.dev.ecore_rtu")
local envd_rtu     = require("rtu.dev.envd_rtu")
local imatrix_rtu  = require("rtu.dev.imatrix_rtu")
local sna_rtu      = require("rtu.dev.sna_rtu")
local sps_rtu      = require("rtu.dev.sps_rtu")
local turbinev_rtu = require("rtu.dev.turbinev_rtu")

local core         = require("graphics.core")

local threads = {}

local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE
local RTU_HW_STATE = databus.RTU_HW_STATE

local MAIN_CLOCK  = 0.5 -- 2Hz,  10 ticks
local COMMS_SLEEP = 100 -- 100ms, 2 ticks

---@param smem rtu_shared_memory
---@param println_ts function
---@param iface string
---@param type string
---@param device ppm_generic
---@param unit rtu_registry_entry
local function handle_unit_mount(smem, println_ts, iface, type, device, unit)
    local sys = smem.rtu_sys

    -- encontrar dispositivo desconectado para reconectar
    -- nota: não é possível verificar isFormed pois isso pausaria esta corrotina e consumiria eventos
    if unit.name == iface then
        local resend_advert, faulted, unknown, invalid = false, false, false, false

        local function fail(msg)
            invalid = true
            log.error(msg .. " na configuração")
        end

        -- encontrado, revincular
        unit.device = device

        if unit.type == RTU_UNIT_TYPE.VIRTUAL then
            resend_advert = true
            if type == "boilerValve" then
                -- multibloco de caldeira
                if unit.reactor < 1 or unit.reactor > 4 then fail(util.c("caldeira '", unit.name, "' não pode inicializar, não atribuída a uma unidade válida")) end
                if (unit.index == false) or unit.index < 1 or unit.index > 2 then fail(util.c("caldeira '", unit.name, "' não pode inicializar, índice inválido fornecido")) end

                unit.type = RTU_UNIT_TYPE.BOILER_VALVE
            elseif type == "turbineValve" then
                -- multibloco de turbina
                if unit.reactor < 1 or unit.reactor > 4 then fail(util.c("turbina '", unit.name, "' não pode inicializar, não atribuída a uma unidade válida")) end
                if (unit.index == false) or unit.index < 1 or unit.index > 3 then fail(util.c("turbina '", unit.name, "' não pode inicializar, índice inválido fornecido")) end

                unit.type = RTU_UNIT_TYPE.TURBINE_VALVE
            elseif type == "dynamicValve" then
                -- multibloco de tanque dinâmico
                if unit.reactor < 0 or unit.reactor > 4 then fail(util.c("tanque dinâmico '", unit.name, "' não pode inicializar, nenhuma atribuição válida fornecida")) end

                if (unit.reactor == 0 and ((unit.index == false) or unit.index < 1 or unit.index > 4)) or
                   (unit.reactor > 0 and unit.index ~= 1) then
                    fail(util.c("tanque dinâmico '", unit.name, "' não pode inicializar, índice inválido fornecido"))
                end

                unit.type = RTU_UNIT_TYPE.DYNAMIC_VALVE
            elseif type == "inductionPort" or type == "reinforcedInductionPort" then
                -- multibloco de matriz de indução
                if unit.reactor ~= 0 then fail(util.c("matriz de indução '", unit.name, "' não pode inicializar, não atribuída à instalação")) end

                unit.type = RTU_UNIT_TYPE.IMATRIX
            elseif type == "spsPort" then
                -- multibloco SPS
                if unit.reactor ~= 0 then fail(util.c("SPS '", unit.name, "' não pode inicializar, não atribuído à instalação")) end

                unit.type = RTU_UNIT_TYPE.SPS
            elseif type == "solarNeutronActivator" or type == "largeSolarNeutronActivator" then
                -- SNA
                if unit.reactor < 1 or unit.reactor > 4 then fail(util.c("SNA '", unit.name, "' não pode inicializar, não atribuído a uma unidade válida")) end

                unit.type = RTU_UNIT_TYPE.SNA
            elseif type == "environmentDetector" or type == "environment_detector"  then
                -- detector de ambiente do Advanced Peripherals
                if unit.reactor < 0 or unit.reactor > 4 then fail(util.c("detector de ambiente '", unit.name, "' não pode inicializar, nenhuma atribuição válida fornecida")) end
                if (unit.index == false) or unit.index < 1 then fail(util.c("detector de ambiente '", unit.name, "' não pode inicializar, índice inválido fornecido")) end

                unit.type = RTU_UNIT_TYPE.ENV_DETECTOR
            elseif type == "draconic_rf_storage" then
                -- núcleo de energia do Draconic Evolution
                if unit.reactor ~= 0 then fail(util.c("núcleo de energia '", unit.name, "' não pode inicializar, não atribuído à instalação")) end

                unit.type = RTU_UNIT_TYPE.ENERGY_CORE
            else
                resend_advert = false
                log.error(util.c("dispositivo virtual '", unit.name, "' não pode inicializar para um tipo desconhecido (", type, ")"))
            end

            databus.tx_unit_hw_type(unit.uid, unit.type)
        end

        -- se desconectado na inicialização, a configuração não teria sido validada
        -- verificando agora que conectou; a configuração não é válida, então não o conecte
        if invalid then
            unit.hw_state = RTU_HW_STATE.OFFLINE
            databus.tx_unit_hw_status(unit.uid, unit.hw_state)
            return
        end

        -- nota para estruturas multibloco do Mekanism: se não formado, indexar as funções do multibloco resulta em uma falha do PPM

        if unit.type == RTU_UNIT_TYPE.BOILER_VALVE then
            unit.rtu, faulted = boilerv_rtu.new(device)
            unit.formed = util.trinary(faulted, false, nil)
        elseif unit.type == RTU_UNIT_TYPE.TURBINE_VALVE then
            unit.rtu, faulted = turbinev_rtu.new(device)
            unit.formed = util.trinary(faulted, false, nil)
        elseif unit.type == RTU_UNIT_TYPE.DYNAMIC_VALVE then
            unit.rtu, faulted = dynamicv_rtu.new(device)
            unit.formed = util.trinary(faulted, false, nil)
        elseif unit.type == RTU_UNIT_TYPE.IMATRIX then
            unit.rtu, faulted = imatrix_rtu.new(device)
            unit.formed = util.trinary(faulted, false, nil)
        elseif unit.type == RTU_UNIT_TYPE.SPS then
            unit.rtu, faulted = sps_rtu.new(device)
            unit.formed = util.trinary(faulted, false, nil)
        elseif unit.type == RTU_UNIT_TYPE.SNA then
            unit.rtu, faulted = sna_rtu.new(device)
        elseif unit.type == RTU_UNIT_TYPE.ENV_DETECTOR then
            unit.rtu, faulted = envd_rtu.new(device)
        elseif unit.type == RTU_UNIT_TYPE.ENERGY_CORE then
            unit.rtu, faulted = ecore_rtu.new(device)
        elseif unit.type == RTU_UNIT_TYPE.REDSTONE then
            unit.rtu.remount_phy(device)
        else
            unknown = true
            log.error(util.c("falha ao identificar o tipo de unidade RTU reconectada (", unit.name, ")"), true)
        end

        if unit.is_multiblock then
            unit.hw_state = RTU_HW_STATE.UNFORMED
            if unit.formed == false then
                log.info(util.c("assumindo que ", unit.name, " não está formado devido a falhas de PPM durante a inicialização"))
            end
        elseif faulted then
            unit.hw_state = RTU_HW_STATE.FAULTED
        elseif not unknown then
            unit.hw_state = RTU_HW_STATE.OK
        else
            unit.hw_state = RTU_HW_STATE.OFFLINE
        end

        databus.tx_unit_hw_status(unit.uid, unit.hw_state)

        if not unknown then
            unit.modbus_io = modbus.new(unit.rtu, true)

            local type_name = types.rtu_type_to_string(unit.type)
            local message = util.c("reconectado o(a) ", type_name, " na interface ", unit.name)
            println_ts(message)
            log.info(message)

            if resend_advert then
                sys.rtu_comms.send_advertisement(sys.units)
            else
                sys.rtu_comms.send_remounted(unit.uid)
            end
        end
    end
end

-- thread principal
---@nodiscard
---@param smem rtu_shared_memory
function threads.thread__main(smem)
    -- imprimir uma mensagem de log no terminal desde que a UI não esteja em execução
    local function println_ts(message) if not smem.rtu_state.fp_ok then util.println_ts(message) end end

    ---@class parallel_thread
    local public = {}

    -- executar thread
    function public.exec()
        databus.tx_rt_status("main", true)
        log.debug("OS: thread principal iniciada")

        -- relógio do loop principal
        local loop_clock = util.new_clock(MAIN_CLOCK)

        -- carregar da memória compartilhada
        local rtu_state     = smem.rtu_state
        local rtu_comms     = smem.rtu_sys.rtu_comms
        local conn_watchdog = smem.rtu_sys.conn_watchdog
        local units         = smem.rtu_sys.units

        local sounders      = backplane.sounders()

        -- tarefas periódicas do loop principal
        local function loop_tick()
            -- piscar indicador de pulso (heartbeat)
            databus.heartbeat()

            -- tarefas periódicas de hardware
            backplane.periodic()

            -- atualizar estados dos alto-falantes
            for _, sounder in pairs(sounders) do
                -- recalcular saída se necessário e reproduzir áudio se disponível
                if sounder.stream.is_recompute_needed() then
                    sounder.stream.compute_buffer()
                    if sounder.stream.any_active() then sounder.play() else sounder.stop() end
                end
            end

            -- tick periódico, se não estivermos vinculados enviar solicitação de estabelecimento
            if rtu_state.linked then
                rtu_comms.manage_failover(backplane.active_nic())
            else
                -- anunciar unidades
                local a_nic, s_nic = backplane.active_nic(), backplane.standby_nic()

                if a_nic.is_network_up() then
                    rtu_comms.send_establish(a_nic, units)
                elseif s_nic and s_nic.is_network_up() then
                    rtu_comms.send_establish(s_nic, units)
                end
            end

            -- iniciar próximo temporizador de relógio
            loop_clock.start()
        end

        -- iniciar desvinculado (em caso de reinicialização)
        rtu_comms.unlink(rtu_state)

        -- iniciar relógio
        loop_clock.start()

        -- loop de eventos
        while true do
            local event, param1, param2, param3, param4, param5 = util.pull_event()

            if event == "modem_message" then
                -- pacote recebido
                local packet = rtu_comms.parse_packet(param1, param2, param3, param4, param5)
                if packet ~= nil then
                    -- passar o pacote para a fila de mensagens de comunicação
                    smem.q.mq_comms.push_network(packet)
                end
            elseif event == "timer" then
                -- passar este evento de temporizador para o manipulador correto
                if loop_clock.is_clock(param1) then
                    -- tick do loop principal
                    loop_tick()
                elseif conn_watchdog.is_timer(param1) then
                    -- tempo limite de conexão do supervisor esgotado
                    rtu_comms.close(rtu_state)
                else
                    -- notificar despachante de retorno de chamada de temporizador, nenhum outro manipulador reivindicou este evento
                    tcd.handle(param1)
                end
            elseif event == "speaker_audio_empty" then
                -- tratar buffer de áudio de alto-falante vazio
                for i = 1, #sounders do
                    local sounder = sounders[i]
                    if sounder.name == param1 then
                        sounder.continue()
                        break
                    end
                end
            elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or
                   event == "double_click" then
                -- tratar um evento de mouse
                renderer.handle_mouse(core.events.new_mouse_event(event, param1, param2, param3))
            elseif event == "peripheral" then
                -- conexão de periférico
                local type, device = ppm.mount(param1)

                if type ~= nil and device ~= nil then
                    if type == "modem" or type == "speaker" then
                        backplane.attach(type, device, param1, println_ts)
                    else
                        -- revincular periférico perdido para a entrada de unidade correta
                        for i = 1, #units do
                            handle_unit_mount(smem, println_ts, param1, type, device, units[i])
                        end
                    end
                end
            elseif event == "peripheral_detach" then
                -- tratar perda de um dispositivo
                local type, device = ppm.handle_unmount(param1)

                if type ~= nil and device ~= nil then
                    if type == "modem" or type == "speaker" then
                        backplane.detach(type, device, param1, println_ts)
                    else
                        for i = 1, #units do
                            -- encontrar dispositivo desconectado
                            if units[i].device == device then
                                -- deixará o PPM evitar travamentos, o que indicará falhas nas consultas MODBUS
                                local unit = units[i]
                                local type_name = types.rtu_type_to_string(unit.type)

                                println_ts(util.c("perdido o(a) ", type_name, " na interface ", unit.name))
                                log.warning(util.c("perdido o periférico da unidade ", type_name, " na interface ", unit.name))

                                unit.hw_state = RTU_HW_STATE.OFFLINE
                                databus.tx_unit_hw_status(unit.uid, unit.hw_state)
                                break
                            end
                        end
                    end
                end
            end

            -- verificar solicitação de encerramento
            if event == "terminate" or ppm.should_terminate() then
                rtu_state.shutdown = true
                log.info("OS: encerramento solicitado, thread principal saindo")
                break
            end
        end
    end

    -- executar a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local rtu_state = smem.rtu_state

        while not rtu_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("main", false)

            if not rtu_state.shutdown then
                log.info("OS: thread principal reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

-- thread manipuladora de comunicações
---@nodiscard
---@param smem rtu_shared_memory
function threads.thread__comms(smem)
    ---@class parallel_thread
    local public = {}

    -- executar thread
    function public.exec()
        databus.tx_rt_status("comms", true)
        log.debug("OS: thread de comunicações iniciada")

        -- carregar da memória compartilhada
        local rtu_state   = smem.rtu_state
        local rtu_comms   = smem.rtu_sys.rtu_comms
        local units       = smem.rtu_sys.units
        local comms_queue = smem.q.mq_comms

        local sounders    = backplane.sounders()

        local last_update = util.time()

        -- loop da thread
        while true do
            local handle_start = util.time()

            -- verificar mensagens na fila de mensagens enquanto não estiver desligado
            while comms_queue.ready() and not rtu_state.shutdown do
                local msg = comms_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.NETWORK then
                        -- pacote recebido
                        -- tratar o pacote (rtu_state passado para permitir definir sinalizador de link, sounders passados para gerenciar áudio de alarme)
                        rtu_comms.handle_packet(msg.message, units, rtu_state, sounders)
                    end
                end

                -- máximo de 100ms gastos processando a fila
                if util.time() - handle_start > 100 then
                    log.warning("OS: thread de comunicações excedeu o limite de 100ms de processamento da fila")
                    break
                end
            end

            -- pausa rápida (yield)
            util.nop()

            -- verificar solicitação de encerramento
            if rtu_state.shutdown then
                rtu_comms.close(rtu_state)
                log.info("OS: thread de comunicações saindo")
                break
            end

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(COMMS_SLEEP, last_update)
        end
    end

    -- executar a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local rtu_state = smem.rtu_state

        while not rtu_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("comms", false)

            if not rtu_state.shutdown then
                log.info("OS: thread de comunicações reiniciando em 5 segundos...")
                util.psleep(5)
            end
        end
    end

    return public
end

-- thread manipuladora de comunicações por unidade
---@nodiscard
---@param smem rtu_shared_memory
---@param unit rtu_registry_entry
function threads.thread__unit_comms(smem, unit)
    -- imprimir uma mensagem de log no terminal desde que a UI não esteja em execução
    local function println_ts(message) if not smem.rtu_state.fp_ok then util.println_ts(message) end end

    ---@class parallel_thread
    local public = {}

    -- executar thread
    function public.exec()
        databus.tx_rt_status("unit_" .. unit.uid, true)
        log.debug(util.c("OS: thread da unidade rtu iniciada -> ", types.rtu_type_to_string(unit.type), " (", unit.name, ")"))

        -- carregar da memória compartilhada
        local rtu_state    = smem.rtu_state
        local rtu_comms    = smem.rtu_sys.rtu_comms
        local packet_queue = unit.pkt_queue

        local last_update  = util.time()

        local last_f_check = 0

        local detail_name  = util.c(types.rtu_type_to_string(unit.type), " (", unit.name, ") ",
                                util.trinary(unit.index == false, "", util.c("[", unit.index, "] ")), "para ",
                                util.trinary(unit.reactor == 0, "a instalação", util.c("reator ", unit.reactor)))
        local short_name   = util.c(types.rtu_type_to_string(unit.type), " (", unit.name, ")")

        if packet_queue == nil then
            log.error("OS: thread da unidade rtu criada sem uma fila de mensagens, saindo...", true)
            return
        end

        -- loop da thread
        while true do
            -- verificar mensagens na fila de mensagens
            while packet_queue.ready() and not rtu_state.shutdown do
                local msg = packet_queue.pop()

                if msg ~= nil then
                    if msg.qtype == mqueue.TYPE.NETWORK then
                        -- ADU recebida
                        local _, reply = unit.modbus_io.handle_adu(msg.message)
                        rtu_comms.send_modbus(reply)
                    end
                end

                -- pausa rápida (yield)
                util.nop()
            end

            -- verificar solicitação de encerramento
            if rtu_state.shutdown then
                log.info("OS: thread da unidade rtu saindo -> " .. short_name)
                break
            end

            -- verificar se o multibloco ainda está formado se este for um multibloco
            if unit.is_multiblock and (util.time_ms() - last_f_check > 250) then
                last_f_check = util.time_ms()

                local is_formed = unit.device.isFormed()

                if unit.formed == nil then
                    unit.formed = is_formed
                    if is_formed then unit.hw_state = RTU_HW_STATE.OK end
                elseif not unit.formed then
                    unit.hw_state = RTU_HW_STATE.UNFORMED
                end

                if (is_formed == true) and not unit.formed then
                    unit.hw_state = RTU_HW_STATE.OK
                    log.info(util.c(detail_name, " agora está formado"))
                    rtu_comms.send_remounted(unit.uid)
                elseif (is_formed == false) and unit.formed then
                    log.warning(util.c(detail_name, " não está mais formado"))
                elseif (is_formed == nil) and (unit.hw_state ~= RTU_HW_STATE.OFFLINE) then
                    log.error(util.c(detail_name, " falhou ao verificar se está formado, tentando remontar..."))

                    local type, dev = ppm.remount(unit.name)
                    if type and dev then
                        handle_unit_mount(smem, println_ts, unit.name, type, dev, unit)
                    else
                        log.error(util.c(detail_name, " falhou ao remontar"))
                    end
                end

                unit.formed = is_formed
            end

            -- verificar status do hardware
            if unit.device.__p_is_healthy() then
                if unit.hw_state == RTU_HW_STATE.FAULTED then unit.hw_state = RTU_HW_STATE.OK end
            else
                if unit.hw_state == RTU_HW_STATE.OK then unit.hw_state = RTU_HW_STATE.FAULTED end
            end

            -- atualizar status do hw
            databus.tx_unit_hw_status(unit.uid, unit.hw_state)

            -- atraso antes da próxima verificação
            last_update = util.adaptive_delay(COMMS_SLEEP, last_update)
        end
    end

    -- executar a thread em modo protegido, tentando novamente no retorno se não estiver desligando
    function public.p_exec()
        local rtu_state = smem.rtu_state

        while not rtu_state.shutdown do
            local status, result = pcall(public.exec)
            if status == false then
                log.fatal(util.strval(result))
            end

            databus.tx_rt_status("unit_" .. unit.uid, false)

            if not rtu_state.shutdown then
                log.info(util.c("OS: thread da unidade rtu ", types.rtu_type_to_string(unit.type), " (", unit.name, ") reiniciando em 5 segundos..."))
                util.psleep(5)
            end
        end
    end

    return public
end

return threads
