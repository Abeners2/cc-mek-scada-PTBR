--
-- Despachante de Callbacks de Temporizador (TCD)
--

local log  = require("scada-common.log")
local util = require("scada-common.util")

local tcd = {}

---@type { callback: function, duration: number, expiry: number }[]
local registry = {}

-- solicita que uma função seja chamada após o tempo especificado
---@param time number seconds
---@param f function callback function
function tcd.dispatch(time, f)
    local timer = util.start_timer(time)
    registry[timer] = {
        callback = f,
        duration = time,
        expiry = time + util.time_s()
    }
end

-- solicita que uma função seja chamada após o tempo especificado, abortando quaisquer instâncias registradas dessa referência de função
---@param time number seconds
---@param f function callback function
function tcd.dispatch_unique(time, f)
    -- cancela se já estiver registrada
    for timer, entry in pairs(registry) do
        if entry.callback == f then
            -- encontrou uma instância desta referência de função, aborta-a
            log.debug(util.c("TCD: abortando callback de temporizador duplicado [timer: ", timer, ", ", f, "]"))

            -- cancela o evento e remove do registro (mesmo que dispare, não chamará)
            util.cancel_timer(timer)
            registry[timer] = nil
        end
    end

    local timer = util.start_timer(time)
    registry[timer] = {
        callback = f,
        duration = time,
        expiry = time + util.time_s()
    }
end

-- aborta um callback solicitado
---@param f function callback function
function tcd.abort(f)
    for timer, entry in pairs(registry) do
        if entry.callback == f then
            -- cancela o evento e remove do registro (mesmo que dispare, não chamará)
            util.cancel_timer(timer)
            registry[timer] = nil
        end
    end
end

-- procura um evento de temporizador e executa o callback se encontrado
---@param event integer timer event timer ID
function tcd.handle(event)
    if registry[event] ~= nil then
        local callback = registry[event].callback
        -- limpa primeiro para que a chamada dispatch_unique de dentro do callback não gere uma mensagem de depuração
        registry[event] = nil
        callback()
    end
end

-- imprime callbacks para ajudar a identificar quaisquer callbacks atrasados<br>
-- nota: imprime na saída de depuração do log
function tcd.diagnostics()
    local count = 0

    for timer, entry in pairs(registry) do
        count = count + 1

        if entry.expiry < util.time_s() then
            local overtime = util.time_s() - entry.expiry
            log.debug(util.c("TCD: temporizador nao atendido ", timer, " para callback ", entry.callback, " esta pelo menos ", overtime, "s atrasado"))
        else
            local time = entry.expiry - util.time_s()
            log.debug(util.c("TCD: temporizador pendente ", timer, " para callback ", entry.callback, " (chamar apos ", entry.duration, "s, expira em ", time, ")"))
        end
    end

    log.debug(util.c("TCD: ", count, " callback(s) registrado(s) no total"))
end

return tcd
