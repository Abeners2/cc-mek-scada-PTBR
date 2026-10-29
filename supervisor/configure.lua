--
-- GUI de Configuração
--

local log         = require("scada-common.log")
local ppm         = require("scada-common.ppm")
local tcd         = require("scada-common.tcd")
local types       = require("scada-common.types")
local util        = require("scada-common.util")

local facility    = require("supervisor.config.facility")
local mekanism    = require("supervisor.config.mekanism")
local system      = require("supervisor.config.system")

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

-- alterações nos dados/formato de configuração para informar o usuário
local changes = {
    { "v1.2.12", { "Adicionado tema de UI do painel frontal", "Adicionados modos de acessibilidade de cor" } },
    { "v1.3.2", { "Adicionado modo de cor padrão com estado desligado preto", "Adicionados modos de cor de indicador azul" } },
    { "v1.6.0", { "Adicionada opção de refrigerante de emergência de sódio" } },
    { "v1.8.0", { "Adicionado suporte para modems de comunicação cabeados", "Adicionada opção para permitir conexões Pocket", "Adicionada opção para permitir comandos de teste Pocket" } },
    { "v1.9.5", { "Adicionadas opções de configuração do Mekanism Generators" } },
    { "v1.9.9", { "Adicionadas opções de configuração de proporção de resíduos" } },
    { "v1.10.4", { "Adicionada opção para usar SNAs nas estatísticas de polônio (padrão)" } },
    { "v1.11.0", { "Adicionada opção para resíduos combinados da instalação" } },
    { "v1.12.0", { "Adicionadas opções para o sistema de armazenamento de energia" } }
}

---@class svr_configurator
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

---@class _svr_cfg_tool_ctl
local tool_ctl = {
    launch_startup = false,
    ask_config = false,
    has_config = false,
    viewing_config = false,
    jumped_to_color = false,

    view_cfg = nil,       ---@type PushButton
    color_cfg = nil,      ---@type PushButton
    color_next = nil,     ---@type PushButton
    color_apply = nil,    ---@type PushButton
    settings_apply = nil, ---@type PushButton

    num_units = nil,      ---@type NumberField
    en_fac_tanks = nil,   ---@type Checkbox
    tank_mode = nil,      ---@type RadioButton
    tank_fluid_opts = {}, ---@type Radio2D[]

    gen_summary = nil,    ---@type function
    load_legacy = nil,    ---@type function

    cooling_elems = {},   ---@type { line: Div, turbines: NumberField, boilers: NumberField, tank: Checkbox }[]
    tank_elems = {},      ---@type { div: Div, tank_opt: Radio2D, no_tank: TextBox }[]
    aux_cool_elems = {},  ---@type { line: Div, enable: Checkbox }[]
    ext_idling = nil,     ---@type Checkbox
    sna_stats = nil,      ---@type Checkbox
    com_waste = nil,      ---@type Checkbox
    ess_opt = nil,        ---@type RadioButton

    mek_profile = nil,    ---@type RadioButton
    custom_configs = {},  ---@type NumberField[]
    waste_ratios = {},    ---@type NumberField[]

    gen_modem_list = function () end,

    dw_free_space = nil,  ---@type TextBox
    dw_log_size = nil,    ---@type TextBox
    dw_del_log_btn = nil, ---@type PushButton
    dw_continue = nil     ---@type PushButton
}

