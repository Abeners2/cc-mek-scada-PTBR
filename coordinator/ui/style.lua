--
-- Graphics Style Options
--

local util        = require("scada-common.util")

local core        = require("graphics.core")
local themes      = require("graphics.themes")

local coordinator = require("coordinator.coordinator")

---@class crd_style
local style = {}

local cpair = core.cpair

local config = coordinator.config

-- estilo do painel frontal

style.fp_theme = themes.sandstone
style.fp = themes.get_fp_style(style.fp_theme)

style.led_grn = cpair(colors.green, colors.green_off)

-- estilo da GUI principal

---@class theme
local smooth_stone = {
    text = colors.black,
    text_inv = colors.white,
    label = colors.gray,
    label_dark = colors.gray,
    disabled = colors.lightGray,
    bg = colors.lightGray,
    checkbox_bg = colors.black,
    accent_light = colors.white,
    accent_dark = colors.gray,

    fuel_color = colors.black,

    header = cpair(colors.white, colors.gray),

    text_fg = cpair(colors.black, colors._INHERIT),
    label_fg = cpair(colors.gray, colors._INHERIT),
    disabled_fg = cpair(colors.lightGray, colors._INHERIT),

    highlight_box = cpair(colors.black, colors.white),
    highlight_box_bright = cpair(colors.black, colors.white),
    field_box = cpair(colors.black, colors.white),

    colors = themes.smooth_stone.colors,

    -- remapeamento de cores para modos assistivos
    color_modes = themes.smooth_stone.color_modes
}

---@type theme
local deepslate = {
    text = colors.white,
    text_inv = colors.black,
    label = colors.lightGray,
    label_dark = colors.gray,
    disabled = colors.gray,
    bg = colors.black,
    checkbox_bg = colors.gray,
    accent_light = colors.gray,
    accent_dark = colors.lightGray,

    fuel_color = colors.lightGray,

    header = cpair(colors.white, colors.gray),

    text_fg = cpair(colors.white, colors._INHERIT),
    label_fg = cpair(colors.lightGray, colors._INHERIT),
    disabled_fg = cpair(colors.gray, colors._INHERIT),

    highlight_box = cpair(colors.white, colors.gray),
    highlight_box_bright = cpair(colors.black, colors.lightGray),
    field_box = cpair(colors.white, colors.gray),

    colors = themes.deepslate.colors,

    -- remapeamento de cores para modos assistivos
    color_modes = themes.deepslate.color_modes
}

style.theme = smooth_stone

-- define os temas conforme a configuracao
---@param main UI_THEME main UI theme
---@param fp FP_THEME front panel theme
---@param color_mode COLOR_MODE the color mode to use
function style.set_themes(main, fp, color_mode)
    local colorblind = color_mode ~= themes.COLOR_MODE.STANDARD and color_mode ~= themes.COLOR_MODE.STD_ON_BLACK
    local gray_ind_off = color_mode == themes.COLOR_MODE.STANDARD or color_mode == themes.COLOR_MODE.BLUE_IND

    style.ind_bkg = colors.gray
    style.fp_ind_bkg = util.trinary(gray_ind_off, colors.gray, colors.black)
    style.ind_hi_box_bg = util.trinary(gray_ind_off, colors.gray, colors.black)

    if main == themes.UI_THEME.SMOOTH_STONE then
        style.theme = smooth_stone
        style.ind_bkg = util.trinary(gray_ind_off, colors.gray, colors.black)
    elseif main == themes.UI_THEME.DEEPSLATE then
        style.theme = deepslate
        style.ind_hi_box_bg = util.trinary(gray_ind_off, colors.lightGray, colors.black)
    end

    style.colorblind = colorblind

    style.root = cpair(style.theme.text, style.theme.bg)
    style.label = cpair(style.theme.label, style.theme.bg)

    -- texto de alto contraste (tambem tags)
    style.hc_text = cpair(style.theme.text, style.theme.text_inv)
    -- texto no fundo padrao
    style.text_colors = cpair(style.theme.text, style.theme.bg)
    -- cores de rotulo e unidade
    style.lu_colors = cpair(style.theme.label, style.theme.label)
    -- cores de rotulo e unidade (mais escuras se definido)
    style.lu_colors_dark = cpair(style.theme.label_dark, style.theme.label_dark)

    style.ind_grn = cpair(util.trinary(colorblind, colors.blue, colors.green), style.ind_bkg)
    style.ind_yel = cpair(colors.yellow, style.ind_bkg)
    style.ind_red = cpair(colors.red, style.ind_bkg)
    style.ind_wht = cpair(colors.white, style.ind_bkg)

    if fp == themes.FP_THEME.SANDSTONE then
        style.fp_theme = themes.sandstone
    elseif fp == themes.FP_THEME.BASALT then
        style.fp_theme = themes.basalt
    end

    style.fp = themes.get_fp_style(style.fp_theme)
