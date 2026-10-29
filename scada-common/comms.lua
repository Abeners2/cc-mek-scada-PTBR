--
-- Objetos de Comunicações de Rede SCADA
--

local log = require("scada-common.log")

-- apelidos básicos de aceleração

local type     = type
local insert   = table.insert

local TYPE_NUM = "number"
local TYPE_STR = "string"
local TYPE_TBL = "table"

-- configurações/atributos de comunicação

local COMPUTER_ID = os.getComputerID()

---@type number|nil maximum acceptable transmission distance
local max_distance = nil

---@class comms
local comms = {}

-- versões de protocolo/dados (alterações independentes de protocolo/dados são rastreadas pela versão do util.lua)
comms.version = "3.4.2"
comms.api_version = "0.1.6"

---@alias frame scada_frame|authd_frame
---@alias packet_container modbus_container|rplc_container|mgmt_container|crdn_container
---@alias packet modbus_adu|rplc_packet|mgmt_packet|crdn_packet

--#region Protocol Definitions

---@enum PROTOCOL
local PROTOCOL = {
    MODBUS_TCP = 0,      -- protocolo estilo "MODBUS TCP"
    RPLC = 1,            -- protocolo de PLC do reator
    SCADA_MGMT = 2,      -- gerenciamento de supervisor SCADA, anúncios de dispositivos, etc
    SCADA_CRDN = 3       -- pacotes de dados/controle para coordenadores de/para controladores supervisórios
}

---@enum RPLC_TYPE
local RPLC_TYPE = {
    STATUS = 0,          -- status do reator/sistema
    MEK_STRUCT = 1,      -- estrutura de construção do mekanism
    MEK_BURN_RATE = 2,   -- definir taxa de queima
    RPS_ENABLE = 3,      -- ativar reator
    RPS_DISABLE = 4,     -- desativar o reator
    RPS_SCRAM = 5,       -- SCRAM do reator (solicitação manual)
    RPS_ASCRAM = 6,      -- SCRAM do reator (solicitação automática)
    RPS_STATUS = 7,      -- status do RPS
    RPS_ALARM = 8,       -- transmissão de alarme do RPS
    RPS_RESET = 9,       -- limpar desarme do RPS (se estiver em estado ruim, desarmará imediatamente)
    RPS_AUTO_RESET = 10, -- limpar desarme do RPS se for apenas um tempo esgotado ou scram automático
    AUTO_BURN_RATE = 11  -- definir uma taxa de queima automática, o PLC responderá com status, velocidade de alternância de ativação limitada
}

---@enum MGMT_TYPE
local MGMT_TYPE = {
    -- conexão
    ESTABLISH = 0,       -- estabelecer nova conexão
    KEEP_ALIVE = 1,      -- pacote keep alive c/ RTT
    CLOSE = 2,           -- fechar uma conexão
    SWITCH_NET = 3,
    -- RTU
    RTU_ADVERT = 4,      -- anúncio de capacidade da RTU
    RTU_DEV_REMOUNT = 5, -- multibloco da RTU possivelmente alterado (formado, não formado) devido a remontagem do PPM
    RTU_TONE_ALARM = 6,  -- instruir RTUs a reproduzir tons de alarme especificados
    -- API
    DIAG_TONE_GET = 7,   -- diagnóstico - obter tons de alarme
    DIAG_TONE_SET = 8,   -- diagnóstico - definir tons de alarme
    DIAG_ALARM_SET = 9,  -- diagnóstico - definir alarme para simular áudio
    INFO_LIST_CMP = 10   -- info - listar todos os computadores na rede
}

