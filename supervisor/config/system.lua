local log         = require("scada-common.log")
local ppm         = require("scada-common.ppm")
local types       = require("scada-common.types")
local util        = require("scada-common.util")

local facility    = require("supervisor.config.facility")
local mekanism    = require("supervisor.config.mekanism")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local Checkbox    = require("graphics.elements.controls.Checkbox")
local PushButton  = require("graphics.elements.controls.PushButton")
local Radio2D     = require("graphics.elements.controls.Radio2D")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")
local TextField   = require("graphics.elements.form.TextField")

local IndLight    = require("graphics.elements.indicators.IndicatorLight")

local tri = util.trinary

local cpair = core.cpair

local LISTEN_MODE = types.LISTEN_MODE

local RIGHT = core.ALIGN.RIGHT

local self = {
    importing_legacy = false,

    update_net_cfg = nil,   ---@type function
    show_auth_key = nil,    ---@type function

    pkt_test = nil,         ---@type Checkbox
    pkt_chan = nil,         ---@type NumberField
    pkt_timeout = nil,      ---@type NumberField
    show_key_btn = nil,     ---@type PushButton
    auth_key_textbox = nil, ---@type TextBox

    auth_key_value = ""
}

local system = {}

-- criar a visualização de configuração do sistema
---@param tool_ctl _svr_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ svr_config, svr_config, svr_config, { [1]: string, [2]: string, [3]: any }[], function ]
---@param divs Div[]
---@param fac_pane MultiPane
---@param mek_pane MultiPane
---@param style { [string]: cpair }
---@param startup function
---@param exit function
function system.create(tool_ctl, main_pane, cfg_sys, divs, fac_pane, mek_pane, style, startup, exit)
    local settings_cfg, ini_cfg, tmp_cfg, fields, load_settings = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]
    local net_cfg, log_cfg, clr_cfg, summary, import_err = divs[1], divs[2], divs[3], divs[4], divs[5]

    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    --#region Rede

    local net_c_1 = Div{parent=net_cfg,x=2,y=4,width=49}
    local net_c_2 = Div{parent=net_cfg,x=2,y=4,width=49}
    local net_c_3 = Div{parent=net_cfg,x=2,y=4,width=49}
    local net_c_4 = Div{parent=net_cfg,x=2,y=4,width=49}
    local net_c_5 = Div{parent=net_cfg,x=2,y=4,width=49}
    local net_c_6 = Div{parent=net_cfg,x=2,y=4,width=49}

    local net_pane = MultiPane{parent=net_cfg,y=4,panes={net_c_1,net_c_2,net_c_3,net_c_4,net_c_5,net_c_6}}

    TextBox{parent=net_cfg,y=2,text=" Configuração de Rede",fg_bg=cpair(colors.black,colors.lightBlue)}

    TextBox{parent=net_c_1,y=1,text="Selecione a(s) interface(s) de rede."}

    local function on_wired_change(_) tool_ctl.gen_modem_list() end

    local wireless = Checkbox{parent=net_c_1,y=3,label="Modem Sem Fio/Ender",default=ini_cfg.WirelessModem,box_fg_bg=cpair(colors.lightBlue,colors.black)}
    TextBox{parent=net_c_1,x=24,y=3,text="(necessário p/ Pocket)",fg_bg=g_lg_fg_bg}
    local wired = Checkbox{parent=net_c_1,y=5,label="Modem Cabeado",default=ini_cfg.WiredModem~=false,box_fg_bg=cpair(colors.lightBlue,colors.black),callback=on_wired_change}
    TextBox{parent=net_c_1,x=3,y=6,text="este DEVE conectar APENAS a computadores SCADA",fg_bg=cpair(colors.red,colors._INHERIT)}
    TextBox{parent=net_c_1,x=3,y=7,text="conectá-lo a periféricos causará problemas",fg_bg=g_lg_fg_bg}
    local modem_list = ListBox{parent=net_c_1,y=8,height=5,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local modem_err = TextBox{parent=net_c_1,x=10,y=14,width=31,text="",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_interfaces()
        tmp_cfg.WirelessModem = wireless.get_value()

        if not wired.get_value() then
            tmp_cfg.WiredModem = false
            tool_ctl.gen_modem_list()
        end

        if not (wired.get_value() or wireless.get_value()) then
            modem_err.set_value("Selecione um tipo de modem.")
            modem_err.show()
        elseif wired.get_value() and type(tmp_cfg.WiredModem) ~= "string" then
            modem_err.set_value("Selecione um modem cabeado.")
            modem_err.show()
        else
            self.update_net_cfg()
            net_pane.set_value(2)
            modem_err.hide(true)
        end
    end

    PushButton{parent=net_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(3)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_1,x=42,y=14,text="Avançar \x1a",callback=submit_interfaces,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_2,y=1,text="Atribua interfaces de conexão se selecionou várias interfaces de rede."}
    TextBox{parent=net_c_2,y=4,text="CLP Reator\nGateway RTU\nCoordenador",fg_bg=g_lg_fg_bg}
    local opts = { "Sem Fio", "Cabeado", "Ambos" }
    local plc_listen = Radio2D{parent=net_c_2,x=14,y=4,rows=1,columns=3,default=ini_cfg.PLC_Listen,options=opts,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lightBlue,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}
    local rtu_listen = Radio2D{parent=net_c_2,x=14,rows=1,columns=3,default=ini_cfg.RTU_Listen,options=opts,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lightBlue,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}
    local crd_listen = Radio2D{parent=net_c_2,x=14,rows=1,columns=3,default=ini_cfg.CRD_Listen,options=opts,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lightBlue,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}

    local function on_pocket_en(en)
        if not en then
            self.pkt_test.set_value(false)
            self.pkt_test.disable()
        else self.pkt_test.enable() end
    end

    TextBox{parent=net_c_2,y=8,text="Com um modem sem fio, configure o acesso Pocket."}
    local pkt_en = Checkbox{parent=net_c_2,y=10,label="Ativar Acesso Pocket",default=ini_cfg.PocketEnabled,callback=on_pocket_en,box_fg_bg=cpair(colors.lightBlue,colors.black),disable_fg_bg=g_lg_fg_bg}
    self.pkt_test = Checkbox{parent=net_c_2,label="Ativar Teste Remoto do Sistema via Pocket",default=ini_cfg.PocketTest,box_fg_bg=cpair(colors.lightBlue,colors.black),disable_fg_bg=g_lg_fg_bg}
    TextBox{parent=net_c_2,x=3,text="Isso permite tocar sons de alarme remotamente.",fg_bg=g_lg_fg_bg}

    local function submit_net_cfg_opts()
        if tmp_cfg.WirelessModem and tmp_cfg.WiredModem then
            tmp_cfg.PLC_Listen = plc_listen.get_value()
            tmp_cfg.RTU_Listen = rtu_listen.get_value()
            tmp_cfg.CRD_Listen = crd_listen.get_value()
        else
            if tmp_cfg.WiredModem then
                tmp_cfg.PLC_Listen = LISTEN_MODE.WIRED
                tmp_cfg.RTU_Listen = LISTEN_MODE.WIRED
                tmp_cfg.CRD_Listen = LISTEN_MODE.WIRED
            else
                tmp_cfg.PLC_Listen = LISTEN_MODE.WIRELESS
                tmp_cfg.RTU_Listen = LISTEN_MODE.WIRELESS
                tmp_cfg.CRD_Listen = LISTEN_MODE.WIRELESS
            end
        end

        if tmp_cfg.WirelessModem then
            tmp_cfg.PocketEnabled = pkt_en.get_value()
            tmp_cfg.PocketTest = self.pkt_test.get_value()
        else
            tmp_cfg.PocketEnabled = false
            tmp_cfg.PocketTest = false
        end

        if tmp_cfg.PocketEnabled then
            self.pkt_chan.enable()
            self.pkt_timeout.enable()
        else
            self.pkt_chan.disable()
            self.pkt_timeout.disable()
        end

        net_pane.set_value(3)
    end

    PushButton{parent=net_c_2,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_2,x=42,y=14,text="Avançar \x1a",callback=submit_net_cfg_opts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_3,y=1,text="Defina os canais de rede abaixo."}
    TextBox{parent=net_c_3,y=3,height=4,text="Cada um dos 5 canais deve ser o mesmo para cada dispositivo nesta rede SCADA. Em servidores multiplayer, recomenda-se não usar os canais padrão.",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=8,width=18,text="Canal Supervisor"}
    local svr_chan = NumberField{parent=net_c_3,x=21,y=8,width=7,default=ini_cfg.SVR_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=8,height=4,text="[SVR_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=9,width=11,text="Canal CLP"}
    local plc_chan = NumberField{parent=net_c_3,x=21,y=9,width=7,default=ini_cfg.PLC_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=9,height=4,text="[PLC_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=10,width=19,text="Canal Gateway RTU"}
    local rtu_chan = NumberField{parent=net_c_3,x=21,y=10,width=7,default=ini_cfg.RTU_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=10,height=4,text="[RTU_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=11,width=19,text="Canal Coordenador"}
    local crd_chan = NumberField{parent=net_c_3,x=21,y=11,width=7,default=ini_cfg.CRD_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=11,height=4,text="[CRD_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=12,width=14,text="Canal Pocket"}
    self.pkt_chan = NumberField{parent=net_c_3,x=21,y=12,width=7,default=ini_cfg.PKT_Channel,min=1,max=65535,fg_bg=bw_fg_bg,dis_fg_bg=cpair(colors.lightGray,colors.white)}
    TextBox{parent=net_c_3,x=29,y=12,height=4,text="[PKT_CHANNEL]",fg_bg=g_lg_fg_bg}

    local chan_err = TextBox{parent=net_c_3,x=10,y=14,width=31,text="Defina todos os canais.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_channels()
        local svr_c, plc_c, rtu_c = tonumber(svr_chan.get_value()), tonumber(plc_chan.get_value()), tonumber(rtu_chan.get_value())
        local crd_c, pkt_c = tonumber(crd_chan.get_value()), tonumber(self.pkt_chan.get_value())

        if not tmp_cfg.PocketEnabled then pkt_c = tmp_cfg.PKT_Channel or 16244 end

        if svr_c ~= nil and plc_c ~= nil and rtu_c ~= nil and crd_c ~= nil and pkt_c ~= nil then
            tmp_cfg.SVR_Channel, tmp_cfg.PLC_Channel, tmp_cfg.RTU_Channel = svr_c, plc_c, rtu_c
            tmp_cfg.CRD_Channel, tmp_cfg.PKT_Channel = crd_c, pkt_c
            net_pane.set_value(4)
            chan_err.hide(true)
        else chan_err.show() end
    end

    PushButton{parent=net_c_3,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_3,x=42,y=14,text="Avançar \x1a",callback=submit_channels,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_4,y=1,text="Defina os tempos limite de conexão abaixo."}
    TextBox{parent=net_c_4,y=3,height=4,text="Geralmente não é necessário alterá-los. Em servidores lentos, tente aumentá-los para esperar mais antes de assumir uma desconexão. O padrão para todos é 5 segundos.",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_4,y=8,width=16,text="Tempo Limite CLP"}
    local plc_timeout = NumberField{parent=net_c_4,x=21,y=8,width=7,default=ini_cfg.PLC_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg}

    TextBox{parent=net_c_4,y=9,width=20,text="Tempo Lim. Gate. RTU"}
    local rtu_timeout = NumberField{parent=net_c_4,x=21,y=9,width=7,default=ini_cfg.RTU_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg}

    TextBox{parent=net_c_4,y=10,width=20,text="Tempo Lim. Coord."}
    local crd_timeout = NumberField{parent=net_c_4,x=21,y=10,width=7,default=ini_cfg.CRD_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg}

    TextBox{parent=net_c_4,y=11,width=19,text="Tempo Limite Pocket"}
    self.pkt_timeout = NumberField{parent=net_c_4,x=21,y=11,width=7,default=ini_cfg.PKT_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg,dis_fg_bg=cpair(colors.lightGray,colors.white)}

    TextBox{parent=net_c_4,x=29,y=8,height=4,width=8,text="segundos\nsegundos\nsegundos\nsegundos",fg_bg=g_lg_fg_bg}

    local ct_err = TextBox{parent=net_c_4,x=10,y=14,width=31,text="Defina todos os tempos limite.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_timeouts()
        local plc_cto, rtu_cto, crd_cto, pkt_cto = tonumber(plc_timeout.get_value()), tonumber(rtu_timeout.get_value()), tonumber(crd_timeout.get_value()), tonumber(self.pkt_timeout.get_value())

        if not tmp_cfg.PocketEnabled then pkt_cto = tmp_cfg.PKT_Timeout or 5 end

        if plc_cto ~= nil and rtu_cto ~= nil and crd_cto ~= nil and pkt_cto ~= nil then
            tmp_cfg.PLC_Timeout, tmp_cfg.RTU_Timeout, tmp_cfg.CRD_Timeout, tmp_cfg.PKT_Timeout = plc_cto, rtu_cto, crd_cto, pkt_cto

            if tmp_cfg.WirelessModem then
                net_pane.set_value(5)
            else
                tmp_cfg.TrustedRange = 0
                tmp_cfg.AuthKey = ""
                main_pane.set_value(5)
            end

            ct_err.hide(true)
        else ct_err.show() end
    end

    PushButton{parent=net_c_4,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(3)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_4,x=42,y=14,text="Avançar \x1a",callback=submit_timeouts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_5,y=1,text="Defina o alcance confiável sem fio abaixo."}
    TextBox{parent=net_c_5,y=3,height=3,text="Definir um valor maior que 0 impede conexões sem fio com dispositivos a essa distância (em blocos) em qualquer direção.",fg_bg=g_lg_fg_bg}
    TextBox{parent=net_c_5,y=7,height=2,text="Isso é opcional. Você pode desativar essa funcionalidade definindo o valor como 0.",fg_bg=g_lg_fg_bg}

    local range = NumberField{parent=net_c_5,y=10,width=10,default=ini_cfg.TrustedRange,min=0,max_chars=20,allow_decimal=true,fg_bg=bw_fg_bg}

    local tr_err = TextBox{parent=net_c_5,x=10,y=14,width=31,text="Defina o alcance confiável.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_tr()
        local range_val = tonumber(range.get_value())
        if range_val ~= nil then
            tmp_cfg.TrustedRange = range_val
            net_pane.set_value(6)
            tr_err.hide(true)
        else tr_err.show() end
    end

    PushButton{parent=net_c_5,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_5,x=42,y=14,text="Avançar \x1a",callback=submit_tr,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_6,y=1,height=2,text="Opcionalmente, defina a chave de autenticação da instalação abaixo. NÃO use uma de suas senhas."}
    TextBox{parent=net_c_6,y=4,height=6,text="Isso permite verificar se as mensagens são autênticas, voltado para segurança sem fio em servidores multiplayer. Todos os dispositivos na mesma rede sem fio DEVEM usar a mesma chave se algum tiver chave. Isso gera cálculos extras (pode causar lentidão).",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_6,y=11,text="Chave de Autent. (Apenas Sem Fio)"}
    local key, _ = TextField{parent=net_c_6,y=12,max_len=64,value=ini_cfg.AuthKey,width=32,height=1,fg_bg=bw_fg_bg}

    local function censor_key(enable) key.censor(tri(enable, "*", nil)) end

    local hide_key = Checkbox{parent=net_c_6,x=34,y=12,label="Ocultar",box_fg_bg=cpair(colors.lightBlue,colors.black),callback=censor_key}

    hide_key.set_value(true)
    censor_key(true)

    local key_err = TextBox{parent=net_c_6,x=10,y=14,width=31,text="Mínimo de 8 caracteres.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_auth()
        local v = key.get_value()
        if string.len(v) == 0 or string.len(v) >= 8 then
            tmp_cfg.AuthKey = key.get_value()
            main_pane.set_value(5)
            key_err.hide(true)
        else key_err.show() end
    end

    PushButton{parent=net_c_6,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(5)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_6,x=42,y=14,text="Avançar \x1a",callback=submit_auth,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Registro de Log

    local log_c_1 = Div{parent=log_cfg,x=2,y=4,width=49}

    TextBox{parent=log_cfg,y=2,text=" Configuração de Log",fg_bg=cpair(colors.black,colors.pink)}

    TextBox{parent=log_c_1,y=1,text="Configure o registro de log abaixo."}

    TextBox{parent=log_c_1,y=3,text="Modo do Arquivo de Log"}
    local mode = RadioButton{parent=log_c_1,y=4,default=ini_cfg.LogMode+1,options={"Anexar ao Iniciar","Substituir ao Iniciar"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.pink}

    TextBox{parent=log_c_1,y=7,text="Caminho do Arquivo de Log"}
    local path = TextField{parent=log_c_1,y=8,width=49,height=1,value=ini_cfg.LogPath,max_len=128,fg_bg=bw_fg_bg}

    local en_dbg = Checkbox{parent=log_c_1,y=10,default=ini_cfg.LogDebug,label="Ativar Registro de Mensagens de Depuração",box_fg_bg=cpair(colors.pink,colors.black)}
    TextBox{parent=log_c_1,x=3,y=11,height=2,text="Isso resulta em arquivos de log muito maiores. É melhor usar apenas quando houver um problema.",fg_bg=g_lg_fg_bg}

    local path_err = TextBox{parent=log_c_1,x=10,y=14,width=31,text="Forneça um caminho de log.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_log()
        if path.get_value() ~= "" then
            path_err.hide(true)
            tmp_cfg.LogMode = mode.get_value() - 1
            tmp_cfg.LogPath = path.get_value()
            tmp_cfg.LogDebug = en_dbg.get_value()
            tool_ctl.color_apply.hide(true)
            tool_ctl.color_next.show()
            main_pane.set_value(6)
        else path_err.show() end
    end

    PushButton{parent=log_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=log_c_1,x=42,y=14,text="Avançar \x1a",callback=submit_log,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Opções de Cor

    local clr_c_1 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_2 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_3 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_4 = Div{parent=clr_cfg,x=2,y=4,width=49}

    local clr_pane = MultiPane{parent=clr_cfg,y=4,panes={clr_c_1,clr_c_2,clr_c_3,clr_c_4}}

    TextBox{parent=clr_cfg,y=2,text=" Configuração de Cor",fg_bg=cpair(colors.black,colors.magenta)}

    TextBox{parent=clr_c_1,y=1,height=2,text="Aqui você pode selecionar o tema de cores para o painel frontal."}
    TextBox{parent=clr_c_1,y=4,height=2,text="Clique em 'Acessibilidade' abaixo para acessar opções de auxílio a daltônicos.",fg_bg=g_lg_fg_bg}

    TextBox{parent=clr_c_1,y=7,text="Tema do Painel Frontal"}
    local fp_theme = RadioButton{parent=clr_c_1,y=8,default=ini_cfg.FrontPanelTheme,options=themes.FP_THEME_NAMES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.magenta}

    TextBox{parent=clr_c_2,y=1,height=6,text="Este sistema usa muitas cores para distinguir o que está bom ou não, com alguns indicadores usando várias cores. Ao selecionar um modo abaixo, os indicadores mudarão conforme mostrado. Em modos não padrão, indicadores com mais de duas cores serão divididos."}

    TextBox{parent=clr_c_2,x=21,y=7,text="Prévia"}
    local _ = IndLight{parent=clr_c_2,x=21,y=8,label="Bom",colors=cpair(colors.black,colors.green)}
    _ = IndLight{parent=clr_c_2,x=21,y=9,label="Aviso",colors=cpair(colors.black,colors.yellow)}
    _ = IndLight{parent=clr_c_2,x=21,y=10,label="Ruim",colors=cpair(colors.black,colors.red)}
    local b_off = IndLight{parent=clr_c_2,x=21,y=11,label="Desl.",colors=cpair(colors.black,colors.black),hidden=true}
    local g_off = IndLight{parent=clr_c_2,x=21,y=11,label="Desl.",colors=cpair(colors.gray,colors.gray),hidden=true}

    local function recolor(value)
        local c = themes.smooth_stone.color_modes[value]

        if value == themes.COLOR_MODE.STANDARD or value == themes.COLOR_MODE.BLUE_IND then
            b_off.hide()
            g_off.show()
        else
            g_off.hide()
            b_off.show()
        end

        if #c == 0 then
            for i = 1, #style.colors do term.setPaletteColor(style.colors[i].c, style.colors[i].hex) end
        else
            term.setPaletteColor(colors.green, c[1].hex)
            term.setPaletteColor(colors.yellow, c[2].hex)
            term.setPaletteColor(colors.red, c[3].hex)
        end
    end

    TextBox{parent=clr_c_2,y=7,width=11,text="Modo de Cor"}
    local c_mode = RadioButton{parent=clr_c_2,y=8,default=ini_cfg.ColorMode,options=themes.COLOR_MODE_NAMES,callback=recolor,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.magenta}

    TextBox{parent=clr_c_2,x=21,y=13,height=2,width=18,text="Nota: a cor exata varia por tema.",fg_bg=g_lg_fg_bg}

    PushButton{parent=clr_c_2,x=42,y=14,min_width=8,text="Pronto",callback=function()clr_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    local function back_from_colors()
        main_pane.set_value(tri(tool_ctl.jumped_to_color, 1, 4))
        tool_ctl.jumped_to_color = false
        recolor(1)
    end

    local function show_access()
        clr_pane.set_value(2)
        recolor(c_mode.get_value())
    end

    local function submit_colors()
        tmp_cfg.FrontPanelTheme = fp_theme.get_value()
        tmp_cfg.ColorMode = c_mode.get_value()

        if tool_ctl.jumped_to_color then
            settings.set("FrontPanelTheme", tmp_cfg.FrontPanelTheme)
            settings.set("ColorMode", tmp_cfg.ColorMode)

            if settings.save("/supervisor.settings") then
                load_settings(settings_cfg, true)
                load_settings(ini_cfg)
                clr_pane.set_value(3)
            else
                clr_pane.set_value(4)
            end
        else
            tool_ctl.gen_summary(tmp_cfg)
            tool_ctl.viewing_config = false
            self.importing_legacy = false
            tool_ctl.settings_apply.show()
            main_pane.set_value(7)
        end
    end

    PushButton{parent=clr_c_1,y=14,text="\x1b Voltar",callback=back_from_colors,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=clr_c_1,x=10,y=14,min_width=16,text="Acessibilidade",callback=show_access,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    tool_ctl.color_next = PushButton{parent=clr_c_1,x=42,y=14,text="Avançar \x1a",callback=submit_colors,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    tool_ctl.color_apply = PushButton{parent=clr_c_1,x=41,y=14,min_width=9,text="Aplicar",callback=submit_colors,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}

    tool_ctl.color_apply.hide(true)

    local function c_go_home()
        main_pane.set_value(1)
        clr_pane.set_value(1)
    end

    TextBox{parent=clr_c_3,y=1,text="Configurações salvas!"}
    PushButton{parent=clr_c_3,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
    PushButton{parent=clr_c_3,x=42,y=14,min_width=8,text="Início",callback=c_go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=clr_c_4,y=1,height=5,text="Falha ao salvar o arquivo de configurações.\n\nPode não haver espaço suficiente para a modificação ou as permissões de arquivo do servidor podem estar negando gravações."}
    PushButton{parent=clr_c_4,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
    PushButton{parent=clr_c_4,x=42,y=14,min_width=8,text="Início",callback=c_go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Resumo e Salvamento

    local sum_c_1 = Div{parent=summary,x=2,y=4,width=49}
    local sum_c_2 = Div{parent=summary,x=2,y=4,width=49}
    local sum_c_3 = Div{parent=summary,x=2,y=4,width=49}
    local sum_c_4 = Div{parent=summary,x=2,y=4,width=49}

    local sum_pane = MultiPane{parent=summary,y=4,panes={sum_c_1,sum_c_2,sum_c_3,sum_c_4}}

    TextBox{parent=summary,y=2,text=" Resumo",fg_bg=cpair(colors.black,colors.green)}

    local setting_list = ListBox{parent=sum_c_1,y=1,height=12,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local function back_from_settings()
        if tool_ctl.viewing_config or self.importing_legacy then
            main_pane.set_value(1)
            tool_ctl.viewing_config = false
            self.importing_legacy = false
            tool_ctl.settings_apply.show()
        else
            main_pane.set_value(6)
        end
    end

    ---@param element graphics_element
    ---@param data any
    local function try_set(element, data)
        if data ~= nil then element.set_value(data) end
    end

    local function save_and_continue()
        for _, field in ipairs(fields) do
            local k, v = field[1], tmp_cfg[field[1]]
            if v == nil then settings.unset(k) else settings.set(k, v) end
        end

        if settings.save("/supervisor.settings") then
            load_settings(settings_cfg, true)
            load_settings(ini_cfg)

            try_set(tool_ctl.num_units, ini_cfg.UnitCount)
            try_set(tool_ctl.tank_mode, ini_cfg.FacilityTankMode)
            try_set(wireless, ini_cfg.WirelessModem)
            try_set(wired, ini_cfg.WiredModem ~= false)
            try_set(plc_listen, ini_cfg.PLC_Listen)
            try_set(rtu_listen, ini_cfg.RTU_Listen)
            try_set(crd_listen, ini_cfg.CRD_Listen)
            try_set(pkt_en, ini_cfg.PocketEnabled)
            try_set(self.pkt_test, ini_cfg.PocketTest)
            try_set(svr_chan, ini_cfg.SVR_Channel)
            try_set(plc_chan, ini_cfg.PLC_Channel)
            try_set(rtu_chan, ini_cfg.RTU_Channel)
            try_set(crd_chan, ini_cfg.CRD_Channel)
            try_set(self.pkt_chan, ini_cfg.PKT_Channel)
            try_set(plc_timeout, ini_cfg.PLC_Timeout)
            try_set(rtu_timeout, ini_cfg.RTU_Timeout)
            try_set(crd_timeout, ini_cfg.CRD_Timeout)
            try_set(self.pkt_timeout, ini_cfg.PKT_Timeout)
            try_set(range, ini_cfg.TrustedRange)
            try_set(key, ini_cfg.AuthKey)
            try_set(mode, ini_cfg.LogMode)
            try_set(path, ini_cfg.LogPath)
            try_set(en_dbg, ini_cfg.LogDebug)
            try_set(fp_theme, ini_cfg.FrontPanelTheme)
            try_set(c_mode, ini_cfg.ColorMode)

            for i = 1, #ini_cfg.CoolingConfig do
                local cfg, elems = ini_cfg.CoolingConfig[i], tool_ctl.cooling_elems[i]
                try_set(elems.boilers, cfg.BoilerCount)
                try_set(elems.turbines, cfg.TurbineCount)
                try_set(elems.tank, cfg.TankConnection)
            end

            for i = 1, #ini_cfg.FacilityTankDefs do
                try_set(tool_ctl.tank_elems[i].tank_opt, ini_cfg.FacilityTankDefs[i])
            end

            for i = 1, #ini_cfg.AuxiliaryCoolant do
                try_set(tool_ctl.aux_cool_elems[i].enable, ini_cfg.AuxiliaryCoolant[i])
            end

            for i = 1, #ini_cfg.TankFluidTypes do
                if tool_ctl.tank_fluid_opts[i] then
                    if (ini_cfg.TankFluidTypes[i] > 0) then
                        tool_ctl.tank_fluid_opts[i].enable()
                        tool_ctl.tank_fluid_opts[i].set_value(ini_cfg.TankFluidTypes[i])
                    else
                        tool_ctl.tank_fluid_opts[i].disable()
                    end
                end
            end

            try_set(tool_ctl.en_fac_tanks, ini_cfg.FacilityTankMode > 0)
            try_set(tool_ctl.ext_idling, ini_cfg.ExtChargeIdling)
            try_set(tool_ctl.sna_stats, ini_cfg.UseSNAStatistics)
            try_set(tool_ctl.com_waste, ini_cfg.CombinedWaste)
            try_set(tool_ctl.ess_opt, ini_cfg.EnergyStorageSystem)

            for k, v in pairs(ini_cfg.MekanismConfig) do
                try_set(tool_ctl.custom_configs[k], v)
            end

            for i = 1, #mekanism.profiles do
                if ini_cfg.MekanismProfile == mekanism.profiles[i].name then
                    try_set(tool_ctl.mek_profile, i)
                    break
                end

                if i == #mekanism.profiles then
                    -- perfil personalizado
                    try_set(tool_ctl.mek_profile, #mekanism.profiles + 1)
                end
            end

            try_set(tool_ctl.waste_ratios[1], ini_cfg.MekanismWasteToPu[1])
            try_set(tool_ctl.waste_ratios[2], ini_cfg.MekanismWasteToPu[2])
            try_set(tool_ctl.waste_ratios[3], ini_cfg.MekanismWasteToPo[1])
            try_set(tool_ctl.waste_ratios[4], ini_cfg.MekanismWasteToPo[2])

            tool_ctl.view_cfg.enable()

            if self.importing_legacy then
                self.importing_legacy = false
                sum_pane.set_value(3)
            else
                sum_pane.set_value(2)
            end
        else
            sum_pane.set_value(4)
        end
    end

    PushButton{parent=sum_c_1,y=14,text="\x1b Voltar",callback=back_from_settings,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    self.show_key_btn = PushButton{parent=sum_c_1,x=10,y=14,min_width=17,text="Mostrar Chave",callback=function()self.show_auth_key()end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    tool_ctl.settings_apply = PushButton{parent=sum_c_1,x=41,y=14,min_width=9,text="Aplicar",callback=save_and_continue,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}

    TextBox{parent=sum_c_2,y=1,text="Configurações salvas!"}

    local function go_home()
        main_pane.set_value(1)
        fac_pane.set_value(1)
        mek_pane.set_value(1)
        net_pane.set_value(1)
        clr_pane.set_value(1)
        sum_pane.set_value(1)
    end

    PushButton{parent=sum_c_2,y=14,min_width=8,text="Início",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.ask_config then
        PushButton{parent=sum_c_2,x=34,y=14,min_width=16,text="Retomar Início",callback=exit,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg}
    else
        PushButton{parent=sum_c_2,x=41,y=14,min_width=9,text="Iniciar",callback=startup,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}
    end

    TextBox{parent=sum_c_3,y=1,height=2,text="O antigo arquivo config.lua será excluído agora e o configurador será encerrado."}

    local function delete_legacy()
        fs.delete("/supervisor/config.lua")
        exit()
    end

    PushButton{parent=sum_c_3,y=14,min_width=10,text="Cancelar",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=sum_c_3,x=44,y=14,min_width=6,text="OK",callback=delete_legacy,fg_bg=cpair(colors.black,colors.green),active_fg_bg=cpair(colors.white,colors.gray)}

    TextBox{parent=sum_c_4,y=1,height=5,text="Falha ao salvar o arquivo de configurações.\n\nPode não haver espaço suficiente para a modificação ou as permissões de arquivo do servidor podem estar negando gravações."}
    PushButton{parent=sum_c_4,y=14,min_width=8,text="Início",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=sum_c_4,x=44,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray)}

    --#endregion

    --#region Erro de Importação

    local i_err = Div{parent=import_err,x=2,y=4,width=49}

    TextBox{parent=import_err,y=2,text=" Erro de Importação",fg_bg=cpair(colors.black,colors.red)}
    TextBox{parent=i_err,y=1,text="Há um problema com o seu arquivo config.lua:"}

    local import_err_msg = TextBox{parent=i_err,y=3,height=6,text=""}

    PushButton{parent=i_err,y=14,min_width=8,text="Início",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=i_err,x=44,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray)}

    --#endregion

    --#region Funções da Ferramenta

    -- expor a chave de autenticação na página de resumo
    function self.show_auth_key()
        self.show_key_btn.disable()
        self.auth_key_textbox.set_value(self.auth_key_value)
    end

    -- atualizar as opções de configuração da interface de rede
    function self.update_net_cfg()
        if tmp_cfg.WirelessModem and tmp_cfg.WiredModem then
            plc_listen.enable()
            rtu_listen.enable()
            crd_listen.enable()
        else
            plc_listen.disable()
            rtu_listen.disable()
            crd_listen.disable()
        end

        if tmp_cfg.WirelessModem then
            pkt_en.enable()
            self.pkt_test.enable()
            self.pkt_chan.enable()
            self.pkt_timeout.enable()
        else
            pkt_en.set_value(false)
            self.pkt_test.set_value(false)
            pkt_en.disable()
            self.pkt_test.disable()
            self.pkt_chan.disable()
            self.pkt_timeout.disable()
        end
    end

    -- carregar um arquivo de configuração legado
    function tool_ctl.load_legacy()
        local config = require("supervisor.config")

        tmp_cfg.UnitCount = config.NUM_REACTORS

        if config.REACTOR_COOLING == nil or tmp_cfg.UnitCount ~= #config.REACTOR_COOLING then
            import_err_msg.set_value("O tamanho da tabela de configuração de resfriamento deve corresponder ao número de unidades.")
            main_pane.set_value(9)
            return
        end

        for i = 1, tmp_cfg.UnitCount do
            local cfg = config.REACTOR_COOLING[i]

            if type(cfg) ~= "table" then
                import_err_msg.set_value("A configuração de resfriamento para a unidade " .. i .. " deve ser uma tabela.")
                main_pane.set_value(9)
                return
            end

            tmp_cfg.CoolingConfig[i] = { BoilerCount = cfg.BOILERS or 0, TurbineCount = cfg.TURBINES or 1, TankConnection = cfg.TANK or false }
        end

        tmp_cfg.FacilityTankMode = config.FAC_TANK_MODE

        if not (util.is_int(tmp_cfg.FacilityTankMode) and tmp_cfg.FacilityTankMode >= 0 and tmp_cfg.FacilityTankMode <= 8) then
            import_err_msg.set_value("Modo de tanque inválido presente na config. FAC_TANK_MODE deve ser um número de 0 a 8.")
            main_pane.set_value(9)
            return
        end

        if config.FAC_TANK_MODE > 0 then
            if config.FAC_TANK_DEFS == nil or tmp_cfg.UnitCount ~= #config.FAC_TANK_DEFS then
                import_err_msg.set_value("O tamanho da tabela de definições de tanques da instalação deve corresponder ao número de unidades ao usar tanques da instalação.")
                main_pane.set_value(9)
                return
            end

            for i = 1, tmp_cfg.UnitCount do
                tmp_cfg.FacilityTankDefs[i] = config.FAC_TANK_DEFS[i]
            end
        else
            tmp_cfg.FacilityTankMode = 0
            tmp_cfg.FacilityTankDefs = {}

            -- no modo de tanque da instalação 0, configurar definições de tanque para corresponder à opção de tanque de unidade
            for i = 1, tmp_cfg.UnitCount do
                tmp_cfg.FacilityTankDefs[i] = tri(tmp_cfg.CoolingConfig[i].TankConnection, 1, 0)
            end
        end

        tmp_cfg.FacilityTankList, tmp_cfg.FacilityTankConns = facility.generate_tank_list_and_conns(tmp_cfg.FacilityTankMode, tmp_cfg.FacilityTankDefs)

        for i = 1, tmp_cfg.UnitCount do tmp_cfg.AuxiliaryCoolant[i] = false end
        for i = 1, tmp_cfg.FacilityTankList do tmp_cfg.TankFluidTypes[i] = types.COOLANT_TYPE.WATER end

        tmp_cfg.SVR_Channel = config.SVR_CHANNEL
        tmp_cfg.PLC_Channel = config.PLC_CHANNEL
        tmp_cfg.RTU_Channel = config.RTU_CHANNEL
        tmp_cfg.CRD_Channel = config.CRD_CHANNEL
        tmp_cfg.PKT_Channel = config.PKT_CHANNEL

        tmp_cfg.PLC_Timeout = config.PLC_TIMEOUT
        tmp_cfg.RTU_Timeout = config.RTU_TIMEOUT
        tmp_cfg.CRD_Timeout = config.CRD_TIMEOUT
        tmp_cfg.PKT_Timeout = config.PKT_TIMEOUT

        tmp_cfg.TrustedRange = config.TRUSTED_RANGE
        tmp_cfg.AuthKey = config.AUTH_KEY or ""
        tmp_cfg.LogMode = config.LOG_MODE
        tmp_cfg.LogPath = config.LOG_PATH
        tmp_cfg.LogDebug = config.LOG_DEBUG or false

        tool_ctl.gen_summary(tmp_cfg)
        sum_pane.set_value(1)
        main_pane.set_value(7)
        self.importing_legacy = true
    end

    -- gerar a lista de resumo
    ---@param cfg svr_config
    function tool_ctl.gen_summary(cfg)
        setting_list.remove_all()

        local alternate = false
        local inner_width = setting_list.get_width() - 1

        self.show_key_btn.enable()
        self.auth_key_value = cfg.AuthKey or "" -- para mostrar a chave de autenticação

        for i = 1, #fields do
            local f = fields[i]
            local height = 1
            local label_w = string.len(f[2])
            local val_max_w = (inner_width - label_w) + 1
            local raw = cfg[f[1]]
            local val = util.strval(raw)
            local skip = false

            if f[1] == "AuthKey" then val = string.rep("*", string.len(val))
            elseif f[1] == "LogMode" then val = tri(raw == log.MODE.APPEND, "anexar", "substituir")
            elseif f[1] == "FrontPanelTheme" then
                val = util.strval(themes.fp_theme_name(raw))
            elseif f[1] == "ColorMode" then
                val = util.strval(themes.color_mode_name(raw))
            elseif f[1] == "CoolingConfig" and type(cfg.CoolingConfig) == "table" then
                val = ""

                for idx = 1, #cfg.CoolingConfig do
                    local ccfg = cfg.CoolingConfig[idx]
                    local b_plural = tri(ccfg.BoilerCount == 1, "", "s")
                    local t_plural = tri(ccfg.TurbineCount == 1, "", "s")
                    local tank = tri(ccfg.TankConnection, "com conex. tanque", "sem conex. tanque")
                    val = val .. tri(idx == 1, "", "\n") ..
                            util.sprintf(" \x07 unid %d - %d caldeira%s, %d turbina%s, %s", idx, ccfg.BoilerCount, b_plural, ccfg.TurbineCount, t_plural, tank)
                end

                if val == "" then val = "sem tanques da instalação" end
            elseif f[1] == "FacilityTankMode" and raw == 0 then val = "sem tanques da instalação"
            elseif f[1] == "FacilityTankDefs" and type(cfg.FacilityTankDefs) == "table" then
                local tank_name_list = { table.unpack(cfg.FacilityTankList) } ---@type (string|integer)[]
                local next_f = 1

                val = ""

                for idx = 1, #tank_name_list do
                    if tank_name_list[idx] == 1 then
                        tank_name_list[idx] = "U" .. idx
                    elseif tank_name_list[idx] == 2 then
                        tank_name_list[idx] = "F" .. next_f
                        next_f = next_f + 1
                    end
                end

                for idx = 1, #cfg.FacilityTankDefs do
                    local t_mode = "não conectado a um tanque"
                    if cfg.FacilityTankDefs[idx] == 1 then
                        t_mode = "conectado ao seu tanque de unidade (" .. tank_name_list[cfg.FacilityTankConns[idx]] .. ")"
                    elseif cfg.FacilityTankDefs[idx] == 2 then
                        t_mode = "conectado ao tanque da instalação " .. tank_name_list[cfg.FacilityTankConns[idx]]
                    end

                    val = val .. tri(idx == 1, "", "\n") .. util.sprintf(" \x07 unid %d - %s", idx, t_mode)
                end

                if val == "" then val = "sem tanques da instalação" end
            elseif f[1] == "FacilityTankList" or f[1] == "FacilityTankConns" then
                -- ocultar estes pois esta informação está disponível na lista FacilityTankDefs (conexões) e na lista TankFluidTypes (lista de tanques)
                skip = true
            elseif f[1] == "TankFluidTypes" and type(cfg.TankFluidTypes) == "table" and type(cfg.FacilityTankList) == "table" then
                local tank_list = cfg.FacilityTankList
                local next_f = 1

                val = ""

                local count = 0
                for idx = 1, #tank_list do
                    if tank_list[idx] > 0 then count = count + 1 end
                end

                local bullet = tri(count < 2, "", " \x07 ")

                for idx = 1, #tank_list do
                    local prefix = "?"
                    local fluid = "água"
                    local type = cfg.TankFluidTypes[idx]

                    if tank_list[idx] > 0 then
                        if tank_list[idx] == 1 then
                            prefix = "U" .. idx
                        elseif tank_list[idx] == 2 then
                            prefix = "F" .. next_f
                            next_f = next_f + 1
                        end

                        if type == types.COOLANT_TYPE.SODIUM then
                            fluid = "sódio"
                        end

                        val = val .. tri(val == "", "", "\n") .. util.sprintf(bullet .. "tanque %s - %s", prefix, fluid)
                    end
                end

                if val == "" then val = "sem tanques de refrig. de emergência" end
            elseif f[1] == "AuxiliaryCoolant" then
                val = ""

                local count = 0
                for idx = 1, #cfg.AuxiliaryCoolant do
                    if cfg.AuxiliaryCoolant[idx] then count = count + 1 end
                end

                local bullet = tri(count < 2, "", " \x07 ")

                for idx = 1, #cfg.AuxiliaryCoolant do
                    if cfg.AuxiliaryCoolant[idx] then
                        val = val .. tri(val == "", "", "\n") .. util.sprintf(bullet .. "unid %d", idx)
                    end
                end

                if val == "" then val = "sem refrigerante auxiliar" end
            elseif f[1] == "EnergyStorageSystem" then
                if raw == types.ESS.INDUCTION_MATRIX then
                    val = "Matriz de Indução"
                elseif raw == types.ESS.ENERGY_CORE then
                    val = "Núcleo de Energia"
                else val = "Desconhecido" end
            elseif f[1] == "MekanismConfig" then
                val = ""

                if type(cfg.MekanismConfig) == "table" then
                    for k, v in pairs(cfg.MekanismConfig) do
                        local value = (string.format("%.10f", v)):gsub("%.?0+$", "")
                        val = val .. tri(val == "", "", "\n") .. util.sprintf(" \x07 %s = %s", k, value)
                    end
                end
            elseif f[1] == "MekanismWasteToPu" or f[1] == "MekanismWasteToPo" then
                if type(raw) == "table" then
                    val = raw[1] .. ":" .. raw[2]
                end
            elseif f[1] == "PLC_Listen" or f[1] == "RTU_Listen" or f[1] == "CRD_Listen" then
                if raw == LISTEN_MODE.WIRELESS then val = "Apenas Sem Fio"
                elseif raw == LISTEN_MODE.WIRED then val = "Apenas Cabeado"
                elseif raw == LISTEN_MODE.ALL then val = "Sem Fio e Cabeado" end
            end

            if not skip then
                if val == "nil" then val = "<não definido>" end

                local c = tri(alternate, g_lg_fg_bg, cpair(colors.gray,colors.white))
                alternate = not alternate

                if (string.len(val) > val_max_w) or string.find(val, "\n") then
                    local lines = util.strwrap(val, inner_width)
                    height = #lines + 1
                end

                local line = Div{parent=setting_list,height=height,fg_bg=c}
                TextBox{parent=line,text=f[2],width=string.len(f[2]),fg_bg=cpair(colors.black,line.get_fg_bg().bkg)}

                local textbox
                if height > 1 then
                    textbox = TextBox{parent=line,y=2,text=val,height=height-1}
                else
                    textbox = TextBox{parent=line,x=label_w+1,y=1,text=val,alignment=RIGHT}
                end

                if f[1] == "AuthKey" then self.auth_key_textbox = textbox end
            end
        end
    end

    -- gerar a lista de modems cabeados disponíveis/atribuídos
    function tool_ctl.gen_modem_list()
        modem_list.remove_all()

        local enable = wired.get_value()

        local function select(iface)
            tmp_cfg.WiredModem = iface
            tool_ctl.gen_modem_list()
        end

        local modems  = ppm.get_wired_modem_list()
        local missing = { tmp = true, ini = true }

        for iface, _ in pairs(modems) do
            if ini_cfg.WiredModem == iface then missing.ini = false end
            if tmp_cfg.WiredModem == iface then missing.tmp = false end
        end

        if missing.tmp and tmp_cfg.WiredModem then
            local line = Div{parent=modem_list,y=1,height=1}

            TextBox{parent=line,y=1,width=4,text="Usad",fg_bg=cpair(tri(enable,colors.blue,colors.gray),colors.white)}
            PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}.disable()
            TextBox{parent=line,x=15,y=1,text="[ausente]",fg_bg=cpair(colors.red,colors.white)}
            TextBox{parent=line,x=25,y=1,text=tmp_cfg.WiredModem}
        end

        if missing.ini and ini_cfg.WiredModem and (tmp_cfg.WiredModem ~= ini_cfg.WiredModem) then
            local line = Div{parent=modem_list,y=1,height=1}
            local used = tmp_cfg.WiredModem == ini_cfg.WiredModem

            TextBox{parent=line,y=1,width=4,text=tri(used,"Usad","----"),fg_bg=cpair(tri(used and enable,colors.blue,colors.gray),colors.white)}
            local select_btn = PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()select(ini_cfg.WiredModem)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}
            TextBox{parent=line,x=15,y=1,text="[ausente]",fg_bg=cpair(colors.red,colors.white)}
            TextBox{parent=line,x=25,y=1,text=ini_cfg.WiredModem}

            if used or not enable then select_btn.disable() end
        end

        -- listar modems cabeados
        for iface, _ in pairs(modems) do
            local line = Div{parent=modem_list,y=1,height=1}
            local used = tmp_cfg.WiredModem == iface

            TextBox{parent=line,y=1,width=4,text=tri(used,"Usad","----"),fg_bg=cpair(tri(used and enable,colors.blue,colors.gray),colors.white)}
            local select_btn = PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()select(iface)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}
            TextBox{parent=line,x=15,y=1,text=iface}

            if used or not enable then select_btn.disable() end
        end
    end

    --#endregion
end

return system
