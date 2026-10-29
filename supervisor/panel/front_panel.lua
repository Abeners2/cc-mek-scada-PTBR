--
-- GUI do Painel Frontal do Supervisor
--

local util          = require("scada-common.util")

local databus       = require("supervisor.databus")
local supervisor    = require("supervisor.supervisor")

local pgi           = require("supervisor.panel.pgi")
local style         = require("supervisor.panel.style")

local chk_entry     = require("supervisor.panel.components.chk_entry")
local pdg_entry     = require("supervisor.panel.components.pdg_entry")
local rtu_entry     = require("supervisor.panel.components.rtu_entry")

local core          = require("graphics.core")

local Div           = require("graphics.elements.Div")
local ListBox       = require("graphics.elements.ListBox")
local MultiPane     = require("graphics.elements.MultiPane")
local Rectangle     = require("graphics.elements.Rectangle")
local TextBox       = require("graphics.elements.TextBox")

local PushButton    = require("graphics.elements.controls.PushButton")
local TabBar        = require("graphics.elements.controls.TabBar")

local DataIndicator = require("graphics.elements.indicators.DataIndicator")
local LED           = require("graphics.elements.indicators.LED")

local ALIGN = core.ALIGN

local cpair = core.cpair
local border = core.border

local ind_grn = style.ind_grn

