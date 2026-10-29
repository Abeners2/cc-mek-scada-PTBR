local util        = require("scada-common.util")

local core        = require("graphics.core")

local Div         = require("graphics.elements.Div")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local Checkbox    = require("graphics.elements.controls.Checkbox")
local PushButton  = require("graphics.elements.controls.PushButton")
local Radio2D     = require("graphics.elements.controls.Radio2D")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")

local tri = util.trinary

local cpair = core.cpair

local self = {
    any_has_tank = false,

    vis_draw = nil,       ---@type function
    draw_fluid_ops = nil, ---@type function

    vis_ftanks = {},      ---@type { line: Div, pipe_conn?: TextBox, pipe_chain?: TextBox, pipe_direct?: TextBox, label?: TextBox }[]
    vis_utanks = {}       ---@type { line: Div, label: TextBox }[]
}

local facility = {}

-- gerar as tabelas de lista de tanques e conexões de tanques
---@param mode integer modo de tanque da instalação
---@param defs integer[] definições de tanques da instalação
---@return integer[] tank_list, integer[] tank_conns
function facility.generate_tank_list_and_conns(mode, defs)
    local tank_mode = mode
    local tank_defs = defs
    local tank_list = { table.unpack(tank_defs) }
    local tank_conns = { table.unpack(tank_defs) }

    local function calc_fdef(start_idx, end_idx)
        local first = 4
        for i = start_idx, end_idx do
            if tank_defs[i] == 2 then
                if i < first then first = i end
            end
        end
        return first
    end

    -- definir unidades usando seus próprios tanques como conectadas ao seu respectivo tanque de unidade
    for i = 1, #tank_defs do
        if tank_defs[i] == 1 then tank_conns[i] = i end
    end

    if tank_mode == 1 then
        -- (1) 1 tanque da instalação no total (A A A A)
        local first_fdef = calc_fdef(1, #tank_defs)
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                tank_conns[i] = first_fdef

                if i > first_fdef then tank_list[i] = 0 end
            end
        end
    elseif tank_mode == 2 then
        -- (2) 2 tanques da instalação no total (A A A B)
        local first_fdef = calc_fdef(1, math.min(3, #tank_defs))
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                if i == 4 then
                    tank_conns[i] = 4
                else
                    tank_conns[i] = first_fdef

                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 3 then
        -- (3) 2 tanques da instalação no total (A A B B)
        for _, a in pairs({ 1, 3 }) do
            local b = a + 1

            if tank_defs[a] == 2 then
                tank_conns[a] = a
            elseif tank_defs[b] == 2 then
                tank_conns[b] = b
            end

            if (tank_defs[a] == 2) and (tank_defs[b] == 2) then
                tank_list[b] = 0
                tank_conns[b] = a
            end
        end
    elseif tank_mode == 4 then
        -- (4) 2 tanques da instalação no total (A B B B)
        local first_fdef = calc_fdef(2, #tank_defs)
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 then
                    tank_conns[i] = 1
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef

                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 5 then
        -- (5) 3 tanques da instalação no total (A A B C)
        local first_fdef = calc_fdef(1, math.min(2, #tank_defs))
        for i = 1, #tank_defs do
            if (i >= first_fdef) and (tank_defs[i] == 2) then
                if i == 3 or i == 4 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef

                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 6 then
        -- (6) 3 tanques da instalação no total (A B B C)
        local first_fdef = calc_fdef(2, math.min(3, #tank_defs))
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 or i == 4 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef

                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 7 then
        -- (7) 3 tanques da instalação no total (A B C C)
        local first_fdef = calc_fdef(3, #tank_defs)
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then
                if i == 1 or i == 2 then
                    tank_conns[i] = i
                elseif i >= first_fdef then
                    tank_conns[i] = first_fdef

                    if i > first_fdef then tank_list[i] = 0 end
                end
            end
        end
    elseif tank_mode == 8 then
        -- (8) 4 tanques da instalação no total (A B C D)
        for i = 1, #tank_defs do
            if tank_defs[i] == 2 then tank_conns[i] = i end
        end
    end

    return tank_list, tank_conns
end

-- criar a visualização de configuração da instalação
---@param tool_ctl _svr_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ svr_config, svr_config, svr_config, table, function ]
---@param fac_cfg Div
---@param style { [string]: cpair }
---@return MultiPane fac_pane
function facility.create(tool_ctl, main_pane, cfg_sys, fac_cfg, style)
    local _, ini_cfg, tmp_cfg, _, _ = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]

    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg

    --#region Instalação

    local fac_c_1 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_2 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_3 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_4 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_5 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_6 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_7 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_8 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_9 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_10 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_11 = Div{parent=fac_cfg,x=2,y=4,width=49}
    local fac_c_12 = Div{parent=fac_cfg,x=2,y=4,width=49}

    local fac_pane = MultiPane{parent=fac_cfg,y=4,panes={fac_c_1,fac_c_2,fac_c_3,fac_c_4,fac_c_5,fac_c_6,fac_c_7,fac_c_8,fac_c_9,fac_c_10,fac_c_11,fac_c_12}}

    TextBox{parent=fac_cfg,y=2,text=" Configuração da Instalação",fg_bg=cpair(colors.black,colors.yellow)}

    --#region Contagem de Unidades

    TextBox{parent=fac_c_1,y=1,height=3,text="Digite o número de reatores que você tem, também chamados de unidades de reator ou 'unidades'. Atualmente, o máximo suportado é 4."}
    tool_ctl.num_units = NumberField{parent=fac_c_1,y=5,width=5,max_chars=2,default=ini_cfg.UnitCount,min=1,max=4,fg_bg=bw_fg_bg}
    TextBox{parent=fac_c_1,x=7,y=5,text="reatores"}
    TextBox{parent=fac_c_1,y=7,height=3,text="Se você já configurou seu Coordenador, certifique-se de atualizar a contagem de unidades configurada no Coordenador.",fg_bg=cpair(colors.yellow,colors._INHERIT)}

    local nu_error = TextBox{parent=fac_c_1,x=10,y=14,width=31,text="Defina o número de reatores.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_num_units()
        local count = tonumber(tool_ctl.num_units.get_value())
        if count ~= nil and count > 0 and count < 5 then
            nu_error.hide(true)
            tmp_cfg.UnitCount = count

            local c_confs = tool_ctl.cooling_elems
            local a_confs = tool_ctl.aux_cool_elems

            for i = 2, 4 do
                if count >= i then
                    c_confs[i].line.show()
                    a_confs[i].line.show()
                else
                    c_confs[i].line.hide(true)
                    a_confs[i].line.hide(true)
                end
            end

            fac_pane.set_value(2)
        else nu_error.show() end
    end

    PushButton{parent=fac_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_1,x=42,y=14,text="Avançar \x1a",callback=submit_num_units,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Configuração de Resfriamento

    TextBox{parent=fac_c_2,y=1,height=4,text="Forneça a configuração de resfriamento do reator abaixo. Isso inclui o número de turbinas, caldeiras e se o reator tem conexão com um tanque dinâmico para refrigerante de emergência."}
    TextBox{parent=fac_c_2,y=6,text="UNID    TURBINAS   CALDEIRAS TEM CONEXÃO TANQUE?",fg_bg=g_lg_fg_bg}

    for i = 1, 4 do
        local num_t, num_b, has_t = 1, 0, false

        if ini_cfg.CoolingConfig[i] then
            local conf = ini_cfg.CoolingConfig[i]
            if util.is_int(conf.TurbineCount) then num_t = math.min(3, math.max(1, conf.TurbineCount or 1)) end
            if util.is_int(conf.BoilerCount) then num_b = math.min(2, math.max(0, conf.BoilerCount or 0)) end
            has_t = conf.TankConnection == true
        end

        local line = Div{parent=fac_c_2,y=7+i,height=1}

        TextBox{parent=line,text="Unid "..i,width=6}
        local turbines = NumberField{parent=line,x=9,y=1,width=5,max_chars=2,default=num_t,min=1,max=3,fg_bg=bw_fg_bg}
        local boilers = NumberField{parent=line,x=20,y=1,width=5,max_chars=2,default=num_b,min=0,max=2,fg_bg=bw_fg_bg}
        local tank = Checkbox{parent=line,x=30,y=1,label="Está Conectado",default=has_t,box_fg_bg=cpair(colors.yellow,colors.black)}

        tool_ctl.cooling_elems[i] = { line = line, turbines = turbines, boilers = boilers, tank = tank }
    end

    local cool_err = TextBox{parent=fac_c_2,x=10,y=14,width=31,text="Preencha todos os campos.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_cooling()
        local any_missing = false
        for i = 1, tmp_cfg.UnitCount do
            local conf = tool_ctl.cooling_elems[i]
            any_missing = any_missing or (tonumber(conf.turbines.get_value()) == nil)
            any_missing = any_missing or (tonumber(conf.boilers.get_value()) == nil)
        end

        if any_missing then
            cool_err.show()
        else
            self.any_has_tank = false

            tmp_cfg.CoolingConfig = {}
            for i = 1, tmp_cfg.UnitCount do
                local conf = tool_ctl.cooling_elems[i]
                -- campos já verificados como números
                tmp_cfg.CoolingConfig[i] = {
                    TurbineCount = tonumber(conf.turbines.get_value()) --[[@as number]],
                    BoilerCount = tonumber(conf.boilers.get_value()) --[[@as number]],
                    TankConnection = conf.tank.get_value()
                }

                if conf.tank.get_value() then self.any_has_tank = true end
            end

            for i = 1, 4 do
                local elem = tool_ctl.tank_elems[i]
                if i <= tmp_cfg.UnitCount then
                    elem.div.show()
                    if tmp_cfg.CoolingConfig[i].TankConnection then
                        elem.no_tank.hide()
                        elem.tank_opt.show()
                    else
                        elem.tank_opt.hide(true)
                        elem.no_tank.show()
                    end
                else elem.div.hide(true) end
            end

            if not self.any_has_tank then
                tmp_cfg.FacilityTankMode = 0
                tmp_cfg.FacilityTankDefs = {}
                tmp_cfg.FacilityTankList = {}
                tmp_cfg.FacilityTankConns = {}
                tmp_cfg.TankFluidTypes = {}
            end

            if self.any_has_tank then fac_pane.set_value(3) else fac_pane.set_value(8) end
        end
    end

    PushButton{parent=fac_c_2,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_2,x=42,y=14,text="Avançar \x1a",callback=submit_cooling,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Opção de Tanques da Instalação

    TextBox{parent=fac_c_3,y=1,height=6,text="Você definiu uma ou mais unidades para usar tanques dinâmicos como refrigerante de emergência. Há dois caminhos de configuração. O primeiro é atribuir tanques dinâmicos às unidades de reator; um tanque por reator, conectado apenas a ele. Configurações de RTU também devem atribuí-lo assim."}
    TextBox{parent=fac_c_3,y=8,height=3,text="Alternativamente, você pode configurá-los como tanques da instalação para conectar a várias unidades de reator. Eles podem se misturar com tanques de unidades."}

    tool_ctl.en_fac_tanks = Checkbox{parent=fac_c_3,y=12,label="Usar Tanques Dinâmicos da Instalação",default=ini_cfg.FacilityTankMode>0,box_fg_bg=cpair(colors.yellow,colors.black)}

    local function submit_en_fac_tank()
        if tool_ctl.en_fac_tanks.get_value() then
            fac_pane.set_value(4)
            tmp_cfg.FacilityTankMode = tri(tmp_cfg.FacilityTankMode == 0, 1, math.min(8, math.max(1, ini_cfg.FacilityTankMode)))
        else
            tmp_cfg.FacilityTankMode = 0
            tmp_cfg.FacilityTankDefs = {}

            -- no modo de tanque da instalação 0, configurar definições de tanque para corresponder à opção de tanque de unidade
            for i = 1, tmp_cfg.UnitCount do
                tmp_cfg.FacilityTankDefs[i] = tri(tmp_cfg.CoolingConfig[i].TankConnection, 1, 0)
            end

            tmp_cfg.FacilityTankList, tmp_cfg.FacilityTankConns = facility.generate_tank_list_and_conns(tmp_cfg.FacilityTankMode, tmp_cfg.FacilityTankDefs)

            self.draw_fluid_ops()

            fac_pane.set_value(7)
        end
    end

    PushButton{parent=fac_c_3,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_3,x=42,y=14,text="Avançar \x1a",callback=submit_en_fac_tank,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Conexões de Tanques da Instalação

    TextBox{parent=fac_c_4,y=1,height=4,text="Defina as conexões das unidades aos tanques dinâmicos, selecionando ao menos um tanque da instalação. O layout dos tanques da instalação será configurado a seguir."}

    for i = 1, 4 do
        local val = math.max(1, ini_cfg.FacilityTankDefs[i] or 2)
        local div = Div{parent=fac_c_4,y=3+(2*i),height=2}

        TextBox{parent=div,y=1,width=33,text="Unid "..i.." será conectada a..."}
        TextBox{parent=div,x=6,y=2,width=3,text="..."}
        local tank_opt = Radio2D{parent=div,x=9,y=2,rows=1,columns=2,default=val,options={"seu Tanque de Unid","Tanque da Instal."},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.yellow,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}
        local no_tank = TextBox{parent=div,x=9,y=2,width=38,text="nenhum tanque (definido há 2 passos)",fg_bg=cpair(colors.gray,colors.lightGray),hidden=true}

        tool_ctl.tank_elems[i] = { div = div, tank_opt = tank_opt, no_tank = no_tank }
    end

    local tank_err = TextBox{parent=fac_c_4,x=10,y=14,width=31,text="Nenhum tanque da inst. selec.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function hide_fconn(i)
        if i > 1 then self.vis_ftanks[i].pipe_conn.hide(true)
        else self.vis_ftanks[i].line.hide(true) end
    end

    local function submit_tank_defs()
        local any_fac = false

        tmp_cfg.FacilityTankDefs = {}
        for i = 1, tmp_cfg.UnitCount do
            local def

            if tmp_cfg.CoolingConfig[i].TankConnection then
                def = tool_ctl.tank_elems[i].tank_opt.get_value()
                any_fac = any_fac or (def == 2)
            else def = 0 end

            if def == 1 then
                self.vis_utanks[i].line.show()
                self.vis_utanks[i].label.set_value("Tanq U" .. i)
                hide_fconn(i)
            else
                if def == 2 then
                    if i > 1 then self.vis_ftanks[i].pipe_conn.show()
                    else self.vis_ftanks[i].line.show() end
                else hide_fconn(i) end
                self.vis_utanks[i].line.hide(true)
            end

            tmp_cfg.FacilityTankDefs[i] = def
        end

        for i = tmp_cfg.UnitCount + 1, 4 do
            self.vis_utanks[i].line.hide(true)
        end

        self.vis_draw(tmp_cfg.FacilityTankMode)

        if any_fac then
            tank_err.hide(true)
            fac_pane.set_value(5)
        else tank_err.show() end
    end

    PushButton{parent=fac_c_4,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(3)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_4,x=42,y=14,text="Avançar \x1a",callback=submit_tank_defs,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Modo de Tanque da Instalação

    TextBox{parent=fac_c_5,y=1,text="Selecione o layout do seu tanque dinâmico."}
    TextBox{parent=fac_c_5,x=12,y=3,text="Tanques Instal.            Tanques Unid.",fg_bg=g_lg_fg_bg}

    --#region Visualizador de Layout de Tanque

    local pipe_cpair = cpair(colors.blue,colors.lightGray)

    local vis = Div{parent=fac_c_5,x=14,y=5,height=7}

    local vis_unit_list = TextBox{parent=vis,x=15,y=1,width=6,height=7,text="Unid 1\n\nUnid 2\n\nUnid 3\n\nUnid 4"}

    -- desenhar tanques de unidades e suas tubulações
    for i = 1, 4 do
        local line = Div{parent=vis,x=22,y=(i*2)-1,width=13,height=1}
        TextBox{parent=line,width=5,text=string.rep("\x8c",5),fg_bg=pipe_cpair}
        local label = TextBox{parent=line,x=7,y=1,width=7,text="Tanq ?"}
        self.vis_utanks[i] = { line = line, label = label }
    end

    -- desenhar conexões de tanques da instalação

    local ftank_1 = Div{parent=vis,y=1,width=13,height=1}
    TextBox{parent=ftank_1,width=7,text="Tanq F1"}
    self.vis_ftanks[1] = {
        line = ftank_1, pipe_direct = TextBox{parent=ftank_1,x=9,y=1,width=5,text=string.rep("\x8c",5),fg_bg=pipe_cpair}
    }

    for i = 2, 4 do
        local line = Div{parent=vis,y=(i-1)*2,width=13,height=2}
        local pipe_conn = TextBox{parent=line,x=13,y=2,width=1,text="\x8c",fg_bg=pipe_cpair}
        local pipe_chain = TextBox{parent=line,x=12,y=1,width=1,height=2,text="\x95\n\x8d",fg_bg=pipe_cpair}
        local pipe_direct = TextBox{parent=line,x=9,y=2,width=4,text="\x8c\x8c\x8c\x8c",fg_bg=pipe_cpair}
        local label = TextBox{parent=line,y=2,width=7,text=""}
        self.vis_ftanks[i] = { line = line, pipe_conn = pipe_conn, pipe_chain = pipe_chain, pipe_direct = pipe_direct, label = label }
    end

    -- desenhar a visualização da tubulação
    ---@param mode integer modo de tubulação
    function self.vis_draw(mode)
        -- um tanque da instalação está conectado a esta unidade
        ---@param i integer unidade 1 - 4
        ---@return boolean connected
        local function is_ft(i) return tmp_cfg.FacilityTankDefs[i] == 2 end

        local u_text = ""
        for i = 1, tmp_cfg.UnitCount do
            u_text = u_text .. "Unid " .. i .. "\n\n"
        end

        vis_unit_list.set_value(u_text)

        local vis_ftanks = self.vis_ftanks
        local next_idx = 1

        if is_ft(1) then
            next_idx = 2

            if (mode == 1 and (is_ft(2) or is_ft(3) or is_ft(4))) or (mode == 2 and (is_ft(2) or is_ft(3))) or ((mode == 3 or mode == 5) and is_ft(2)) then
                vis_ftanks[1].pipe_direct.set_value("\x8c\x8c\x8c\x9c\x8c")
            else
                vis_ftanks[1].pipe_direct.set_value(string.rep("\x8c",5))
            end
        end

        local _2_12_need_passt = (mode == 1 and (is_ft(3) or is_ft(4))) or (mode == 2 and is_ft(3))
        local _2_46_need_chain = (mode == 4 and (is_ft(3) or is_ft(4))) or (mode == 6 and is_ft(3))

        if is_ft(2) then
            vis_ftanks[2].label.set_value("Tanq F" .. next_idx)

            if (mode < 4 or mode == 5) and is_ft(1) then
                vis_ftanks[2].label.hide(true)
                vis_ftanks[2].pipe_direct.hide(true)
                if _2_12_need_passt then
                    vis_ftanks[2].pipe_chain.set_value("\x95\n\x9d")
                else
                    vis_ftanks[2].pipe_chain.set_value("\x95\n\x8d")
                end
                vis_ftanks[2].pipe_chain.show()
            else
                vis_ftanks[2].label.show()
                next_idx = next_idx + 1

                vis_ftanks[2].pipe_chain.hide(true)
                if _2_12_need_passt or _2_46_need_chain then
                    vis_ftanks[2].pipe_direct.set_value("\x8c\x8c\x8c\x9c")
                else
                    vis_ftanks[2].pipe_direct.set_value("\x8c\x8c\x8c\x8c")
                end
                vis_ftanks[2].pipe_direct.show()
            end

            vis_ftanks[2].line.show()
        elseif is_ft(1) and _2_12_need_passt then
            vis_ftanks[2].label.hide(true)
            vis_ftanks[2].pipe_direct.hide(true)
            vis_ftanks[2].pipe_chain.set_value("\x95\n\x95")
            vis_ftanks[2].pipe_chain.show()
            vis_ftanks[2].line.show()
        else
            vis_ftanks[2].line.hide(true)
        end

        if is_ft(3) then
            vis_ftanks[3].label.set_value("Tanq F" .. next_idx)

            if (mode < 3 and (is_ft(1) or is_ft(2))) or ((mode == 4 or mode == 6) and is_ft(2)) then
                vis_ftanks[3].label.hide(true)
                vis_ftanks[3].pipe_direct.hide(true)
                if (mode == 1 or mode == 4) and is_ft(4) then
                    vis_ftanks[3].pipe_chain.set_value("\x95\n\x9d")
                else
                    vis_ftanks[3].pipe_chain.set_value("\x95\n\x8d")
                end
                vis_ftanks[3].pipe_chain.show()
            else
                vis_ftanks[3].label.show()
                next_idx = next_idx + 1

                vis_ftanks[3].pipe_chain.hide(true)
                if (mode == 1 or mode == 3 or mode == 4 or mode == 7) and is_ft(4) then
                    vis_ftanks[3].pipe_direct.set_value("\x8c\x8c\x8c\x9c")
                else
                    vis_ftanks[3].pipe_direct.set_value("\x8c\x8c\x8c\x8c")
                end
                vis_ftanks[3].pipe_direct.show()
            end

            vis_ftanks[3].line.show()
        elseif (mode == 1 and is_ft(4) and (is_ft(1) or is_ft(2))) or (mode == 4 and is_ft(2) and is_ft(4)) then
            vis_ftanks[3].label.hide(true)
            vis_ftanks[3].pipe_direct.hide(true)
            vis_ftanks[3].pipe_chain.set_value("\x95\n\x95")
            vis_ftanks[3].pipe_chain.show()
            vis_ftanks[3].line.show()
        else
            vis_ftanks[3].line.hide(true)
        end

        if is_ft(4) then
            vis_ftanks[4].label.set_value("Tanq F" .. next_idx)

            if (mode == 1 and (is_ft(1) or is_ft(2) or is_ft(3))) or ((mode == 3 or mode == 7) and is_ft(3)) or (mode == 4 and (is_ft(2) or is_ft(3))) then
                vis_ftanks[4].label.hide(true)
                vis_ftanks[4].pipe_direct.hide(true)
                vis_ftanks[4].pipe_chain.show()
            else
                vis_ftanks[4].label.show()
                vis_ftanks[4].pipe_chain.hide(true)
                vis_ftanks[4].pipe_direct.show()
            end

            vis_ftanks[4].line.show()
        else
            vis_ftanks[4].line.hide(true)
        end
    end

    local function change_mode(mode)
        tmp_cfg.FacilityTankMode = mode
        self.vis_draw(mode)
    end

    local tank_modes = { "Modo 1", "Modo 2", "Modo 3", "Modo 4", "Modo 5", "Modo 6", "Modo 7", "Modo 8" }
    tool_ctl.tank_mode = RadioButton{parent=fac_c_5,y=4,callback=change_mode,default=math.max(1,ini_cfg.FacilityTankMode),options=tank_modes,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.yellow}

    --#endregion

    local function next_from_tank_mode()
        -- determinar lista de tanques e conexões
        tmp_cfg.FacilityTankList, tmp_cfg.FacilityTankConns = facility.generate_tank_list_and_conns(tmp_cfg.FacilityTankMode, tmp_cfg.FacilityTankDefs)

        self.draw_fluid_ops()

        fac_pane.set_value(7)
    end

    PushButton{parent=fac_c_5,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_5,x=42,y=14,text="Avançar \x1a",callback=next_from_tank_mode,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    PushButton{parent=fac_c_5,x=10,y=14,min_width=7,text="Sobre",callback=function()fac_pane.set_value(6)end,fg_bg=cpair(colors.black,colors.lightBlue),active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Sobre o Modo de Tanque da Instalação

    TextBox{parent=fac_c_6,height=3,text="Esta ferramenta de visualização mostra as conexões de tubulação necessárias para uma configuração de tanque dinâmico selecionada."}
    TextBox{parent=fac_c_6,y=5,height=4,text="Exemplos: Um tanque U2 deve ser configurado em uma RTU como o tanque dinâmico para a unidade #2. Um tanque F3 deve ser configurado em uma RTU como o tanque dinâmico #3 para a instalação."}
    TextBox{parent=fac_c_6,y=10,height=3,text="Alguns modos podem parecer iguais se você não estiver usando um total de 4 unidades de reator. A wiki tem detalhes. Modos que parecem iguais funcionarão da mesma forma.",fg_bg=g_lg_fg_bg}

    PushButton{parent=fac_c_6,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(5)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Tipos de Fluido dos Tanques Dinâmicos

    TextBox{parent=fac_c_7,height=3,text="Especifique o tipo de refrigerante de cada tanque, apenas para exibição. Água é a única opção se uma ou mais das unidades conectadas for resfriada a água."}

    local tank_fluid_list = Div{parent=fac_c_7,y=5,height=8}

    function self.draw_fluid_ops()
        tank_fluid_list.remove_all()

        local tank_list = tmp_cfg.FacilityTankList
        local tank_conns = tmp_cfg.FacilityTankConns

        local next_f = 1

        for i = 1, #tank_list do
            local type = tmp_cfg.TankFluidTypes[i]

            if type == 0 then type = 1 end

            tool_ctl.tank_fluid_opts[i] = nil

            if tank_list[i] == 1 then
                local row = Div{parent=tank_fluid_list,height=2}

                TextBox{parent=row,width=13,text="Tanq. Unid. "..i}
                TextBox{parent=row,text="Conectado a: Unid "..i,fg_bg=cpair(colors.gray,colors.lightGray)}

                local tank_fluid = Radio2D{parent=row,x=34,y=1,rows=1,columns=2,default=type,options={"Água","Sódio"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.yellow,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}

                if tmp_cfg.CoolingConfig[i].BoilerCount == 0 then
                    tank_fluid.set_value(1)
                    tank_fluid.disable()
                end

                tool_ctl.tank_fluid_opts[i] = tank_fluid
            elseif tank_list[i] == 2 then
                local row = Div{parent=tank_fluid_list,height=2}

                TextBox{parent=row,width=15,text="Tanq. Instal. "..next_f}

                local conns = ""
                local any_bwr = false

                for u = 1, #tank_conns do
                    if tank_conns[u] == i then
                        conns = conns .. tri(conns == "", "", ", ") .. "Unid " .. u
                        any_bwr = any_bwr or (tmp_cfg.CoolingConfig[u].BoilerCount == 0)
                    end
                end

                TextBox{parent=row,text="Conectado a: "..conns,fg_bg=cpair(colors.gray,colors.lightGray)}

                local tank_fluid = Radio2D{parent=row,x=34,y=1,rows=1,columns=2,default=type,options={"Água","Sódio"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.yellow,disable_color=colors.gray,disable_fg_bg=g_lg_fg_bg}

                if any_bwr then
                    tank_fluid.set_value(1)
                    tank_fluid.disable()
                end

                tool_ctl.tank_fluid_opts[i] = tank_fluid

                next_f = next_f + 1
            end
        end
    end

    local function back_from_fluids()
        fac_pane.set_value(tri(tmp_cfg.FacilityTankMode == 0, 3, 5))
    end

    local function submit_tank_fluids()
        tmp_cfg.TankFluidTypes = {}

        for i = 1, #tmp_cfg.FacilityTankList do
            if tool_ctl.tank_fluid_opts[i] ~= nil then
                tmp_cfg.TankFluidTypes[i] = tool_ctl.tank_fluid_opts[i].get_value()
            else tmp_cfg.TankFluidTypes[i] = 0 end
        end

        fac_pane.set_value(8)
    end

    PushButton{parent=fac_c_7,y=14,text="\x1b Voltar",callback=back_from_fluids,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_7,x=42,y=14,text="Avançar \x1a",callback=submit_tank_fluids,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Refrigerante Auxiliar

    TextBox{parent=fac_c_8,height=5,text="O resfriamento auxiliar a água pode ser ativado nas unidades para fornecer água extra durante a aceleração da turbina. Em reatores a água, isso vai para o reator. Em reatores a sódio, a água vai para a caldeira."}

    for i = 1, 4 do
        local line = Div{parent=fac_c_8,y=7+i,height=1}

        TextBox{parent=line,text="Unid "..i.." -",width=8}
        local aux_cool = Checkbox{parent=line,x=10,y=1,label="Possui Refrigerante Auxiliar",default=ini_cfg.AuxiliaryCoolant[i],box_fg_bg=cpair(colors.yellow,colors.black)}

        tool_ctl.aux_cool_elems[i] = { line = line, enable = aux_cool }
    end

    local function back_from_aux_cool()
        if self.any_has_tank then fac_pane.set_value(7) else fac_pane.set_value(2) end
    end

    local function submit_aux_cool()
        tmp_cfg.AuxiliaryCoolant = {}

        for i = 1, tmp_cfg.UnitCount do
            tmp_cfg.AuxiliaryCoolant[i] = tool_ctl.aux_cool_elems[i].enable.get_value()
        end

        fac_pane.set_value(9)
    end

    PushButton{parent=fac_c_8,y=14,text="\x1b Voltar",callback=back_from_aux_cool,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_8,x=42,y=14,text="Avançar \x1a",callback=submit_aux_cool,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Espera Estendida

    TextBox{parent=fac_c_9,height=6,text="O controle de nível de carga fornece controle automático para manter o nível de carga de uma matriz de indução. Para um controle mais suave, reatores ativados serão mantidos ligados a 0.01 mB/t por um curto período antes de desligarem. Isso minimiza ultrapassar a meta de carga."}
    TextBox{parent=fac_c_9,y=8,height=3,text="Você pode estender isso para um minuto inteiro para minimizar reatores ligando/desligando rapidamente, mas pode haver maior ultrapassagem da meta."}

    tool_ctl.ext_idling = Checkbox{parent=fac_c_9,y=12,label="Ativar Espera Estendida",default=ini_cfg.ExtChargeIdling,box_fg_bg=cpair(colors.yellow,colors.black)}

    local function submit_idling()
        tmp_cfg.ExtChargeIdling = tool_ctl.ext_idling.get_value()
        fac_pane.set_value(10)
    end

    PushButton{parent=fac_c_9,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(8)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_9,x=42,y=14,text="Avançar \x1a",callback=submit_idling,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Estatísticas de SNA

    TextBox{parent=fac_c_10,height=3,text="A tela de fluxo e outras telas de dados usam Ativadores de Nêutrons Solares (SNAs) conectados para indicar valores de produção de Polônio."}
    TextBox{parent=fac_c_10,y=5,height=3,text="Se não estiver usando SNAs, você pode desmarcar esta opção para que o Supervisor calcule uma estimativa com base na taxa de queima atual."}

    tool_ctl.sna_stats = Checkbox{parent=fac_c_10,y=9,label="Usar SNAs para Estatísticas de Po",default=ini_cfg.UseSNAStatistics,box_fg_bg=cpair(colors.yellow,colors.black)}

    TextBox{parent=fac_c_10,y=11,height=3,text="Ambos os modos dependem de proporções corretas de resíduos na seção Configuração do Mekanism.",fg_bg=g_lg_fg_bg}

    local function submit_sna_stats()
        tmp_cfg.UseSNAStatistics = tool_ctl.sna_stats.get_value()
        fac_pane.set_value(11)
    end

    PushButton{parent=fac_c_10,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(9)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_10,x=42,y=14,text="Avançar \x1a",callback=submit_sna_stats,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Resíduos Combinados da Instalação

    TextBox{parent=fac_c_11,height=3,text="A configuração padrão espera que o processamento de resíduos (SNAs e PRCs) seja por unidade para estatísticas e gerenciamento individual de reserva de Pu."}
    TextBox{parent=fac_c_11,y=5,height=3,text="Se a sua configuração combina todo o resíduo nuclear de MÚLTIPLAS unidades antes do processamento, selecione o gerenciamento combinado abaixo."}
    TextBox{parent=fac_c_11,y=9,text="Ambas as opções esperam uma SPS combinada na instalação.",fg_bg=g_lg_fg_bg}

    tool_ctl.com_waste = Checkbox{parent=fac_c_11,y=11,label="Resíduos Combinados da Instalação",default=ini_cfg.CombinedWaste,box_fg_bg=cpair(colors.yellow,colors.black)}

    local function submit_com_waste()
        tmp_cfg.CombinedWaste = tool_ctl.com_waste.get_value()
        fac_pane.set_value(12)
    end

    PushButton{parent=fac_c_11,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(10)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_11,x=42,y=14,text="Avançar \x1a",callback=submit_com_waste,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion
    --#region Armazenamento de Energia

    TextBox{parent=fac_c_12,height=2,text="Selecione o sistema de armazenamento de energia que você está usando nesta instalação."}

    TextBox{parent=fac_c_12,y=4,text="Sistema de Armazenamento de Energia (ESS)"}
    tool_ctl.ess_opt = RadioButton{parent=fac_c_12,y=5,default=math.max(1,ini_cfg.EnergyStorageSystem),options={"Matriz de Indução (Mekanism)","Núcleo de Energia (Draconic Evolution)"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.yellow}

    local function submit_ess()
        tmp_cfg.EnergyStorageSystem = tool_ctl.ess_opt.get_value()
        main_pane.set_value(3)
    end

    TextBox{parent=fac_c_12,y=9,height=4,text="Na maioria das interfaces, este disp. será chamado de Energy Storage System ou de ESS, em vez de Matriz de Indução ou Núcleo de Energia, então você deve estar ciente desses termos.",fg_bg=g_lg_fg_bg}
    TextBox{parent=fac_c_12,x=7,y=10,width=21,height=1,text="Energy Storage System",fg_bg=cpair(colors.blue,colors._INHERIT)}
    TextBox{parent=fac_c_12,x=35,y=10,width=3,height=1,text="ESS",fg_bg=cpair(colors.blue,colors._INHERIT)}

    PushButton{parent=fac_c_12,y=14,text="\x1b Voltar",callback=function()fac_pane.set_value(11)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=fac_c_12,x=42,y=14,text="Avançar \x1a",callback=submit_ess,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#endregion

    return fac_pane
end

return facility
