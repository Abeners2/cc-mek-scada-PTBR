--
-- GUI do Coordenador SCADA da Unidade de Reator
--

local unit_detail = require("coordinator.ui.components.unit_detail")

-- cria uma visualizacao de unidade
---@param main DisplayBox main displaybox
---@param id integer
local function init(main, id)
    unit_detail(main, id)
end

return init
