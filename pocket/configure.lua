--
-- GUI de Configuracao
--

local log         = require("scada-common.log")
local types       = require("scada-common.types")
local util        = require("scada-common.util")

local system      = require("pocket.config.system")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local DisplayBox  = require("graphics.elements.DisplayBox")
local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local PushButton  = require("graphics.elements.controls.PushButton")

local println = util.println
local tri = util.trinary

local cpair = core.cpair

local CENTER = core.ALIGN.CENTER

-- alteracoes nos dados/formato de configuracao para informar o usuario
local changes = {
    { "v0.9.2", { "Adicionadas opcoes de escala de temperatura" } },
    { "v0.11.3", { "Adicionadas opcoes de escala de energia" } },
    { "v0.13.2", { "Adicionada opcao de cor verde/ciano para pastilhas Po/Pu" } }
}

---@class pkt_configurator
local configurator = {}

local style = {}

style.root          = cpair(colors.black, colors.lightGray)
style.header        = cpair(colors.white, colors.gray)

style.colors        = themes.smooth_stone.colors

style.bw_fg_bg      = cpair(colors.black, colors.white)
style.g_lg_fg_bg    = cpair(colors.gray, colors.lightGray)
style.nav_fg_bg     = style.bw_fg_bg
style.btn_act_fg_bg = cpair(colors.white, colors.gray)
style.btn_dis_fg_bg = cpair(colors.lightGray, colors.white)

---@class _pkt_cfg_tool_ctl
local tool_ctl = {
    launch_startup = false,
    ask_config = false,
    has_config = false,
    viewing_config = false,

    view_cfg = nil,       ---@type PushButton
    settings_apply = nil, ---@type PushButton

    gen_summary = nil,    ---@type function
    load_legacy = nil,    ---@type function

    dw_free_space = nil,  ---@type TextBox
    dw_log_size = nil,    ---@type TextBox
    dw_del_log_btn = nil, ---@type PushButton
    dw_continue = nil     ---@type PushButton
}

---@class pkt_config
local tmp_cfg = {
    GreenPuPellet = false,
    TempScale = 1,      ---@type TEMP_SCALE
    EnergyScale = 1,    ---@type ENERGY_SCALE
    SVR_Channel = nil,  ---@type integer
    CRD_Channel = nil,  ---@type integer
    PKT_Channel = nil,  ---@type integer
    ConnTimeout = nil,  ---@type number
    TrustedRange = nil, ---@type number
    AuthKey = nil,      ---@type string|nil
    LogMode = 0,        ---@type LOG_MODE
    LogPath = "",
    LogDebug = false,
}

---@class pkt_config
local ini_cfg = {}
---@class pkt_config
local settings_cfg = {}

-- todos os campos de configuracao, seus nomes amigaveis e valores padrao
local fields = {
    { "GreenPuPellet", "Cor Pastilhas", false },
    { "TempScale", "Escala Temp.", types.TEMP_SCALE.KELVIN },
    { "EnergyScale", "Escala Energia", types.ENERGY_SCALE.FE },
    { "SVR_Channel", "Canal SVR", 16240 },
    { "CRD_Channel", "Canal CRD", 16243 },
    { "PKT_Channel", "Canal PKT", 16244 },
    { "ConnTimeout", "Tempo Limite", 5 },
    { "TrustedRange", "Alcance Conf.", 0 },
    { "AuthKey", "Chave Autent." , ""},
    { "LogMode", "Modo de Log", log.MODE.APPEND },
    { "LogPath", "Caminho do Log", "/log.txt" },
    { "LogDebug", "Log de Debug", false }
}

-- carrega dados do arquivo de configuracao
---@param target pkt_config
---@param raw boolean? true para nao usar valores padrao
local function load_settings(target, raw)
    for _, v in pairs(fields) do settings.unset(v[1]) end

    local loaded = settings.load("/pocket.settings")

    for _, v in pairs(fields) do target[v[1]] = settings.get(v[1], tri(raw, nil, v[3])) end

    return loaded
end

