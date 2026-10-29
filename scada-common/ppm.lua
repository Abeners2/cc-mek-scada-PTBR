--
-- Gerenciador de Periféricos Protegidos (PPM)
--

local log  = require("scada-common.log")
local util = require("scada-common.util")

---@class ppm
local ppm = {}

local ACCESS_FAULT        = nil                 ---@type nil
local UNDEFINED_FIELD     = "__PPM_UNDEF_FIELD__"
local VIRTUAL_DEVICE_TYPE = "ppm_vdev"

ppm.ACCESS_FAULT          = ACCESS_FAULT
ppm.UNDEFINED_FIELD       = UNDEFINED_FIELD
ppm.VIRTUAL_DEVICE_TYPE   = VIRTUAL_DEVICE_TYPE

----------------------------
-- PRIVATE DATA/FUNCTIONS --
----------------------------

local REPORT_FREQUENCY = 20 -- registra a cada 20 falhas por função

local _ppm = {
    mounts = {},    ---@type { [string]: ppm_entry }
    next_vid = 0,
    auto_cf = false,
    faulted = false,
    last_fault = "",
    terminate = false,
    mute = false
}

-- Encapsula chamadas de periféricos com pcall do Lua, pois não queremos que uma desconexão trave um programa.
-- Além disso, fornece verificações de falha específicas de periféricos (limpeza automática de falhas tem padrão true).<br>
-- Nota: assume que iface é um periférico válido.
---@param iface string CC peripheral interface
local function peri_init(iface)
    local self = {
        faulted = false,
        last_fault = "",
        fault_counts = {},          ---@type { [string]: integer }
        auto_cf = true,
        type = VIRTUAL_DEVICE_TYPE, ---@type string
        device = {}                 ---@type ppm_generic
    }

    if iface ~= "__virtual__" then
        self.type = peripheral.getType(iface)
        self.device = peripheral.wrap(iface)
    end

    -- cria uma versão protegida de uma chamada de função de periférico
    ---@nodiscard
    ---@param key string function name
    ---@param func function function
    ---@return function method protected version of the function
    local function protect_peri_function(key, func)
        return function (...)
            local return_table = table.pack(pcall(func, ...))

            local status = return_table[1]
            table.remove(return_table, 1)

            if status then
                -- limpeza automática de falhas
                if self.auto_cf then self.faulted = false end
                if _ppm.auto_cf then _ppm.faulted = false end

                self.fault_counts[key] = 0

                return table.unpack(return_table)
            else
                local result = return_table[1]

                -- função falhou
                self.faulted = true
                self.last_fault = result

                _ppm.faulted = true
                _ppm.last_fault = result

                if not _ppm.mute and (self.fault_counts[key] % REPORT_FREQUENCY == 0) then
                    local count_str = ""
                    if self.fault_counts[key] > 0 then
                        count_str = " [" .. self.fault_counts[key] .. " falhas totais]"
                    end

                    log.error(util.c("PPM: [@", iface, "] ", key, "() protegido -> ", result, count_str))
                end

                self.fault_counts[key] = self.fault_counts[key] + 1

                if result == "Terminated" then _ppm.terminate = true end

                return ACCESS_FAULT, result
            end
        end
    end

    -- funções genéricas de gerenciamento e monitoramento de falhas

    local function clear_fault() self.faulted = false end
    local function get_last_fault() return self.last_fault end
    local function is_faulted() return self.faulted end
    local function is_ok() return not self.faulted end

    -- verifica se um periférico possui alguma função com falha<br>
    -- contrasta com is_faulted() e is_ok(), pois estes verificam apenas se a última operação falhou,
    -- a menos que a limpeza automática de falhas esteja desativada, ponto em que as falhas se tornam persistentes
    local function is_healthy()
        for _, v in pairs(self.fault_counts) do if v > 0 then return false end end
        return true
    end

    local function enable_afc() self.auto_cf = true end
    local function disable_afc() self.auto_cf = false end

    -- anexa funções PPM às funções do dispositivo

    self.device.__p_clear_fault = clear_fault
    self.device.__p_last_fault  = get_last_fault
    self.device.__p_is_faulted  = is_faulted
    self.device.__p_is_ok       = is_ok
    self.device.__p_is_healthy  = is_healthy
    self.device.__p_enable_afc  = enable_afc
    self.device.__p_disable_afc = disable_afc

    ---@class PPMDevice
    local dev = self.device

    dev.__p_clear_fault = clear_fault
    dev.__p_last_fault  = get_last_fault
    dev.__p_is_faulted  = is_faulted
    dev.__p_is_ok       = is_ok
    dev.__p_is_healthy  = is_healthy
    dev.__p_enable_afc  = enable_afc
    dev.__p_disable_afc = disable_afc

    -- processo de inicialização de chamada de periférico (remapeamento)

    for key, func in pairs(self.device) do
        self.fault_counts[key] = 0
        self.device[key] = protect_peri_function(key, func)
    end

    -- adiciona função de índice padrão para capturar índices indefinidos

    local mt = {
        __index = function (_, key)
            -- tenta encontrar a função caso ela tenha sido adicionada (multibloco formado)
            local funcs = peripheral.wrap(iface)
            if (type(funcs) == "table") and (type(funcs[key]) == "function") then
                -- adiciona esta função e a retorna
                self.fault_counts[key] = 0
                self.device[key] = protect_peri_function(key, funcs[key])

                log.info(util.c("PPM: [@", iface, "] inicializou campo anteriormente indefinido ", key, "()"))

                return self.device[key]
            end

            -- função ainda ausente, retorna um manipulador de função indefinida
            -- nota: o código deve evitar armazenar funções para multiblocos e, em vez disso, tentar indexá-las novamente
            return (function ()
                -- isso continuará contando chamadas aqui como falhas
                if self.fault_counts[key] == nil then self.fault_counts[key] = 0 end

                -- função falhou
                self.faulted = true
                self.last_fault = UNDEFINED_FIELD

                _ppm.faulted = true
                _ppm.last_fault = UNDEFINED_FIELD

                if not _ppm.mute and (self.fault_counts[key] % REPORT_FREQUENCY == 0) then
                    local count_str = ""
                    if self.fault_counts[key] > 0 then
                        count_str = " [" .. self.fault_counts[key] .. " chamadas totais]"
                    end

                    log.error(util.c("PPM: [@", iface, "] capturou funcao indefinida ", key, "()", count_str))
                end

                self.fault_counts[key] = self.fault_counts[key] + 1

                return ACCESS_FAULT, UNDEFINED_FIELD
            end)
        end
    }

    setmetatable(self.device, mt)

    ---@class ppm_entry
    local entry = { type = self.type, dev = self.device }

    return entry
