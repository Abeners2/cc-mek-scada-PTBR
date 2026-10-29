--
-- Comunicações de Rede e Autenticação de Mensagens
--

local comms  = require("scada-common.comms")
local log    = require("scada-common.log")
local ppm    = require("scada-common.ppm")
local util   = require("scada-common.util")

local md5    = require("lockbox.digest.md5")
local sha1   = require("lockbox.digest.sha1")
local pbkdf2 = require("lockbox.kdf.pbkdf2")
local hmac   = require("lockbox.mac.hmac")
local stream = require("lockbox.util.stream")
local array  = require("lockbox.util.array")

local LINK_TIMEOUT_MS          = 5000
local DISCOVERY_PERIOD_UP_MS   = 3000
local DISCOVERY_PERIOD_DOWN_MS = 500

---@class scada_net_interface
local network = {}

-- motor de criptografia
local _crypt = {
    key = nil,
    hmac = nil
}

-- inicializa o sistema de autenticação de mensagens
---@param passkey string facility passkey
---@return integer init_time milliseconds init took
function network.init_mac(passkey)
    local start = util.time_ms()

    local key_deriv = pbkdf2()

    -- configura o PBKDF2
    key_deriv.setPRF(hmac().setBlockSize(64).setDigest(sha1))
    key_deriv.setBlockLen(20)
    key_deriv.setDKeyLen(20)
    key_deriv.setIterations(256)
    key_deriv.setSalt("pepper")
    key_deriv.setPassword(passkey)
    key_deriv.finish()

    _crypt.key = array.fromHex(key_deriv.asHex())

    -- inicializa o HMAC
    _crypt.hmac = hmac()
    _crypt.hmac.setBlockSize(64)
    _crypt.hmac.setDigest(md5)
    _crypt.hmac.setKey(_crypt.key)

    local init_time = util.time_ms() - start
    log.info("NET: network.init_mac() concluido em " .. init_time .. "ms")

    return init_time
end

-- desinicializa o sistema de autenticação de mensagens
function network.deinit_mac()
    _crypt.key, _crypt.hmac = nil, nil
end

-- gera o HMAC da mensagem
---@nodiscard
---@param message string initial value concatenated with ciphertext
local function compute_hmac(message)
    -- local start = util.time_ms()

    _crypt.hmac.init()
    _crypt.hmac.update(stream.fromString(message))
    _crypt.hmac.finish()

    local hash = _crypt.hmac.asHex()

    -- log.debug("NET: compute_hmac(): hmac-md5 = " .. util.strval(hash) ..  " (levou " .. (util.time_ms() - start) .. "ms)")

    return hash
end

-- Controlador de Interface de Rede (NIC)<br>
-- envia e recebe quadros de rede usando um modem<br>
-- utiliza HMAC-MD5 para autenticação de mensagens, se ativado e usando um modem sem fio
---@param modem Modem|nil modem to use
---@param lld_tx_chan integer? link layer discovery transmit channel, or nil to disable probing (will still reply)
function network.nic(modem, lld_tx_chan)
    local self = {
        -- nome da interface do modem
        iface = "?",
        -- nome phy
        name = "?",
        -- usado para evitar cálculos custosos de MAC se não for necessário
        use_hash = false,
        -- usado para retornar rapidamente das funções tx/rx se não houver nada para fazer
        phy_up = false,
        -- monitora se esta NIC parece ter acesso à rede
        link_up = false,
        -- última vez que uma resposta de descoberta ou outro tráfego foi recebido
        last_lld_rx = 0,
        -- última vez que a descoberta foi transmitida
        last_lld_tx = 0,
        -- canais abertos
        channels = {}
    }

    -- envia um quadro de descoberta da camada de enlace
    ---@param dest_addr integer destination address
    ---@param r_chan integer remote channel
    ---@param l_chan integer local channel
    ---@param ack boolean true if this is an acknowledgement
    local function _send_ll_discovery_frame(dest_addr, r_chan, l_chan, ack)
        if not self.phy_up then return end

        local reply = comms.lld_frame()

        reply.make(dest_addr, ack)

        -- log.debug(util.c("_send_ll_discovery_frame { ", dest_addr, ", ", r_chan, ", ", l_chan, " }"))