---@enum CRDN_TYPE
local CRDN_TYPE = {
    INITIAL_BUILDS = 0,  -- pacote inicial e completo de construções para o coordenador
    PROCESS_READY = 1,   -- inicialização de processo concluída + último conjunto de informações para recuperação de inicialização do supervisor
    FAC_BUILDS = 2,      -- construções de RTU da instalação
    FAC_STATUS = 3,      -- estado da instalação e dispositivos da instalação
    FAC_CMD = 4,         -- comando da instalação
    UNIT_BUILDS = 5,     -- construção de cada unidade de reator (reator + RTUs)
    UNIT_STATUSES = 6,   -- estado de cada uma das unidades de reator
    UNIT_CMD = 7,        -- comandar uma unidade de reator
    API_GET_FAC = 8,     -- API: obter dados gerais da instalação
    API_GET_FAC_DTL = 9, -- API: obter dados (detalhados) para o aplicativo da instalação
    API_GET_UNIT = 10,   -- API: obter dados da unidade de reator
    API_GET_BUILD = 11,  -- API: obter dados para o aplicativo de construção
    API_GET_CTRL = 12,   -- API: obter dados para o aplicativo de controle
    API_GET_PROC = 13,   -- API: obter dados para o aplicativo de processo
    API_GET_WASTE = 14,  -- API: obter dados para o aplicativo de resíduos
    API_GET_RAD = 15     -- API: obter dados para o aplicativo de monitor de radiação
}

---@enum ESTABLISH_ACK
local ESTABLISH_ACK = {
    ALLOW = 0,           -- link aprovado
    DENY = 1,            -- link negado
    COLLISION = 2,       -- link negado devido a link ativo existente
    BAD_VERSION = 3,     -- link negado devido a incompatibilidade de versão de comunicação
    BAD_API_VERSION = 4  -- link negado devido a incompatibilidade de versão da API
}

---@enum DEVICE_TYPE device types for establish messages
local DEVICE_TYPE = { PLC = 0, RTU = 1, SVR = 2, CRD = 3, PKT = 4 }

---@enum PLC_AUTO_ACK
local PLC_AUTO_ACK = {
    FAIL = 0,            -- falha ao definir taxa de queima/taxa de queima inválida
    DIRECT_SET_OK = 1,   -- taxa de queima definida com sucesso
    RAMP_SET_OK = 2,     -- rampa de taxa de queima iniciada com sucesso
    ZERO_DIS_OK = 3      -- reator desativado com sucesso com taxa de queima < 0.01
}

---@enum FAC_COMMAND
local FAC_COMMAND = {
    SCRAM_ALL = 0,       -- SCRAM em todos os reatores
    STOP = 1,            -- parar controle automático de processo
    START = 2,           -- iniciar controle automático de processo
    ACK_ALL_ALARMS = 3,  -- reconhecer todos os alarmes em todas as unidades
    SET_WASTE_MODE = 4,  -- definir modo automático de processamento de resíduos
    SET_PU_FB = 5,       -- definir modo de retorno (fallback) para plutônio
    SET_SPS_LP = 6       -- definir SPS em modo de baixa energia
}

---@enum UNIT_COMMAND
local UNIT_COMMAND = {
    SCRAM = 0,           -- SCRAM no reator
    START = 1,           -- iniciar o reator
    RESET_RPS = 2,       -- redefinir o RPS
    SET_BURN = 3,        -- definir a taxa de queima
    SET_WASTE = 4,       -- definir o modo de processamento de resíduos
    ACK_ALL_ALARMS = 5,  -- reconhecer todos os alarmes ativos
    ACK_ALARM = 6,       -- reconhecer um alarme específico
    RESET_ALARM = 7,     -- redefinir um alarme específico
    SET_GROUP = 8        -- atribuir esta unidade a um grupo
}

comms.PROTOCOL = PROTOCOL

comms.RPLC_TYPE = RPLC_TYPE
comms.MGMT_TYPE = MGMT_TYPE
comms.CRDN_TYPE = CRDN_TYPE

comms.ESTABLISH_ACK = ESTABLISH_ACK
comms.DEVICE_TYPE = DEVICE_TYPE

comms.PLC_AUTO_ACK = PLC_AUTO_ACK

comms.UNIT_COMMAND = UNIT_COMMAND
comms.FAC_COMMAND = FAC_COMMAND