end

----------------------
-- PUBLIC FUNCTIONS --
----------------------

-- RELATÓRIOS --

-- silencia impressões de erro
function ppm.disable_reporting() _ppm.mute = true end

-- permite impressões de erro
function ppm.enable_reporting() _ppm.mute = false end

-- MEMÓRIA DE FALHAS --

-- ativa a limpeza automática do sinalizador de falha
function ppm.enable_afc() _ppm.auto_cf = true end

-- desativa a limpeza automática do sinalizador de falha
function ppm.disable_afc() _ppm.auto_cf = false end

-- limpa o sinalizador de falha
function ppm.clear_fault() _ppm.faulted = false end

-- verifica o sinalizador de falha
---@nodiscard
function ppm.is_faulted() return _ppm.faulted end

-- obtém a última mensagem de falha
---@nodiscard
function ppm.get_last_fault() return _ppm.last_fault end

-- ENCERRAMENTO --

-- se um erro capturado foi uma solicitação de encerramento
---@nodiscard
function ppm.should_terminate() return _ppm.terminate end

-- MONTAGEM --

-- monta todos os periféricos disponíveis (limpa as montagens primeiro)
function ppm.mount_all()
    local ifaces = peripheral.getNames()

    _ppm.mounts = {}

    for i = 1, #ifaces do
        _ppm.mounts[ifaces[i]] = peri_init(ifaces[i])

        log.info(util.c("PPM: encontrou um ", _ppm.mounts[ifaces[i]].type, " (", ifaces[i], ")"))
    end

    if #ifaces == 0 then
        log.warning("PPM: mount_all() -> nenhum dispositivo encontrado")
    end
