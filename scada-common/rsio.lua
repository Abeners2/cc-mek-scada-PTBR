--
-- E/S de Redstone (Redstone I/O)
--

local util = require("scada-common.util")

---@class rsio
local rsio = {}

--#region RS I/O Constants

---@enum IO_LVL I/O logic level
local IO_LVL = {
    DISCONNECT = -1, -- usado para sessão RTU para indicar que esta RTU não está conectada a esta porta
    LOW = 0,
    HIGH = 1,
    FLOATING = 2     -- usado para sessão RTU para indicar que esta RTU está conectada, mas ainda não foi lida
}

---@enum IO_DIR I/O direction
local IO_DIR = {
    IN = 0,
    OUT = 1
}

---@enum IO_MODE I/O mode (digital/analog input/output)
local IO_MODE = {
    DIGITAL_IN = 0,
    DIGITAL_OUT = 1,
    ANALOG_IN = 2,
    ANALOG_OUT = 3
}

---@enum IO_PORT redstone I/O logic port
local IO_PORT = {
    -- entradas digitais --

    -- instalação
    F_SCRAM       = 1,  -- ativo baixo, scram em toda a instalação
    F_ACK         = 2,  -- ativo alto, reconhecimento de alarme da instalação

    -- reator
    R_SCRAM       = 3,  -- ativo baixo, scram do reator
    R_RESET       = 4,  -- ativo alto, redefinição do RPS do reator
    R_ENABLE      = 5,  -- ativo alto, ativação do reator

    -- unidade
    U_ACK         = 6,  -- ativo alto, reconhecimento de alarme da unidade

    -- saídas digitais --

    -- instalação
    F_ALARM       = 7,  -- ativo alto, alarme em toda a instalação (qualquer alarme de unidade de alta prioridade)
    F_ALARM_ANY   = 8,  -- ativo alto, qualquer alarme independentemente da prioridade
    F_CHARGE_LOW  = 27, -- ativo alto, carga de armazenamento de energia baixa
    F_CHARGE_HIGH = 28, -- ativo alto, carga de armazenamento de energia alta

    F_WASTE_PU    = 31, -- ativo baixo, rota de resíduo -> plutônio -> pastilhas
    F_WASTE_PO    = 32, -- ativo baixo, rota de resíduo -> polônio
    F_WASTE_POPL  = 33, -- ativo baixo, rota de polônio -> pastilhas
    F_WASTE_AM    = 34, -- ativo baixo, rota de polônio -> antimatéria

    -- saídas da unidade
    U_ALARM       = 25, -- ativo alto, alarme da unidade
    U_EMER_COOL   = 26, -- ativo baixo, controle de refrigerante de emergência
    U_AUX_COOL    = 30, -- ativo baixo, controle de refrigerante auxiliar

    U_WASTE_PU    = 9,  -- ativo baixo, rota de resíduo -> plutônio -> pastilhas
    U_WASTE_PO    = 10, -- ativo baixo, rota de resíduo -> polônio
    U_WASTE_POPL  = 11, -- ativo baixo, rota de polônio -> pastilhas
    U_WASTE_AM    = 12, -- ativo baixo, rota de polônio -> antimatéria

    -- reator
    R_ACTIVE      = 13, -- ativo alto, o reator está ativo
    R_AUTO_CTRL   = 14, -- ativo alto, a taxa de queima do reator é automática
    R_SCRAMMED    = 15, -- ativo alto, o reator sofreu scram
    R_AUTO_SCRAM  = 16, -- ativo alto, o reator sofreu scram automaticamente
    R_HIGH_DMG    = 17, -- ativo alto, o dano do reator está alto
    R_HIGH_TEMP   = 18, -- ativo alto, o reator está em alta temperatura
    R_LOW_COOLANT = 19, -- ativo alto, o reator está com refrigerante muito baixo
    R_EXCESS_HC   = 20, -- ativo alto, o reator está com excesso de refrigerante aquecido
    R_EXCESS_WS   = 21, -- ativo alto, o reator está com excesso de resíduos
    R_INSUFF_FUEL = 22, -- ativo alto, o reator está com combustível insuficiente
    R_PLC_FAULT   = 23, -- ativo alto, o PLC do reator reporta uma falha de acesso ao dispositivo
    R_PLC_TIMEOUT = 24, -- ativo alto, o PLC do reator não respondeu

    -- saídas analógicas --

    -- instalação
    F_ENERGY_CHG  = 29  -- nível de carga analógico do sistema de armazenamento de energia
}