--#endregion

-- endereço de transmissão de destino (para todos os dispositivos)
comms.BROADCAST = -1

-- versão de firmware usada para indicar que um pacote de estabelecimento é um teste de conexão
comms.CONN_TEST_FWV = "CONN_TEST"

-- configura a distância máxima permitida para recebimento de mensagens<br>
-- pacotes recebidos com distâncias maiores que esta serão descartados silenciosamente
---@param distance integer max modem message distance (0 disables the limit)
function comms.set_trusted_range(distance)
    if distance == 0 then max_distance = nil else max_distance = distance end
end

--#region Network Frames (Layer 2)

-- quadro de descoberta da camada de enlace SCADA
---@nodiscard
function comms.lld_frame()
    local self = {
        modem_frame = nil, ---@type modem_frame|nil

        valid = false,

        raw = {},

        src_addr  = nil, ---@type integer|nil
        dest_addr = nil, ---@type integer|nil
        ack       = false
    }

    ---@class lld_frame
    local public = {}

    -- cria um quadro de descoberta da camada de enlace
    ---@param dest_addr integer destination computer address (ID)
    ---@param ack boolean if this is an acknowledgement
    function public.make(dest_addr, ack)
        self.valid = true

        self.src_addr  = COMPUTER_ID
        self.dest_addr = dest_addr
        self.ack       = ack

        self.raw = { COMPUTER_ID, dest_addr, ack }
    end

    -- analisa os campos do quadro do modem como um quadro de descoberta da camada de enlace
    ---@param side string modem side
    ---@param sender integer sender channel
    ---@param reply_to integer reply channel
    ---@param message any message body
    ---@param distance integer transmission distance
    ---@return boolean valid valid frame received
    function public.receive(side, sender, reply_to, message, distance)
        ---@class modem_frame
        self.modem_frame = {
            iface = side, s_chan = sender, r_chan = reply_to, dist = distance, data = message
        }

        self.valid = false
        self.raw   = self.modem_frame.data

        if (type(max_distance) == TYPE_NUM) and (type(distance) == TYPE_NUM) and (distance > max_distance) then
            -- fora da distância máxima de transmissão permitida
            -- log.debug("COMMS: lld_frame.receive(): descartando quadro com distancia " .. distance .. " (fora do alcance confiavel)")
        elseif type(self.raw) == TYPE_TBL then
            self.src_addr  = self.raw[1]
            self.dest_addr = self.raw[2]
            self.ack       = self.raw[3] == true

            -- verifica se este quadro é destinado a este dispositivo, caso contrário descarta o mais rápido possível
            if (self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST) then
                self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM
            end
        end

        return self.valid
    end

    -- acessores públicos --

    ---@nodiscard
    function public.modem_event() return self.modem_frame end
    ---@nodiscard
    function public.raw_frame() return self.raw end

    ---@nodiscard
    function public.interface() return self.modem_frame.iface end
    ---@nodiscard
    function public.local_channel() return self.modem_frame.s_chan end
    ---@nodiscard
    function public.remote_channel() return self.modem_frame.r_chan end

    ---@nodiscard
    function public.is_valid() return self.valid end

    ---@nodiscard
    function public.src_addr() return self.src_addr or comms.BROADCAST end
    ---@nodiscard
    function public.dest_addr() return self.dest_addr or comms.BROADCAST end
    ---@nodiscard
    function public.is_ack() return self.ack end

    return public
end

