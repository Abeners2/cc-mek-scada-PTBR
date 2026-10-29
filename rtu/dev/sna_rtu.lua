local rtu = require("rtu.rtu")

local sna_rtu = {}

-- criar novo dispositivo ativador de nêutrons solares (SNA)
---@nodiscard
---@param sna SolarNeutronActivator|ppm_generic
---@return rtu_device interface, boolean faulted
function sna_rtu.new(sna)
    local unit = rtu.init_unit(sna)

    -- desativar limpeza automática de falhas
    sna.__p_clear_fault()
    sna.__p_disable_afc()

    -- entradas discretas --
    -- nenhuma

    -- bobinas --
    -- nenhuma

    -- registradores de entrada --
    -- propriedades de construção
    unit.connect_input_reg(sna.getInputCapacity)
    unit.connect_input_reg(sna.getOutputCapacity)
    -- estado atual
    unit.connect_input_reg(sna.getProductionRate)
    unit.connect_input_reg(sna.getPeakProductionRate)
    -- tanques
    unit.connect_input_reg(sna.getInput)
    unit.connect_input_reg(sna.getInputNeeded)
    unit.connect_input_reg(sna.getInputFilledPercentage)
    unit.connect_input_reg(sna.getOutput)
    unit.connect_input_reg(sna.getOutputNeeded)
    unit.connect_input_reg(sna.getOutputFilledPercentage)

    -- registradores de retenção --
    -- nenhum

    -- verificar se alguma chamada falhou
    local faulted = sna.__p_is_faulted()
    sna.__p_clear_fault()
    sna.__p_enable_afc()

    return unit.interface(), faulted
end

return sna_rtu