end

-- monta um dispositivo especificado
---@nodiscard
---@param iface string CC peripheral interface
---@return string|nil type, ppm_generic|nil device
function ppm.mount(iface)
    local ifaces = peripheral.getNames()
    local pm_dev = nil
    local pm_type = nil

    for i = 1, #ifaces do
        if iface == ifaces[i] then
            _ppm.mounts[iface] = peri_init(iface)

            pm_type = _ppm.mounts[iface].type
            pm_dev = _ppm.mounts[iface].dev

            log.info(util.c("PPM: mount(", iface, ") -> encontrou um ", pm_type))
            break
        end
    end

    return pm_type, pm_dev
end

-- desmonta e remonta um dispositivo especificado
---@nodiscard
---@param iface string CC peripheral interface
---@return string|nil type, ppm_generic|nil device
function ppm.remount(iface)
    local ifaces = peripheral.getNames()
    local pm_dev = nil
    local pm_type = nil

    for i = 1, #ifaces do
        if iface == ifaces[i] then
            log.info(util.c("PPM: remount(", iface, ") -> e um ", pm_type))
            ppm.unmount(_ppm.mounts[iface].dev)

            _ppm.mounts[iface] = peri_init(iface)

            pm_type = _ppm.mounts[iface].type
            pm_dev = _ppm.mounts[iface].dev

            log.info(util.c("PPM: remount(", iface, ") -> remontou um ", pm_type))
            break
        end
    end

    return pm_type, pm_dev
end

-- monta um dispositivo virtual substituto (placeholder)
---@nodiscard
---@return string type, ppm_generic device
function ppm.mount_virtual()
    local iface = "ppm_vdev_" .. _ppm.next_vid

    _ppm.mounts[iface] = peri_init("__virtual__")
    _ppm.next_vid = _ppm.next_vid + 1

    log.info(util.c("PPM: mount_virtual() -> alocou novo dispositivo virtual ", iface))

    return _ppm.mounts[iface].type, _ppm.mounts[iface].dev
end

-- desmonta manualmente um periférico do PPM
---@param device ppm_generic device table
function ppm.unmount(device)
    if device then
        for iface, data in pairs(_ppm.mounts) do
            if data.dev == device then
                log.warning(util.c("PPM: desmontou manualmente ", data.type, " montado em ", iface))
                _ppm.mounts[iface] = nil
                break
            end
        end
    end
end

-- trata o evento peripheral_detach
---@nodiscard
---@param iface string CC peripheral interface
---@return string|nil type, ppm_generic|nil device
function ppm.handle_unmount(iface)
    local pm_dev = nil
    local pm_type = nil

    -- o que foi desconectado?
    local lost_dev = _ppm.mounts[iface]

    if lost_dev then
        pm_type = lost_dev.type
        pm_dev = lost_dev.dev

        log.warning(util.c("PPM: perdeu dispositivo ", pm_type, " montado em ", iface))
    else
        log.error(util.c("PPM: perdeu dispositivo desconhecido pelo PPM montado em ", iface))
    end

    _ppm.mounts[iface] = nil

    return pm_type, pm_dev
end

-- registra todas as montagens, para ser usado se `ppm.mount_all` for chamado antes que o log esteja pronto
function ppm.log_mounts()
    for iface, mount in pairs(_ppm.mounts) do
        log.info(util.c("PPM: havia encontrado um ", mount.type, " (", iface, ")"))
    end

    if util.table_len(_ppm.mounts) == 0 then
        log.warning("PPM: nenhum dispositivo havia sido encontrado")
    end
end

-- ACESSORES GERAIS --

-- lista todos os periféricos disponíveis
---@nodiscard
---@return string[] names
function ppm.list_avail() return peripheral.getNames() end

-- lista os periféricos montados
---@nodiscard
---@return { [string]: ppm_entry } mounts
function ppm.list_mounts()
    local list = {}
    for k, v in pairs(_ppm.mounts) do list[k] = v end
    return list
end

