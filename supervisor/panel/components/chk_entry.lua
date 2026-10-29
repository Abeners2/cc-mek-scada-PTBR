--
-- Entrada de Falha na Verificação de ID da RTU
--

local types   = require("scada-common.types")

local style   = require("supervisor.panel.style")

local core    = require("graphics.core")

local Div     = require("graphics.elements.Div")
local TextBox = require("graphics.elements.TextBox")

local ALIGN = core.ALIGN

local cpair = core.cpair

-- criar uma entrada da lista de verificação de ID
---@param parent ListBox pai
---@param fail_code integer código de falha
---@param msg string mensagem
---@param details string? detalhes
local function init(parent, fail_code, msg, details)
    -- div raiz
    local root = Div{parent=parent,x=2,y=2,height=4,width=parent.get_width()-2}
    local entry = Div{parent=root,x=2,y=1,height=3,fg_bg=style.theme.highlight_box_bright}

    local fg_bg = cpair(colors.black, colors.yellow)
    local tag = "AUSENTE"

    if fail_code == types.RTU_LINK_FAIL.OUT_OF_RANGE then
        fg_bg = cpair(colors.black, colors.orange)
        tag = "ÍND. INVÁL."
    elseif fail_code == types.RTU_LINK_FAIL.DUPLICATE then
        fg_bg = cpair(colors.black, colors.red)
        tag = "DUPLICADO"
    elseif fail_code == types.RTU_LINK_FAIL.MISMATCH then
        fg_bg = cpair(colors.black, colors.red)
        tag = "INCOMPAT."
    end

    TextBox{parent=entry,y=1,text="",width=11,fg_bg=fg_bg}
    TextBox{parent=entry,text=tag,alignment=ALIGN.CENTER,width=11,fg_bg=fg_bg}
    TextBox{parent=entry,text="",width=11,fg_bg=fg_bg}

    TextBox{parent=entry,x=13,y=2,text=msg}
    if details then TextBox{parent=entry,x=13,y=3,text=details,fg_bg=style.fp.label_fg} end

    return root
end

return init
