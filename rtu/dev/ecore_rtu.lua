local rtu = require("rtu.rtu")

local ecore_rtu = {}

-- criar novo dispositivo de núcleo de energia do Draconic Evolution
---@nodiscard
---@param ecore DraconicEnergyCore|ppm_generic
---@return rtu_device interface, boolean faulted
function ecore_rtu.new(ecore)
    local unit = rtu.init_unit(ecore)

    -- entradas discretas --
    -- nenhuma

    -- bobinas --
    -- nenhuma

    -- registradores de entrada --
    -- propriedades de construção
    unit.connect_input_reg("getMaxEnergyStored")
    -- taxas de E/S
    unit.connect_input_reg("getInputPerTick")
    unit.connect_input_reg("getOutputPerTick")
    unit.connect_input_reg("getTransferPerTick")
    -- tanques
    unit.connect_input_reg("getEnergyStored")

    -- registradores de retenção --
    -- nenhum

    return unit.interface(), false
end

return ecore_rtu
