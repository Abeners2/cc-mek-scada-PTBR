local rtu = require("rtu.rtu")

local sps_rtu = {}

-- criar novo dispositivo mudador de fase supercrítico (SPS)
---@nodiscard
---@param sps SPS|ppm_generic
---@return rtu_device interface, boolean faulted
function sps_rtu.new(sps)
    local unit = rtu.init_unit(sps)

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
    unit.connect_input_reg("getCoils")
    unit.connect_input_reg("getInputCapacity")
    unit.connect_input_reg("getOutputCapacity")
    unit.connect_input_reg("getMaxEnergy")
    -- estado atual
    unit.connect_input_reg("getProcessRate")
    -- tanques
    unit.connect_input_reg("getInput")
    unit.connect_input_reg("getInputNeeded")
    unit.connect_input_reg("getInputFilledPercentage")
    unit.connect_input_reg("getOutput")
    unit.connect_input_reg("getOutputNeeded")
    unit.connect_input_reg("getOutputFilledPercentage")
    unit.connect_input_reg("getEnergy")
    unit.connect_input_reg("getEnergyNeeded")
    unit.connect_input_reg("getEnergyFilledPercentage")

    -- registradores de retenção --
    -- nenhum

    return unit.interface(), false
end

return sps_rtu
