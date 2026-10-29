local log          = require("scada-common.log")
local mqueue       = require("scada-common.mqueue")
local ppm          = require("scada-common.ppm")
local rsio         = require("scada-common.rsio")
local types        = require("scada-common.types")
local util         = require("scada-common.util")

local databus      = require("rtu.databus")
local modbus       = require("rtu.modbus")
local rtu          = require("rtu.rtu")
local threads      = require("rtu.threads")

local boilerv_rtu  = require("rtu.dev.boilerv_rtu")
local dynamicv_rtu = require("rtu.dev.dynamicv_rtu")
local ecore_rtu    = require("rtu.dev.ecore_rtu")
local envd_rtu     = require("rtu.dev.envd_rtu")
local imatrix_rtu  = require("rtu.dev.imatrix_rtu")
local redstone_rtu = require("rtu.dev.redstone_rtu")
local sna_rtu      = require("rtu.dev.sna_rtu")
local sps_rtu      = require("rtu.dev.sps_rtu")
local turbinev_rtu = require("rtu.dev.turbinev_rtu")

local println = util.println
local println_ts = util.println_ts

local RTU_UNIT_TYPE = types.RTU_UNIT_TYPE
local RTU_HW_STATE = databus.RTU_HW_STATE

-- imprimir e registrar um erro fatal durante a inicialização
---@param msg string
local function log_fail(msg)
    println(msg)
    log.fatal(msg)
end

-- obter uma representação em string de uma interface de porta
---@param entry rtu_rs_definition
---@return string
local function entry_iface_name(entry)
    return util.trinary(entry.color ~= nil, util.c(entry.side, "/", rsio.color_name(entry.color)), entry.side)
end

