--
-- GUI de Configuração
--

local log        = require("scada-common.log")
local ppm        = require("scada-common.ppm")
local tcd        = require("scada-common.tcd")
local types      = require("scada-common.types")
local util       = require("scada-common.util")

local facility   = require("coordinator.config.facility")
local hmi        = require("coordinator.config.hmi")
local system     = require("coordinator.config.system")

local core       = require("graphics.core")
local themes     = require("graphics.themes")

local DisplayBox = require("graphics.elements.DisplayBox")
local Div        = require("graphics.elements.Div")
local ListBox    = require("graphics.elements.ListBox")
local MultiPane  = require("graphics.elements.MultiPane")
local TextBox    = require("graphics.elements.TextBox")

local PushButton = require("graphics.elements.controls.PushButton")

local println = util.println
local tri = util.trinary

local cpair = core.cpair

local CENTER = core.ALIGN.CENTER

-- alterações nos dados/formato de configuração para avisar o usuário
local changes = {
    { "v1.2.4", { "Adicionadas opções de escala de temperatura" } },
    { "v1.2.12", { "Adicionado tema da UI principal", "Adicionado tema da UI do painel frontal", "Adicionados modos de acessibilidade de cores" } },
    { "v1.3.3", { "Adicionado modo de cor padrão com estado desligado preto", "Adicionados modos de cor de indicador azul" } },
    { "v1.5.1", { "Adicionadas opções de escala de energia" } },
    { "v1.6.13", { "Adicionada opção de par verde/ciano para pastilhas de Po/Pu" } },
    { "v1.7.0", { "Adicionado suporte a modems de comunicação cabeados", "Adicionada opção para permitir conexões Pocket" } },
    { "v1.9.7", { "Removida opção de Desativar Visão de Fluxo" } },
    { "v1.11.0", { "Adicionada opção para ativar as Visões Detalhadas de Fluxo", "Adicionada opção de alternador da Visão Detalhada de Fluxo" } },
    { "v1.12.0", { "Adicionada opção para alternar a tela de abertura (splash)" } }
}

---@class crd_configurator
local configurator = {}

local style = {}

style.root          = cpair(colors.black, colors.lightGray)
style.header        = cpair(colors.white, colors.gray)

style.colors        = themes.smooth_stone.colors

style.bw_fg_bg      = cpair(colors.black, colors.white)
style.g_lg_fg_bg    = cpair(colors.gray, colors.lightGray)
style.nav_fg_bg     = style.bw_fg_bg
style.btn_act_fg_bg = cpair(colors.white, colors.gray)
style.btn_dis_fg_bg = cpair(colors.lightGray,colors.white)

---@class _crd_cfg_tool_ctl
local tool_ctl = {
    -- configuração do supervisor
    com_waste = false,
    tank_mode = 0,
    tank_list = {},
    unit_bt_cnt = nil, ---@type [ integer, integer ][] lista de contagens de [ caldeira, turbina ]

    launch_startup = false,
    start_fail = 0,
    fail_message = "",
    has_config = false,
    viewing_config = false,
    jumped_to_color = false,

    view_cfg = nil,           ---@type PushButton
    color_cfg = nil,          ---@type PushButton
    color_next = nil,         ---@type PushButton
    color_apply = nil,        ---@type PushButton
    settings_apply = nil,     ---@type PushButton

    gen_summary = nil,        ---@type function
    load_legacy = nil,        ---@type function

    -- elementos de configuração da hmi
    s_vol = nil,              ---@type NumberField
    pellet_color = nil,       ---@type RadioButton
    clock_fmt = nil,          ---@type RadioButton
    temp_scale = nil,         ---@type RadioButton
    energy_scale = nil,       ---@type RadioButton
    en_flow_dtl = nil,        ---@type Checkbox
    show_win_sw = nil,        ---@type Checkbox
    en_splash = nil,          ---@type Checkbox

    -- elementos e funções de configuração da instalação (facility)
    num_units = nil,          ---@type NumberField
    init_sv_connect_ui = nil, ---@type function
    is_int_min_max = nil,     ---@type function

    update_mon_reqs = nil,    ---@type function

    gen_mon_list = function () end,
    gen_modem_list = function () end,

    dw_free_space = nil,      ---@type TextBox
    dw_log_size = nil,        ---@type TextBox
    dw_del_log_btn = nil,     ---@type PushButton
    dw_continue = nil         ---@type PushButton
}