rsio.IO_LVL = IO_LVL
rsio.IO_DIR = IO_DIR
rsio.IO_MODE = IO_MODE
rsio.IO = IO_PORT

rsio.NUM_PORTS = 34
rsio.NUM_DIG_PORTS = 33
rsio.NUM_ANA_PORTS = 1

-- autoverificações

assert(rsio.NUM_PORTS == (rsio.NUM_DIG_PORTS + rsio.NUM_ANA_PORTS), "contagens de portas inconsistentes")

local dup_chk = {}
for _, v in pairs(IO_PORT) do
    assert(dup_chk[v] ~= true, "duplicata na lista de portas")
    dup_chk[v] = true
end

assert(#dup_chk == rsio.NUM_PORTS, "lista de portas malformada")

--#endregion

--#region Utility Functions and Attribute Tables

local IO = IO_PORT

-- lista de todos os nomes de portas
---@type string[]
local PORT_NAMES = {}

for k, v in pairs(IO) do PORT_NAMES[v] = k end

-- lista de todos os modos de E/S das portas
---@type { [IO_PORT]: IO_MODE }
local MODES = {
    [IO.F_SCRAM]       = IO_MODE.DIGITAL_IN,
    [IO.F_ACK]         = IO_MODE.DIGITAL_IN,
    [IO.R_SCRAM]       = IO_MODE.DIGITAL_IN,
    [IO.R_RESET]       = IO_MODE.DIGITAL_IN,
    [IO.R_ENABLE]      = IO_MODE.DIGITAL_IN,
    [IO.U_ACK]         = IO_MODE.DIGITAL_IN,
    [IO.F_ALARM]       = IO_MODE.DIGITAL_OUT,
    [IO.F_ALARM_ANY]   = IO_MODE.DIGITAL_OUT,
    [IO.F_CHARGE_LOW]  = IO_MODE.DIGITAL_OUT,
    [IO.F_CHARGE_HIGH] = IO_MODE.DIGITAL_OUT,
    [IO.F_WASTE_PU]    = IO_MODE.DIGITAL_OUT,
    [IO.F_WASTE_PO]    = IO_MODE.DIGITAL_OUT,
    [IO.F_WASTE_POPL]  = IO_MODE.DIGITAL_OUT,
    [IO.F_WASTE_AM]    = IO_MODE.DIGITAL_OUT,
    [IO.U_ALARM]       = IO_MODE.DIGITAL_OUT,
    [IO.U_EMER_COOL]   = IO_MODE.DIGITAL_OUT,
    [IO.U_AUX_COOL]    = IO_MODE.DIGITAL_OUT,
    [IO.U_WASTE_PU]    = IO_MODE.DIGITAL_OUT,
    [IO.U_WASTE_PO]    = IO_MODE.DIGITAL_OUT,
    [IO.U_WASTE_POPL]  = IO_MODE.DIGITAL_OUT,
    [IO.U_WASTE_AM]    = IO_MODE.DIGITAL_OUT,
    [IO.R_ACTIVE]      = IO_MODE.DIGITAL_OUT,
    [IO.R_AUTO_CTRL]   = IO_MODE.DIGITAL_OUT,
    [IO.R_SCRAMMED]    = IO_MODE.DIGITAL_OUT,
    [IO.R_AUTO_SCRAM]  = IO_MODE.DIGITAL_OUT,
    [IO.R_HIGH_DMG]    = IO_MODE.DIGITAL_OUT,
    [IO.R_HIGH_TEMP]   = IO_MODE.DIGITAL_OUT,
    [IO.R_LOW_COOLANT] = IO_MODE.DIGITAL_OUT,
    [IO.R_EXCESS_HC]   = IO_MODE.DIGITAL_OUT,
    [IO.R_EXCESS_WS]   = IO_MODE.DIGITAL_OUT,
    [IO.R_INSUFF_FUEL] = IO_MODE.DIGITAL_OUT,
    [IO.R_PLC_FAULT]   = IO_MODE.DIGITAL_OUT,
    [IO.R_PLC_TIMEOUT] = IO_MODE.DIGITAL_OUT,
    [IO.F_ENERGY_CHG]  = IO_MODE.ANALOG_OUT
}

assert(rsio.NUM_PORTS == #PORT_NAMES, "comprimento dos nomes de portas incorreto")
assert(rsio.NUM_PORTS == #MODES, "comprimento dos modos incorreto")

-- porta para string
---@nodiscard
---@param port IO_PORT
function rsio.to_string(port)
    if util.is_int(port) and port > 0 and port <= #PORT_NAMES then
        return PORT_NAMES[port]
    else return "UNKNOWN" end
end

local _B_AND = bit.band

local function _I_ACTIVE_HIGH(level) return level == IO_LVL.HIGH end
local function _I_ACTIVE_LOW(level) return level == IO_LVL.LOW end
local function _O_ACTIVE_HIGH(active) if active then return IO_LVL.HIGH else return IO_LVL.LOW end end
local function _O_ACTIVE_LOW(active) if active then return IO_LVL.LOW else return IO_LVL.HIGH end end

-- mapeamentos de E/S para função de E/S e modo de E/S
local RS_DIO_MAP = {
    [IO.F_SCRAM]       = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.IN  },
    [IO.F_ACK]         = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.IN  },

    [IO.R_SCRAM]       = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.IN  },
    [IO.R_RESET]       = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.IN  },
    [IO.R_ENABLE]      = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.IN  },

    [IO.U_ACK]         = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.IN  },

    [IO.F_ALARM]       = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.F_ALARM_ANY]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.F_CHARGE_LOW]  = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.F_CHARGE_HIGH] = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },

    [IO.F_WASTE_PU]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.F_WASTE_PO]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.F_WASTE_POPL]  = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.F_WASTE_AM]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },

    [IO.U_ALARM]       = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.U_EMER_COOL]   = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.U_AUX_COOL]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },

    [IO.U_WASTE_PU]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.U_WASTE_PO]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.U_WASTE_POPL]  = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },
    [IO.U_WASTE_AM]    = { _in = _I_ACTIVE_LOW,  _out = _O_ACTIVE_LOW,  mode = IO_DIR.OUT },

    [IO.R_ACTIVE]      = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_AUTO_CTRL]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_SCRAMMED]    = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_AUTO_SCRAM]  = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_HIGH_DMG]    = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_HIGH_TEMP]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_LOW_COOLANT] = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_EXCESS_HC]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_EXCESS_WS]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_INSUFF_FUEL] = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_PLC_FAULT]   = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT },
    [IO.R_PLC_TIMEOUT] = { _in = _I_ACTIVE_HIGH, _out = _O_ACTIVE_HIGH, mode = IO_DIR.OUT }
}

