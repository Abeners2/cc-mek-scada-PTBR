local rtu = require("rtu.rtu")

local dynamicv_rtu = {}

-- criar novo dispositivo de tanque dinâmico
---@nodiscard
---@param dynamic_tank DynamicTank|ppm_generic
---@return rtu_device interface, boolean faulted
function dynamicv_rtu.new(dynamic_tank)
    local unit = rtu.init_unit(dynamic_tank)

    -- entradas discretas --
    unit.connect_di("isFormed")

    -- bobinas --
    unit.connect_coil(function () dynamic_tank.incrementContainerEditMode() end, function () end)
    unit.connect_coil(function () dynamic_tank.decrementContainerEditMode() end, function () end)

    -- registradores de entrada --
    -- propriedades do multibloco
    unit.connect_input_reg("getLength")
    unit.connect_input_reg("getWidth")
    unit.connect_input_reg("getHeight")
    unit.connect_input_reg("getMinPos")
    unit.connect_input_reg("getMaxPos")
    -- propriedades de construção
    unit.connect_input_reg("getTankCapacity")
    unit.connect_input_reg("getChemicalTankCapacity")
    -- tanques/contêineres
    unit.connect_input_reg("getStored")
    unit.connect_input_reg("getFilledPercentage")

    -- registradores de retenção --
    unit.connect_holding_reg("getContainerEditMode", "setContainerEditMode")

    return unit.interface(), false
end

return dynamicv_rtu
