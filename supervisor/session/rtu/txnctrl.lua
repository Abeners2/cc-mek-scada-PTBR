--
-- Controlador de Transações MODBUS
--

local util = require("scada-common.util")

local txnctrl = {}

-- espera máxima de 2000ms
local TIMEOUT = 2000

-- criar um novo controlador de transações
---@nodiscard
function txnctrl.new()
    local self = {
        list = {},
        next_id = 0
    }

    ---@class transaction_controller
    local public = {}

    local insert = table.insert
    local remove = table.remove

    -- obter o tamanho da lista de transações
    ---@nodiscard
    function public.length()
        return #self.list
    end

    -- verificar se não há transações ativas
    ---@nodiscard
    function public.empty()
        return #self.list == 0
    end

    -- criar uma nova transação do tipo informado
    ---@nodiscard
    ---@param txn_type integer
    ---@return integer txn_id
    function public.create(txn_type)
        local txn_id = self.next_id

        insert(self.list, {
            txn_id = txn_id,
            txn_type = txn_type,
            expiry = util.time() + TIMEOUT
        })

        self.next_id = self.next_id + 1

        return txn_id
    end

    -- marcar uma transação como resolvida para obter seu tipo
    ---@nodiscard
    ---@param txn_id integer
    ---@return integer|nil txn_type
    function public.resolve(txn_id)
        local txn_type = nil

        for i = 1, public.length() do
            if self.list[i].txn_id == txn_id then
                local entry = remove(self.list, i)
                txn_type = entry.txn_type
                break
            end
        end

        return txn_type
    end

    -- renovar uma transação reinserindo-a com seu ID e tipo
    ---@param txn_id integer
    ---@param txn_type integer
    function public.renew(txn_id, txn_type)
        insert(self.list, {
            txn_id = txn_id,
            txn_type = txn_type,
            expiry = util.time() + TIMEOUT
        })
    end

    -- fechar transações expiradas
    function public.cleanup()
        local now = util.time()
        util.filter_table(self.list, function (txn) return txn.expiry > now end)
    end

    -- limpar a lista de transações
    function public.clear()
        self.list = {}
    end

    return public
end

return txnctrl
