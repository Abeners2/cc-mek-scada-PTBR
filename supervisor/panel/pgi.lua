--
-- Interface Gráfica Protegida
--

local log  = require("scada-common.log")
local util = require("scada-common.util")

local pgi = {}

local data = {
    rtu_list = nil,  ---@type ListBox|nil
    pdg_list = nil,  ---@type ListBox|nil
    chk_list = nil,  ---@type ListBox|nil
    rtu_entry = nil, ---@type function
    pdg_entry = nil, ---@type function
    chk_entry = nil, ---@type function
    -- entradas das listas
    entries = {
        rtu = {},    ---@type Div[]
        pdg = {},    ---@type Div[]
        chk = {},    ---@type Div[][]
        missing = {} ---@type Div[]
    }
}

-- vincular caixas de listagem
---@param rtu_list ListBox elemento da lista de RTU
---@param rtu_entry fun(parent: ListBox, id: integer) : Div construtor de entrada de RTU
---@param pdg_list ListBox elemento da lista de diagnósticos pocket
---@param pdg_entry fun(parent: ListBox, id: integer) : Div construtor de entrada de diagnósticos pocket
---@param chk_list ListBox elemento da lista CHK
---@param chk_entry fun(parent: ListBox, msg: string, fail_code: integer) : Div construtor de entrada CHK
function pgi.link_elements(rtu_list, rtu_entry, pdg_list, pdg_entry, chk_list, chk_entry)
    data.rtu_list = rtu_list
    data.pdg_list = pdg_list
    data.chk_list = chk_list
    data.rtu_entry = rtu_entry
    data.pdg_entry = pdg_entry
    data.chk_entry = chk_entry
end

-- desvincular todos os campos, desativando a PGI
function pgi.unlink()
    data.rtu_list = nil
    data.pdg_list = nil
    data.chk_list = nil
    data.rtu_entry = nil
    data.pdg_entry = nil
    data.chk_entry = nil
end

-- adicionar uma entrada de RTU à lista de RTU
---@param session_id integer sessão da RTU
function pgi.create_rtu_entry(session_id)
    if data.rtu_list ~= nil and data.rtu_entry ~= nil then
        local success, result = pcall(data.rtu_entry, data.rtu_list, session_id)

        if success then
            data.entries.rtu[session_id] = result
            log.debug(util.c("PGI: entrada de RTU criada (", session_id, ")"))
        else
            log.error(util.c("PGI: falha ao criar entrada de RTU (", result, ")"), true)
        end
    end
end

-- excluir uma entrada de RTU da lista de RTU
---@param session_id integer sessão da RTU
function pgi.delete_rtu_entry(session_id)
    if data.entries.rtu[session_id] ~= nil then
        local success, result = pcall(data.entries.rtu[session_id].delete)
        data.entries.rtu[session_id] = nil

        if success then
            log.debug(util.c("PGI: entrada de RTU excluída (", session_id, ")"))
        else
            log.error(util.c("PGI: falha ao excluir entrada de RTU (", result, ")"), true)
        end
    else
        log.warning(util.c("PGI: tentativa de excluir entrada de RTU desconhecida ", session_id))
    end
end

-- adicionar uma entrada PDG à lista PDG
---@param session_id integer sessão de diagnósticos pocket
function pgi.create_pdg_entry(session_id)
    if data.pdg_list ~= nil and data.pdg_entry ~= nil then
        local success, result = pcall(data.pdg_entry, data.pdg_list, session_id)

        if success then
            data.entries.pdg[session_id] = result
            log.debug(util.c("PGI: entrada PDG criada (", session_id, ")"))
        else
            log.error(util.c("PGI: falha ao criar entrada PDG (", result, ")"), true)
        end
    end
end