-- quadro de rede SCADA
---@nodiscard
function comms.scada_frame()
    local self = {
        modem_frame = nil, ---@type modem_frame|nil

        valid         = false,
        authenticated = false,

        raw = {},

        src_addr  = nil, ---@type integer|nil
        dest_addr = nil, ---@type integer|nil
        seq_num   = nil, ---@type integer|nil
        protocol  = nil, ---@type PROTOCOL|nil
        length    = 0,
        payload   = {}
    }

    ---@class scada_frame
    local public = {}

    -- cria um quadro SCADA
    ---@param dest_addr integer destination computer address (ID)
    ---@param seq_num integer sequence number
    ---@param protocol PROTOCOL
    ---@param payload table
    function public.make(dest_addr, seq_num, protocol, payload)
        self.valid = true

        self.src_addr  = COMPUTER_ID
        self.dest_addr = dest_addr
        self.seq_num   = seq_num
        self.protocol  = protocol
        self.length    = #payload
        self.payload   = payload

        self.raw = { COMPUTER_ID, dest_addr, seq_num, protocol, payload }
    end

    -- analisa os campos do quadro do modem como um quadro SCADA
    ---@param side string modem side
    ---@param sender integer sender channel
    ---@param reply_to integer reply channel
    ---@param message any message body
    ---@param distance integer transmission distance
    ---@return boolean valid valid frame received
    function public.receive(side, sender, reply_to, message, distance)
        ---@class modem_frame
        self.modem_frame = {
            iface = side, s_chan = sender, r_chan = reply_to, dist = distance, data = message
        }

        self.valid = false
        self.raw   = self.modem_frame.data

        if (type(max_distance) == TYPE_NUM) and (type(distance) == TYPE_NUM) and (distance > max_distance) then
            -- fora da distância máxima de transmissão permitida
            -- log.debug("COMMS: scada_frame.receive(): descartando quadro com distancia " .. distance .. " (fora do alcance confiavel)")
        elseif type(self.raw) == TYPE_TBL then
            self.src_addr  = self.raw[1]
            self.dest_addr = self.raw[2]

            -- verifica se este quadro é destinado a este dispositivo, caso contrário descarta o mais rápido possível
            -- se for, verifica se a carga útil (payload) é uma tabela e continua
            if ((self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST)) and (type(self.raw[5]) == TYPE_TBL) then
                self.seq_num  = self.raw[3]
                self.protocol = self.raw[4]
                self.length   = #self.raw[5]
                self.payload  = self.raw[5]

                self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM and
                             type(self.seq_num) == TYPE_NUM and type(self.protocol) == TYPE_NUM
            end
        end

        return self.valid
    end

    -- reporta que este pacote foi autenticado (foi recebido com um HMAC válido)
    function public.stamp_authenticated() self.authenticated = true end

    -- acessores públicos --

    ---@nodiscard
    function public.modem_event() return self.modem_frame end
    ---@nodiscard
    function public.raw_header() return { self.src_addr, self.dest_addr, self.seq_num, self.protocol } end
    ---@nodiscard
    function public.raw_frame() return self.raw end

    ---@nodiscard
    function public.interface() return self.modem_frame.iface end
    ---@nodiscard
    function public.local_channel() return self.modem_frame.s_chan end
    ---@nodiscard
    function public.remote_channel() return self.modem_frame.r_chan end

    ---@nodiscard
    function public.is_valid() return self.valid end
    ---@nodiscard
    function public.is_authenticated() return self.authenticated end

    ---@nodiscard
    function public.src_addr() return self.src_addr or comms.BROADCAST end
    ---@nodiscard
    function public.dest_addr() return self.dest_addr or comms.BROADCAST end
    ---@nodiscard
    function public.seq_num() return self.seq_num or -1 end
    ---@nodiscard
    function public.protocol() return self.protocol or PROTOCOL.SCADA_MGMT end
    ---@nodiscard
    function public.length() return self.length or 0 end
    ---@nodiscard
    function public.data() return self.payload or {} end

    return public
end