-- configurar gateway RTU com base nas definições do arquivo de configurações
---@param config rtu_config
---@param __shared_memory rtu_shared_memory
---@return boolean success
return function(config, __shared_memory)
    local units = __shared_memory.rtu_sys.units

    local rtu_redstone = config.Redstone
    local rtu_devices = config.Peripherals

    --#region Interfaces de Redstone

    local rs_rtus   = {} ---@type { name: string, hw_state: RTU_HW_STATE, rtu: rtu_rs_device, phy: table, banks: rtu_rs_definition[][] }[]
    local all_conns = { [0] = {}, {}, {}, {}, {} }

    -- percorrer a lista de definições de redstone
    for entry_idx = 1, #rtu_redstone do
        local entry = rtu_redstone[entry_idx]

        local assignment
        local for_reactor = entry.unit
        local phy         = entry.relay or 0
        local phy_name    = entry.relay or "local"
        local iface_name  = entry_iface_name(entry)

        if util.is_int(entry.unit) and entry.unit > 0 and entry.unit < 5 then
            ---@cast for_reactor integer
            assignment = "unidade de reator " .. entry.unit
        elseif entry.unit == nil then
            assignment = "instalação"
            for_reactor = 0
        else
            log_fail(util.c("uinit> atribuição de unidade inválida no índice de bloco #", entry_idx))
            return false
        end

        -- criar a RTU apropriada se não existir e verificar a validade do nome do relé
        if entry.relay then
            if type(entry.relay) ~= "string" then
                log_fail(util.c("uinit> relé de redstone inválido '", entry.relay, '"'))
                return false
            elseif not rs_rtus[entry.relay] then
                log.debug(util.c("uinit> RTU de redstone de relé alocada na interface ", entry.relay))

                local hw_state = RTU_HW_STATE.OK
                local relay    = ppm.get_periph(entry.relay)

                if not relay then
                    hw_state = RTU_HW_STATE.OFFLINE
                    log.warning(util.c("uinit> relé de redstone ", entry.relay, " não está conectado"))
                    local _, v_device = ppm.mount_virtual()
                    relay = v_device
                elseif ppm.get_type(entry.relay) ~= "redstone_relay" then
                    hw_state = RTU_HW_STATE.FAULTED
                    log.warning(util.c("uinit> relé de redstone ", entry.relay, " não é um relé de redstone"))
                end

                rs_rtus[entry.relay] = { name = entry.relay, hw_state = hw_state, rtu = redstone_rtu.new(relay), phy = relay, banks = { [0] = {}, {}, {}, {}, {} } }
            end
        elseif rs_rtus[0] == nil then
            log.debug(util.c("uinit> RTU de redstone local alocada"))
            rs_rtus[0] = { name = "redstone_local", hw_state = RTU_HW_STATE.OK, rtu = redstone_rtu.new(), phy = rs, banks = { [0] = {}, {}, {}, {}, {} } }
        end

        -- verificar configuração
        local valid = false
        if rsio.is_valid_port(entry.port) and rsio.is_valid_side(entry.side) then
            valid = util.trinary(entry.color == nil, true, rsio.is_color(entry.color))
        end

        local bank  = rs_rtus[phy].banks[for_reactor]
        local conns = all_conns[for_reactor]

        if not valid then
            log_fail(util.c("uinit> definição de redstone inválida no índice de bloco #", entry_idx))
            return false
        else
            -- vincular redstone na RTU
            local mode = rsio.get_io_mode(entry.port)
            if mode == rsio.IO_MODE.DIGITAL_IN then
                -- não pode ter entradas duplicadas
                if util.table_contains(conns, entry.port) then
                    local message = util.c("uinit> ignorando entrada duplicada para a porta ", rsio.to_string(entry.port), " no lado ", iface_name, " @ ", phy_name)
                    println(message)
                    log.warning(message)
                else
                    table.insert(bank, entry)
                end
            elseif mode == rsio.IO_MODE.ANALOG_IN then
                -- não pode ter entradas duplicadas
                if util.table_contains(conns, entry.port) then
                    local message = util.c("uinit> ignorando entrada duplicada para a porta ", rsio.to_string(entry.port), " no lado ", iface_name, " @ ", phy_name)
                    println(message)
                    log.warning(message)
                else
                    table.insert(bank, entry)
                end
            elseif (mode == rsio.IO_MODE.DIGITAL_OUT) or (mode == rsio.IO_MODE.ANALOG_OUT) then
                table.insert(bank, entry)
            else
                -- deve ser código inalcançável, já validamos as portas
                log.fatal("uinit> falha ao identificar o modo de E/S no índice de bloco #" .. entry_idx)
                println("uinit> encontrado um erro de software, verifique os logs")
                return false
            end

            table.insert(conns, entry.port)

            log.debug(util.c("uinit> redstone agrupada ", #conns, ": ", rsio.to_string(entry.port), " (", iface_name, " @ ", phy_name, ") para ", assignment))
        end
    end

    -- criar entradas de unidade para RTUs de redstone
    for _, def in pairs(rs_rtus) do
        local rtu_conns = { [0] = {}, {}, {}, {}, {} }

        -- conectar os bancos de E/S
        for for_reactor = 0, #def.banks do
            local bank   = def.banks[for_reactor]
            local conns  = rtu_conns[for_reactor]
            local assign = util.trinary(for_reactor > 0, "unidade de reator " .. for_reactor, "a instalação")

            -- vincular redstone à RTU
            for i = 1, #bank do
                local conn     = bank[i]
                local phy_name = conn.relay or "local"

                local mode = rsio.get_io_mode(conn.port)
                if mode == rsio.IO_MODE.DIGITAL_IN then
                    def.rtu.link_di(conn.side, conn.color, conn.invert)
                elseif mode == rsio.IO_MODE.DIGITAL_OUT then
                    def.rtu.link_do(conn.side, conn.color, conn.invert)
                elseif mode == rsio.IO_MODE.ANALOG_IN then
                    def.rtu.link_ai(conn.side)
                elseif mode == rsio.IO_MODE.ANALOG_OUT then
                    def.rtu.link_ao(conn.side)
                else
                    log.fatal(util.c("uinit> falha ao identificar o modo de E/S de ", rsio.to_string(conn.port), " (", entry_iface_name(conn), " @ ", phy_name, ") para ", assign))
                    println("uinit> encontrado um erro de software, verifique os logs")
                    return false
                end

                table.insert(conns, conn.port)

                log.debug(util.c("uinit> redstone vinculada ", for_reactor, ".", #conns, ": ", rsio.to_string(conn.port), " (", entry_iface_name(conn), ")", " @ ", phy_name, ") para ", assign))
            end
        end

        ---@type rtu_registry_entry
        local unit = {
            uid = 0,
            name = def.name,
            type = RTU_UNIT_TYPE.REDSTONE,
            index = false,
            reactor = nil,
            device = def.phy,
            rs_conns = rtu_conns,
            is_multiblock = false,
            formed = nil,
            hw_state = def.hw_state,
            rtu = def.rtu,
            modbus_io = modbus.new(def.rtu, false),
            pkt_queue = nil,
            thread = nil
        }

        table.insert(units, unit)

        local type = util.trinary(def.phy == rs, "redstone", "redstone_relay")

        log.info(util.c("uinit> unidade RTU inicializada #", #units, ": ", unit.name, " (", type, ")"))

        unit.uid = #units

        databus.tx_unit_hw_status(unit.uid, unit.hw_state)
    end

    --#endregion
    --#region Periféricos Montados

    for i = 1, #rtu_devices do
        local entry = rtu_devices[i]   ---@type rtu_peri_definition
        local name = entry.name
        local index = entry.index
        local for_reactor = util.trinary(entry.unit == nil, 0, entry.unit)

        -- VERIFICAR: nome é uma string
        if type(name) ~= "string" then
            log_fail(util.c("uinit> entrada de dispositivo #", i, ": dispositivo ", name, " não é uma string"))
            return false
        end

        -- VERIFICAR: tipo do índice
        if (index ~= nil) and (not util.is_int(index)) then
            log_fail(util.c("uinit> entrada de dispositivo #", i, ": índice ", index, " não é válido"))
            return false
        end

        -- VERIFICAR: intervalo do índice
        local function validate_index(min, max)
            if (not util.is_int(index)) or ((index < min) and (max ~= nil and index > max)) then
                local message = util.c("uinit> entrada de dispositivo #", i, ": índice ", index, " não é >= ", min)
                if max ~= nil then message = util.c(message, " e <= ", max) end
                log_fail(message)
                return false
            else return true end
        end

        -- VERIFICAR: reator é um inteiro >= 0
        local function validate_assign(for_facility)
            if for_facility and for_reactor ~= 0 then
                log_fail(util.c("uinit> entrada de dispositivo #", i, ": deve ser apenas para a instalação"))
                return false
            elseif (not for_facility) and ((not util.is_int(for_reactor)) or (for_reactor < 1) or (for_reactor > 4)) then
                log_fail(util.c("uinit> entrada de dispositivo #", i, ": atribuição de unidade ", for_reactor, " não é válida"))
                return false
            else return true end
        end

        local device = ppm.get_periph(name)

        local type                  ---@type string|nil
        local rtu_iface             ---@type rtu_device
        local rtu_type              ---@type RTU_UNIT_TYPE
        local is_multiblock = false ---@type boolean
        local formed = nil          ---@type boolean|nil
        local faulted = nil         ---@type boolean|nil

        if device == nil then
            local message = util.c("uinit> '", name, "' não encontrado, usando espaço reservado")
            println(message)
            log.warning(message)

            -- montar um dispositivo virtual (espaço reservado)
            type, device = ppm.mount_virtual()
        else
            type = ppm.get_type(name)
        end

        if type == "boilerValve" then
            -- multibloco de caldeira
            if not validate_index(1, 2) then return false end
            if not validate_assign() then return false end

            rtu_type = RTU_UNIT_TYPE.BOILER_VALVE
            rtu_iface, faulted = boilerv_rtu.new(device)
            is_multiblock = true
            formed = device.isFormed()

            if formed == ppm.ACCESS_FAULT then
                println_ts(util.c("uinit> falha ao verificar se '", name, "' está formado"))
                log.warning(util.c("uinit> falha ao verificar se '", name, "' é um multibloco de caldeira formado"))
            end
        elseif type == "turbineValve" then
            -- multibloco de turbina
            if not validate_index(1, 3) then return false end
            if not validate_assign() then return false end

            rtu_type = RTU_UNIT_TYPE.TURBINE_VALVE
            rtu_iface, faulted = turbinev_rtu.new(device)
            is_multiblock = true
            formed = device.isFormed()

            if formed == ppm.ACCESS_FAULT then
                println_ts(util.c("uinit> falha ao verificar se '", name, "' está formado"))
                log.warning(util.c("uinit> falha ao verificar se '", name, "' é um multibloco de turbina formado"))
            end
        elseif type == "dynamicValve" then
            -- multibloco de tanque dinâmico
            if entry.unit == nil then
                if not validate_index(1, 4) then return false end
                if not validate_assign(true) then return false end
            else
                if not validate_index(1, 1) then return false end
                if not validate_assign() then return false end
            end

            rtu_type = RTU_UNIT_TYPE.DYNAMIC_VALVE
            rtu_iface, faulted = dynamicv_rtu.new(device)
            is_multiblock = true
            formed = device.isFormed()

            if formed == ppm.ACCESS_FAULT then
                println_ts(util.c("uinit> falha ao verificar se '", name, "' está formado"))
                log.warning(util.c("uinit> falha ao verificar se '", name, "' é um multibloco de tanque dinâmico formado"))
            end
        elseif type == "inductionPort" or type == "reinforcedInductionPort" then
            -- multibloco de matriz de indução (normal ou reforçada)
            if not validate_assign(true) then return false end

            rtu_type = RTU_UNIT_TYPE.IMATRIX
            rtu_iface, faulted = imatrix_rtu.new(device)
            is_multiblock = true
            formed = device.isFormed()

            if formed == ppm.ACCESS_FAULT then
                println_ts(util.c("uinit> falha ao verificar se '", name, "' está formado"))
                log.warning(util.c("uinit> falha ao verificar se '", name, "' é um multibloco de matriz de indução formado"))
            end
        elseif type == "spsPort" then
            -- multibloco SPS
            if not validate_assign(true) then return false end

            rtu_type = RTU_UNIT_TYPE.SPS
            rtu_iface, faulted = sps_rtu.new(device)
            is_multiblock = true
            formed = device.isFormed()

            if formed == ppm.ACCESS_FAULT then
                println_ts(util.c("uinit> falha ao verificar se '", name, "' está formado"))
                log.warning(util.c("uinit> falha ao verificar se '", name, "' é um multibloco SPS formado"))
            end
        elseif type == "solarNeutronActivator" or type == "largeSolarNeutronActivator" then
            -- SNA (normal ou grande)
            if not validate_assign(entry.unit == nil) then return false end

            rtu_type = RTU_UNIT_TYPE.SNA
            rtu_iface, faulted = sna_rtu.new(device)
        elseif type == "environmentDetector" or type == "environment_detector" then
            -- detector de ambiente do Advanced Peripherals
            if not validate_index(1) then return false end
            if not validate_assign(entry.unit == nil) then return false end

            rtu_type = RTU_UNIT_TYPE.ENV_DETECTOR
            rtu_iface, faulted = envd_rtu.new(device)
        elseif type == "draconic_rf_storage" then
            -- núcleo de energia do Draconic Evolution
            if not validate_assign(true) then return false end

            rtu_type = RTU_UNIT_TYPE.ENERGY_CORE
            rtu_iface, faulted = ecore_rtu.new(device)
        elseif type == ppm.VIRTUAL_DEVICE_TYPE then
            -- dispositivo de espaço reservado
            rtu_type = RTU_UNIT_TYPE.VIRTUAL
            rtu_iface = rtu.init_unit().interface()
        else
            log_fail(util.c("uinit> dispositivo '", name, "' não é de um tipo conhecido (", type, ")"))
            return false
        end

        if is_multiblock then
            if not formed then
                if formed == false then
                    log.info(util.c("uinit> dispositivo '", name, "' não está formado"))
                else formed = false end
            elseif faulted then
                -- às vezes há uma condição de corrida na inicialização do servidor onde ele relata formado, mas
                -- as outras funções ainda não estão definidas (pelo menos essa é a teoria). marcar como não formado para tentar conexão mais tarde
                formed = false
                log.warning(util.c("uinit> dispositivo '", name, "' está formado, mas a inicialização teve uma ou mais falhas: marcado como não formado"))
            end
        end

        ---@class rtu_registry_entry
        local rtu_unit = {
            uid = 0,                                 ---@type integer ID da unidade RTU
            name = name,                             ---@type string nome da unidade
            type = rtu_type,                         ---@type RTU_UNIT_TYPE tipo da unidade
            index = index or false,                  ---@type integer|false índice do dispositivo
            reactor = for_reactor,                   ---@type integer|nil atribuição de unidade/instalação
            device = device,                         ---@type ppm_generic|string|0 referência de periférico (para redstone: 0 é local, string é o nome do relé)
            rs_conns = nil,                          ---@type IO_PORT[][]|nil conexões de redstone disponíveis
            is_multiblock = is_multiblock,           ---@type boolean se isto for para um periférico multibloco
            formed = formed,                         ---@type boolean|nil se este periférico está formado atualmente
            hw_state = RTU_HW_STATE.OFFLINE,         ---@type RTU_HW_STATE status do dispositivo de hardware
            rtu = rtu_iface,                         ---@type rtu_device|rtu_rs_device interface de hardware da RTU
            modbus_io = modbus.new(rtu_iface, true), ---@type modbus interface MODBUS
            pkt_queue = mqueue.new(),                ---@type mqueue|nil fila de pacotes
            thread = nil                             ---@type parallel_thread|nil thread associada da RTU
        }

        rtu_unit.thread = threads.thread__unit_comms(__shared_memory, rtu_unit)

        table.insert(units, rtu_unit)

        local for_message = "a instalação"
        if for_reactor > 0 then
            for_message = util.c("reator ", for_reactor)
        end

        local index_str = util.trinary(index ~= nil, util.c(" [", index, "]"), "")
        log.info(util.c("uinit> unidade RTU inicializada #", #units, ": ", name, " (", types.rtu_type_to_string(rtu_type), ")", index_str, " para ", for_message))

        rtu_unit.uid = #units

        -- determinar status do hardware
        if rtu_unit.type == RTU_UNIT_TYPE.VIRTUAL then
            rtu_unit.hw_state = RTU_HW_STATE.OFFLINE
        else
            if rtu_unit.is_multiblock then
                rtu_unit.hw_state = util.trinary(rtu_unit.formed == true, RTU_HW_STATE.OK, RTU_HW_STATE.UNFORMED)
            elseif faulted then
                rtu_unit.hw_state = RTU_HW_STATE.FAULTED
            else
                rtu_unit.hw_state = RTU_HW_STATE.OK
            end
        end

        -- relatar status do hardware
        databus.tx_unit_hw_status(rtu_unit.uid, rtu_unit.hw_state)
    end

    --#endregion

    return true
end