---@class crd_config
local tmp_cfg = {
    UnitCount = 1,
    SpeakerVolume = 1.0,
    Time24Hour = true,
    GreenPuPellet = false,
    TempScale = 1,          ---@type TEMP_SCALE
    EnergyScale = 1,        ---@type ENERGY_SCALE
    FlowDetailView = false,
    FlowViewSwitcher = false,
    SplashScreen = true,
    MainDisplay = nil,      ---@type string
    FlowDisplay = nil,      ---@type string
    UnitDisplays = {},      ---@type string[]
    WirelessModem = true,
    WiredModem = false,     ---@type string|false
    PreferWireless = true,
    API_Enabled = true,
    SVR_Channel = nil,      ---@type integer
    CRD_Channel = nil,      ---@type integer
    PKT_Channel = nil,      ---@type integer
    SVR_Timeout = nil,      ---@type number
    API_Timeout = nil,      ---@type number
    TrustedRange = nil,     ---@type number
    AuthKey = nil,          ---@type string|nil
    LogMode = 0,            ---@type LOG_MODE
    LogPath = "",
    LogDebug = false,
    MainTheme = 1,          ---@type UI_THEME
    FrontPanelTheme = 1,    ---@type FP_THEME
    ColorMode = 1           ---@type COLOR_MODE
}

---@class crd_config
local ini_cfg = {}
---@class crd_config
local settings_cfg = {}

-- todos os campos de configuração, seus nomes amigáveis e seus valores padrão
local fields = {
    { "UnitCount", "Número de Reatores", 1 },
    { "MainDisplay", "Monitor Principal", nil },
    { "FlowDisplay", "Monitor de Fluxo", nil },
    { "UnitDisplays", "Monitores de Unidade", {} },
    { "SpeakerVolume", "Volume do Alto-falante", 1.0 },
    { "Time24Hour", "Formato de 24 Horas", true },
    { "GreenPuPellet", "Cor das Pastilhas", false },
    { "TempScale", "Escala de Temperatura", types.TEMP_SCALE.KELVIN },
    { "EnergyScale", "Escala de Energia", types.ENERGY_SCALE.FE },
    { "FlowDetailView", "Visões Detalhadas de Fluxo", false },
    { "FlowViewSwitcher", "Alternador de Visão de Fluxo", false },
    { "SplashScreen", "Usar Telas de Abertura", true },
    { "WirelessModem", "Modem Sem Fio/Ender", true },
    { "WiredModem", "Modem Cabeado", false },
    { "PreferWireless", "Preferir Modem Sem Fio", true },
    { "API_Enabled", "Conectividade API Pocket", true },
    { "SVR_Channel", "Canal SVR", 16240 },
    { "CRD_Channel", "Canal CRD", 16243 },
    { "PKT_Channel", "Canal PKT", 16244 },
    { "SVR_Timeout", "Timeout de Conexão do Supervisor", 5 },
    { "API_Timeout", "Timeout de Conexão da API", 5 },
    { "TrustedRange", "Alcance Confiável", 0 },
    { "AuthKey", "Chave de Autenticação" , ""},
    { "LogMode", "Modo de Log", log.MODE.APPEND },
    { "LogPath", "Caminho do Log", "/log.txt" },
    { "LogDebug", "Registrar Mensagens de Debug", false },
    { "MainTheme", "Tema da UI Principal", themes.UI_THEME.SMOOTH_STONE },
    { "FrontPanelTheme", "Tema do Painel Frontal", themes.FP_THEME.SANDSTONE },
    { "ColorMode", "Modo de Cor", themes.COLOR_MODE.STANDARD }
}

