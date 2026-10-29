--
-- Fila de Mensagens (Message Queue)
--

local mqueue = {}

---@class queue_item
---@field qtype MQ_TYPE
---@field message any

---@class queue_data
---@field key any
---@field val any

---@enum MQ_TYPE
local TYPE = {
    COMMAND = 0,
    DATA = 1,
    NETWORK = 2
}

mqueue.TYPE = TYPE

local insert = table.insert
local remove = table.remove

-- cria uma nova fila de mensagens
---@nodiscard
function mqueue.new()
    ---@type queue_item[]
    local queue = {}

    ---@class mqueue
    local public = {}

    -- obtém o tamanho da fila
    function public.length() return #queue end

    -- verifica se a fila está vazia
    ---@nodiscard
    ---@return boolean is_empty
    function public.empty() return #queue == 0 end

    -- verifica se a fila possui conteúdo
    ---@nodiscard
    ---@return boolean has_contents
    function public.ready() return #queue ~= 0 end

    -- insere um novo item na fila
    ---@param qtype MQ_TYPE
    ---@param message any
    local function _push(qtype, message) insert(queue, { qtype = qtype, message = message }) end

    -- insere um comando na fila
    ---@param message any
    function public.push_command(message) _push(TYPE.COMMAND, message) end

    -- insere dados na fila
    ---@param key any
    ---@param value any
    function public.push_data(key, value) _push(TYPE.DATA, { key = key, val = value }) end

    -- insere um quadro SCADA, pacote ou contêiner de pacote na fila
    ---@param object frame|packet|packet_container
    function public.push_network(object) _push(TYPE.NETWORK, object) end

    -- remove e retorna um item da fila
    ---@nodiscard
    ---@return queue_item|nil
    function public.pop()
        if #queue > 0 then
            return remove(queue, 1)
        else return nil end
    end

    return public
end

return mqueue
