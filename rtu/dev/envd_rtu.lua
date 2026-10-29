local rtu = require("rtu.rtu")

local envd_rtu = {}

-- criar novo dispositivo detector de ambiente
---@nodiscard
---@param envd EnvironmentDetector|ppm_generic
---@return rtu_device interface, boolean faulted
function envd_rtu.new(envd)
    local unit = rtu.init_unit(envd)

    -- desativar limpeza automática de falhas
    envd.__p_clear_fault()
    envd.__p_disable_afc()

    -- entradas discretas --
    -- nenhuma

    -- bobinas --
    -- nenhuma

    -- registradores de entrada --
    unit.connect_input_reg(envd.getRadiation)
    unit.connect_input_reg(envd.getRadiationRaw)

    -- registradores de retenção --
    -- nenhum

    -- verificar se alguma chamada falhou
    local faulted = envd.__p_is_faulted()
    envd.__p_clear_fault()
    envd.__p_enable_afc()

    return unit.interface(), faulted
end

return envd_rtu