-- quadro SCADA autenticado
---@nodiscard
function comms.authd_frame()
    local self = {
        modem_frame = nil, ---@type modem_frame|nil

        valid = false,

        raw = {},

        src_addr  = nil, ---@type integer|nil
        dest_addr = nil, ---@type integer|nil
        mac       = "",
        payload   = {}
    }

    ---@class authd_frame
    local public = {}

    -- cria um quadro SCADA autenticado
    ---@param s_frame scada_frame scada frame to authenticate
    ---@param mac function message authentication hash function
    function public.make(s_frame, mac)
        self.valid = true

        self.src_addr  = s_frame.src_addr()
        self.dest_addr = s_frame.dest_addr()
        self.mac       = mac(textutils.serialize(s_frame.raw_header(), { allow_repetitions = true, compact = true }))

        self.raw = { self.src_addr, self.dest_addr, self.mac, s_frame.raw_frame() }
    end

    -- analisa os campos do quadro do modem como um quadro SCADA autenticado
    ---@param side string modem side
    ---@param sender integer sender channel
    ---@param reply_to integer reply channel
    ---@param message any message body
    ---@param distance integer transmission distance
    ---@return boolean valid valid frame received
    function public.receive(side, sender, reply_to, message, distance)
        ---@class modem_frame
        self.modem_frame = {
            iface = side, s_chan = sender, r_chan = reply_to, data = message, dist = distance
        }

        self.valid = false
        self.raw   = self.modem_frame.data

        if (type(max_distance) == TYPE_NUM) and ((type(distance) ~= TYPE_NUM) or (distance > max_distance)) then
            -- fora da distância máxima de transmissão permitida
            -- log.debug("COMMS: authd_frame.receive(): descartando quadro com distancia " .. distance .. " (fora do alcance confiavel)")
        elseif type(self.raw) == TYPE_TBL then
            self.src_addr  = self.raw[1]
            self.dest_addr = self.raw[2]

            -- verifica se este pacote é destinado a este dispositivo, caso contrário descarta o mais rápido possível
            if (self.dest_addr == COMPUTER_ID) or (self.dest_addr == comms.BROADCAST) then
                self.mac     = self.raw[3]
                self.payload = self.raw[4]

                self.valid = type(self.src_addr) == TYPE_NUM and type(self.dest_addr) == TYPE_NUM and
                             type(self.mac) == TYPE_STR and type(self.payload) == TYPE_TBL
            end
        end

        return self.valid
    end

    -- acessores públicos --

    ---@nodiscard
    function public.modem_event() return self.modem_frame end
    ---@nodiscard
    function public.raw_frame() return self.raw end

    ---@nodiscard
    function public.local_channel() return self.modem_frame.s_chan end
    ---@nodiscard
    function public.remote_channel() return self.modem_frame.r_chan end

    ---@nodiscard
    function public.is_valid() return self.valid end

    ---@nodiscard
    function public.src_addr() return self.src_addr or comms.BROADCAST end
    ---@nodiscard
    function public.dest_addr() return self.dest_addr or comms.BROADCAST end
    ---@nodiscard
    function public.mac() return self.mac or "" end
    ---@nodiscard
    function public.data() return self.payload or {} end

    return public
end

--#endregion

--#region Network Packets (Layer 3)

