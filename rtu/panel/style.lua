--
-- Opções de Estilo Gráfico
--

local core   = require("graphics.core")
local themes = require("graphics.themes")

---@class rtu_style
local style = {}

local cpair = core.cpair

style.theme = themes.sandstone
style.fp = themes.get_fp_style(style.theme)
style.colorblind = false

style.ind_grn = cpair(colors.green, colors.green_off)

-- definir tema conforme configuração
---@param fp FP_THEME tema do painel frontal
---@param color_mode COLOR_MODE o modo de cor a ser usado
function style.set_theme(fp, color_mode)
    if fp == themes.FP_THEME.SANDSTONE then
        style.theme = themes.sandstone
    elseif fp == themes.FP_THEME.BASALT then
        style.theme = themes.basalt
    end

    style.fp = themes.get_fp_style(style.theme)

    style.colorblind = color_mode ~= themes.COLOR_MODE.STANDARD and color_mode ~= themes.COLOR_MODE.STD_ON_BLACK

    if color_mode == themes.COLOR_MODE.STANDARD or color_mode == themes.COLOR_MODE.BLUE_IND then
        style.ind_bkg = colors.gray
    else
        style.ind_bkg = colors.black
    end
end

return style
