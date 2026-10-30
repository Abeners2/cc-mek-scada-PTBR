---@class rtu_unit_qtypes
local qtypes = {}

-- comandos de sessão RTU da válvula de turbina
local TBV_RTU_S_CMDS = {
    INC_DUMP_MODE = 1,
    DEC_DUMP_MODE = 2
}

-- comandos de sessão RTU da válvula de turbina c/ parâmetros
local TBV_RTU_S_DATA = {
    SET_DUMP_MODE = 1
}

-- comandos de sessão RTU da válvula de tanque dinâmico
local DTV_RTU_S_CMDS = {
    INC_CONT_MODE = 1,
    DEC_CONT_MODE = 2
}

-- comandos de sessão RTU da válvula de tanque dinâmico c/ parâmetros
local DTV_RTU_S_DATA = {
    SET_CONT_MODE = 1
}

qtypes.TBV_RTU_S_CMDS = TBV_RTU_S_CMDS
qtypes.TBV_RTU_S_DATA = TBV_RTU_S_DATA
qtypes.DTV_RTU_S_CMDS = DTV_RTU_S_CMDS
qtypes.DTV_RTU_S_DATA = DTV_RTU_S_DATA

return qtypes
