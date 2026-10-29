local comms       = require("scada-common.comms")
local network     = require("scada-common.network")
local ppm         = require("scada-common.ppm")
local tcd         = require("scada-common.tcd")
local util        = require("scada-common.util")

local core        = require("graphics.core")

local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local PushButton  = require("graphics.elements.controls.PushButton")

local NumberField = require("graphics.elements.form.NumberField")

local tri = util.trinary

local cpair = core.cpair

local PROTOCOL = comms.PROTOCOL
local DEVICE_TYPE = comms.DEVICE_TYPE
local ESTABLISH_ACK = comms.ESTABLISH_ACK
local MGMT_TYPE = comms.MGMT_TYPE

local self = {
    nic = nil,            ---@type nic
    net_listen = false,
    sv_addr = comms.BROADCAST,
    sv_seq_num = util.time_ms() * 10,
    show_sv_cfg = nil,    ---@type function

    sv_conn_button = nil, ---@type PushButton
    sv_conn_status = nil, ---@type TextBox
    sv_conn_detail = nil, ---@type TextBox
    sv_next = nil,        ---@type PushButton
    sv_skip = nil,        ---@type PushButton

    tool_ctl = nil,       ---@type _crd_cfg_tool_ctl
    tmp_cfg = nil         ---@type crd_config
}

-- verifica se um valor é um inteiro dentro de um intervalo (inclusivo)
---@param x any
---@param min integer
---@param max integer
local function is_int_min_max(x, min, max) return util.is_int(x) and x >= min and x <= max end