assert(rsio.NUM_DIG_PORTS == util.table_len(RS_DIO_MAP), "comprimento de RS_DIO_MAP incorreto")

-- obtém a direção de E/S de uma porta
---@nodiscard
---@param port IO_PORT
---@return IO_DIR
function rsio.get_io_dir(port)
    if rsio.is_valid_port(port) then
        return util.trinary(MODES[port] == IO_MODE.DIGITAL_OUT or MODES[port] == IO_MODE.ANALOG_OUT, IO_DIR.OUT, IO_DIR.IN)
    else return IO_DIR.IN end
end

-- obtém o modo de uma porta
---@nodiscard
---@param port IO_PORT
---@return IO_MODE
function rsio.get_io_mode(port)
    if rsio.is_valid_port(port) then return MODES[port]
    else return IO_MODE.ANALOG_IN end
end

--#endregion

--#region Generic Checks

---@type string[]
local RS_SIDES = rs.getSides()

-- verifica se uma porta é válida
---@nodiscard
---@param port IO_PORT
---@return boolean valid
function rsio.is_valid_port(port)
    return util.is_int(port) and port > 0 and port <= rsio.NUM_PORTS
end

-- verifica se um lado é válido
---@nodiscard
---@param side string
---@return boolean valid
function rsio.is_valid_side(side)
    if side ~= nil then
        for i = 0, #RS_SIDES do
            if RS_SIDES[i] == side then return true end
        end
    end

    return false
