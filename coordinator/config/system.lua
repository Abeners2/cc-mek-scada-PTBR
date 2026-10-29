
local comms       = require("scada-common.comms")
local log         = require("scada-common.log")
local network     = require("scada-common.network")
local ppm         = require("scada-common.ppm")
local types       = require("scada-common.types")
local util        = require("scada-common.util")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local Checkbox    = require("graphics.elements.controls.Checkbox")
local PushButton  = require("graphics.elements.controls.PushButton")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")
local TextField   = require("graphics.elements.form.TextField")

local IndLight    = require("graphics.elements.indicators.IndicatorLight")

local tri = util.trinary

local cpair = core.cpair

local RIGHT = core.ALIGN.RIGHT

local self = {
    importing_legacy = false,

    api_en = nil,           ---@type Checkbox
    pkt_chan = nil,         ---@type NumberField
    api_timeout = nil,      ---@type NumberField
    show_auth_key = nil,    ---@type function
    show_key_btn = nil,     ---@type PushButton
    auth_key_textbox = nil, ---@type TextBox
    auth_key_value = ""
}

local system = {}

-- cria a visão de configuração do sistema
---@param tool_ctl _crd_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ crd_config, crd_config, crd_config, { [1]: string, [2]: string, [3]: any }[], function ]
---@param divs Div[]
---@param ext [ MultiPane, MultiPane, MultiPane, function, function, function ]
---@param style { [string]: cpair }
function system.create(tool_ctl, main_pane, cfg_sys, divs, ext, style)
    local settings_cfg, ini_cfg, tmp_cfg, fields, load_settings = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]
    local net_cfg, log_cfg, clr_cfg, summary = divs[1], divs[2], divs[3], divs[4]
    local fac_pane, crd_pane, mon_pane, preset_monitor_fields, startup, exit = ext[1], ext[2], ext[3], ext[4], ext[5], ext[6]

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
    TextBox{parent=net_c_1,x=23,y=3,text="(necessário p/ Pocket)",fg_bg=g_lg_fg_bg}
    local wired = Checkbox{parent=net_c_1,y=5,label="Modem Cabeado",default=ini_cfg.WiredModem~=false,box_fg_bg=cpair(colors.lightBlue,colors.black),callback=on_wired_change}
    TextBox{parent=net_c_1,x=3,y=6,text="este DEVE conectar APENAS a computadores SCADA",fg_bg=cpair(colors.red,colors._INHERIT)}
    TextBox{parent=net_c_1,x=3,y=7,text="conectá-lo a periféricos causará problemas",fg_bg=g_lg_fg_bg}
    local modem_list = ListBox{parent=net_c_1,y=8,height=5,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local modem_err = TextBox{parent=net_c_1,x=10,y=14,width=30,text="",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

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
            if tmp_cfg.WirelessModem and tmp_cfg.WiredModem then
                self.wl_pref.enable()
            else
                self.wl_pref.set_value(tmp_cfg.WirelessModem)
                self.wl_pref.disable()
            end

            if not tmp_cfg.WirelessModem then
                self.api_en.set_value(false)
                self.api_en.disable()
            else
                self.api_en.enable()
            end

            net_pane.set_value(2)
            modem_err.hide(true)
        end
    end

    PushButton{parent=net_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_1,x=41,y=14,text="Avançar \x1a",callback=submit_interfaces,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_2,text="Se selecionou múltiplas interfaces, especifique se este dispositivo deve preferir sem fio ou cabeada. A interface preferida também é reassumida ao reconectar mesmo após failover."}
    self.wl_pref = Checkbox{parent=net_c_2,y=7,label="Preferir Sem Fio",default=ini_cfg.PreferWireless,box_fg_bg=cpair(colors.lightBlue,colors.black),disable_fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_2,y=9,text="Com modem sem fio, configure o acesso Pocket."}
    self.api_en = Checkbox{parent=net_c_2,y=11,label="Ativar Acesso Pocket",default=ini_cfg.API_Enabled,box_fg_bg=cpair(colors.lightBlue,colors.black),disable_fg_bg=g_lg_fg_bg}

    local function submit_net_cfg_opts()
        if tmp_cfg.WirelessModem and tmp_cfg.WiredModem then
            tmp_cfg.PreferWireless = self.wl_pref.get_value()
        else
            tmp_cfg.PreferWireless = tmp_cfg.WirelessModem
        end

        tmp_cfg.API_Enabled = tri(tmp_cfg.WirelessModem, self.api_en.get_value(), false)

        if tmp_cfg.API_Enabled then
            self.pkt_chan.enable()
            self.api_timeout.enable()
        else
            self.pkt_chan.disable()
            self.api_timeout.disable()
        end

        net_pane.set_value(3)
    end

    PushButton{parent=net_c_2,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_2,x=41,y=14,text="Avançar \x1a",callback=submit_net_cfg_opts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_3,y=1,text="Defina os canais de rede abaixo."}
    TextBox{parent=net_c_3,y=3,height=4,text="Cada um dos 5 canais nomeados exclusivamente, incluindo os 3 abaixo, deve ser igual para cada dispositivo nesta rede SCADA. Em servidores multiplayer, recomenda-se não usar os canais padrão.",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=8,width=18,text="Canal Supervisor"}
    local svr_chan = NumberField{parent=net_c_3,x=21,y=8,width=7,default=ini_cfg.SVR_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=8,height=4,text="[SVR_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=10,width=19,text="Canal Coordenador"}
    local crd_chan = NumberField{parent=net_c_3,x=21,y=10,width=7,default=ini_cfg.CRD_Channel,min=1,max=65535,fg_bg=bw_fg_bg}
    TextBox{parent=net_c_3,x=29,y=10,height=4,text="[CRD_CHANNEL]",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_3,y=12,width=14,text="Canal Pocket"}
    self.pkt_chan = NumberField{parent=net_c_3,x=21,y=12,width=7,default=ini_cfg.PKT_Channel,min=1,max=65535,fg_bg=bw_fg_bg,dis_fg_bg=cpair(colors.lightGray,colors.white)}
    TextBox{parent=net_c_3,x=29,y=12,height=4,text="[PKT_CHANNEL]",fg_bg=g_lg_fg_bg}

    local chan_err = TextBox{parent=net_c_3,x=10,y=14,width=30,text="Defina todos os canais.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_channels()
        local svr_c, crd_c, pkt_c = tonumber(svr_chan.get_value()), tonumber(crd_chan.get_value()), tonumber(self.pkt_chan.get_value())

        if not tmp_cfg.API_Enabled then pkt_c = tmp_cfg.PKT_Channel or 16244 end

        if svr_c ~= nil and crd_c ~= nil and pkt_c ~= nil then
            tmp_cfg.SVR_Channel, tmp_cfg.CRD_Channel, tmp_cfg.PKT_Channel = svr_c, crd_c, pkt_c
            net_pane.set_value(4)
            chan_err.hide(true)
        else chan_err.show() end
    end

    PushButton{parent=net_c_3,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_3,x=41,y=14,text="Avançar \x1a",callback=submit_channels,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_4,y=1,text="Defina os tempos limite (timeouts) abaixo."}
    TextBox{parent=net_c_4,y=3,height=4,text="Você geralmente não precisa modificá-los. Em servidores lentos, pode aumentá-los para fazer o sistema aguardar mais antes de assumir desconexão. O padrão para todos é 5 segundos.",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_4,y=8,width=19,text="Timeout Supervisor"}
    local svr_timeout = NumberField{parent=net_c_4,x=20,y=8,width=7,default=ini_cfg.SVR_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg}

    TextBox{parent=net_c_4,y=10,width=14,text="Timeout Pocket"}
    self.api_timeout = NumberField{parent=net_c_4,x=20,y=10,width=7,default=ini_cfg.API_Timeout,min=2,max=25,max_chars=6,max_frac_digits=2,allow_decimal=true,fg_bg=bw_fg_bg,dis_fg_bg=cpair(colors.lightGray,colors.white)}

    TextBox{parent=net_c_4,x=28,y=8,height=4,width=8,text="segundos\n\nsegundos",fg_bg=g_lg_fg_bg}

    local ct_err = TextBox{parent=net_c_4,x=10,y=14,width=30,text="Defina todos os timeouts.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_timeouts()
        local svr_cto, api_cto = tonumber(svr_timeout.get_value()), tonumber(self.api_timeout.get_value())

        if not tmp_cfg.API_Enabled then api_cto = tmp_cfg.API_Timeout or 5 end

        if svr_cto ~= nil and api_cto ~= nil then
            tmp_cfg.SVR_Timeout, tmp_cfg.API_Timeout = svr_cto, api_cto

            if tmp_cfg.WirelessModem then
                net_pane.set_value(5)
            else
                tmp_cfg.TrustedRange = 0
                tmp_cfg.AuthKey = ""

                network.deinit_mac()

                -- prepara tela de conexão com o supervisor
                tool_ctl.init_sv_connect_ui()

                main_pane.set_value(3)
            end

            ct_err.hide(true)
        else ct_err.show() end
    end

    PushButton{parent=net_c_4,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(3)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_4,x=41,y=14,text="Avançar \x1a",callback=submit_timeouts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_5,y=1,text="Defina o alcance confiável sem fio abaixo."}
    TextBox{parent=net_c_5,y=3,height=3,text="Definir um valor maior que 0 impede conexões sem fio com dispositivos a essa distância em metros (blocos) em qualquer direção.",fg_bg=g_lg_fg_bg}
    TextBox{parent=net_c_5,y=7,height=2,text="Isso é opcional. Você pode desativar esta funcionalidade definindo o valor como 0.",fg_bg=g_lg_fg_bg}

    local range = NumberField{parent=net_c_5,y=10,width=10,default=ini_cfg.TrustedRange,min=0,max_chars=20,allow_decimal=true,fg_bg=bw_fg_bg}

    local tr_err = TextBox{parent=net_c_5,x=10,y=14,width=30,text="Defina o alcance confiável.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_tr()
        local range_val = tonumber(range.get_value())
        if range_val ~= nil then
            tmp_cfg.TrustedRange = range_val
            comms.set_trusted_range(range_val)
            net_pane.set_value(6)
            tr_err.hide(true)
        else tr_err.show() end
    end

    PushButton{parent=net_c_5,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_5,x=41,y=14,text="Avançar \x1a",callback=submit_tr,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=net_c_6,y=1,height=2,text="Opcionalmente, defina a chave de autenticação da instalação abaixo. NÃO use uma de suas senhas."}
    TextBox{parent=net_c_6,y=4,height=6,text="Isso permite verificar se as mensagens são autênticas, voltado para segurança sem fio em servidores multiplayer. Todos os dispositivos na mesma rede sem fio DEVEM usar a mesma chave se algum tiver chave. Isso gera processamento extra (pode causar lentidão).",fg_bg=g_lg_fg_bg}

    TextBox{parent=net_c_6,y=11,text="Chave de Autenticação (Apenas Sem Fio)"}
    local key, _ = TextField{parent=net_c_6,y=12,max_len=64,value=ini_cfg.AuthKey,width=32,height=1,fg_bg=bw_fg_bg}

    local function censor_key(enable) key.censor(tri(enable, "*", nil)) end

    local hide_key = Checkbox{parent=net_c_6,x=34,y=12,label="Ocultar",box_fg_bg=cpair(colors.lightBlue,colors.black),callback=censor_key}

    hide_key.set_value(true)
    censor_key(true)

    local key_err = TextBox{parent=net_c_6,x=10,y=14,width=30,text="Mínimo de 8 caracteres.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_auth()
        local v = key.get_value()
        if string.len(v) == 0 or string.len(v) >= 8 then
            tmp_cfg.AuthKey = key.get_value()
            key_err.hide(true)

            -- inicializa mac para conexão com o supervisor
            if string.len(v) >= 8 then network.init_mac(tmp_cfg.AuthKey) else network.deinit_mac() end

            -- prepara tela de conexão com o supervisor
            tool_ctl.init_sv_connect_ui()

            main_pane.set_value(3)
        else key_err.show() end
    end

    PushButton{parent=net_c_6,y=14,text="\x1b Voltar",callback=function()net_pane.set_value(5)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=net_c_6,x=41,y=14,text="Avançar \x1a",callback=submit_auth,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Registro de Log

    local log_c_1 = Div{parent=log_cfg,x=2,y=4,width=49}

    TextBox{parent=log_cfg,y=2,text=" Configuração de Log",fg_bg=cpair(colors.black,colors.pink)}

    TextBox{parent=log_c_1,y=1,text="Configure o registro de log abaixo."}

    TextBox{parent=log_c_1,y=3,text="Modo do Arquivo de Log"}
    local mode = RadioButton{parent=log_c_1,y=4,default=ini_cfg.LogMode+1,options={"Anexar ao Iniciar","Substituir ao Iniciar"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.pink}

    TextBox{parent=log_c_1,y=7,text="Caminho do Arquivo de Log"}
    local path = TextField{parent=log_c_1,y=8,width=49,height=1,value=ini_cfg.LogPath,max_len=128,fg_bg=bw_fg_bg}

    local en_dbg = Checkbox{parent=log_c_1,y=10,default=ini_cfg.LogDebug,label="Ativar Registro de Mensagens de Debug",box_fg_bg=cpair(colors.pink,colors.black)}
    TextBox{parent=log_c_1,x=3,y=11,height=2,text="Isso resulta em arquivos de log muito maiores. É melhor usar apenas quando houver um problema.",fg_bg=g_lg_fg_bg}

    local path_err = TextBox{parent=log_c_1,x=10,y=14,width=30,text="Informe um caminho de log.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_log()
        if path.get_value() ~= "" then
            path_err.hide(true)
            tmp_cfg.LogMode = mode.get_value() - 1
            tmp_cfg.LogPath = path.get_value()
            tmp_cfg.LogDebug = en_dbg.get_value()
            tool_ctl.color_apply.hide(true)
            tool_ctl.color_next.show()
            main_pane.set_value(8)
        else path_err.show() end
    end

    PushButton{parent=log_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(6)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=log_c_1,x=41,y=14,text="Avançar \x1a",callback=submit_log,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Opções de Cor

    local clr_c_1 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_2 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_3 = Div{parent=clr_cfg,x=2,y=4,width=49}
    local clr_c_4 = Div{parent=clr_cfg,x=2,y=4,width=49}

    local clr_pane = MultiPane{parent=clr_cfg,y=4,panes={clr_c_1,clr_c_2,clr_c_3,clr_c_4}}

    TextBox{parent=clr_cfg,y=2,text=" Configuração de Cores",fg_bg=cpair(colors.black,colors.magenta)}

    TextBox{parent=clr_c_1,y=1,height=2,text="Aqui você pode selecionar os temas de cores para as diferentes telas da UI."}
    TextBox{parent=clr_c_1,y=4,height=2,text="Clique em 'Acessibilidade' abaixo para acessar opções de auxílio a daltônicos.",fg_bg=g_lg_fg_bg}

    TextBox{parent=clr_c_1,y=7,text="Tema da UI Principal"}
    local main_theme = RadioButton{parent=clr_c_1,y=8,default=ini_cfg.MainTheme,options=themes.UI_THEME_NAMES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.magenta}

    TextBox{parent=clr_c_1,x=22,y=7,text="Tema do Painel Frontal"}
    local fp_theme = RadioButton{parent=clr_c_1,x=22,y=8,default=ini_cfg.FrontPanelTheme,options=themes.FP_THEME_NAMES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.magenta}

    TextBox{parent=clr_c_2,y=1,height=6,text="Este sistema usa cores intensamente para distinguir o que está OK ou não, com alguns indicadores usando várias cores. Ao selecionar um modo abaixo, os indicadores mudarão como mostrado. Em modos não padrão, indicadores com mais de duas cores geralmente serão divididos."}

    TextBox{parent=clr_c_2,x=21,y=7,text="Prévia"}
    local _ = IndLight{parent=clr_c_2,x=21,y=8,label="Bom",colors=cpair(colors.black,colors.green)}
    _ = IndLight{parent=clr_c_2,x=21,y=9,label="Alerta",colors=cpair(colors.black,colors.yellow)}
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

    TextBox{parent=clr_c_2,y=7,width=12,text="Modo de Cor"}
    local c_mode = RadioButton{parent=clr_c_2,y=8,default=ini_cfg.ColorMode,options=themes.COLOR_MODE_NAMES,callback=recolor,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.magenta}

    TextBox{parent=clr_c_2,x=21,y=13,height=2,width=18,text="Nota: a cor exata varia por tema.",fg_bg=g_lg_fg_bg}

    PushButton{parent=clr_c_2,x=42,y=14,min_width=8,text="Pronto",callback=function()clr_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    local function back_from_colors()
        main_pane.set_value(tri(tool_ctl.jumped_to_color, 1, 7))
        tool_ctl.jumped_to_color = false
        recolor(1)
    end

    local function show_access()
        clr_pane.set_value(2)
        recolor(c_mode.get_value())
    end

    local function submit_colors()
        tmp_cfg.MainTheme = main_theme.get_value()
        tmp_cfg.FrontPanelTheme = fp_theme.get_value()
        tmp_cfg.ColorMode = c_mode.get_value()

        if tool_ctl.jumped_to_color then
            settings.set("MainTheme", tmp_cfg.MainTheme)
            settings.set("FrontPanelTheme", tmp_cfg.FrontPanelTheme)
            settings.set("ColorMode", tmp_cfg.ColorMode)

            if settings.save("/coordinator.settings") then
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
            main_pane.set_value(9)
        end
    end

    PushButton{parent=clr_c_1,y=14,text="\x1b Voltar",callback=back_from_colors,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=clr_c_1,x=10,y=14,min_width=16,text="Acessibilidade",callback=show_access,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    tool_ctl.color_next = PushButton{parent=clr_c_1,x=41,y=14,text="Avançar \x1a",callback=submit_colors,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    tool_ctl.color_apply = PushButton{parent=clr_c_1,x=41,y=14,min_width=9,text="Aplicar",callback=submit_colors,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}

    tool_ctl.color_apply.hide(true)

    local function c_go_home()
        main_pane.set_value(1)
        clr_pane.set_value(1)
    end

    TextBox{parent=clr_c_3,y=1,text="Configurações salvas!"}
    PushButton{parent=clr_c_3,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray)}
    PushButton{parent=clr_c_3,x=42,y=14,min_width=8,text="Início",callback=c_go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=clr_c_4,y=1,height=5,text="Falha ao salvar o arquivo de configurações.\n\nPode não haver espaço suficiente para a modificação ou as permissões de arquivo do servidor estão negando gravações."}
    PushButton{parent=clr_c_4,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray)}
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

    local function back_from_summary()
        if tool_ctl.viewing_config or self.importing_legacy then
            main_pane.set_value(1)
            tool_ctl.viewing_config = false
            self.importing_legacy = false
            tool_ctl.settings_apply.show()
        else
            main_pane.set_value(8)
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

        if settings.save("/coordinator.settings") then
            load_settings(settings_cfg, true)
            load_settings(ini_cfg)

            try_set(wireless, ini_cfg.WirelessModem)
            try_set(wired, ini_cfg.WiredModem ~= false)
            try_set(self.wl_pref, ini_cfg.PreferWireless)
            try_set(self.api_en, ini_cfg.API_Enabled)
            try_set(svr_chan, ini_cfg.SVR_Channel)
            try_set(crd_chan, ini_cfg.CRD_Channel)
            try_set(self.pkt_chan, ini_cfg.PKT_Channel)
            try_set(svr_timeout, ini_cfg.SVR_Timeout)
            try_set(self.api_timeout, ini_cfg.API_Timeout)
            try_set(range, ini_cfg.TrustedRange)
            try_set(key, ini_cfg.AuthKey)
            try_set(tool_ctl.num_units, ini_cfg.UnitCount)
            try_set(tool_ctl.s_vol, ini_cfg.SpeakerVolume)
            try_set(tool_ctl.pellet_color, ini_cfg.GreenPuPellet)
            try_set(tool_ctl.clock_fmt, tri(ini_cfg.Time24Hour, 1, 2))
            try_set(tool_ctl.temp_scale, ini_cfg.TempScale)
            try_set(tool_ctl.energy_scale, ini_cfg.EnergyScale)
            try_set(tool_ctl.en_flow_dtl, ini_cfg.FlowDetailView)
            try_set(tool_ctl.show_win_sw, ini_cfg.FlowViewSwitcher)
            try_set(tool_ctl.en_splash, ini_cfg.SplashScreen)
            try_set(mode, ini_cfg.LogMode)
            try_set(path, ini_cfg.LogPath)
            try_set(en_dbg, ini_cfg.LogDebug)
            try_set(main_theme, ini_cfg.MainTheme)
            try_set(fp_theme, ini_cfg.FrontPanelTheme)
            try_set(c_mode, ini_cfg.ColorMode)

            preset_monitor_fields()

            tool_ctl.gen_mon_list()

            tool_ctl.view_cfg.enable()
            tool_ctl.color_cfg.enable()

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

    PushButton{parent=sum_c_1,y=14,text="\x1b Voltar",callback=back_from_summary,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    self.show_key_btn = PushButton{parent=sum_c_1,x=10,y=14,min_width=17,text="Exibir Chave",callback=function()self.show_auth_key()end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    tool_ctl.settings_apply = PushButton{parent=sum_c_1,x=41,y=14,min_width=9,text="Aplicar",callback=save_and_continue,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}

    TextBox{parent=sum_c_2,y=1,text="Configurações salvas!"}

    local function go_home()
        main_pane.set_value(1)
        net_pane.set_value(1)
        fac_pane.set_value(1)
        mon_pane.set_value(1)
        crd_pane.set_value(1)
        clr_pane.set_value(1)
        sum_pane.set_value(1)
    end

    PushButton{parent=sum_c_2,y=14,min_width=8,text="Início",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.start_fail ~= 0 then
        PushButton{parent=sum_c_2,x=34,y=14,min_width=16,text="Retomar Início",callback=exit,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg}
    else
        PushButton{parent=sum_c_2,x=41,y=14,min_width=9,text="Iniciar",callback=startup,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}
    end

    TextBox{parent=sum_c_3,y=1,height=2,text="Os arquivos antigos config.lua e coord.settings serão excluídos agora e o configurador será encerrado."}

    local function delete_legacy()
        fs.delete("/coordinator/config.lua")
        fs.delete("/coord.settings")
        exit()
    end

    PushButton{parent=sum_c_3,y=14,min_width=10,text="Cancelar",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=sum_c_3,x=44,y=14,min_width=6,text="OK",callback=delete_legacy,fg_bg=cpair(colors.black,colors.green),active_fg_bg=cpair(colors.white,colors.gray)}

    TextBox{parent=sum_c_4,y=1,height=5,text="Falha ao salvar o arquivo de configurações.\n\nPode não haver espaço suficiente para a modificação ou as permissões de arquivo do servidor estão negando gravações."}
    PushButton{parent=sum_c_4,y=14,min_width=8,text="Início",callback=go_home,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=sum_c_4,x=44,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=cpair(colors.white,colors.gray)}

    --#endregion

    --#region Funções de Ferramenta

    -- carrega um arquivo de configuração legado
    function tool_ctl.load_legacy()
        local config = require("coordinator.config")

        tmp_cfg.SVR_Channel = config.SVR_CHANNEL
        tmp_cfg.CRD_Channel = config.CRD_CHANNEL
        tmp_cfg.PKT_Channel = config.PKT_CHANNEL
        tmp_cfg.SVR_Timeout = config.SV_TIMEOUT
        tmp_cfg.API_Timeout = config.API_TIMEOUT
        tmp_cfg.TrustedRange = config.TRUSTED_RANGE
        tmp_cfg.AuthKey = config.AUTH_KEY or ""

        tmp_cfg.UnitCount = config.NUM_UNITS
        tmp_cfg.SpeakerVolume = config.SOUNDER_VOLUME
        tmp_cfg.Time24Hour = config.TIME_24_HOUR

        tmp_cfg.LogMode = config.LOG_MODE
        tmp_cfg.LogPath = config.LOG_PATH
        tmp_cfg.LogDebug = config.LOG_DEBUG or false

        settings.load("/coord.settings")

        tmp_cfg.MainDisplay = settings.get("PRIMARY_DISPLAY")
        tmp_cfg.FlowDisplay = settings.get("FLOW_DISPLAY")
        tmp_cfg.UnitDisplays = settings.get("UNIT_DISPLAYS", {})

        -- se houver entradas extras de monitor, exclua-as agora
        -- não fazer isso fará com que o aplicativo falhe ao iniciar
        if tool_ctl.is_int_min_max(tmp_cfg.UnitCount, 1, 4) then
            for i = tmp_cfg.UnitCount + 1, 4 do tmp_cfg.UnitDisplays[i] = nil end
        end

        if settings.get("ControlStates") == nil then
            local ctrl_states = {
                process = settings.get("PROCESS"),
                waste_modes = settings.get("WASTE_MODES"),
                priority_groups = settings.get("PRIORITY_GROUPS"),
            }

            settings.set("ControlStates", ctrl_states)
        end

        settings.unset("PRIMARY_DISPLAY")
        settings.unset("FLOW_DISPLAY")
        settings.unset("UNIT_DISPLAYS")
        settings.unset("PROCESS")
        settings.unset("WASTE_MODES")
        settings.unset("PRIORITY_GROUPS")

        tool_ctl.gen_summary(tmp_cfg)
        sum_pane.set_value(1)
        main_pane.set_value(9)
        self.importing_legacy = true
    end

    -- expõe a chave de autenticação na página de resumo
    function self.show_auth_key()
        self.show_key_btn.disable()
        self.auth_key_textbox.set_value(self.auth_key_value)
    end

    -- gera a lista de resumo
    ---@param cfg crd_config
    function tool_ctl.gen_summary(cfg)
        setting_list.remove_all()

        local alternate = false
        local inner_width = setting_list.get_width() - 1

        self.show_key_btn.enable()
        self.auth_key_value = cfg.AuthKey or "" -- para exibir a chave de autenticação

        for i = 1, #fields do
            local f = fields[i]
            local height = 1
            local label_w = string.len(f[2])
            local val_max_w = (inner_width - label_w) + 1
            local raw = cfg[f[1]]
            local val = util.strval(raw)

            if f[1] == "AuthKey" then val = string.rep("*", string.len(val))
            elseif f[1] == "LogMode" then val = util.trinary(raw == log.MODE.APPEND, "anexar", "substituir")
            elseif f[1] == "GreenPuPellet" then
                val = tri(raw, "Pu Verde/Po Ciano", "Pu Ciano/Po Verde")
            elseif f[1] == "TempScale" then
                val = util.strval(types.TEMP_SCALE_NAMES[raw])
            elseif f[1] == "EnergyScale" then
                val = util.strval(types.ENERGY_SCALE_NAMES[raw])
            elseif f[1] == "MainTheme" then
                val = util.strval(themes.ui_theme_name(raw))
            elseif f[1] == "FrontPanelTheme" then
                val = util.strval(themes.fp_theme_name(raw))
            elseif f[1] == "ColorMode" then
                val = util.strval(themes.color_mode_name(raw))
            elseif f[1] == "UnitDisplays" and type(cfg.UnitDisplays) == "table" then
                val = ""
                for idx = 1, #cfg.UnitDisplays do
                    val = val .. util.trinary(idx == 1, "", "\n") .. util.sprintf(" \x07 Unidade %d - %s", idx, cfg.UnitDisplays[idx])
                end
            end

            if val == "nil" then val = "<não definido>" end

            local c = util.trinary(alternate, g_lg_fg_bg, cpair(colors.gray,colors.white))
            alternate = not alternate

            if (string.len(val) > val_max_w) or string.find(val, "\n") then
                local lines = util.strwrap(val, inner_width)
                height = #lines + 1
            end

            if (f[1] == "UnitDisplays") and (height == 1) and (val ~= "<não definido>") then height = 2 end

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

    -- gera a lista de modems cabeados disponíveis/atribuídos
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

            TextBox{parent=line,y=1,width=4,text="Uso",fg_bg=cpair(tri(enable,colors.blue,colors.gray),colors.white)}
            PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}.disable()
            TextBox{parent=line,x=15,y=1,text="[ausente]",fg_bg=cpair(colors.red,colors.white)}
            TextBox{parent=line,x=25,y=1,text=tmp_cfg.WiredModem}
        end

        if missing.ini and ini_cfg.WiredModem and (tmp_cfg.WiredModem ~= ini_cfg.WiredModem) then
            local line = Div{parent=modem_list,y=1,height=1}
            local used = tmp_cfg.WiredModem == ini_cfg.WiredModem

            TextBox{parent=line,y=1,width=4,text=tri(used,"Uso","----"),fg_bg=cpair(tri(used and enable,colors.blue,colors.gray),colors.white)}
            local select_btn = PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()select(ini_cfg.WiredModem)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}
            TextBox{parent=line,x=15,y=1,text="[ausente]",fg_bg=cpair(colors.red,colors.white)}
            TextBox{parent=line,x=25,y=1,text=ini_cfg.WiredModem}

            if used or not enable then select_btn.disable() end
        end

        -- lista modems cabeados
        for iface, _ in pairs(modems) do
            local line = Div{parent=modem_list,y=1,height=1}
            local used = tmp_cfg.WiredModem == iface

            TextBox{parent=line,y=1,width=4,text=tri(used,"Uso","----"),fg_bg=cpair(tri(used and enable,colors.blue,colors.gray),colors.white)}
            local select_btn = PushButton{parent=line,x=6,y=1,min_width=8,height=1,text="SELEC.",callback=function()select(iface)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=g_lg_fg_bg}
            TextBox{parent=line,x=15,y=1,text=iface}

            if used or not enable then select_btn.disable() end
        end
    end

    --#endregion
end

return system
