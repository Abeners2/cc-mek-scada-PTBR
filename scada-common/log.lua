--
-- Registrador do Sistema de Arquivos (Logger)
--

local util = require("scada-common.util")

-- strings constantes para velocidade
local DBG_TAG, INF_TAG, WRN_TAG, ERR_TAG, FTL_TAG = "[DBG] ", "[INF] ", "[WRN] ", "[ERR] ", "[FTL] "
local COLON, FUNC, ARROW = ":", "():", " > "

local MIN_SPACE    = 2048
local OUT_OF_SPACE = "Out of space"
local TIME_FMT     = "%F %T "

---@class logger
local log = {}

---@enum LOG_MODE
local MODE = { APPEND = 0, NEW = 1 }

log.MODE = MODE

log.MIN_SPACE = MIN_SPACE

local _log = {
    not_ready = true,
    path = "/log.txt",
    mode = MODE.APPEND,
    debug = false,
    file = nil,         ---@type table|nil
    dmesg_out = nil,    ---@type Redirect|nil
    dmesg_restore_coord = { 1, 1 },
    dmesg_scroll_count = 0
}

---@type function
local free_space = fs.getFreeSpace

-----------------------
-- PRIVATE FUNCTIONS --
-----------------------

-- verifica se o erro fornecido indica falta de espaço ou se o espaço disponível é insuficiente
---@param err_msg string|nil error message
---@return boolean out_of_space
local function check_out_of_space(err_msg)
    return (free_space(_log.path) < MIN_SPACE) or ((err_msg ~= nil) and (string.find(err_msg, OUT_OF_SPACE) ~= nil))
end

-- função privada de escrita no log
---@param msg_bits any[]
local function write_log(msg_bits)
    if _log.not_ready then return end

    local time_stamp = os.date(TIME_FMT)
    local stamped    = util.c(time_stamp, table.unpack(msg_bits))

    -- tenta escrever no log
    local status, result = pcall(function ()
        _log.file.writeLine(stamped)
        _log.file.flush()
    end)

    -- se não tivermos espaço, precisamos criar um novo arquivo de log
    if check_out_of_space() then
        -- exclui o arquivo de log antigo antes de abrir um novo
        _log.file.close()
        fs.delete(_log.path)

        -- reinicializa o logger e passa dmesg_out para que não mude
        log.init(_log.path, _log.mode, _log.debug, _log.dmesg_out)

        -- registra a mensagem e o aviso de reciclagem
        _log.file.writeLine(time_stamp .. WRN_TAG .. "arquivo de log reciclado")
        _log.file.writeLine(stamped)
        _log.file.flush()
    elseif (not status) and (result ~= nil) then
        util.println("erro inesperado ao escrever no arquivo de log: " .. result)
    end
end

----------------------
-- PUBLIC FUNCTIONS --
----------------------

-- inicializa o logger
---@param path string file path
---@param write_mode LOG_MODE file write mode
---@param include_debug boolean whether or not to include debug logs
---@param dmesg_redirect? Redirect terminal/window to direct dmesg to
function log.init(path, write_mode, include_debug, dmesg_redirect)
    local err_msg

    _log.path = path
    _log.mode = write_mode
    _log.debug = include_debug
    _log.file, err_msg = fs.open(path, util.trinary(_log.mode == MODE.APPEND, "a", "w"))

    if dmesg_redirect then
        _log.dmesg_out = dmesg_redirect
    else
        _log.dmesg_out = term.current()
    end

    -- verifica problemas de espaço
    local out_of_space = check_out_of_space(err_msg)

    -- tenta lidar com problemas
    if _log.file == nil or out_of_space then
        if out_of_space then
            if fs.exists(_log.path) then
                fs.delete(_log.path)

                _log.file, err_msg = fs.open(path, util.trinary(_log.mode == MODE.APPEND, "a", "w"))

                if _log.file then
                    _log.file.writeLine(os.date(TIME_FMT) .. WRN_TAG .. "arquivo de log reciclado na inicializacao")
                    _log.file.flush()
                else error("falha ao configurar o arquivo de log: " .. err_msg) end
            else error("falha ao liberar espaco para o arquivo de log, exclua arquivos nao utilizados") end
        else error("erro inesperado ao configurar o arquivo de log: " .. err_msg) end
    end

    _log.not_ready = false
end

-- fecha o identificador do arquivo de log
function log.close() _log.file.close() end

-- direciona a saída dmesg para um monitor/janela
---@param window Window window or terminal reference
function log.direct_dmesg(window) _log.dmesg_out = window end