end

-- verifica se uma cor é uma cor única válida
---@nodiscard
---@param color any
---@return boolean valid
function rsio.is_color(color)
    return util.is_int(color) and (color > 0) and (_B_AND(color, (color - 1)) == 0)
end

-- cor para string
---@nodiscard
---@param color color
---@return string
function rsio.color_name(color)
    local color_name_map = { [colors.red] = "red", [colors.orange] = "orange", [colors.yellow] = "yellow", [colors.lime] = "lime", [colors.green] = "green", [colors.cyan] = "cyan", [colors.lightBlue] = "lightBlue", [colors.blue] = "blue", [colors.purple] = "purple", [colors.magenta] = "magenta", [colors.pink] = "pink", [colors.white] = "white", [colors.lightGray] = "lightGray", [colors.gray] = "gray", [colors.black] = "black", [colors.brown] = "brown" }

    if rsio.is_color(color) then
        return color_name_map[color]
    else return "unknown" end
end

--#endregion

--#region Digital I/O

-- verifica se uma porta é digital
---@nodiscard
---@param port IO_PORT
function rsio.is_digital(port)
    return rsio.is_valid_port(port) and (MODES[port] == IO_MODE.DIGITAL_IN or MODES[port] == IO_MODE.DIGITAL_OUT)
end

-- obtém a leitura de nível de E/S digital a partir de um valor de entrada booleano de redstone
---@nodiscard
---@param rs_value boolean raw value from redstone
---@return IO_LVL
function rsio.digital_read(rs_value)
    if rs_value then return IO_LVL.HIGH else return IO_LVL.LOW end
end

-- obtém o valor de saída booleano de redstone correspondente a um nível de E/S digital
---@nodiscard
---@param level IO_LVL logic level
---@return boolean
function rsio.digital_write(level) return level == IO_LVL.HIGH end

-- retorna o nível correspondente a ativo
---@nodiscard
---@param port IO_PORT port (to determine active high/low)
---@param active boolean state to convert to logic level
---@return IO_LVL|false
function rsio.digital_write_active(port, active)
    if not rsio.is_digital(port) then
        return false
    else
        return RS_DIO_MAP[port]._out(active)
    end
end

-- retorna true se o nível corresponder a ativo
---@nodiscard
---@param port IO_PORT port (to determine active low/high)
---@param level IO_LVL logic level
---@return boolean|nil state true for active, false for inactive, or nil if invalid port or level provided
function rsio.digital_is_active(port, level)
    if (not rsio.is_digital(port)) or level == IO_LVL.FLOATING or level == IO_LVL.DISCONNECT then
        return nil
    else
        return RS_DIO_MAP[port]._in(level)
    end
end

--#endregion

--#region Analog I/O

-- verifica se uma porta é analógica
---@nodiscard
---@param port IO_PORT
function rsio.is_analog(port)
    return rsio.is_valid_port(port) and (MODES[port] == IO_MODE.ANALOG_IN or MODES[port] == IO_MODE.ANALOG_OUT)
end

-- lê um valor analógico escalonado de min a max
---@nodiscard
---@param rs_value number redstone reading (0 to 15)
---@param min number minimum of range
---@param max number maximum of range
---@return number value scaled reading (min to max)
function rsio.analog_read(rs_value, min, max)
    local value = rs_value / 15
    return (value * (max - min)) + min
end

-- escreve um valor analógico a partir do intervalo de escala fornecido
---@nodiscard
---@param value number value to write (from min to max range)
---@param min number minimum of range
---@param max number maximum of range
---@return integer rs_value scaled redstone reading (0 to 15)
function rsio.analog_write(value, min, max)
    local scaled_value = (value - min) / (max - min)
    return math.floor(scaled_value * 15)
end

--#endregion

return rsio