---@diagnostic disable-next-line: need-check-nil
        modem.transmit(r_chan, l_chan, reply.raw_frame())
    end

    ---@class nic:Modem
    local public = {}

    -- obtém o nome phy
    ---@nodiscard
    function public.phy_name() return self.name end

    -- verifica se esta NIC possui um modem conectado
    ---@nodiscard
    function public.is_connected() return self.phy_up end

    -- verifica se esta NIC detectou um link de rede
    ---@nodiscard
    function public.is_network_up() return self.link_up end

    -- conecta a um periférico de modem
    ---@param reconnected_modem Modem
    function public.connect(reconnected_modem)
        modem = reconnected_modem

        self.iface    = ppm.get_iface(modem)
        self.name     = util.c(util.trinary(modem.isWireless(), "WLAN_PHY", "ETH_PHY"), "{", self.iface, "}")
        self.use_hash = _crypt.hmac and modem.isWireless()
        self.phy_up   = true
        self.link_up  = false

        -- abre apenas canais abertos anteriormente
        modem.closeAll()
        for _, channel in ipairs(self.channels) do
            modem.open(channel)
        end

        -- vincula todas as funções públicas exceto transmit, open e close
        for key, func in pairs(modem) do
            if key ~= "transmit" and key ~= "open" and key ~= "close" and key ~= "closeAll" then public[key] = func end
        end
    end

    -- marca esta NIC como não tendo mais um modem conectado (geralmente devido à desconexão de periférico)
    function public.disconnect()
        self.phy_up  = false
        self.link_up = false
    end

    -- verifica se um periférico é este modem
    ---@nodiscard
    ---@param device ppm_generic
    function public.is_modem(device) return device == modem end

    -- encapsula funções do modem e depois cria funções personalizadas
    if modem then public.connect(modem) end

    -- abre um canal no modem<br>
    -- se desconectado *após* a abertura, os canais abertos anteriormente serão reabertos na reconexão
    ---@param channel integer
    function public.open(channel)
        if modem then modem.open(channel) end

        local already_open = false
        for i = 1, #self.channels do
            if self.channels[i] == channel then
                already_open = true
                break
            end
        end

        if not already_open then
            table.insert(self.channels, channel)
        end
    end

    -- fecha um canal no modem
    ---@param channel integer
    function public.close(channel)
        if modem then modem.close(channel) end

        for i = 1, #self.channels do
            if self.channels[i] == channel then
                table.remove(self.channels, i)
                return
            end
        end
    end

    -- fecha todos os canais no modem
    function public.closeAll()
        if modem then modem.closeAll() end
        self.channels = {}
    end

    -- envia um quadro, com autenticação de mensagem se configurado
    ---@param dest_channel integer destination channel
    ---@param local_channel integer local channel
    ---@param frame scada_frame frame
    function public.transmit(dest_channel, local_channel, frame)
        if self.phy_up then
            local tx_frame = frame ---@type authd_frame|scada_frame

            if self.use_hash then
                -- local start = util.time_ms()
                tx_frame = comms.authd_frame()
                tx_frame.make(frame, compute_hmac)
                -- log.debug("NET: network.nic.transmit(): processamento de dados levou " .. (util.time_ms() - start) .. "ms")
            end

---@diagnostic disable-next-line: need-check-nil
            modem.transmit(dest_channel, local_channel, tx_frame.raw_frame())
        else
            log.debug("NET: " .. self.name ..".transmit() tx descartado, phy esta inativo")
        end
    end

    -- analisa os componentes do quadro do modem como um quadro de rede SCADA
    ---@nodiscard
    ---@param side string modem side
    ---@param sender integer sender channel
    ---@param reply_to integer reply channel
    ---@param message any SCADA frame sent with or without message authentication
    ---@param distance integer transmission distance
    ---@return scada_frame|nil frame received frame if valid and passed authentication check
    function public.receive(side, sender, reply_to, message, distance)
        local frame = nil

        if self.phy_up and side == self.iface then
            local s_frame = comms.scada_frame()

            if self.use_hash then
                -- analisa o quadro como um quadro SCADA autenticado
                local a_frame = comms.authd_frame()

                if a_frame.receive(side, sender, reply_to, message, distance) then
                    if s_frame.receive(side, sender, reply_to, a_frame.data(), distance) then
                        -- local start         = util.time_ms()
                        local computed_hmac = compute_hmac(textutils.serialize(s_frame.raw_header(), { allow_repetitions = true, compact = true }))

                        if a_frame.mac() == computed_hmac then
                            -- log.debug("NET: " .. self.name ..".receive(): HMAC verificado em " .. (util.time_ms() - start) .. "ms")
                            s_frame.stamp_authenticated()
                        else
                            -- log.debug("NET: " .. self.name ..".receive(): falha na verificacao do HMAC em " .. (util.time_ms() - start) .. "ms")
                        end
                    end
                end
            else
                -- analisa o quadro como um quadro SCADA genérico
                s_frame.receive(side, sender, reply_to, message, distance)
            end

            -- se for válido, retorna-o, caso contrário, tenta tratá-lo como uma transação da camada de enlace
            if s_frame.is_valid() then
                self.link_up     = true
                self.last_lld_rx = util.time_ms()

                frame = s_frame
            else
                local l_frame = comms.lld_frame()

                -- tenta recebê-lo como um quadro de descoberta da camada de enlace e responde se for válido
                -- mantém o valor retornado como nil; esta é uma lógica interna da camada 2 para ocultar da aplicação
                if l_frame.receive(side, sender, reply_to, message, distance) then
                    self.link_up     = true
                    self.last_lld_rx = util.time_ms()

                    if not l_frame.is_ack() then
                        _send_ll_discovery_frame(l_frame.src_addr(), l_frame.remote_channel(), l_frame.local_channel(), true)
                    end
                end
            end
        end

        return frame
    end

    -- tarefa periódica da NIC para manter a detecção de link de rede
    ---@return boolean link_up if the network link is still up
    function public.periodic()
        local now = util.time_ms()

        if now >= (self.last_lld_rx + LINK_TIMEOUT_MS) then
            if self.link_up then log.debug("NET: " .. self.name ..".periodic(): tempo limite do link esgotado") end

            self.link_up = false
        end

        if lld_tx_chan and self.phy_up then
            if (now - self.last_lld_tx) > util.trinary(self.link_up, DISCOVERY_PERIOD_UP_MS, DISCOVERY_PERIOD_DOWN_MS) then
                self.last_lld_tx = now

                for _, channel in ipairs(self.channels) do
                    _send_ll_discovery_frame(comms.BROADCAST, lld_tx_chan, channel, false)
                end
            end
        end

        return self.link_up
    end

    return public
end

return network
