local rtu = require("rtu.rtu")

local boilerv_rtu = {}

-- criar novo dispositivo de caldeira
---@nodiscard
---@param boiler Boiler|ppm_generic
---@return rtu_device interface, boolean faulted
function boilerv_rtu.new(boiler)
    local unit = rtu.init_unit(boiler)

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
    unit.connect_input_reg("getBoilCapacity")
    unit.connect_input_reg("getSteamCapacity")
    unit.connect_input_reg("getWaterCapacity")
    unit.connect_input_reg("getHeatedCoolantCapacity")
    unit.connect_input_reg("getCooledCoolantCapacity")
    unit.connect_input_reg("getSuperheaters")
    -- estado atual
    unit.connect_input_reg("getTemperature")
    unit.connect_input_reg("getBoilRate")
    unit.connect_input_reg("getMaxBoilRate")
    unit.connect_input_reg("getEnvironmentalLoss")
    -- tanques
    unit.connect_input_reg("getSteam")
    unit.connect_input_reg("getSteamNeeded")
    unit.connect_input_reg("getSteamFilledPercentage")
    unit.connect_input_reg("getWater")
    unit.connect_input_reg("getWaterNeeded")
    unit.connect_input_reg("getWaterFilledPercentage")
    unit.connect_input_reg("getHeatedCoolant")
    unit.connect_input_reg("getHeatedCoolantNeeded")
    unit.connect_input_reg("getHeatedCoolantFilledPercentage")
    unit.connect_input_reg("getCooledCoolant")
    unit.connect_input_reg("getCooledCoolantNeeded")
    unit.connect_input_reg("getCooledCoolantFilledPercentage")

    -- registradores de retenção --
    -- nenhum

    return unit.interface(), false
end

return boilerv_rtu
