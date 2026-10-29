--
-- Funções Utilitárias
--

local cc_strings = require("cc.strings")

local const      = require("scada-common.constants")

local math = math
local string = string
local table = table
local os = os

local getmetatable = getmetatable
local print = print
local tostring = tostring
local type = type

local t_concat = table.concat
local t_insert = table.insert
local t_pack   = table.pack

---@class util
local util = {}

-- versão do scada-common
util.version = "1.11.3"

util.TICK_TIME_S = 0.05
util.TICK_TIME_MS = 50

--#region OPERATORS

-- operador ternário
---@nodiscard
---@param cond any condition
---@param a any return if evaluated as true
---@param b any return if false or nil
---@return any value
function util.trinary(cond, a, b)
    if cond then return a else return b end
end

--#endregion

--#region PRINT

local p_time = "[%H:%M:%S] "

-- imprime
---@param message any
function util.print(message) term.write(tostring(message)) end

-- imprime linha
---@param message any
function util.println(message) print(tostring(message)) end

-- imprime com timestamp
---@param message any
function util.print_ts(message) term.write(os.date(p_time) .. tostring(message)) end

-- imprime linha com timestamp
---@param message any
function util.println_ts(message) print(os.date(p_time) .. tostring(message)) end

--#endregion

--#region STRING TOOLS

-- obtém um valor como string
---@nodiscard
---@param val any
---@return string
function util.strval(val)
    local t = type(val)
    if t == "string" then return val end
    -- isso depende do curto-circuito do Lua na verificação 'or' para metatables (nota: metatables não terão metatables)
    if (t == "table" and (getmetatable(val) == nil or getmetatable(val).__tostring == nil)) or t == "function" then
        return t_concat{"[", tostring(val), "]"}
    else return tostring(val) end
end

-- tokeniza uma string por um separador<br>
-- não se comporta exatamente como o strtok do C
---@param str string string to tokenize
---@param sep string separator to tokenize by
---@return string[] token_list
function util.strtok(str, sep)
    local list = {}
    for part in string.gmatch(str, "([^" .. sep .. "]+)") do t_insert(list, part) end
    return list
end

-- repete um espaço n vezes
---@nodiscard
---@param n integer
---@return string
function util.spaces(n) return string.rep(" ", n) end

-- preenche o texto com espaços até uma largura mínima (centralizado)
---@nodiscard
---@param str string text
---@param n integer minimum width
---@return string
function util.pad(str, n)
    local len = string.len(str)
    local lpad = math.floor((n - len) / 2)
    local rpad = (n - len) - lpad

    return t_concat{util.spaces(lpad), str, util.spaces(rpad)}
end

-- remove espaços em branco no início e no fim
---@nodiscard
---@param s string text
---@return string
function util.trim(s)
    local str = s:gsub("^%s*(.-)%s*$", "%1")
    return str
end

-- quebra uma string em uma tabela de linhas
---@nodiscard
---@param str string
---@param limit integer line limit, must be greater than 0
---@return string[] lines
function util.strwrap(str, limit)
    assert(limit > 0, "util.strwrap() limit not greater than 0")
    return cc_strings.wrap(str, limit)
end

-- garante que uma string tenha pelo menos 'width' de comprimento
---@nodiscard
---@param str string
---@param width integer minimum width
---@return string string
function util.strminw(str, width) return cc_strings.ensure_width(str, width) end

-- concatenação com conversão integrada para string
---@nodiscard
---@param ... any
---@return string
function util.concat(...)
    local args, strings = t_pack(...), {}
    for i = 1, args.n do strings[i] = util.strval(args[i]) end
    return t_concat(strings)
end

-- apelido (alias)
util.c = util.concat

-- implementação de sprintf
---@nodiscard
---@param format string
---@param ... any
function util.sprintf(format, ...) return string.format(format, ...) end

-- formata uma string numérica com vírgulas como separador de milhar<br>
-- subtrai dos espaços no início, se presentes, para cada vírgula usada
---@nodiscard
---@param num string number string
---@return string
function util.comma_format(num)
    local formatted = num
    local commas = 0
    local i = 1

    while i > 0 do
        formatted, i = formatted:gsub("^(%s-%d+)(%d%d%d)", "%1,%2")
        if i > 0 then commas = commas + 1 end
    end

    local _, num_spaces = formatted:gsub(" %s-", "")
    local remove = math.min(num_spaces, commas)

    formatted = string.sub(formatted, remove + 1)

    return formatted