end

-- PARES DE CORES COMUNS --

style.wh_gray = cpair(colors.white, colors.gray)

style.bw_fg_bg = cpair(colors.black, colors.white)

style.hzd_fg_bg  = style.wh_gray
style.dis_colors = cpair(colors.white, colors.lightGray)

style.lg_gray = cpair(colors.lightGray, colors.gray)
style.lg_white = cpair(colors.lightGray, colors.white)
style.gray_white = cpair(colors.gray, colors.white)

-- COMPONENTES DE UI --

style.reactor = {
    -- estados do reator<br>
    ---@see REACTOR_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "PLC OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "PLC  FALHA" },
        { color = cpair(colors.white, colors.gray),   text = "DESATIVADO" },
        { color = cpair(colors.black, colors.green),  text = "ATIVO" },
        { color = cpair(colors.black, colors.red),    text = "EM SCRAM" },
        { color = cpair(colors.black, colors.red),    text = "DESAT. FORCADO" }
    }
}

style.boiler = {
    -- estados da caldeira<br>
    ---@see BOILER_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "RTU  FALHA" },
        { color = cpair(colors.white, colors.gray),   text = "OCIOSO" },
        { color = cpair(colors.black, colors.green),  text = "ATIVO" }
    }
}

style.turbine = {
    -- estados da turbina<br>
    ---@see TURBINE_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "RTU  FALHA" },
        { color = cpair(colors.white, colors.gray),   text = "OCIOSO" },
        { color = cpair(colors.black, colors.green),  text = "ATIVO" },
        { color = cpair(colors.black, colors.red),    text = "DESARME" }
    }
}

style.dtank = {
    -- estados do tanque dinamico<br>
    ---@see TANK_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "RTU  FALHA" },
        { color = cpair(colors.black, colors.green),  text = "ONLINE" },
        { color = cpair(colors.black, colors.yellow), text = "NIVEL BAIXO" },
        { color = cpair(colors.black, colors.green),  text = "CHEIO" }
    }
}

style.ess = {
    -- estados da matriz de inducao e do nucleo de energia<br>
    ---@see ESS_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "RTU  FALHA" },
        { color = cpair(colors.black, colors.green),  text = "ONLINE" },
        { color = cpair(colors.black, colors.yellow), text = "CARGA BAIXA" },
        { color = cpair(colors.black, colors.yellow), text = "CARGA  ALTA" }
    }
}

style.sps = {
    -- estados do SPS<br>
    ---@see SPS_STATE
    states = {
        { color = cpair(colors.black, colors.yellow), text = "OFFLINE" },
        { color = cpair(colors.black, colors.orange), text = "NAO FORMADO" },
        { color = cpair(colors.black, colors.orange), text = "RTU  FALHA" },
        { color = cpair(colors.white, colors.gray),   text = "OCIOSO" },
        { color = cpair(colors.black, colors.green),  text = "ATIVO" }
    }
}

-- obtem o estilo de residuos, que depende da configuracao
---@return { states: { color: color, text: string }, states_abbrv: { color: color, text: string }, options: string[], unit_opts: { text: string, fg_bg: cpair, active_fg_bg:cpair } }
function style.get_waste()
    local pu_color = util.trinary(config.GreenPuPellet, colors.green, colors.cyan)
    local po_color = util.trinary(config.GreenPuPellet, colors.cyan, colors.green)

    return {
        -- estados do processamento automatico de residuos
        states = {
            { color = cpair(colors.black, pu_color),      text = "PLUTONIO" },
            { color = cpair(colors.black, po_color),      text = "POLONIO" },
            { color = cpair(colors.black, colors.purple), text = "ANTIMATERIA" }
        },
        states_abbrv = {
            { color = cpair(colors.black, pu_color),      text = "Pu" },
            { color = cpair(colors.black, po_color),      text = "Po" },
            { color = cpair(colors.black, colors.purple), text = "AM" }
        },
        -- opcoes do botao de selecao do processo
        options = { "Plutonio", "Polonio", "Antimateria" },
        -- selecao de residuo da unidade
        unit_opts = {
            { text = "Auto", fg_bg = cpair(colors.black, colors.lightGray), active_fg_bg = cpair(colors.white, colors.gray) },
            { text = "Pu", fg_bg = cpair(colors.black, colors.lightGray), active_fg_bg = cpair(colors.black, pu_color) },
            { text = "Po", fg_bg = cpair(colors.black, colors.lightGray), active_fg_bg = cpair(colors.black, po_color) },
            { text = "AM", fg_bg = cpair(colors.black, colors.lightGray), active_fg_bg = cpair(colors.black, colors.purple) }
        }
    }
end

return style