-- envia um pacote de gerenciamento ao supervisor
---@param msg_type MGMT_TYPE
---@param msg table
local function send_sv(msg_type, msg)
    local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

    mgmt.make(msg_type, msg)
    frame.make(self.sv_addr, self.sv_seq_num, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

    self.nic.transmit(self.tmp_cfg.SVR_Channel, self.tmp_cfg.CRD_Channel, frame)
    self.sv_seq_num = self.sv_seq_num + 1
end

-- processa uma mensagem de estabelecimento do supervisor
---@param packet mgmt_packet
local function handle_packet(packet)
    local error_msg = nil

    if packet.scada_frame.local_channel() ~= self.tmp_cfg.CRD_Channel then
        error_msg = "Erro: canal de recepção desconhecido."
    elseif packet.scada_frame.remote_channel() == self.tmp_cfg.SVR_Channel and packet.scada_frame.protocol() == PROTOCOL.SCADA_MGMT then
        if packet.type == MGMT_TYPE.ESTABLISH then
            if packet.length == 2 then
                local est_ack = packet.data[1]
                local config = packet.data[2]

                if est_ack == ESTABLISH_ACK.ALLOW then
                    if type(config) == "table" and #config == 5 then
                        local cool_conf = config[2] ---@type sv_cooling_conf

                        local count_ok = is_int_min_max(config[1], 1, 4)
                        local cool_ok  = type(cool_conf) == "table" and type(cool_conf.r_cool) == "table" and #cool_conf.r_cool == config[1]


                        if count_ok and cool_ok then
                            self.tmp_cfg.UnitCount = config[1]

                            self.tool_ctl.com_waste = config[4]
                            self.tool_ctl.tank_list = cool_conf.fac_tank_list
                            self.tool_ctl.tank_mode = cool_conf.fac_tank_mode

                            self.tool_ctl.unit_bt_cnt = {}

                            for i = 1, self.tmp_cfg.UnitCount do
                                local num_b = cool_conf.r_cool[i].BoilerCount
                                local num_t = cool_conf.r_cool[i].TurbineCount

                                self.tool_ctl.unit_bt_cnt[i] = { num_b, num_t }

                                cool_ok = cool_ok and is_int_min_max(num_b, 0, 2) and is_int_min_max(num_t, 1, 3)
                            end
                        end

                        if not count_ok then
                            error_msg = "Erro: qtd. de unidades do supervisor fora da faixa."
                        elseif not cool_ok then
                            error_msg = "Erro: config. de resfriamento do supervisor malformada."
                            self.tool_ctl.unit_bt_cnt = nil
                        end

                        self.sv_addr = packet.scada_frame.src_addr()
                        send_sv(MGMT_TYPE.CLOSE, {})
                    else
                        error_msg = "Erro: config. de resfriamento inválida do supervisor."
                    end
                else
                    error_msg = "Erro: tamanho inválido de resposta do supervisor."
                end
            elseif packet.length == 1 then
                local est_ack = packet.data[1]

                if est_ack == ESTABLISH_ACK.DENY then
                    error_msg = "Erro: conexão negada pelo supervisor."
                elseif est_ack == ESTABLISH_ACK.COLLISION then
                    error_msg = "Erro: um coordenador já está conectado. Tente novamente."
                elseif est_ack == ESTABLISH_ACK.BAD_VERSION then
                    error_msg = "Erro: versão de comunic. do coordenador incompatível."
                else
                    error_msg = "Erro: resposta inválida do supervisor."
                end
            else
                error_msg = "Erro: tamanho inválido de resposta do supervisor."
            end
        else
            error_msg = "Erro: sem resposta de estabelecimento do supervisor."
        end
    end

    self.net_listen = false

    if error_msg then
        self.sv_conn_status.set_value("")
        self.sv_conn_detail.set_value(error_msg)
        self.sv_conn_button.enable()
    else
        self.sv_conn_status.set_value("Conectado!")
        self.sv_conn_detail.set_value("Dados recebidos com sucesso, aperte 'Avançar'.")
        self.sv_skip.hide()
        self.sv_next.show()
    end
end

-- processa falha na conexão ao supervisor
local function handle_timeout()
    self.net_listen = false
    self.sv_conn_button.enable()
    self.sv_conn_status.set_value("Tempo esgotado.")
    self.sv_conn_detail.set_value("O supervisor não respondeu. Verifique se o app está ativo nele.")
end

-- tenta uma conexão ao supervisor para obter informações de resfriamento
---@param cfg crd_config current configuration for modem settings
local function sv_connect(cfg)
    self.sv_conn_button.disable()
    self.sv_conn_detail.set_value("")

    local modem = nil

    if cfg.WirelessModem then
        modem = ppm.get_wireless_modem()

        if cfg.WiredModem then
            local wd_modem = ppm.get_modem(cfg.WiredModem)

            if cfg.PreferWireless then
                if not modem then
                    modem = wd_modem
                end
            else
                if wd_modem then
                    modem = wd_modem
                end
            end
        end
    elseif cfg.WiredModem then
        modem = ppm.get_modem(cfg.WiredModem)
    end

    if modem == nil then
        self.sv_conn_status.set_value("Modem(ns) configurado(s) não encontrado(s).")
    else
        self.sv_conn_status.set_value("Modem encontrado, conectando...")

        self.nic = network.nic(modem)
        self.nic.open(self.tmp_cfg.CRD_Channel)

        self.sv_addr = comms.BROADCAST
        self.net_listen = true

        send_sv(MGMT_TYPE.ESTABLISH, { comms.version, "0.0.0", DEVICE_TYPE.CRD })

        tcd.dispatch_unique(8, handle_timeout)
    end
end

local facility = {}

-- cria a visão de configuração da instalação
---@param tool_ctl _crd_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ crd_config, crd_config, crd_config, { [1]: string, [2]: string, [3]: any }[], function ]
---@param fac_cfg Div
---@param style { [string]: cpair }
---@return MultiPane fac_pane
function facility.create(tool_ctl, main_pane, cfg_sys, fac_cfg, style)
    local _, ini_cfg, tmp_cfg, _, _ = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]

    self.tmp_cfg = tmp_cfg
    self.tool_ctl = tool_ctl

    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    --#region Facility

    local fac_c_1 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_2 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_3 = Div{parent=fac_cfg,x=2,y=4,width=49}

    local fac_pane = MultiPane{parent=fac_cfg,y=4,panes={fac_c_1,fac_c_2,fac_c_3}}

    TextBox{parent=fac_cfg,y=2,text=" Configuração da Instalação",fg_bg=cpair(colors.black,colors.yellow)}

    TextBox{parent=fac_c_1,y=1,height=3,text="Esta ferramenta pode conectar ao computador Supervisor para carregar propriedades da instalação e ajudar a configurar monitores."}
    TextBox{parent=fac_c_1,y=5,height=3,text="O aplicativo de inicialização do Supervisor deve estar em execução e configurado no Supervisor antes de conectar aqui."}

    self.sv_conn_status = TextBox{parent=fac_c_1,x=12,y=9,text=""}
    self.sv_conn_detail = TextBox{parent=fac_c_1,y=11,height=2,text=""}

    self.sv_conn_button = PushButton{parent=fac_c_1,y=9,text="Conectar",min_width=10,callback=function()sv_connect(tmp_cfg)end,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    local function sv_skip()
        tcd.abort(handle_timeout)
        tool_ctl.unit_bt_cnt = nil
        self.net_listen = false
        fac_pane.set_value(2)
    end

    local function sv_next()
        self.show_sv_cfg()
        tool_ctl.update_mon_reqs()
        fac_pane.set_value(3)
    end

    PushButton{parent=fac_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    self.sv_skip = PushButton{parent=fac_c_1,x=43,y=14,text="Pular \x1a",callback=sv_skip,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    self.sv_next = PushButton{parent=fac_c_1,x=41,y=14,text="Avançar \x1a",callback=sv_next,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,hidden=true}

    TextBox{parent=fac_c_2,y=1,height=3,text="Insira a quantidade de reatores que você possui, também chamados de unidades de reator ou 'unidades'. O máximo suportado é 4."}
    tool_ctl.num_units = NumberField{parent=fac_c_2,y=5,width=5,max_chars=2,default=ini_cfg.UnitCount,min=1,max=4,fg_bg=bw_fg_bg}
    TextBox{parent=fac_c_2,x=7,y=5,text="reatores"}
    TextBox{parent=fac_c_2,y=7,height=3,text="Isso definirá quantos monitores você precisa. Se não corresponder ao número de unidades do supervisor, não conectará.",fg_bg=cpair(colors.yellow,colors._INHERIT)}
    TextBox{parent=fac_c_2,y=10,height=3,text="Como você pulou a sinc. do supervisor, a altura mín. do monitor principal não é exata e está marcada com * na próxima página.",fg_bg=g_lg_fg_bg}

    local nu_error = TextBox{parent=fac_c_2,x=9,y=14,width=31,text="Defina o número de reatores.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_num_units()
        local count = tonumber(tool_ctl.num_units.get_value())
        if count ~= nil and count > 0 and count < 5 then
            nu_error.hide(true)
            tmp_cfg.UnitCount = count
            tool_ctl.update_mon_reqs()
            main_pane.set_value(4)
        else nu_error.show() end
    end

    PushButton{parent=fac_c_2,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_2,x=41,y=14,text="Avançar \x1a",callback=submit_num_units,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=fac_c_3,y=1,height=2,text="A seguinte configuração da instalação foi obtida do computador supervisor."}

    local fac_config_list = ListBox{parent=fac_c_3,y=4,height=9,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    PushButton{parent=fac_c_3,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_3,x=41,y=14,text="Avançar \x1a",callback=function()main_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Tool and Helper Functions

    tool_ctl.is_int_min_max = is_int_min_max

    -- redefine a tela de conexão para uma nova tentativa
    function tool_ctl.init_sv_connect_ui()
        self.sv_next.hide()
        self.sv_skip.disable()
        self.sv_skip.show()
        self.sv_conn_button.enable()
        self.sv_conn_status.set_value("")
        self.sv_conn_detail.set_value("")

        -- o usuário precisa aguardar alguns segundos, incentivando-o a conectar
        tcd.dispatch_unique(2, function () self.sv_skip.enable() end)
    end

    -- mostra a contagem de unidades e dados de configuração de resfriamento da instalação
    function self.show_sv_cfg()
        local conf = tool_ctl.unit_bt_cnt
        fac_config_list.remove_all()

        local str = util.sprintf("A instalação possui %d unidade%s de reator:", #conf, tri(#conf==1,"","s"))
        TextBox{parent=fac_config_list,text=str,fg_bg=cpair(colors.gray,colors.white)}

        for i = 1, #conf do
            local num_b, num_t = conf[i][1], conf[i][2]
            str = util.sprintf("\x07 Unidade %d tem %d caldeira%s e %d turbina%s", i, num_b, tri(num_b == 1, "", "s"), num_t, tri(num_t == 1, "", "s"))
            TextBox{parent=fac_config_list,text=str,fg_bg=cpair(colors.gray,colors.white)}
        end
    end

    --#endregion

    return fac_pane
end

-- processa mensagens recebidas do modem
---@param side string
---@param sender integer
---@param reply_to integer
---@param message any
---@param distance integer
function facility.receive_sv(side, sender, reply_to, message, distance)
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

return facility
