--
-- Camada de Interconexão Publicador-Assinante (PSIL)
--

local util = require("scada-common.util")

local psil = {}

-- instancia uma nova camada de interconexão
---@nodiscard
function psil.create()
    ---@type { [string]: { subscribers: { notify: fun(param: any) }[], value: any } } interconnect table
    local ic = {}

    -- aloca um novo campo de interconexão
    ---@key string data key
    local function alloc(key)
        ic[key] = { subscribers = {}, value = nil }
    end

    ---@class psil
    local public = {}

    -- inscreve-se em um objeto de dados na interconexão<br>
    -- chamará func() imediatamente se um valor já estiver disponível
    ---@param key string data key
    ---@param func function function to call on change
    function public.subscribe(key, func)
        -- aloca nova chave se não encontrada ou notifica se o valor for encontrado
        if ic[key] == nil then
            alloc(key)
        elseif ic[key].value ~= nil then
            func(ic[key].value)
        end

        -- inscreve-se na chave
        table.insert(ic[key].subscribers, { notify = func })
    end

    -- cancela a inscrição de uma função de uma determinada chave
    ---@param key string data key
    ---@param func function function to unsubscribe
    function public.unsubscribe(key, func)
        if ic[key] ~= nil then
            util.filter_table(ic[key].subscribers, function (s) return s.notify ~= func end)
        end
    end

    -- publica dados em uma determinada chave, repassando a todos os assinantes se tiver mudado
    ---@param key string data key
    ---@param value any data value
    function public.publish(key, value)
        if ic[key] == nil then alloc(key) end

        if ic[key].value ~= value then
            ic[key].value = value

            for i = 1, #ic[key].subscribers do
                ic[key].subscribers[i].notify(value)
            end
        end
    end

    -- publica um valor booleano alternado em uma determinada chave, repassando a todos os assinantes se tiver mudado<br>
    -- destinado a ser usado para alternar indicadores booleanos como heartbeats sem variáveis de estado extras
    ---@param key string data key
    function public.toggle(key)
        if ic[key] == nil then alloc(key) end

        ic[key].value = ic[key].value == false

        for i = 1, #ic[key].subscribers do
            ic[key].subscribers[i].notify(ic[key].value)
        end
    end

    -- obtém o valor atualmente armazenado para uma chave, ou nil se não definido
    ---@param key string data key
    ---@return any
    function public.get(key)
        if ic[key] ~= nil then return ic[key].value else return nil end
    end

    -- limpa o conteúdo da interconexão
    function public.purge() ic = {} end

    return public
end

return psil
