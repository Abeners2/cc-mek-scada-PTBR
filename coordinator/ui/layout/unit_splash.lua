--
-- Tela de abertura do display da unidade
--

local ioctl   = require("coordinator.ioctl")

local core    = require("graphics.core")

local TextBox = require("graphics.elements.TextBox")

local Waiting = require("graphics.elements.animations.Waiting")

local ALIGN = core.ALIGN

-- cria a nova tela de abertura da unidade
---@param main DisplayBox unit displaybox
---@param id integer
local function init(main, id)
    local mid_x, mid_y = math.floor(main.get_width() / 2), math.floor(main.get_height() / 2)

    Waiting{parent=main,x=mid_x-2,y=mid_y-4}

    local status = TextBox{parent=main,x=mid_x-15,y=mid_y+2,width=30,text="Aguardando...",alignment=ALIGN.CENTER}

    status.register(ioctl.get_db().os_ps, "splash_status_unit_" .. id, status.set_value)
end

return init