-- registro estilo dmesg para inicialização porque gosto de coisas estilo linux
---@param msg any message
---@param tag? string log tag
---@param tag_color? integer log tag color
---@return dmesg_ts_coord coordinates line area to place working indicator
function log.dmesg(msg, tag, tag_color)
    ---@class dmesg_ts_coord
    local ts_coord = { x1 = 2, x2 = 3, y = 1 }

    msg = util.strval(msg)
    tag = util.strval(tag or "")

    local t_stamp = string.format("%12.2f", os.clock())
    local out = _log.dmesg_out

    if out ~= nil then
        local out_w, out_h = out.getSize()

        local lines = { msg }

        -- quebra a linha se necessário
        if string.len(msg) > out_w then
            local remaining = true
            local s_start = 1
            local s_end = out_w
            local i = 1

            lines = {}

            while remaining do
                local line = string.sub(msg, s_start, s_end)

                if line == "" then
                    remaining = false
                else
                    lines[i] = line

                    s_start = s_end + 1
                    s_end = s_end + out_w
                    i = i + 1
                end
            end
        end

        -- inicia a saída com tag e tempo, assumindo que temos largura suficiente para ficar em uma linha
        local cur_x, cur_y = out.getCursorPos()

        if cur_x > 1 then
            if cur_y == out_h then
                out.scroll(1)
                out.setCursorPos(1, cur_y)
                _log.dmesg_scroll_count = _log.dmesg_scroll_count + 1
            else
                out.setCursorPos(1, cur_y + 1)
            end
        end

        -- tempo colorido
        local initial_color = out.getTextColor()
        out.setTextColor(colors.white)
        out.write("[")
        out.setTextColor(colors.lightGray)
        out.write(t_stamp)
        ts_coord.x2, ts_coord.y = out.getCursorPos()
        ts_coord.x2 = ts_coord.x2 - 1
        out.setTextColor(colors.white)
        out.write("] ")

        -- imprime tag opcionalmente colorida
        if tag ~= "" then
            out.write("[")
            if tag_color then out.setTextColor(tag_color) end
            out.write(tag)
            out.setTextColor(colors.white)
            out.write("] ")
        end

        out.setTextColor(initial_color)

        -- exibe a mensagem
        for i = 1, #lines do
            cur_x, cur_y = out.getCursorPos()

            if i > 1 and cur_x > 1 then
                if cur_y == out_h then
                    out.scroll(1)
                    out.setCursorPos(1, cur_y)
                    _log.dmesg_scroll_count = _log.dmesg_scroll_count + 1
                else
                    out.setCursorPos(1, cur_y + 1)
                end
            end

            out.write(lines[i])
        end

        _log.dmesg_restore_coord = { out.getCursorPos() }

        write_log{"[", t_stamp, "] [", tag, "] ", msg}
    end

    return ts_coord
end

-- imprime uma mensagem dmesg, mas mostra os segundos restantes em vez do timestamp
---@nodiscard
---@param msg string message
---@param tag? string log tag
---@param tag_color? integer log tag color
---@return function update, function done
function log.dmesg_working(msg, tag, tag_color)
    local ts_coord = log.dmesg(msg, tag, tag_color)
    local initial_scroll = _log.dmesg_scroll_count

    local out = _log.dmesg_out
    local width = (ts_coord.x2 - ts_coord.x1) + 1

    if out ~= nil then
        local initial_color = out.getTextColor()

        local counter = 0

        local function update(sec_remaining)
            local new_y = ts_coord.y - (_log.dmesg_scroll_count - initial_scroll)
            if new_y < 1 then return end

            local time = util.sprintf("%ds", sec_remaining)
            local available = width - (string.len(time) + 2)
            local progress = ""

            out.setCursorPos(ts_coord.x1, new_y)
            out.write(" ")

            if counter % 4 == 0 then
                progress = "|"
            elseif counter % 4 == 1 then
                progress = "/"
            elseif counter % 4 == 2 then
                progress = "-"
            elseif counter % 4 == 3 then
                progress = "\\"
            end

            out.setTextColor(colors.blue)
            out.write(progress)
            out.setTextColor(colors.lightGray)
            out.write(util.spaces(available) .. time)
            out.setTextColor(initial_color)

            counter = counter + 1

            out.setCursorPos(table.unpack(_log.dmesg_restore_coord))
        end

        local function done(ok)
            local new_y = ts_coord.y - (_log.dmesg_scroll_count - initial_scroll)
            if new_y < 1 then return end

            out.setCursorPos(ts_coord.x1, new_y)

            if ok or ok == nil then
                out.setTextColor(colors.green)
                out.write(util.pad("OK", width))
            else
                out.setTextColor(colors.red)
                out.write(util.pad("FALHA", width))
            end

            out.setTextColor(initial_color)

            out.setCursorPos(table.unpack(_log.dmesg_restore_coord))
        end

        return update, done
    else
        return function () end, function () end
    end
end

-- registra mensagens de depuração (debug)
---@param msg any message
---@param trace? boolean include file trace
function log.debug(msg, trace)
    if _log.debug then
        if trace then
            local info = debug.getinfo(2)

            if info.name ~= nil then
                write_log{DBG_TAG, info.short_src, COLON, info.name, FUNC, info.currentline, ARROW, msg}
            else
                write_log{DBG_TAG, info.short_src, COLON, info.currentline, ARROW, msg}
            end
        else
            write_log{DBG_TAG, msg}
        end
    end
end

-- registra mensagens informativas (info)
---@param msg any message
function log.info(msg) write_log{INF_TAG, msg} end

-- registra mensagens de aviso (warning)
---@param msg any message
function log.warning(msg) write_log{WRN_TAG, msg} end

-- registra mensagens de erro (error)
---@param msg any message
---@param trace? boolean include file trace
function log.error(msg, trace)
    if trace then
        local info = debug.getinfo(2)

        if info.name ~= nil then
            write_log{ERR_TAG, info.short_src, COLON, info.name, FUNC, info.currentline, ARROW, msg}
        else
            write_log{ERR_TAG, info.short_src, COLON, info.currentline, ARROW, msg}
        end
    else
        write_log{ERR_TAG, msg}
    end
end

-- registra erros fatais (fatal)
---@param msg any message
function log.fatal(msg) write_log{FTL_TAG, msg} end

return log