-- contêiner de pacote MODBUS, modelado a partir do MODBUS TCP
---@nodiscard
function comms.modbus_container()
    local self = {
        frame = nil,      ---@type scada_frame

        raw = {},

        txn_id    = -1,
        length    = 0,
        unit_id   = -1,
        func_code = 0x80, ---@type MODBUS_FCODE
        data      = {}
    }

    ---@class modbus_container
    local public = {}

    -- cria um pacote MODBUS
    ---@param txn_id integer
    ---@param unit_id integer
    ---@param func_code MODBUS_FCODE
    ---@param data table
    ---@return boolean success
    function public.make(txn_id, unit_id, func_code, data)
        if type(data) == TYPE_TBL then
            self.txn_id    = txn_id
            self.length    = #data
            self.unit_id   = unit_id
            self.func_code = func_code
            self.data      = data

            -- preenche o array bruto
            self.raw = { self.txn_id, self.unit_id, self.func_code }
            for i = 1, self.length do insert(self.raw, data[i]) end

            return true
        end

        log.error("COMMS: [modbus_make] dados nao sao uma tabela")
        return false
    end

    -- decodifica um pacote MODBUS a partir de um quadro SCADA
    ---@param frame scada_frame
    ---@return modbus_adu|nil packet the decoded packet, if valid
    function public.decode(frame)
        if frame then
            local data = frame.data()

            self.frame = frame
            self.raw   = data

            if frame.protocol() == PROTOCOL.MODBUS_TCP then
                self.txn_id    = data[1]
                self.unit_id   = data[2]
                self.func_code = data[3]
                self.data      = { table.unpack(data, 4, #data) }
                self.length    = #self.data

                if type(self.txn_id) == TYPE_NUM and type(self.unit_id) == TYPE_NUM and type(self.func_code) == TYPE_NUM then
                    return public.get()
                end
            else log.debug("COMMS: [modbus_decode] tentativa de analise de protocolo incorreto " .. frame.protocol(), true) end
        else log.debug("COMMS: [modbus_decode] descartando quadro nil", true) end

        return nil
    end

    -- obtém a tabela de pacote bruto para transmissão
    ---@nodiscard
    function public.raw_packet() return self.raw end

    -- cria um novo pacote (ADU) a partir do conteúdo deste contêiner
    ---@nodiscard
    function public.get()
        ---@class modbus_adu
        local adu = {
            scada_frame = self.frame,
            txn_id = self.txn_id,
            length = self.length,
            unit_id = self.unit_id,
            func_code = self.func_code,
            data = self.data
        }

        return adu
    end

    return public
end

-- contêiner de pacote do PLC do reator
---@nodiscard
function comms.rplc_container()
    local self = {
        frame = nil, ---@type scada_frame

        raw   = {},

        id     = 0,
        type   = 0,  ---@type RPLC_TYPE
        length = 0,
        data   = {}
    }

    ---@class rplc_container
    local public = {}

    -- cria um pacote RPLC
    ---@param id integer
    ---@param packet_type RPLC_TYPE
    ---@param data table
    ---@return boolean success
    function public.make(id, packet_type, data)
        if type(data) == TYPE_TBL then
            -- propriedades acessoras do pacote
            self.id     = id
            self.type   = packet_type
            self.length = #data
            self.data   = data

            -- preenche o array bruto
            self.raw = { self.id, self.type }
            for i = 1, #data do insert(self.raw, data[i]) end

            return true
        end

        log.error("COMMS: [rplc_make] dados nao sao uma tabela")
        return false
    end

    -- decodifica um pacote RPLC a partir de um quadro SCADA
    ---@param frame scada_frame
    ---@return rplc_packet|nil packet the decoded packet, if valid
    function public.decode(frame)
        if frame then
            local data = frame.data()

            self.frame = frame
            self.raw   = data

            if frame.protocol() == PROTOCOL.RPLC then
                self.id     = data[1]
                self.type   = data[2]
                self.data   = { table.unpack(data, 3, #data) }
                self.length = #self.data

                if type(self.id) == TYPE_NUM and type(self.type) == TYPE_NUM then
                    return public.get()
                end
            else log.debug("COMMS: [rplc_decode] tentativa de analise de protocolo incorreto " .. frame.protocol(), true) end
        else log.debug("COMMS: [rplc_decode] quadro nil encontrado", true) end

        return nil
    end

    -- obtém a tabela de pacote bruto para transmissão
    ---@nodiscard
    function public.raw_packet() return self.raw end

    -- cria um novo pacote a partir do conteúdo deste contêiner
    ---@nodiscard
    function public.get()
        ---@class rplc_packet
        local packet = {
            scada_frame = self.frame,
            id = self.id,
            type = self.type,
            length = self.length,
            data = self.data
        }

        return packet
    end

    return public
end

-- contêiner de pacote de gerenciamento SCADA
---@nodiscard
function comms.mgmt_container()
    local self = {
        frame = nil, ---@type scada_frame

        raw = {},

        type   = 0,  ---@type MGMT_TYPE
        length = 0,
        data   = {}
    }

    ---@class mgmt_container
    local public = {}

    -- cria um pacote de gerenciamento SCADA
    ---@param packet_type MGMT_TYPE
    ---@param data table
    ---@return boolean success
    function public.make(packet_type, data)
        if type(data) == TYPE_TBL then
            -- propriedades acessoras do pacote
            self.type   = packet_type
            self.length = #data
            self.data   = data

            -- preenche o array bruto
            self.raw = { self.type }
            for i = 1, #data do insert(self.raw, data[i]) end

            return true
        end

        log.error("COMMS: [mgmt_make] dados nao sao uma tabela")
        return false
    end

    -- decodifica um pacote de gerenciamento SCADA a partir de um quadro SCADA
    ---@param frame scada_frame
    ---@return mgmt_packet|nil packet the decoded packet, if valid
    function public.decode(frame)
        if frame then
            local data = frame.data()

            self.frame = frame
            self.raw   = data

            if frame.protocol() == PROTOCOL.SCADA_MGMT then
                self.type   = data[1]
                self.data   = { table.unpack(data, 2, #data) }
                self.length = #self.data

                if type(self.type) == TYPE_NUM then
                    return public.get()
                end
            else log.debug("COMMS: [mgmt_decode] tentativa de analise de protocolo incorreto " .. frame.protocol(), true) end
        else log.debug("COMMS: [mgmt_decode] quadro nil encontrado", true) end

        return nil
    end

    -- obtém a tabela de pacote bruto para transmissão
    ---@nodiscard
    function public.raw_packet() return self.raw end

    -- cria um novo pacote a partir do conteúdo deste contêiner
    ---@nodiscard
    function public.get()
        ---@class mgmt_packet
        local packet = {
            scada_frame = self.frame,
            type = self.type,
            length = self.length,
            data = self.data
        }

        return packet
    end

    return public
end

-- contêiner de pacote de coordenador SCADA
---@nodiscard
function comms.crdn_container()
    local self = {
        frame = nil, ---@type scada_frame

        raw = {},

        type   = 0,  ---@type CRDN_TYPE
        length = 0,
        data   = {}
    }

    ---@class crdn_container
    local public = {}

    -- cria um pacote de coordenador
    ---@param packet_type CRDN_TYPE
    ---@param data table
    ---@return boolean success
    function public.make(packet_type, data)
        if type(data) == TYPE_TBL then
            -- propriedades acessoras do pacote
            self.type   = packet_type
            self.length = #data
            self.data   = data

            -- preenche o array bruto
            self.raw = { self.type }
            for i = 1, #data do insert(self.raw, data[i]) end

            return true
        end

        log.error("COMMS: [crdn_make] dados nao sao uma tabela")
        return false
    end

    -- decodifica um pacote de coordenador a partir de um quadro SCADA
    ---@param frame scada_frame
    ---@return crdn_packet|nil packet the decoded packet, if valid
    function public.decode(frame)
        if frame then
            local data = frame.data()

            self.frame = frame
            self.raw   = data

            if frame.protocol() == PROTOCOL.SCADA_CRDN then
                self.type   = data[1]
                self.data   = { table.unpack(data, 2, #data) }
                self.length = #self.data

                if type(self.type) == TYPE_NUM then
                    return public.get()
                end
            else log.debug("COMMS: [crdn_decode] tentativa de analise de protocolo incorreto " .. frame.protocol(), true) end
        else log.debug("COMMS: [crdn_decode] quadro nil encontrado", true) end

        return nil
    end

    -- obtém a tabela de pacote bruto para transmissão
    ---@nodiscard
    function public.raw_packet() return self.raw end

    -- cria um novo pacote a partir do conteúdo deste contêiner
    ---@nodiscard
    function public.get()
        ---@class crdn_packet
        local packet = {
            scada_frame = self.frame,
            type = self.type,
            length = self.length,
            data = self.data
        }

        return packet
    end

    return public
end

--#endregion

return comms
