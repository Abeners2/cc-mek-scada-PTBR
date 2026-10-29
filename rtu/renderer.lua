--
-- Controle de Renderização Gráfica
--

local panel_view = require("rtu.panel.front_panel")
local style      = require("rtu.panel.style")

local core       = require("graphics.core")
local flasher    = require("graphics.flasher")

local DisplayBox = require("graphics.elements.DisplayBox")

---@class rtu_renderer
local renderer = {}

local ui = {
    display = nil
}

-- tentar iniciar a UI
---@param config rtu_config configuração
---@param units rtu_registry_entry[] entradas da RTU
---@return boolean success, any error_msg
function renderer.try_start_ui(config, units)
    local status, msg = true, nil

    if ui.display == nil then
        -- definir tema
        style.set_theme(config.FrontPanelTheme, config.ColorMode)

        -- redefinir terminal
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)

        -- definir cores substituídas
        for i = 1, #style.theme.colors do
            term.setPaletteColor(style.theme.colors[i].c, style.theme.colors[i].hex)
        end

        -- aplicar modo de cor
        local c_mode_overrides = style.theme.color_modes[config.ColorMode]
        for i = 1, #c_mode_overrides do
            term.setPaletteColor(c_mode_overrides[i].c, c_mode_overrides[i].hex)
        end

        -- inicializar visualização do painel frontal
        status, msg = pcall(function ()
            ui.display = DisplayBox{window=term.current(),fg_bg=style.fp.root}
            panel_view(ui.display, config, units)
        end)

        if status then
            -- iniciar tarefa de retorno de chamada do pisca-pisca
            flasher.run()
        else
            -- relatar falha e fechar ui
            msg = core.extract_assert_msg(msg)
            renderer.close_ui()
        end
    end

    return status, msg
end

-- fechar a UI
function renderer.close_ui()
    if ui.display ~= nil then
        -- parar indicadores piscantes
        flasher.clear()

        -- excluir árvore de elementos
        ui.display.delete()
        ui.display = nil

        -- restaurar cores
        for i = 1, #style.theme.colors do
            local r, g, b = term.nativePaletteColor(style.theme.colors[i].c)
            term.setPaletteColor(style.theme.colors[i].c, r, g, b)
        end

        -- redefinir terminal
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

-- tratar um evento de mouse
---@param event mouse_interaction|nil
function renderer.handle_mouse(event)
    if ui.display ~= nil and event ~= nil then
        ui.display.handle_mouse(event)
    end
end

return renderer
