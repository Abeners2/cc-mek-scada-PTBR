local comms      = require("scada-common.comms")
local network    = require("scada-common.network")
local ppm        = require("scada-common.ppm")
local rsio       = require("scada-common.rsio")
local tcd        = require("scada-common.tcd")
local util       = require("scada-common.util")

local rtu        = require("rtu.rtu")

local redstone   = require("rtu.config.redstone")

local core       = require("graphics.core")

local Div        = require("graphics.elements.Div")
local ListBox    = require("graphics.elements.ListBox")
local TextBox    = require("graphics.elements.TextBox")

local PushButton = require("graphics.elements.controls.PushButton")

local tri = util.trinary

local cpair = core.cpair

local PROTOCOL = comms.PROTOCOL
local DEVICE_TYPE = comms.DEVICE_TYPE
local ESTABLISH_ACK = comms.ESTABLISH_ACK
local MGMT_TYPE = comms.MGMT_TYPE

local self = {
    checking_wl = true,
    wd_modem = nil,      ---@type Modem|nil
    wl_modem = nil,      ---@type Modem|nil

    nic = nil,           ---@type nic
    net_listen = false,

    self_check_pass = true,

    self_check_wireless = true,

    settings = nil,      ---@type rtu_config

    run_test_btn = nil,  ---@type PushButton
    sc_log = nil,        ---@type ListBox
    self_check_msg = nil ---@type function
}

-- relatar conclusão bem-sucedida da verificação
local function check_complete()
    TextBox{parent=self.sc_log,text="> todos os testes passaram!",fg_bg=cpair(colors.blue,colors._INHERIT)}
    TextBox{parent=self.sc_log,text=""}
    local more = Div{parent=self.sc_log,height=3,fg_bg=cpair(colors.gray,colors._INHERIT)}
    TextBox{parent=more,text="se você ainda tiver um problema:"}
    TextBox{parent=more,text="- verifique a wiki no GitHub"}
    TextBox{parent=more,text="- peça ajuda nas discussões do GitHub ou Discord"}
end

