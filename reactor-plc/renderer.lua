--
-- Controle de Renderização Gráfica
--

local panel_view = require("reactor-plc.panel.front_panel")
local style      = require("reactor-plc.panel.style")

local core       = require("graphics.core")
local flasher    = require("graphics.flasher")

local DisplayBox = require("graphics.elements.DisplayBox")

---@class reactor_plc_renderer
local renderer = {}

local ui = {
    display = nil
}

-- tenta iniciar a UI
---@param config plc_config configuration
---@return boolean success, any error_msg
function renderer.try_start_ui(config)
    local status, msg = true, nil

    if ui.display == nil then
        -- define o tema
        style.set_theme(config.FrontPanelTheme, config.ColorMode)

        -- redefine o terminal
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)

        -- define as cores sobrescritas
        for i = 1, #style.theme.colors do
            term.setPaletteColor(style.theme.colors[i].c, style.theme.colors[i].hex)
        end

        -- aplica o modo de cor
        local c_mode_overrides = style.theme.color_modes[config.ColorMode]
        for i = 1, #c_mode_overrides do
            term.setPaletteColor(c_mode_overrides[i].c, c_mode_overrides[i].hex)
        end

        -- inicializa a visualização do painel frontal
        status, msg = pcall(function ()
            ui.display = DisplayBox{window=term.current(),fg_bg=style.fp.root}
            panel_view(ui.display, config)
        end)

        if status then
            -- inicia a tarefa de callback do pisca-pisca (flasher)
            flasher.run()
        else
            -- reporta falha e fecha a ui
            msg = core.extract_assert_msg(msg)
            renderer.close_ui()
        end
    end

    return status, msg
end

-- fecha a UI
function renderer.close_ui()
    if ui.display ~= nil then
        -- para os indicadores piscantes
        flasher.clear()

        -- exclui a árvore de elementos
        ui.display.delete()
        ui.display = nil

        -- restaura as cores
        for i = 1, #style.theme.colors do
            local r, g, b = term.nativePaletteColor(style.theme.colors[i].c)
            term.setPaletteColor(style.theme.colors[i].c, r, g, b)
        end

        -- redefine o terminal
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
    end
end

-- a UI está pronta?
---@nodiscard
---@return boolean ready
function renderer.ui_ready() return ui.display ~= nil end

-- trata um evento de mouse
---@param event mouse_interaction|nil
function renderer.handle_mouse(event)
    if ui.display ~= nil and event ~= nil then
        ui.display.handle_mouse(event)
    end
end

return renderer