---@class svr_config
local tmp_cfg = {
    UnitCount = 1,
    CoolingConfig = {},     ---@type { TurbineCount: integer, BoilerCount: integer, TankConnection: boolean }[]
    FacilityTankMode = 0,   -- layout de refrigerante de emergência de tanque dinâmico
    FacilityTankDefs = {},  ---@type integer[] destino de conexão de tanque de cada unidade (0 = desconectado, 1 = unidade, 2 = instalação)
    FacilityTankList = {},  ---@type integer[] lista de tanques por slot (0 = nenhum ou coberto por tanque acima, 1 = tanque de unidade, 2 = tanque da instalação)
    FacilityTankConns = {}, ---@type integer[] mapa de conexões de tanques de unidades (índices são unidades, valores são índices de tanques na lista de tanques)
    TankFluidTypes = {},    ---@type integer[] qual tipo de fluido cada tanque na lista de tanques deve conter
    AuxiliaryCoolant = {},  ---@type boolean[] se uma unidade possui refrigerante auxiliar
    ExtChargeIdling = false,
    UseSNAStatistics = true,
    CombinedWaste = false,
    EnergyStorageSystem = 1, ---@type ESS
    MekanismProfile = mekanism.profiles[1].name,
    MekanismConfig = mekanism.profiles[1].fields,
    MekanismWasteToPu = { 10, 1 },
    MekanismWasteToPo = { 10, 1 },
    WirelessModem = true,
    WiredModem = false,     ---@type string|false
    PLC_Listen = 1,         ---@type LISTEN_MODE
    RTU_Listen = 1,         ---@type LISTEN_MODE
    CRD_Listen = 1,         ---@type LISTEN_MODE
    PocketEnabled = true,
    PocketTest = true,
    SVR_Channel = nil,      ---@type integer
    PLC_Channel = nil,      ---@type integer
    RTU_Channel = nil,      ---@type integer
    CRD_Channel = nil,      ---@type integer
    PKT_Channel = nil,      ---@type integer
    PLC_Timeout = nil,      ---@type number
    RTU_Timeout = nil,      ---@type number
    CRD_Timeout = nil,      ---@type number
    PKT_Timeout = nil,      ---@type number
    TrustedRange = nil,     ---@type number
    AuthKey = nil,          ---@type string|nil
    LogMode = 0,            ---@type LOG_MODE
    LogPath = "",
    LogDebug = false,
    FrontPanelTheme = 1,    ---@type FP_THEME
    ColorMode = 1           ---@type COLOR_MODE
}

---@class svr_config
local ini_cfg = {}
---@class svr_config
local settings_cfg = {}

-- todos os campos de configurações, seus nomes amigáveis e seus valores padrão
local fields = {
    { "UnitCount", "Número de Reatores", 1 },
    { "CoolingConfig", "Configuração de Resfriamento", {} },
    { "FacilityTankMode", "Modo de Tanque da Instalação", 0 },
    { "FacilityTankDefs", "Definições de Tanques da Instalação", {} },
    { "FacilityTankList", "Lista de Tanques da Instalação", {} },         -- oculto
    { "FacilityTankConns", "Conexões de Tanques da Instalação", {} },     -- oculto
    { "TankFluidTypes", "Tipos de Fluido dos Tanques", {} },
    { "AuxiliaryCoolant", " Água de Resfriamento Auxiliar", {} },
    { "ExtChargeIdling", "Espera de Carga Estendida", false },
    { "UseSNAStatistics", "Usar Estatísticas de SNA", true },
    { "CombinedWaste", "Resíduos Combinados da Instalação", false },
    { "EnergyStorageSystem", "Sistema de Armazenamento de Energia", types.ESS.INDUCTION_MATRIX },
    { "MekanismProfile", "Perfil do Mekanism", mekanism.profiles[1].name },
    { "MekanismConfig", "Configuração do Mekanism", mekanism.profiles[1].fields },
    { "MekanismWasteToPu", "Resíduo Nuclear para Plutônio", { 10, 1 } },
    { "MekanismWasteToPo", "Resíduo Nuclear para Polônio", { 10, 1 } },
    { "WirelessModem", "Modem de Comms Sem Fio/Ender", true },
    { "WiredModem", "Modem de Comms Cabeado", false },
    { "PLC_Listen", "Modo de Escuta do CLP", types.LISTEN_MODE.WIRELESS },
    { "RTU_Listen", "Modo de Escuta do Gateway RTU", types.LISTEN_MODE.WIRELESS },
    { "CRD_Listen", "Modo de Escuta do Coordenador", types.LISTEN_MODE.WIRELESS },
    { "PocketEnabled", "Conectividade Pocket", true },
    { "PocketTest", "Recursos de Teste Pocket", true },
    { "SVR_Channel", "Canal SVR", 16240 },
    { "PLC_Channel", "Canal CLP", 16241 },
    { "RTU_Channel", "Canal RTU", 16242 },
    { "CRD_Channel", "Canal CRD", 16243 },
    { "PKT_Channel", "Canal PKT", 16244 },
    { "PLC_Timeout", "Tempo Limite de Conexão CLP", 5 },
    { "RTU_Timeout", "Tempo Limite de Conexão RTU", 5 },
    { "CRD_Timeout", "Tempo Limite de Conexão CRD", 5 },
    { "PKT_Timeout", "Tempo Limite de Conexão PKT", 5 },
    { "TrustedRange", "Alcance Confiável", 0 },
    { "AuthKey", "Chave de Autenticação" , "" },
    { "LogMode", "Modo de Log", log.MODE.APPEND },
    { "LogPath", "Caminho do Log", "/log.txt" },
    { "LogDebug", "Registrar Mensagens de Depuração", false },
    { "FrontPanelTheme", "Tema do Painel Frontal", themes.FP_THEME.SANDSTONE },
    { "ColorMode", "Modo de Cor", themes.COLOR_MODE.STANDARD }
}

