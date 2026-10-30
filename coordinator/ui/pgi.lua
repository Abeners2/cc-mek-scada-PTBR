--
-- Interface Grafica Protegida (PGI)
--

local log  = require("scada-common.log")
local util = require("scada-common.util")

local pgi = {}

local data = {
    pkt_list = nil,  ---@type ListBox|nil
    pkt_entry = nil, ---@type function
    -- entradas de sessao
    s_entries = {
        pkt = {}     ---@type Div[]
    }
}

-- vincula as caixas de lista
---@param pkt_list ListBox pocket list element
---@param pkt_entry fun(parent: ListBox, id: integer) : Div pocket entry constructor
function pgi.link_elements(pkt_list, pkt_entry)
    data.pkt_list = pkt_list
    data.pkt_entry = pkt_entry
end

-- desvincula todos os campos, desabilitando a PGI
function pgi.unlink()
    data.pkt_list = nil
    data.pkt_entry = nil
end

-- adiciona uma entrada PKT a lista PKT
---@param session_id integer pocket session
function pgi.create_pkt_entry(session_id)
    if data.pkt_list ~= nil and data.pkt_entry ~= nil then
        local success, result = pcall(data.pkt_entry, data.pkt_list, session_id)

        if success then
            data.s_entries.pkt[session_id] = result
        else
            log.error(util.c("PGI: falha ao criar entrada PKT (", result, ")"), true)
        end
    end
end

-- remove uma entrada PKT da lista PKT
---@param session_id integer pocket session
function pgi.delete_pkt_entry(session_id)
    if data.s_entries.pkt[session_id] ~= nil then
        local success, result = pcall(data.s_entries.pkt[session_id].delete)
        data.s_entries.pkt[session_id] = nil

        if not success then
            log.error(util.c("PGI: falha ao remover entrada PKT (", result, ")"), true)
        end
    else
        log.debug(util.c("PGI: tentou remover entrada PKT desconhecida ", session_id))
    end
end

return pgi