-- excluir uma entrada PDG da lista PDG
---@param session_id integer sessão de diagnósticos pocket
function pgi.delete_pdg_entry(session_id)
    if data.entries.pdg[session_id] ~= nil then
        local success, result = pcall(data.entries.pdg[session_id].delete)
        data.entries.pdg[session_id] = nil

        if success then
            log.debug(util.c("PGI: entrada PDG excluída (", session_id, ")"))
        else
            log.error(util.c("PGI: falha ao excluir entrada PDG (", result, ")"), true)
        end
    else
        log.warning(util.c("PGI: tentativa de excluir entrada PDG desconhecida ", session_id))
    end
end

-- adicionar uma entrada de falha na verificação de ID de dispositivo à lista CHK
---@note isso assume que apenas um tipo de falha pode ocorrer por cada RTU da sessão de gateway RTU, o que é o caso
---@param unit unit_session sessão da RTU
---@param fail_code integer código de falha
---@param msg string descrição para mostrar
---@param details string? detalhes para mostrar
function pgi.create_chk_entry(unit, fail_code, msg, details)
    local gw_session = unit.get_session_id()

    if data.chk_list ~= nil and data.chk_entry ~= nil then
        if not data.entries.chk[gw_session] then data.entries.chk[gw_session] = {} end

        local success, result = pcall(data.chk_entry, data.chk_list, fail_code, msg, details)

        if success then
            data.entries.chk[gw_session][unit.get_unit_id()] = result
            log.debug(util.c("PGI: entrada CHK criada (", gw_session, ":", unit.get_unit_id(), ")"))
        else
            log.error(util.c("PGI: falha ao criar entrada CHK (", result, ")"), true)
        end
    end
end

-- excluir uma entrada de falha na verificação de ID de dispositivo da lista CHK<br>
-- isso assume que apenas um tipo de falha pode ocorrer por cada RTU da sessão de gateway RTU, o que é o caso
---@param unit unit_session sessão da RTU
function pgi.delete_chk_entry(unit)
    local gw_session = unit.get_session_id()
    local ent_chk = data.entries.chk

    if ent_chk[gw_session] ~= nil and ent_chk[gw_session][unit.get_unit_id()] ~= nil then
        local success, result = pcall(ent_chk[gw_session][unit.get_unit_id()].delete)
        ent_chk[gw_session][unit.get_unit_id()] = nil

        if success then
            log.debug(util.c("PGI: entrada CHK excluída ", gw_session, ":", unit.get_unit_id()))
        else
            log.error(util.c("PGI: falha ao excluir entrada CHK (", result, ")"), true)
        end
    else
        log.warning(util.c("PGI: tentativa de excluir entrada CHK desconhecida com sessão ", gw_session, " e ID de unidade ", unit.get_unit_id()))
    end
end

-- adicionar uma entrada de ID de dispositivo ausente à lista CHK
---@param message string mensagem de dispositivo ausente
function pgi.create_missing_entry(message)
    if data.entries.missing[message] ~= nil then
        log.warning(util.c("PGI: tentativa de criar uma entrada CHK ausente duplicada \"", message, "\""))
    elseif data.chk_list ~= nil and data.chk_entry ~= nil then
        local success, result = pcall(data.chk_entry, data.chk_list, 4, message)

        if success then
            data.entries.missing[message] = result
            log.debug(util.c("PGI: entrada CHK ausente criada (", message, ")"))
        else
            log.error(util.c("PGI: falha ao criar entrada CHK ausente (", result, ")"), true)
        end
    end
end

-- excluir uma entrada de ID de dispositivo ausente da lista CHK
---@param message string mensagem de dispositivo ausente
function pgi.delete_missing_entry(message)
    if data.entries.missing[message] ~= nil then
        local success, result = pcall(data.entries.missing[message].delete)
        data.entries.missing[message] = nil

        if success then
            log.debug(util.c("PGI: entrada CHK ausente excluída \"", message, "\""))
        else
            log.error(util.c("PGI: falha ao excluir entrada CHK ausente (", result, ")"), true)
        end
    else
        log.warning(util.c("PGI: tentativa de excluir entrada CHK ausente desconhecida \"", message, "\""))
    end
end

return pgi
