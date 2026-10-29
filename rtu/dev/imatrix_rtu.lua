local rtu = require("rtu.rtu")

local imatrix_rtu = {}

-- criar novo dispositivo de matriz de indução
---@nodiscard
---@param imatrix InductionMatrix|ppm_generic
---@return rtu_device interface, boolean faulted
function imatrix_rtu.new(imatrix)
    local unit = rtu.init_unit(imatrix)

    -- entradas discretas --
    unit.connect_di("isFormed")

    -- bobinas --
    -- nenhuma

    -- registradores de entrada --
    -- propriedades do multibloco
    unit.connect_input_reg("getLength")
    unit.connect_input_reg("getWidth")
    unit.connect_input_reg("getHeight")
    unit.connect_input_reg("getMinPos")
    unit.connect_input_reg("getMaxPos")
    -- propriedades de construção
    unit.connect_input_reg("getMaxEnergy")
    unit.connect_input_reg("getTransferCap")
    unit.connect_input_reg("getInstalledCells")
    unit.connect_input_reg("getInstalledProviders")
    -- taxas de E/S
    unit.connect_input_reg("getLastInput")
    unit.connect_input_reg("getLastOutput")
    -- tanques
    unit.connect_input_reg("getEnergy")
    unit.connect_input_reg("getEnergyNeeded")
    unit.connect_input_reg("getEnergyFilledPercentage")

    -- registradores de retenção --
    -- nenhum

    return unit.interface(), false
end

return imatrix_rtu