-- cria a visualizacao de configuracao
---@param display DisplayBox
local function config_view(display)
    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    local function exit() os.queueEvent("terminate") end

    TextBox{parent=display,y=1,text="Configurador do Pocket",alignment=CENTER,fg_bg=style.header}

    local root_pane_div = Div{parent=display,y=2}

    local main_page = Div{parent=root_pane_div,y=1}
    local ui_cfg = Div{parent=root_pane_div,y=1}
    local net_cfg = Div{parent=root_pane_div,y=1}
    local log_cfg = Div{parent=root_pane_div,y=1}
    local summary = Div{parent=root_pane_div,y=1}
    local changelog = Div{parent=root_pane_div,y=1}
    local disk_warn = Div{parent=root_pane_div,y=1}

    local main_pane = MultiPane{parent=root_pane_div,y=1,panes={main_page,ui_cfg,net_cfg,log_cfg,summary,changelog,disk_warn}}

    local req_space = log.MIN_SPACE
    if fs.exists("/pocket.settings") then
        req_space = math.max(0, req_space - fs.getSize("/pocket.settings"))
    end

    -- mostra aviso de espaco em disco se necessario
    if fs.getFreeSpace("/") < req_space then main_pane.set_value(7) end

    --#region Main Page

    local y_start = 7

    TextBox{parent=main_page,x=2,y=2,height=4,text="Bem-vindo ao configurador do Pocket! Selecione uma das opcoes a seguir."}

    if tool_ctl.ask_config then
        TextBox{parent=main_page,x=2,y=y_start,height=4,width=49,text="Configure o dispositivo antes de iniciar.",fg_bg=cpair(colors.red,colors.lightGray)}
        y_start = y_start + 3
    end

    local function view_config()
        tool_ctl.viewing_config = true
        tool_ctl.gen_summary(settings_cfg)
        tool_ctl.settings_apply.hide(true)
        main_pane.set_value(5)
    end

    if fs.exists("/pocket/config.lua") then
        PushButton{parent=main_page,x=2,y=y_start,min_width=22,text="Importar Cfg. Antiga",callback=function()tool_ctl.load_legacy()end,fg_bg=cpair(colors.black,colors.cyan),active_fg_bg=btn_act_fg_bg}
        y_start = y_start + 2
    end

    PushButton{parent=main_page,x=2,y=y_start,min_width=18,text="Configurar Disp.",callback=function()main_pane.set_value(2)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
    tool_ctl.view_cfg = PushButton{parent=main_page,x=2,y=y_start+2,min_width=20,text="Ver Configuracao",callback=view_config,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    if not tool_ctl.has_config then tool_ctl.view_cfg.disable() end

    local function startup()
        tool_ctl.launch_startup = true
        exit()
    end

    PushButton{parent=main_page,x=2,y=y_start+4,min_width=12,text="Alteracoes",callback=function()main_pane.set_value(6)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.ask_config then
        PushButton{parent=main_page,x=2,y=18,min_width=6,text="Sair",callback=exit,dis_fg_bg=btn_dis_fg_bg}.disable()
        PushButton{parent=main_page,x=18,y=18,min_width=8,text="Retomar",callback=exit,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg}
    else
        PushButton{parent=main_page,x=2,y=18,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
        PushButton{parent=main_page,x=17,y=18,min_width=9,text="Iniciar",callback=startup,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    end

    --#endregion

    -- #region Disk Space Warning

    TextBox{parent=disk_warn,y=2,text=" Espaco Insuficiente",fg_bg=cpair(colors.white,colors.black)}

    local disk_page = Div{parent=disk_warn,x=2,y=4,width=24}

    local function delete_log()
        fs.delete(ini_cfg.LogPath)

        local space = fs.getFreeSpace("/")
        tool_ctl.dw_free_space.set_value(space.." bytes livres")

        if not fs.exists(ini_cfg.LogPath) then
            tool_ctl.dw_log_size.set_value("log de 0 bytes")
            tool_ctl.dw_del_log_btn.disable()
        end

        if space >= req_space then tool_ctl.dw_continue.enable() end
    end

    TextBox{parent=disk_page,height=5,text="Nao ha espaco suficiente para configurar com seguranca. Salvar pode falhar."}

    tool_ctl.dw_free_space = TextBox{parent=disk_page,height=1,text=fs.getFreeSpace("/").." bytes livres",fg_bg=cpair(colors.gray,colors._INHERIT)}
    TextBox{parent=disk_page,height=1,text=req_space.." bytes necessarios",fg_bg=cpair(colors.gray,colors._INHERIT)}

    if fs.exists(ini_cfg.LogPath) then
        tool_ctl.dw_log_size = TextBox{parent=disk_page,y=8,height=1,text="log de "..fs.getSize(ini_cfg.LogPath).." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}

        TextBox{parent=disk_page,y=10,height=2,text="Voce pode excluir o log para liberar espaco."}
        tool_ctl.dw_del_log_btn = PushButton{parent=disk_page,y=13,min_width=17,text="Excluir Arq. Log",callback=delete_log,fg_bg=cpair(colors.black,colors.orange),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    else
        TextBox{parent=disk_page,y=9,height=5,text="O arquivo de log nao foi encontrado. Libere espaco manualmente removendo outros arquivos."}
    end

    PushButton{parent=disk_page,y=15,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
    tool_ctl.dw_continue = PushButton{parent=disk_page,x=15,y=15,min_width=10,text="Continuar",callback=function()main_pane.set_value(1)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    tool_ctl.dw_continue.disable()

    -- #endregion

    --#region System Configuration

    local settings = { settings_cfg, ini_cfg, tmp_cfg, fields, load_settings }
    local divs     = { ui_cfg, net_cfg, log_cfg, summary }

    system.create(tool_ctl, main_pane, settings, divs, style, startup, exit)

    --#endregion

    --#region Config Change Log

    local cl = Div{parent=changelog,x=2,y=4,width=24}

    TextBox{parent=changelog,y=2,text=" Hist. de Alteracoes",fg_bg=bw_fg_bg}

    local c_log = ListBox{parent=cl,y=1,height=13,width=24,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    for _, change in ipairs(changes) do
        TextBox{parent=c_log,text=change[1],fg_bg=bw_fg_bg}
        for _, v in ipairs(change[2]) do
            local e = Div{parent=c_log,height=#util.strwrap(v,21)}
            TextBox{parent=e,y=1,text="- ",fg_bg=cpair(colors.gray,colors.white)}
            TextBox{parent=e,y=1,x=3,text=v,height=e.get_height(),fg_bg=cpair(colors.gray,colors.white)}
        end
    end

    PushButton{parent=cl,y=15,text="\x1b Voltar",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
end

-- redefine a tela do terminal
local function reset_term()
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

-- executa o configurador do pocket
---@param ask_config? boolean indica se esta sendo chamado pelo startup devido a uma configuracao invalida
function configurator.configure(ask_config)
    tool_ctl.ask_config = ask_config == true

    load_settings(settings_cfg, true)
    tool_ctl.has_config = load_settings(ini_cfg)

    reset_term()

    -- define cores substituidas
    for i = 1, #style.colors do
        term.setPaletteColor(style.colors[i].c, style.colors[i].hex)
    end

    local status, error = pcall(function ()
        local display = DisplayBox{window=term.current(),fg_bg=style.root}
        config_view(display)

        while true do
            local event, param1, param2, param3 = util.pull_event()

            -- trata evento
            if event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
                local m_e = core.events.new_mouse_event(event, param1, param2, param3)
                if m_e then display.handle_mouse(m_e) end
            elseif event == "char" or event == "key" or event == "key_up" then
                local k_e = core.events.new_key_event(event, param1, param2)
                if k_e then display.handle_key(k_e) end
            elseif event == "paste" then
                display.handle_paste(param1)
            end

            if event == "terminate" then return end
        end
    end)

    -- restaura cores
    for i = 1, #style.colors do
        local r, g, b = term.nativePaletteColor(style.colors[i].c)
        term.setPaletteColor(style.colors[i].c, r, g, b)
    end

    reset_term()
    if not status then
        println("erro no configurador: " .. error)
    end

    return status, error, tool_ctl.launch_startup
end

return configurator