-- carrega campos de tmp_cfg a partir de ini_cfg para monitores
local function preset_monitor_fields()
    tmp_cfg.MainDisplay = ini_cfg.MainDisplay
    tmp_cfg.FlowDisplay = ini_cfg.FlowDisplay
    for i = 1, ini_cfg.UnitCount do
        tmp_cfg.UnitDisplays[i] = ini_cfg.UnitDisplays[i]
    end
end

-- carrega dados do arquivo de configurações
---@param target crd_config
---@param raw boolean? verdadeiro para não usar valores padrão
local function load_settings(target, raw)
    for _, v in pairs(fields) do settings.unset(v[1]) end

    local loaded = settings.load("/coordinator.settings")

    for _, v in pairs(fields) do target[v[1]] = settings.get(v[1], tri(raw, nil, v[3])) end

    return loaded
end

-- cria a visão de configuração
---@param display DisplayBox
local function config_view(display)
    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    local function exit() os.queueEvent("terminate") end

    TextBox{parent=display,y=1,text="Configurador do Coordenador",alignment=CENTER,fg_bg=style.header}

    local root_pane_div = Div{parent=display,y=2}

    local main_page = Div{parent=root_pane_div,y=1}
    local net_cfg = Div{parent=root_pane_div,y=1}
    local fac_cfg = Div{parent=root_pane_div,y=1}
    local crd_cfg = Div{parent=root_pane_div,y=1}
    local mon_cfg = Div{parent=root_pane_div,y=1}
    local spkr_cfg = Div{parent=root_pane_div,y=1}
    local log_cfg = Div{parent=root_pane_div,y=1}
    local clr_cfg = Div{parent=root_pane_div,y=1}
    local summary = Div{parent=root_pane_div,y=1}
    local changelog = Div{parent=root_pane_div,y=1}
    local disk_warn = Div{parent=root_pane_div,y=1}

    local main_pane = MultiPane{parent=root_pane_div,y=1,panes={main_page,net_cfg,fac_cfg,crd_cfg,mon_cfg,spkr_cfg,log_cfg,clr_cfg,summary,changelog,disk_warn}}

    local req_space = log.MIN_SPACE
    if fs.exists("/coordinator.settings") then
        req_space = math.max(0, req_space - fs.getSize("/coordinator.settings"))
    end

    -- mostra aviso de espaço em disco se necessário
    if fs.getFreeSpace("/") < req_space then main_pane.set_value(11) end

    --#region Página Principal

    local y_start = 5

    TextBox{parent=main_page,x=2,y=2,height=2,text="Bem-vindo ao configurador do Coordenador! Selecione uma das opções a seguir."}

    if tool_ctl.start_fail == 2 then
        local msg = util.c("Aviso: Há um problema na configuração de monitores. ", tool_ctl.fail_message, " Reconfigure os monitores ou corrija seus tamanhos.")
        TextBox{parent=main_page,x=2,y=y_start,height=4,width=49,text=msg,fg_bg=cpair(colors.red,colors.lightGray)}
        y_start = y_start + 5
    elseif tool_ctl.start_fail > 0 then
        TextBox{parent=main_page,x=2,y=y_start,height=4,width=49,text="Aviso: Este dispositivo não está configurado para esta versão do Coordenador. Se você tinha uma config válida, ela não foi perdida. Verifique o Log de Alterações para ver o que mudou.",fg_bg=cpair(colors.red,colors.lightGray)}
        y_start = y_start + 5
    end

    local function view_config()
        tool_ctl.viewing_config = true
        tool_ctl.gen_summary(settings_cfg)
        tool_ctl.settings_apply.hide(true)
        main_pane.set_value(9)
    end

    if fs.exists("/coordinator/config.lua") then
        PushButton{parent=main_page,x=2,y=y_start,min_width=28,text="Importar 'config.lua' Legado",callback=function()tool_ctl.load_legacy()end,fg_bg=cpair(colors.black,colors.cyan),active_fg_bg=btn_act_fg_bg}
        y_start = y_start + 2
    end

    PushButton{parent=main_page,x=2,y=y_start,min_width=18,text="Configurar Sistema",callback=function()main_pane.set_value(2)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
    tool_ctl.view_cfg = PushButton{parent=main_page,x=2,y=y_start+2,min_width=20,text="Ver Configuração",callback=view_config,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    local function jump_color()
        tool_ctl.jumped_to_color = true
        tool_ctl.color_next.hide(true)
        tool_ctl.color_apply.show()
        main_pane.set_value(8)
    end

    local function startup()
        tool_ctl.launch_startup = true
        exit()
    end

    tool_ctl.color_cfg = PushButton{parent=main_page,x=36,y=y_start,min_width=15,text="Opções de Cor",callback=jump_color,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,dis_fg_bg=cpair(colors.lightGray,colors.white)}
    PushButton{parent=main_page,x=39,y=y_start+2,min_width=12,text="Alterações",callback=function()main_pane.set_value(10)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.start_fail ~= 0 then
        PushButton{parent=main_page,x=2,y=17,min_width=6,text="Sair",callback=exit,dis_fg_bg=btn_dis_fg_bg}.disable()
        PushButton{parent=main_page,x=35,y=17,min_width=16,text="Retomar Início",callback=exit,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg}
    else
        PushButton{parent=main_page,x=2,y=17,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
        PushButton{parent=main_page,x=42,y=17,min_width=9,text="Iniciar",callback=startup,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg}
    end

    if not tool_ctl.has_config then
        tool_ctl.view_cfg.disable()
        tool_ctl.color_cfg.disable()
    end

    --#endregion

    -- #region Aviso de Espaço em Disco

    TextBox{parent=disk_warn,y=2,text=" Espaço em Disco Insuficiente",fg_bg=cpair(colors.white,colors.black)}

    local disk_page = Div{parent=disk_warn,x=2,y=4,width=49}

    local function delete_log()
        fs.delete(ini_cfg.LogPath)

        local space = fs.getFreeSpace("/")
        tool_ctl.dw_free_space.set_value("Espaço Livre Disponível: "..space.." bytes")

        if not fs.exists(ini_cfg.LogPath) then
            tool_ctl.dw_log_size.set_value("Tamanho do Arquivo de Log: 0 bytes")
            tool_ctl.dw_del_log_btn.disable()
        end

        if space >= req_space then tool_ctl.dw_continue.enable() end
    end

    TextBox{parent=disk_page,height=3,text="Não há espaço em disco suficiente para configurar este dispositivo com segurança. Salvar a configuração pode falhar e causar perda de dados."}

    TextBox{parent=disk_page,y=5,height=1,text="Capacidade:              "..fs.getCapacity("/").." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}
    tool_ctl.dw_free_space = TextBox{parent=disk_page,height=1,text="Espaço Livre Disponível: "..fs.getFreeSpace("/").." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}
    TextBox{parent=disk_page,height=1,text="Espaço Livre Necessário: "..req_space.." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}

    if fs.exists(ini_cfg.LogPath) then
        TextBox{parent=disk_page,y=9,height=2,text="Se o seu arquivo de log estiver neste computador e não em um disco externo, excluí-lo pode ajudar."}
        tool_ctl.dw_log_size = TextBox{parent=disk_page,y=12,height=1,text="Tamanho do Arquivo de Log: "..fs.getSize(ini_cfg.LogPath).." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}

        tool_ctl.dw_del_log_btn = PushButton{parent=disk_page,x=33,y=12,min_width=17,text="Excluir Log",callback=delete_log,fg_bg=cpair(colors.black,colors.orange),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    else
        TextBox{parent=disk_page,y=9,height=4,text="O arquivo de log não foi encontrado, então você precisará liberar espaço manualmente. Remova quaisquer arquivos não relacionados a este aplicativo que você tenha criado."}
    end

    PushButton{parent=disk_page,y=14,min_width=6,text="Sair",callback=exit,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}
    tool_ctl.dw_continue = PushButton{parent=disk_page,x=40,y=14,min_width=10,text="Continuar",callback=function()main_pane.set_value(1)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    tool_ctl.dw_continue.disable()

    -- #endregion

    local settings = { settings_cfg, ini_cfg, tmp_cfg, fields, load_settings }

    --#region Configuração da Instalação

    local fac_pane = facility.create(tool_ctl, main_pane, settings, fac_cfg, style)

    --#endregion

    --#region Configuração da IHM

    local crd_pane, mon_pane = hmi.create(tool_ctl, main_pane, settings, { crd_cfg, mon_cfg, spkr_cfg }, style)

    --#endregion

    --#region Configuração do Sistema

    local divs = { net_cfg, log_cfg, clr_cfg, summary }
    local ext  = { fac_pane, crd_pane, mon_pane, preset_monitor_fields, startup, exit }

    system.create(tool_ctl, main_pane, settings, divs, ext, style)

    --#endregion

    --#region Log de Alterações de Config

    local cl = Div{parent=changelog,x=2,y=4,width=49}

    TextBox{parent=changelog,y=2,text=" Log de Alterações de Config",fg_bg=bw_fg_bg}

    local c_log = ListBox{parent=cl,y=1,height=12,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    for _, change in ipairs(changes) do
        TextBox{parent=c_log,text=change[1],fg_bg=bw_fg_bg}
        for _, v in ipairs(change[2]) do
            local e = Div{parent=c_log,height=#util.strwrap(v,46)}
            TextBox{parent=e,y=1,text="- ",fg_bg=cpair(colors.gray,colors.white)}
            TextBox{parent=e,y=1,x=3,text=v,height=e.get_height(),fg_bg=cpair(colors.gray,colors.white)}
        end
    end

    PushButton{parent=cl,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
end

-- redefine a tela do terminal
local function reset_term()
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

-- executa o configurador do coordenador<br>
-- start_fail 0 é OK (padrão se não fornecido), 1 é config inválida, 2 é config de monitor inválida
---@param start_code? 0|1|2 indica estado de erro quando chamado pelo app de inicialização
---@param message? any mensagem em string para exibir em um start_fail de 2
function configurator.configure(start_code, message)
    tool_ctl.start_fail = start_code or 0
    tool_ctl.fail_message = util.trinary(type(message) == "string", message, "")

    load_settings(settings_cfg, true)
    tool_ctl.has_config = load_settings(ini_cfg)

    -- copia alguns valores importantes para começar
    preset_monitor_fields()

    -- precisa ser inicializado pois é usado antes de ser definido
    tmp_cfg.WiredModem = ini_cfg.WiredModem

    reset_term()

    ppm.mount_all()

    -- define cores sobrescritas
    for i = 1, #style.colors do
        term.setPaletteColor(style.colors[i].c, style.colors[i].hex)
    end

    local status, error = pcall(function ()
        local display = DisplayBox{window=term.current(),fg_bg=style.root}
        config_view(display)

        tool_ctl.gen_mon_list()
        tool_ctl.gen_modem_list()

        while true do
            local event, param1, param2, param3, param4, param5 = util.pull_event()

            -- trata evento
            if event == "timer" then
                tcd.handle(param1)
            elseif event == "mouse_click" or event == "mouse_up" or event == "mouse_drag" or event == "mouse_scroll" or event == "double_click" then
                local m_e = core.events.new_mouse_event(event, param1, param2, param3)
                if m_e then display.handle_mouse(m_e) end
            elseif event == "char" or event == "key" or event == "key_up" then
                local k_e = core.events.new_key_event(event, param1, param2)
                if k_e then display.handle_key(k_e) end
            elseif event == "paste" then
                display.handle_paste(param1)
            elseif event == "peripheral_detach" then
---@diagnostic disable-next-line: discard-returns
                ppm.handle_unmount(param1)
                tool_ctl.gen_mon_list()
            elseif event == "peripheral" then
---@diagnostic disable-next-line: discard-returns
                ppm.mount(param1)
                tool_ctl.gen_mon_list()
                tool_ctl.gen_modem_list()
            elseif event == "monitor_resize" then
                tool_ctl.gen_mon_list()
                tool_ctl.gen_modem_list()
            elseif event == "modem_message" then
                facility.receive_sv(param1, param2, param3, param4, param5)
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
        println("erro do configurador: " .. error)
    end

    return status, error, tool_ctl.launch_startup
end

return configurator