-- criar nova visualização do painel frontal
---@param panel DisplayBox displaybox principal
---@param config svr_config configuração
local function init(panel, config)
    local s_hi_box = style.theme.highlight_box
    local s_hi_bright = style.theme.highlight_box_bright

    local label_fg = style.fp.label_fg
    local label_d_fg = style.fp.label_d_fg

    local term_w, term_h = term.getSize()

    TextBox{parent=panel,y=1,text="SUPERVISOR SCADA",alignment=ALIGN.CENTER,fg_bg=style.theme.header}

    local page_div = Div{parent=panel,y=3}

    --
    -- indicadores do sistema
    --

    local main_page = Div{parent=page_div,y=1}

    local system = Div{parent=main_page,width=18,height=17,x=2,y=2}

    local status = LED{parent=system,label="STATUS",colors=cpair(colors.green,colors.red)}
    local heartbeat = LED{parent=system,label="PULSO",colors=ind_grn}
    system.line_break()

    status.register(databus.ps, "status", status.update)
    heartbeat.register(databus.ps, "heartbeat", heartbeat.update)

    if config.WirelessModem and config.WiredModem then
        local wd_modem = LED{parent=system,label="MODEM CAB",colors=ind_grn}
        local wl_modem = LED{parent=system,label="MODEM S/F",colors=ind_grn}
        wd_modem.register(databus.ps, "has_wd_modem", wd_modem.update)
        wl_modem.register(databus.ps, "has_wl_modem", wl_modem.update)
    else
        local modem = LED{parent=system,label="MODEM",colors=ind_grn}
        modem.register(databus.ps, util.trinary(config.WirelessModem, "has_wl_modem", "has_wd_modem"), modem.update)
    end

    --
    -- avisos
    --

    local warning_box = Rectangle{parent=main_page,x=20,y=2,width=28,height=11,border=border(1,s_hi_box.bkg,true),thin=true,even_inner=true,hidden=true}

    TextBox{parent=warning_box,text="Uma ou mais unidades têm taxa de aquec. que desvia dos Joules por mB de comb. configurados. Verifique a config. do Mekanism no Supervisor.",fg_bg=cpair(colors.red,colors._INHERIT)}
    PushButton{parent=warning_box,x=18,y=9,min_width=9,text="IGNORAR",callback=function()warning_box.hide(true)end,fg_bg=s_hi_box,active_fg_bg=s_hi_bright}

    warning_box.register(databus.ps, "energy_mismatch", function (x) if x then warning_box.show() else warning_box.hide(true) end end)

    --
    -- rotulagem de hardware
    --

    local hw_labels = Rectangle{parent=main_page,x=2,y=term_h-7,width=14,height=5,border=border(1,s_hi_box.bkg,true),even_inner=true}

    local comp_id = util.sprintf("%03d", os.getComputerID())

    TextBox{parent=hw_labels,text="FW "..databus.ps.get("version"),fg_bg=s_hi_box}
    TextBox{parent=hw_labels,text="NT "..databus.ps.get("comms_version"),fg_bg=s_hi_box}
    TextBox{parent=hw_labels,text="SN "..comp_id.."-SVR",fg_bg=s_hi_box}

    --
    -- manipulação de páginas
    --

    -- página de sessões de clp

    local plc_page = Div{parent=page_div,y=1,hidden=true}
    local plc_list = Div{parent=plc_page,x=2,y=2,width=term_w-2}

    for i = 1, supervisor.config.UnitCount do
        local ps_prefix = "plc_" .. i .. "_"
        local plc_entry = Div{parent=plc_list,height=3,fg_bg=s_hi_bright}

        TextBox{parent=plc_entry,y=1,text="",width=8,fg_bg=s_hi_box}
        TextBox{parent=plc_entry,y=2,text="UNID "..i,alignment=ALIGN.CENTER,width=8,fg_bg=s_hi_box}
        TextBox{parent=plc_entry,y=3,text="",width=8,fg_bg=s_hi_box}

        local conn = LED{parent=plc_entry,x=10,y=2,label="LINK",colors=cpair(colors.green_hc,colors.green_off)}
        conn.register(databus.ps, ps_prefix .. "conn", conn.update)

        local plc_addr = TextBox{parent=plc_entry,x=17,y=2,text=" --- ",width=5,fg_bg=label_d_fg}
        plc_addr.register(databus.ps, ps_prefix .. "addr", plc_addr.set_value)

        TextBox{parent=plc_entry,x=term_w-28,y=2,text="FW:",width=3}
        local plc_fw_v = TextBox{parent=plc_entry,x=term_w-24,y=2,text=" ------- ",width=9,fg_bg=label_fg}
        plc_fw_v.register(databus.ps, ps_prefix .. "fw", plc_fw_v.set_value)

        TextBox{parent=plc_entry,x=term_w-14,y=2,text="RTT:",width=4}
        local plc_rtt = DataIndicator{parent=plc_entry,x=term_w-9,y=2,unit="",format="%4d",value=0,width=4,fg_bg=label_fg}
        TextBox{parent=plc_entry,x=term_w-4,y=2,text="ms",width=4,fg_bg=label_fg}
        plc_rtt.register(databus.ps, ps_prefix .. "rtt", plc_rtt.update)
        plc_rtt.register(databus.ps, ps_prefix .. "rtt_color", plc_rtt.recolor)

        plc_list.line_break()
    end

    -- página de sessões de rtu

    local rtu_page = Div{parent=page_div,y=1,hidden=true}
    local rtu_list = ListBox{parent=rtu_page,y=1,height=term_h-2,width=term_w,scroll_height=1000,nav_fg_bg=cpair(colors.gray,colors.lightGray),nav_active=cpair(colors.black,colors.gray)}
    local _ = Div{parent=rtu_list,height=1} -- preenchimento

    -- página de sessão do coordenador

    local crd_page = Div{parent=page_div,y=1,hidden=true}
    local crd_box = Div{parent=crd_page,x=2,y=2,width=term_w-2,height=4,fg_bg=s_hi_bright}

    local crd_conn = LED{parent=crd_box,x=2,y=2,label="CONEXÃO",colors=cpair(colors.green_hc,colors.green_off)}
    crd_conn.register(databus.ps, "crd_conn", crd_conn.update)

    TextBox{parent=crd_box,x=4,y=3,text="COMPUT.",width=8,fg_bg=label_d_fg}
    local crd_addr = TextBox{parent=crd_box,x=13,y=3,text="---",width=5,fg_bg=label_d_fg}
    crd_addr.register(databus.ps, "crd_addr", crd_addr.set_value)

    TextBox{parent=crd_box,x=22,y=2,text="FW:",width=3}
    local crd_fw_v = TextBox{parent=crd_box,x=26,y=2,text=" ------- ",width=9,fg_bg=label_fg}
    crd_fw_v.register(databus.ps, "crd_fw", crd_fw_v.set_value)

    TextBox{parent=crd_box,x=term_w-15,y=2,text="RTT:",width=4}
    local crd_rtt = DataIndicator{parent=crd_box,x=term_w-10,y=2,unit="",format="%5d",value=0,width=5,fg_bg=label_fg}
    TextBox{parent=crd_box,x=term_w-4,y=2,text="ms",width=4,fg_bg=label_fg}
    crd_rtt.register(databus.ps, "crd_rtt", crd_rtt.update)
    crd_rtt.register(databus.ps, "crd_rtt_color", crd_rtt.recolor)

    -- página de sessões pocket

    local pkt_page = Div{parent=page_div,y=1,hidden=true}
    local pdg_list = ListBox{parent=pkt_page,y=1,height=term_h-2,width=term_w,scroll_height=1000,fg_bg=style.fp.text_fg,nav_fg_bg=cpair(colors.gray,colors.lightGray),nav_active=cpair(colors.black,colors.gray)}
    local _ = Div{parent=pdg_list,height=1} -- preenchimento

    -- página de verificação de ID de dispositivo RTU/diagnóstico

    local chk_page = Div{parent=page_div,y=1,hidden=true}
    local chk_list = ListBox{parent=chk_page,y=1,height=term_h-2,width=term_w,scroll_height=1000,fg_bg=style.fp.text_fg,nav_fg_bg=cpair(colors.gray,colors.lightGray),nav_active=cpair(colors.black,colors.gray)}
    local _ = Div{parent=chk_list,height=1} -- preenchimento

    -- página de informações

    local info_page = Div{parent=page_div,y=1,hidden=true}
    local info = Div{parent=info_page,height=6,x=2,y=2}

    TextBox{parent=info,text="SVR \x1a Status do Supervisor"}
    TextBox{parent=info,text="PLC \x1a Conexões de CLP do Reator"}
    TextBox{parent=info,text="RTU \x1a Conexões de Gateway RTU"}
    TextBox{parent=info,text="CRD \x1a Conexão do Coordenador"}
    TextBox{parent=info,text="PKT \x1a Conexões Pocket"}
    TextBox{parent=info,text="DEV \x1a Alertas de Disp./Config. de RTU"}

    local notes = Div{parent=info_page,width=term_w-2,height=8,x=2,y=9,fg_bg=style.fp.disabled_fg}

    TextBox{parent=notes,text="A aba DEV mostrará dispositivos ausentes e dispositivos que conectaram com informações incorretas. Entradas ausentes indicarão como deve ser a config., duplicadas indicarão o que está duplicado, e fora do intervalo indicarão a entrada inválida. Ex: turbina #2 quando só deveria ter 1 na unidade."}

    -- montar painéis de páginas

    local panes = { main_page, plc_page, rtu_page, crd_page, pkt_page, chk_page, info_page }

    local page_pane = MultiPane{parent=page_div,y=1,panes=panes}

    local tabs = {
        { name = "SVR", color = style.fp.text },
        { name = "PLC", color = style.fp.text },
        { name = "RTU", color = style.fp.text },
        { name = "CRD", color = style.fp.text },
        { name = "PKT", color = style.fp.text },
        { name = "DEV", color = style.fp.text },
        { name = "INF", color = style.fp.text }
    }

    TabBar{parent=panel,y=2,tabs=tabs,min_width=7,callback=page_pane.set_value,fg_bg=style.theme.highlight_box_bright}

    -- vincular gerenciamento de listas RTU/PDG/CHK ao PGI
    pgi.link_elements(rtu_list, rtu_entry, pdg_list, pdg_entry, chk_list, chk_entry)
end

return init