-- obtém o lado/interface de um periférico montado pela tabela do dispositivo
---@nodiscard
---@param device ppm_generic device table
---@return string|nil iface CC peripheral interface
function ppm.get_iface(device)
    if device then
        for iface, data in pairs(_ppm.mounts) do
            if data.dev == device then return iface end
        end
    end

    return nil
end

-- obtém um periférico montado pelo lado/interface
---@nodiscard
---@param iface string CC peripheral interface
---@return ppm_generic|nil device function table
function ppm.get_periph(iface)
    if _ppm.mounts[iface] then
        return _ppm.mounts[iface].dev
    else return nil end
end

-- obtém o tipo de um periférico montado pelo lado/interface
---@nodiscard
---@param iface string CC peripheral interface
---@return string|nil type
function ppm.get_type(iface)
    if _ppm.mounts[iface] then
        return _ppm.mounts[iface].type
    else return nil end
end

-- obtém todos os periféricos montados por tipo
---@nodiscard
---@param type string type name
---@return ppm_generic[] devices device function tables
function ppm.get_all_devices(type)
    local devices = {}

    for _, data in pairs(_ppm.mounts) do
        if data.type == type then
            table.insert(devices, data.dev)
        end
    end

    return devices
end

-- obtém um periférico montado por tipo (se houver vários, retorna o primeiro)
---@nodiscard
---@param type string type name
---@return ppm_generic|nil device, string|nil iface device and interface
function ppm.get_device(type)
    local device, d_iface = nil, nil

    for iface, data in pairs(_ppm.mounts) do
        if data.type == type then
            device = data.dev
            d_iface = iface
            break
        end
    end

    return device, d_iface
end

-- ACESSORES DE DISPOSITIVOS ESPECÍFICOS --

-- obtém o reator de fissão (se houver vários, retorna o primeiro)
---@nodiscard
---@return FissionReactor|nil reactor, string|nil iface reactor and interface
function ppm.get_fission_reactor()
    local dev, iface = ppm.get_device("fissionReactorLogicAdapter")

    ---@cast dev FissionReactor|nil

    return dev, iface
end

-- obtém um modem pelo nome
---@nodiscard
---@param iface string CC peripheral interface
---@return Modem|nil modem function table
function ppm.get_modem(iface)
    local modem  = nil
    local device = _ppm.mounts[iface]

    if device and device.type == "modem" then modem = device.dev end

    ---@cast modem Modem|nil

    return modem
end

-- obtém o modem sem fio (se houver vários, retorna o primeiro)<br>
-- se estiver em um ambiente emulado CraftOS, modems cabeados serão usados em seu lugar
---@nodiscard
---@return Modem|nil modem, string|nil iface
function ppm.get_wireless_modem()
    local w_modem, w_iface = nil, nil
    local emulated_env = periphemu ~= nil

    for iface, device in pairs(_ppm.mounts) do
        if device.type == "modem" and (emulated_env or device.dev.isWireless()) then
            w_modem = device.dev
            w_iface = iface
            break
        end
    end

    return w_modem, w_iface
end

-- lista todos os modems cabeados conectados
---@nodiscard
---@return { [string]: ppm_entry } modems
function ppm.get_wired_modem_list()
    local list = {}

    for iface, device in pairs(_ppm.mounts) do
        if device.type == "modem" and not device.dev.isWireless() then list[iface] = device end
    end

    return list
end

-- lista todos os monitores conectados
---@nodiscard
---@return { [string]: ppm_entry } monitors
function ppm.get_monitor_list()
    local list = {}

    for iface, device in pairs(_ppm.mounts) do
        if device.type == "monitor" then list[iface] = device end
    end

    return list
end

-- FUNÇÕES AUXILIARES

-- obtém o tamanho em blocos de um monitor dada sua largura e altura em uma determinada escala de texto
---@nodiscard
---@param width integer character width
---@param height integer character height
---@param scale number? scale or default 0.5
---@return integer block_width, integer block_height
function ppm.monitor_block_size(width, height, scale)
    local b_w = util.round(((width * 6 * (scale or 0.5)) + 20) / 64)
    local b_h = util.round(((height * 9 * (scale or 0.5)) + 20) / 64)
    return b_w, b_h
end

return ppm