end

--#endregion

--#region MATH

-- verifica se um valor é um inteiro
---@nodiscard
---@param x any value
---@return boolean is_integer
function util.is_int(x) return type(x) == "number" and x == math.floor(x) end

-- obtém o sinal de um número
---@nodiscard
---@param x number value
---@return integer sign (-1 for < 0, 1 otherwise)
function util.sign(x) return util.trinary(x < 0, -1, 1) end

-- arredonda um número para um inteiro
---@nodiscard
---@return integer rounded
function util.round(x) return math.floor(x + 0.5) end

-- cria um novo objeto de média móvel (filtro FIR)
---@nodiscard
---@param length integer history length
function util.mov_avg(length)
    local data = {}
    local index = 1
    local last_t = 0 ---@type number|nil

    ---@class moving_average
    local public = {}

    -- redefine tudo para um determinado valor, ou limpa todos os dados se nenhum valor for fornecido
    ---@param x number? value
    function public.reset(x)
        index = 1
        data = {}

        if x then
            for _ = 1, length do t_insert(data, x) end
        end
    end

    -- registra um novo valor
    ---@param x number new value
    ---@param t number? optional last update time to prevent duplicated entries
    function public.record(x, t)
        if type(t) == "number" and last_t == t then return end

        data[index] = x
        last_t = t

        index = index + 1
        if index > length then index = 1 end
    end

    -- calcula a média móvel
    ---@nodiscard
    ---@return number average
    function public.compute()
        if #data == 0 then return 0 end

        local sum = 0
        for i = 1, #data do
            sum = sum + data[i]
        end

        return sum / #data
    end

    return public
end

-- cria um novo objeto de média móvel exponencial (filtro IIR)
---@nodiscard
---@param alpha number EMA filter alpha value
function util.ema_filter(alpha)
    local state = nil ---@type number|nil
    local last_t = 0 ---@type number|nil

    ---@class ema_filter
    local public = {}

    -- redefine o estado do filtro, opcionalmente inicializando-o com o valor fornecido
    ---@param x number? value
    function public.reset(x) state = x end

    -- atualiza o estado do filtro com um novo valor
    ---@param x number new value
    ---@param t number? optional last update time to prevent duplicated entries
    function public.update(x, t)
        if type(t) == "number" and last_t == t then return end

        if state then
            state = state + (alpha * (x - state))
        else state = x end

        last_t = t
    end

    -- obtém a média móvel
    ---@nodiscard
    ---@return number average
    function public.get() return state or 0.0 end

    return public
end

--#endregion

--#region TIME

-- tempo atual
---@nodiscard
---@return integer milliseconds
function util.time_ms() return os.epoch("local") end

-- tempo atual
---@nodiscard
---@return number seconds
function util.time_s() return os.epoch("local") / 1000.0 end

-- tempo atual
---@nodiscard
---@return integer milliseconds
function util.time() return util.time_ms() end

-- verifica o TPS cedendo por um tick e cronometrando quanto tempo isso leva
---@nodiscard
--- EVENT_CONSUMER: this function consumes events
function util.get_tps()
    local t_start = util.time_ms()
    util.nop()
    local t_end = util.time_ms()

    return 1000 / (t_end - t_start)
end

--#endregion

--#region OS

-- wrapper de os.pullEventRaw com tipos
---@nodiscard
---@param target_event? string event to wait for
---@return os_event event, any param1, any param2, any param3, any param4, any param5
function util.pull_event(target_event) return os.pullEventRaw(target_event) end

-- wrapper de os.queueEvent com tipos
---@param event os_event
---@param param1 any
---@param param2 any
---@param param3 any
---@param param4 any
---@param param5 any
function util.push_event(event, param1, param2, param3, param4, param5)
    return os.queueEvent(event, param1, param2, param3, param4, param5)
end

-- inicia um temporizador do SO
---@nodiscard
---@param t number timer duration in seconds
---@return integer timer ID
function util.start_timer(t) return os.startTimer(t) end