-- enviar um pacote de gerenciamento para o supervisor
---@param msg_type MGMT_TYPE
---@param msg table
local function send_sv(msg_type, msg)
    local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

    mgmt.make(msg_type, msg)
    frame.make(comms.BROADCAST, util.time_ms() * 10, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

    self.nic.transmit(self.settings.SVR_Channel, self.settings.RTU_Channel, frame)
end

-- tratar uma mensagem de estabelecimento do supervisor
---@param packet mgmt_packet
local function handle_packet(packet)
    local error_msg = nil

    if packet.scada_frame.local_channel() ~= self.settings.RTU_Channel then
        error_msg = "erro: canal de recepção desconhecido"
    elseif packet.scada_frame.remote_channel() == self.settings.SVR_Channel and packet.scada_frame.protocol() == PROTOCOL.SCADA_MGMT then
        if packet.type == MGMT_TYPE.ESTABLISH then
            if packet.length == 1 then
                local est_ack = packet.data[1]

                if est_ack== ESTABLISH_ACK.ALLOW then
                    -- OK
                elseif est_ack == ESTABLISH_ACK.DENY then
                    error_msg = "erro: conexão com o supervisor negada"
                elseif est_ack == ESTABLISH_ACK.BAD_VERSION then
                    error_msg = "versão de comunicação do gateway RTU não corresponde à versão de comunicação do supervisor, certifique-se de que ambos os dispositivos estão atualizados (ccmsi update)"
                else
                    error_msg = "erro: resposta inválida do supervisor"
                end
            else
                error_msg = "erro: tamanho de resposta inválido do supervisor"
            end
        else
            error_msg = "erro: não obteve uma resposta de estabelecimento do supervisor"
        end
    end

    self.net_listen = false

    if error_msg then
        self.self_check_msg(nil, false, error_msg)
    else
        self.self_check_msg(nil, true, "")
    end

    util.push_event("conn_test_complete", error_msg == nil)
end

-- tratar falha de conexão com o supervisor
local function handle_timeout()
    self.net_listen = false
    util.push_event("conn_test_complete", false)
end


-- verificar se um valor é um inteiro dentro de um intervalo (inclusivo)
---@param x any
---@param min integer
---@param max integer
local function is_int_min_max(x, min, max) return util.is_int(x) and x >= min and x <= max end

-- executar o autoteste
local function self_check()
    self.run_test_btn.disable()

    self.sc_log.remove_all()
    ppm.mount_all()

    self.self_check_pass = true

    local cfg = self.settings
    self.wd_modem = ppm.get_modem(cfg.WiredModem)
    self.wl_modem = ppm.get_wireless_modem()
    local valid_cfg = rtu.validate_config(cfg)

    if cfg.WiredModem then
        self.self_check_msg("> verif. modem cabeado conectado...", self.wd_modem, "por favor conecte o modem de comunicação cabeado " .. cfg.WiredModem)
    end

    if cfg.WirelessModem then
        self.self_check_msg("> verif. modem sem fio/ender conectado...", self.wl_modem, "por favor conecte um modem ender ou sem fio para comunicações sem fio")
    end

    self.self_check_msg("> verif. configuração do gateway...", valid_cfg, "acesse Configurar Gateway e aplique as configurações para definir quaisquer configurações ausentes e reparar quaisquer corrompidas")

    -- verificar configurações de redstone

    local phys = {} ---@type rtu_rs_definition[][]
    local inputs = { [0] = {}, {}, {}, {}, {} }

    for i = 1, #cfg.Redstone do
        local entry = cfg.Redstone[i]
        local name = entry.relay or "local"

        if phys[name] == nil then phys[name] = {} end
        table.insert(phys[entry.relay or "local"], entry)
    end

    for name, entries in pairs(phys) do
        TextBox{parent=self.sc_log,text="> verificando redstone @ "..name.."...",fg_bg=cpair(colors.blue,colors.white)}

        local ifaces = {}
        local bundled_sides = {}

        for i = 1, #entries do
            local entry = entries[i]
            local ident = entry.side .. tri(entry.color, ":" .. rsio.color_name(entry.color), "")

            local sc_dupe  = util.table_contains(ifaces, ident)
            local mixed = (bundled_sides[entry.side] and (entry.color == nil)) or (bundled_sides[entry.side] == false and (entry.color ~= nil))

            local mixed_msg = util.trinary(bundled_sides[entry.side], "entrada(s) agrupada(s) mas esta entrada não é", "entrada(s) não agrupada(s) mas esta entrada é")

            self.self_check_msg("> verif. redstone " .. ident .. " única...", not sc_dupe, "apenas uma porta deve ser definida para uma combinação lado/cor")
            self.self_check_msg("> verif. redstone " .. ident .. " feixe...", not mixed, "este lado tem " .. mixed_msg .. " agrupada, o que não funcionará")
            self.self_check_msg("> verif. redstone " .. ident .. " válida...", redstone.validate(entry), "configuração inválida, por favor reconfigure a entrada de redstone")

            if rsio.get_io_dir(entry.port) == rsio.IO_DIR.IN then
                local in_dupe = util.table_contains(inputs[entry.unit or 0], entry.port)
                self.self_check_msg("> verif. redstone " .. ident .. " entrada...", not in_dupe, "você não pode ter múltiplas da mesma entrada para uma determinada unidade ou instalação ("..rsio.to_string(entry.port)..")")
            end

            bundled_sides[entry.side] = bundled_sides[entry.side] or entry.color ~= nil
            table.insert(ifaces, ident)
        end
    end

    -- verificar configurações de periféricos
    for i = 1, #cfg.Peripherals do
        local entry = cfg.Peripherals[i]
        local valid = false

        if type(entry.name) == "string" then
            self.self_check_msg("> verif. " .. entry.name .. " conectado...", ppm.get_periph(entry.name), "por favor conecte este dispositivo via modem cabeado ou contato direto e certifique-se de que a configuração corresponde ao nome de conexão")

            local p_type = ppm.get_type(entry.name)

            if p_type == "boilerValve" then
                valid = is_int_min_max(entry.index, 1, 2) and is_int_min_max(entry.unit, 1, 4)
            elseif p_type == "turbineValve" then
                valid = is_int_min_max(entry.index, 1, 3) and is_int_min_max(entry.unit, 1, 4)
            elseif p_type == "solarNeutronActivator" or p_type == "largeSolarNeutronActivator" or p_type == "dynamicValve" then
                valid = (entry.unit == nil and is_int_min_max(entry.index, 1, 4)) or is_int_min_max(entry.unit, 1, 4)
            elseif p_type == "environmentDetector" or p_type == "environment_detector"  then
                valid = (entry.unit == nil or is_int_min_max(entry.unit, 1, 4)) and util.is_int(entry.index)
            else
                valid = true

                if p_type ~= nil and not (p_type == "inductionPort" or p_type == "reinforcedInductionPort" or p_type == "spsPort") then
                    self.self_check_msg("> verif. " .. entry.name .. " válido...", false, "tipo de dispositivo não reconhecido")
                end
            end
        end

        if not valid then
            self.self_check_msg("> verif. " .. entry.name .. " válido...", false, "configuração inválida, por favor reconfigure a entrada de periférico")
        end
    end

    if valid_cfg then
        self.checking_wl = true

        if cfg.WirelessModem and self.wl_modem then
            self.self_check_msg("> verif. conexão sem fio do supervisor...")

            -- inicializar mac conforme necessário
            if cfg.AuthKey and string.len(cfg.AuthKey) >= 8 then
                network.init_mac(cfg.AuthKey)
            else
                network.deinit_mac()
            end

            comms.set_trusted_range(cfg.TrustedRange)

            self.nic = network.nic(self.wl_modem)

            self.nic.closeAll()
            self.nic.open(cfg.RTU_Channel)

            self.net_listen = true

            send_sv(MGMT_TYPE.ESTABLISH, { comms.version, comms.CONN_TEST_FWV, DEVICE_TYPE.RTU, {} })

            tcd.dispatch_unique(8, handle_timeout)
        elseif cfg.WiredModem and self.wd_modem then
            -- pular para cabeado
            util.push_event("conn_test_complete", true)
        else
            self.self_check_msg("> sem modem, impossível testar conexão do supervisor", false)
        end
    else
        if self.self_check_pass then check_complete() end
        self.run_test_btn.enable()
    end
end

-- sair do autoteste de volta ao início
---@param main_pane MultiPane
local function exit_self_check(main_pane)
    tcd.abort(handle_timeout)
    self.net_listen = false
    self.run_test_btn.enable()
    self.sc_log.remove_all()
    main_pane.set_value(1)
end

local check = {}

-- criar a visualização de autoteste
---@param main_pane MultiPane
---@param settings_cfg rtu_config
---@param check_sys Div
---@param style { [string]: cpair }
function check.create(main_pane, settings_cfg, check_sys, style)
    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    self.settings = settings_cfg

    local sc = Div{parent=check_sys,x=2,y=4,width=49}

    TextBox{parent=check_sys,y=2,text=" Autoteste do Gateway RTU",fg_bg=bw_fg_bg}

    self.sc_log = ListBox{parent=sc,y=1,height=12,width=49,scroll_height=1000,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local last_check = { nil, nil } ---@type [ Div?, integer? ]

    function self.self_check_msg(msg, success, fail_msg)
        if type(msg) == "string" then
            local lines = util.strwrap(msg, 48)
            last_check[1] = Div{parent=self.sc_log,height=#lines}
            local e = TextBox{parent=last_check[1],text=msg,fg_bg=bw_fg_bg}
            last_check[2] = e.get_x() + string.len(lines[#lines])
        end

        if type(fail_msg) == "string" then
            TextBox{parent=last_check[1],x=last_check[2],y=last_check[1].get_height(),text=tri(success,"PASSOU","FALHOU"),fg_bg=tri(success,cpair(colors.green,colors._INHERIT),cpair(colors.red,colors._INHERIT))}

            if not success then
                local fail = Div{parent=self.sc_log,height=#util.strwrap(fail_msg,46)}
                TextBox{parent=fail,x=3,text=fail_msg,fg_bg=cpair(colors.gray,colors.white)}
            end

            self.self_check_pass = self.self_check_pass and success
        end
    end

    PushButton{parent=sc,y=14,text="\x1b Voltar",callback=function()exit_self_check(main_pane)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    self.run_test_btn = PushButton{parent=sc,x=40,y=14,min_width=10,text="Testar",callback=function()self_check()end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
end

-- tratar mensagens de modem recebidas
---@param side string
---@param sender integer
---@param reply_to integer
---@param message any
---@param distance integer
function check.receive_sv(side, sender, reply_to, message, distance)
    if self.nic ~= nil and self.net_listen then
        local frame = self.nic.receive(side, sender, reply_to, message, distance)

        if frame and frame.protocol() == PROTOCOL.SCADA_MGMT then
            local pkt = comms.mgmt_container().decode(frame)
            if pkt then
                tcd.abort(handle_timeout)
                handle_packet(pkt)
            end
        end
    end
end

-- tratar testes de conexão concluídos
---@param pass boolean
function check.conn_test_callback(pass)
    local cfg = self.settings

    if self.checking_wl then
        if not pass then
            self.self_check_msg(nil, false, "certifique-se de que seu supervisor está em execução, escutando na interface sem fio, seus canais estão corretos, os alcances confiáveis estão definidos corretamente (se ativados), as chaves da instalação coincidem (se definidas) e, se estiver usando modems sem fio em vez de modems ender, que seus dispositivos estão próximos na mesma dimensão")
        end

        if cfg.WiredModem and self.wd_modem then
            self.checking_wl = false
            self.self_check_msg("> verif. conexão cabeada do supervisor...")

            comms.set_trusted_range(0)

            self.nic = network.nic(self.wd_modem)

            self.nic.closeAll()
            self.nic.open(cfg.RTU_Channel)

            self.net_listen = true

            send_sv(MGMT_TYPE.ESTABLISH, { comms.version, comms.CONN_TEST_FWV, DEVICE_TYPE.RTU, {} })

            tcd.dispatch_unique(8, handle_timeout)
        else
            if self.self_check_pass then check_complete() end
            self.run_test_btn.enable()
        end
    else
        if not pass then
            self.self_check_msg(nil, false, "certifique-se de que seu supervisor está em execução, escutando na interface cabeada, o cabo está intacto e seus canais estão corretos")
        end

        if self.self_check_pass then check_complete() end
        self.run_test_btn.enable()
    end
end

return check
