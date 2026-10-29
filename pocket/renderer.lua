--
-- Controle de Renderizacao Grafica
--

local main_view  = require("pocket.ui.main")
local style      = require("pocket.ui.style")

local core       = require("graphics.core")
local flasher    = require("graphics.flasher")

local DisplayBox = require("graphics.elements.DisplayBox")

---@class pocket_renderer
local renderer = {}

local ui = {
    display = nil
}

-- tenta iniciar a GUI do pocket
---@return boolean success, any error_msg
function renderer.try_start_ui()
    local status, msg = true, nil

    if ui.display == nil then
        -- redefine a tela
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)

        -- define as cores substituidas
        for i = 1, #style.colors do
            term.setPaletteColor(style.colors[i].c, style.colors[i].hex)
        end

        -- inicializa a visualizacao do painel frontal
        status, msg = pcall(function ()
            ui.display = DisplayBox{window=term.current(),fg_bg=style.root}
            main_view(ui.display)
        end)

        if status then
            -- inicia a tarefa de retorno de chamada do pisca-pisca
            flasher.run()
        else
            -- relata falha e fecha a interface
            msg = core.extract_assert_msg(msg)
            renderer.close_ui()
        end
    end

    return status, msg
end

-- encerra a interface
function renderer.close_ui()
    if ui.display ~= nil then
        -- para os indicadores piscantes
        flasher.clear()

        -- oculta para parar os retornos de chamada de animacao
        ui.display.hide()

        -- limpa os elementos raiz da interface
        ui.display = nil

        -- restaura as cores
        for i = 1, #style.colors do
            local r, g, b = term.nativePaletteColor(style.colors[i].c)
            term.setPaletteColor(style.colors[i].c, r, g, b)
        end

        -- redefine o terminal
        term.setTextColor(colors.white)
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(1, 1)
    end
end

-- a interface esta pronta?
---@nodiscard
---@return boolean ready
function renderer.ui_ready() return ui.display ~= nil end

-- processa um evento de mouse
---@param event mouse_interaction|nil
function renderer.handle_mouse(event)
    if ui.display ~= nil and event ~= nil then
        ui.display.handle_mouse(event)
    end
end

-- processa um evento de teclado
---@param event key_interaction|nil
function renderer.handle_key(event)
    if ui.display ~= nil and event ~= nil then
        ui.display.handle_key(event)
    end
end

-- processa um evento de colagem
---@param text string
function renderer.handle_paste(text)
    if ui.display ~= nil then
        ui.display.handle_paste(text)
    end
end

return renderer