-- cancela um temporizador do SO
---@param timer integer timer ID
function util.cancel_timer(timer) os.cancelTimer(timer) end

--#endregion

--#region PARALLELIZATION

-- chamada sleep protegida para que ainda sejamos responsáveis por capturar o encerramento<br>
-- retorna o resultado de pcall
---@param t number seconds
---@return boolean success, any result, any ...
--- EVENT_CONSUMER: this function consumes events
function util.psleep(t) return pcall(os.sleep, t) end

-- no-op para fornecer uma breve pausa (1 tick) para ceder (yield)<br>
--- EVENT_CONSUMER: this function consumes events
function util.nop() util.psleep(0.05) end

-- tenta manter um tempo mínimo de loop (duração da execução)<br>
-- nota: não cederá por períodos de tempo inferiores a 50ms
---@nodiscard
---@param target_timing integer minimum amount of milliseconds to wait for
---@param last_update integer millisecond time of last update
---@return integer time_now
--- EVENT_CONSUMER: this function consumes events
function util.adaptive_delay(target_timing, last_update)
    local sleep_for = target_timing - (util.time() - last_update)
    -- apenas se >50ms, pois os loops de trabalho já cedem 0.05s
    if sleep_for >= 50 then util.psleep(sleep_for / 1000.0) end
    return util.time()
end

--#endregion

--#region TABLE UTILITIES

-- exclui elementos de uma tabela se a função passada retornar false quando receber um elemento da tabela<br>
-- resumindo: exclui elementos que retornam false, mantém elementos que retornam true
---@generic Type
---@param t Type[] table to remove elements from
---@param f fun(t_elem: Type) : boolean should return false to delete an element when passed the element
---@param on_delete? function optional function to execute on deletion, passed the table element to be deleted as the parameter
function util.filter_table(t, f, on_delete)
    local move_to = 1
    for i = 1, #t do
        local element = t[i]
        if element ~= nil then
            if f(element) then
                if t[move_to] == nil then
                    t[move_to] = element
                    t[i] = nil
                end
                move_to = move_to + 1
            else
                if on_delete then on_delete(element) end
                t[i] = nil
            end
        end
    end
end

-- verifica se uma tabela contém o elemento fornecido
---@generic Type
---@nodiscard
---@param t Type[] table to check
---@param element Type element to check for
function util.table_contains(t, element)
    for i = 1, #t do
        if t[i] == element then return true end
    end

    return false
end

-- conta o tamanho de uma tabela, mesmo que os valores não sejam sequenciais ou contenham chaves nomeadas
---@nodiscard
---@param t table
---@return integer length
function util.table_len(t)
    local n = 0
    for _, _ in pairs(t) do n = n + 1 end
    return n
end

--#endregion

--#region MEKANISM MATH

-- converte Joules para FE (ou RF)
---@nodiscard
---@param J number Joules
---@return number FE Forge Energy or Redstone Flux
function util.joules_to_fe_rf(J) return (J * 0.4) end

-- converte FE (ou RF) para Joules
---@nodiscard
---@param FE number Forge Energy or Redstone Flux
---@return number J Joules
function util.fe_rf_to_joules(FE) return (FE * 2.5) end

-- formata um valor de energia no formato XXX.XX UNIDADE<br>
-- exemplo para FE: FE, kFE, MFE, GFE, TFE, PFE, EFE, ZFE
---@nodiscard
---@param e number energy value
---@param label string energy scale label
---@param combine_label? boolean if a label should be included in the string itself
---@param format? string format override
---@return string str, string unit
function util.power_format(e, label, combine_label, format)
    local unit, value

    if type(format) ~= "string" then format = "%.2f" end

    local a = math.abs(e)

    if a < 1000.0 then
        unit = ""
        value = e
    elseif a < 1000000.0 then
        unit = "k"
        value = e / 1000.0
    elseif a < 1000000000.0 then
        unit = "M"
        value = e / 1000000.0
    elseif a < 1000000000000.0 then
        unit = "G"
        value = e / 1000000000.0
    elseif a < 1000000000000000.0 then
        unit = "T"
        value = e / 1000000000000.0
    elseif a < 1000000000000000000.0 then
        unit = "P"
        value = e / 1000000000000000.0
    elseif a < 1000000000000000000000.0 then
        -- se você conseguir isso, por favor vá tocar na grama
        unit = "E"
        value = e / 1000000000000000000.0
    else
        -- como e por que você fez isso?
        unit = "Z"
        value = e / 1000000000000000000000.0
    end

    unit = unit .. label

    if combine_label then
        return util.sprintf(util.c(format, " %s"), value, unit), unit
    else
        return util.sprintf(format, value), unit
    end