-- carregar dados do arquivo de configurações
---@param target svr_config
---@param raw boolean? true para não usar valores padrão
local function load_settings(target, raw)
    for _, v in pairs(fields) do settings.unset(v[1]) end

    local loaded = settings.load("/supervisor.settings")

    for _, v in pairs(fields) do target[v[1]] = settings.get(v[1], tri(raw, nil, v[3])) end

    return loaded
end

-- criar a visualização de configuração
---@param display DisplayBox
local function config_view(display)
    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    local function exit() os.queueEvent("terminate") end

    TextBox{parent=display,y=1,text="Configurador do Supervisor",alignment=CENTER,fg_bg=style.header}

    local root_pane_div = Div{parent=display,y=2}

    local main_page = Div{parent=root_pane_div,y=1}
    local fac_cfg = Div{parent=root_pane_div,y=1}
    local mek_cfg = Div{parent=root_pane_div,y=1}
    local net_cfg = Div{parent=root_pane_div,y=1}
    local log_cfg = Div{parent=root_pane_div,y=1}
    local clr_cfg = Div{parent=root_pane_div,y=1}
    local summary = Div{parent=root_pane_div,y=1}
    local changelog = Div{parent=root_pane_div,y=1}
    local import_err = Div{parent=root_pane_div,y=1}
    local disk_warn = Div{parent=root_pane_div,y=1}

    local main_pane = MultiPane{parent=root_pane_div,y=1,panes={main_page,fac_cfg,mek_cfg,net_cfg,log_cfg,clr_cfg,summary,changelog,import_err,disk_warn}}

    local req_space = log.MIN_SPACE
    if fs.exists("/supervisor.settings") then
        req_space = math.max(0, req_space - fs.getSize("/supervisor.settings"))
    end

    -- mostrar aviso de espaço em disco se necessário
    if fs.getFreeSpace("/") < req_space then main_pane.set_value(10) end

    --#region Página Principal

    local y_start = 5

    TextBox{parent=main_page,x=2,y=2,height=2,text="Bem-vindo ao configurador do Supervisor! Selecione uma das opções a seguir."}

    if tool_ctl.ask_config then
        TextBox{parent=main_page,x=2,y=y_start,height=4,width=49,text="Aviso: Este dispositivo não está configurado para esta versão do Supervisor. Se tinha uma config válida antes, ela não foi perdida. Verifique o Log de Alterações para ver o que mudou.",fg_bg=cpair(colors.red,colors.lightGray)}
        y_start = y_start + 5
    end

    local function view_config()
        tool_ctl.viewing_config = true
        tool_ctl.gen_summary(settings_cfg)
        tool_ctl.settings_apply.hide(true)
        main_pane.set_value(7)
    end

    if fs.exists("/supervisor/config.lua") then
        PushButton{parent=main_page,x=2,y=y_start,min_width=28,text="Importar 'config.lua' Legado",callback=function()tool_ctl.load_legacy()end,fg_bg=cpair(colors.black,colors.cyan),active_fg_bg=btn_act_fg_bg}
        y_start = y_start + 2
    end

    PushButton{parent=main_page,x=2,y=y_start,min_width=18,text="Configurar Sistema",callback=function()main_pane.set_value(2)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
    tool_ctl.view_cfg = PushButton{parent=main_page,x=2,y=y_start+2,min_width=20,text="Ver Configuração",callback=view_config,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    local function jump_color()
        tool_ctl.jumped_to_color = true
        tool_ctl.color_next.hide(true)
        tool_ctl.color_apply.show()
        main_pane.set_value(6)
    end

    local function startup()
        tool_ctl.launch_startup = true
        exit()
    end

    tool_ctl.color_cfg = PushButton{parent=main_page,x=36,y=y_start,min_width=15,text="Opções de Cor",callback=jump_color,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    PushButton{parent=main_page,x=39,y=y_start+2,min_width=12,text="Alterações",callback=function()main_pane.set_value(8)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    if tool_ctl.ask_config then
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
        TextBox{parent=disk_page,y=9,height=2,text="Se o arquivo de log estiver neste computador e não em um disco externo, excluí-lo pode ajudar."}
        tool_ctl.dw_log_size = TextBox{parent=disk_page,y=12,height=1,text="Tamanho do Log: "..fs.getSize(ini_cfg.LogPath).." bytes",fg_bg=cpair(colors.gray,colors._INHERIT)}

        tool_ctl.dw_del_log_btn = PushButton{parent=disk_page,x=33,y=12,min_width=17,text="Excluir Arq. Log",callback=delete_log,fg_bg=cpair(colors.black,colors.orange),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
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

    --#region Configuração do Mekanism

    local mek_pane = mekanism.create(tool_ctl, main_pane, settings, mek_cfg, style)

    --#endregion

    --#region Configuração do Sistema

    local divs = { net_cfg, log_cfg, clr_cfg, summary, import_err }

    system.create(tool_ctl, main_pane, settings, divs, fac_pane, mek_pane, style, startup, exit)

    --#endregion

    --#region Log de Alterações da Configuração

    local cl = Div{parent=changelog,x=2,y=4,width=49}

    TextBox{parent=changelog,y=2,text=" Log de Alterações da Config.",fg_bg=bw_fg_bg}

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

-- redefinir tela do terminal
local function reset_term()
    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
end

-- executar o configurador do supervisor
---@param ask_config? boolean indicar se está sendo chamado pelo app de inicialização devido a uma configuração inválida
function configurator.configure(ask_config)
    tool_ctl.ask_config = ask_config == true

    load_settings(settings_cfg, true)
    tool_ctl.has_config = load_settings(ini_cfg)

    -- estes precisam ser inicializados pois são usados antes de serem definidos
    tmp_cfg.WiredModem = ini_cfg.WiredModem
    tmp_cfg.FacilityTankMode = ini_cfg.FacilityTankMode
    tmp_cfg.TankFluidTypes = { table.unpack(ini_cfg.TankFluidTypes) }

    reset_term()

    ppm.mount_all()

    -- definir cores substituídas
    for i = 1, #style.colors do
        term.setPaletteColor(style.colors[i].c, style.colors[i].hex)
    end

    local status, error = pcall(function ()
        local display = DisplayBox{window=term.current(),fg_bg=style.root}
        config_view(display)

        tool_ctl.gen_modem_list()

        while true do
            local event, param1, param2, param3 = util.pull_event()

            -- tratar evento
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
                tool_ctl.gen_modem_list()
            elseif event == "peripheral" then
---@diagnostic disable-next-line: discard-returns
                ppm.mount(param1)
                tool_ctl.gen_modem_list()
            end

            if event == "terminate" then return end
        end
    end)

    -- restaurar cores
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