end

-- calcula a taxa de rotação do Mekanism para uma turbina
---@nodiscard
---@param turbine turbinev_session_db turbine data
function util.turbine_rotation(turbine)
    local build = turbine.build

    local inner_vol = build.steam_cap / const.mek.TURBINE_GAS_PER_TANK
    local disp_rate = (build.dispersers * const.mek.TURBINE_DISPERSER_FLOW) * inner_vol
    local vent_rate = build.vents * const.mek.TURBINE_VENT_FLOW

    local max_rate = math.min(disp_rate, vent_rate)
    local flow = math.min(max_rate, turbine.tanks.steam.amount)

    return (flow * (turbine.tanks.steam.amount / build.steam_cap)) / max_rate
end

--#endregion

--#region UTILITY CLASSES

-- WATCHDOG --

-- watchdog baseado em temporizador do SO<br>
-- dispara um evento de temporizador se não for alimentado dentro de 'timeout' segundos
---@nodiscard
---@param timeout number timeout duration
function util.new_watchdog(timeout)
    local self = { timeout = timeout, wd_timer = util.start_timer(timeout) }

    ---@class watchdog
    local public = {}

    -- verifica se um temporizador é este watchdog
    ---@nodiscard
    ---@param timer number event timer ID
    function public.is_timer(timer) return self.wd_timer == timer end

    -- sacia a fera
    function public.feed()
        public.cancel()
        self.wd_timer = util.start_timer(self.timeout)
    end

    -- cancela o watchdog
    function public.cancel()
        if self.wd_timer ~= nil then util.cancel_timer(self.wd_timer) end
    end

    return public
end

-- RELÓGIO DE LOOP (LOOP CLOCK) --

-- relógio de loop baseado em temporizador do SO<br>
-- dispara um evento de temporizador no período especificado, não inicia no momento da construção
---@nodiscard
---@param period number clock period
function util.new_clock(period)
    local self = { period = period, timer = nil }

    ---@class clock
    local public = {}

    -- verifica se um temporizador é este relógio
    ---@nodiscard
    ---@param timer number timer event timer ID
    function public.is_clock(timer) return self.timer == timer end

    -- inicia o relógio
    function public.start() self.timer = util.start_timer(self.period) end

    return public
end

-- VALIDADOR DE CAMPOS --

-- cria um novo validador de tipos<br>
-- pode executar verificações sequenciais e verificar valid() para ver se ainda é válido
---@nodiscard
function util.new_validator()
    local valid = true

    ---@class validator
    local public = {}

    function public.assert_type_bool(value) valid = valid and type(value) == "boolean" end
    function public.assert_type_num(value) valid = valid and type(value) == "number" end
    function public.assert_type_int(value) valid = valid and util.is_int(value) end
    function public.assert_type_str(value) valid = valid and type(value) == "string" end
    function public.assert_type_table(value) valid = valid and type(value) == "table" end

    function public.assert(check) valid = valid and (check == true) end
    function public.assert_eq(check, expect) valid = valid and check == expect end
    function public.assert_min(check, min) valid = valid and check >= min end
    function public.assert_min_ex(check, min) valid = valid and check > min end
    function public.assert_max(check, max) valid = valid and check <= max end
    function public.assert_max_ex(check, max) valid = valid and check < max end
    function public.assert_range(check, min, max) valid = valid and check >= min and check <= max end
    function public.assert_range_ex(check, min, max) valid = valid and check > min and check < max end

    function public.assert_channel(channel) valid = valid and util.is_int(channel) and channel >= 0 and channel <= 65535 end

    -- verifica se todas as asserções passaram com sucesso
    ---@nodiscard
    function public.valid() return valid end

    return public
end

--#endregion

return util
