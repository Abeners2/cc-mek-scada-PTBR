local ppm         = require("scada-common.ppm")
local types       = require("scada-common.types")
local util        = require("scada-common.util")

local core        = require("graphics.core")

local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local Checkbox    = require("graphics.elements.controls.Checkbox")
local PushButton  = require("graphics.elements.controls.PushButton")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")

local cpair = core.cpair

local self = {
    apply_mon = nil,    ---@type PushButton

    edit_monitor = nil, ---@type function

    mon_iface = "",
    mon_expect = {}     ---@type integer[]
}

local hmi = {}

-- cria a visão de configuração da IHM (interface homem-máquina)
---@param tool_ctl _crd_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ crd_config, crd_config, crd_config, { [1]: string, [2]: string, [3]: any }[], function ]
---@param divs Div[]
---@param style { [string]: cpair }
---@return MultiPane crd_pane, MultiPane mon_pane
function hmi.create(tool_ctl, main_pane, cfg_sys, divs, style)
    local _, ini_cfg, tmp_cfg, _, _ = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]
    local crd_cfg, mon_cfg, spkr_cfg = divs[1], divs[2], divs[3]

    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    --#region UI do Coordenador

    local crd_c_1 = Div{parent=crd_cfg,x=2,y=4,width=49}
    local crd_c_2 = Div{parent=crd_cfg,x=2,y=4,width=49}
    local crd_c_3 = Div{parent=crd_cfg,x=2,y=4,width=49}

    local crd_pane = MultiPane{parent=crd_cfg,y=4,panes={crd_c_1,crd_c_2,crd_c_3}}

    TextBox{parent=crd_cfg,y=2,text=" Configuração da UI do Coordenador",fg_bg=cpair(colors.black,colors.lime)}

    TextBox{parent=crd_c_1,y=1,height=2,text="Você pode personalizar a UI com as opções de interface abaixo."}

    TextBox{parent=crd_c_1,y=4,text="Formato do Relógio"}
    tool_ctl.clock_fmt = RadioButton{parent=crd_c_1,y=5,default=util.trinary(ini_cfg.Time24Hour,1,2),options={"24 Horas","12 Horas"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lime}

    TextBox{parent=crd_c_1,x=20,y=4,text="Cor da Pastilha Po/Pu"}
    tool_ctl.pellet_color = RadioButton{parent=crd_c_1,x=20,y=5,default=util.trinary(ini_cfg.GreenPuPellet,1,2),options={"Pu Verde/Po Ciano","Pu Ciano/Po Verde (Mek 10.4+)"},radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lime}

    TextBox{parent=crd_c_1,y=8,text="Escala de Temp."}
    tool_ctl.temp_scale = RadioButton{parent=crd_c_1,y=9,default=ini_cfg.TempScale,options=types.TEMP_SCALE_NAMES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lime}

    TextBox{parent=crd_c_1,x=20,y=8,text="Escala de Energia"}
    tool_ctl.energy_scale = RadioButton{parent=crd_c_1,x=20,y=9,default=ini_cfg.EnergyScale,options=types.ENERGY_SCALE_NAMES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.lime}

    local function submit_ui_opts()
        tmp_cfg.Time24Hour = tool_ctl.clock_fmt.get_value() == 1
        tmp_cfg.GreenPuPellet = tool_ctl.pellet_color.get_value() == 1
        tmp_cfg.TempScale = tool_ctl.temp_scale.get_value()
        tmp_cfg.EnergyScale = tool_ctl.energy_scale.get_value()
        crd_pane.set_value(2)
    end

    PushButton{parent=crd_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(3)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=crd_c_1,x=41,y=14,text="Avançar \x1a",callback=submit_ui_opts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=crd_c_2,y=1,height=4,text="O monitor de fluxo pode exibir janelas de detalhes dos componentes. Ativar este recurso permite clicar nos blocos de reator, caldeira e turbina para abrir mais detalhes."}

    local function en_show_sw(en)
        if en then tool_ctl.show_win_sw.enable() else tool_ctl.show_win_sw.disable() end
    end

    tool_ctl.en_flow_dtl = Checkbox{parent=crd_c_2,y=6,default=ini_cfg.FlowDetailView,label="Ativar Janelas de Detalhes de Fluxo",callback=en_show_sw,box_fg_bg=cpair(colors.lime,colors.black)}
    TextBox{parent=crd_c_2,x=39,y=6,text="novo!",fg_bg=cpair(colors.red,colors._INHERIT)}  ---@todo remove NEW tag on next revision
    TextBox{parent=crd_c_2,x=3,height=1,text="Isso pode impactar negativamente o desempenho.",fg_bg=g_lg_fg_bg}
    TextBox{parent=crd_c_2,x=3,height=1,text="Pode aumentar a altura mín. do monitor de fluxo.",fg_bg=cpair(colors.yellow,colors._INHERIT)}

    tool_ctl.show_win_sw = Checkbox{parent=crd_c_2,y=10,default=ini_cfg.FlowViewSwitcher,label="Mostrar Alternador de Janelas",box_fg_bg=cpair(colors.lime,colors.black),disable_fg_bg=g_lg_fg_bg}
    TextBox{parent=crd_c_2,x=33,y=10,text="novo!",fg_bg=cpair(colors.red,colors._INHERIT)}  ---@todo remove NEW tag on next revision
    TextBox{parent=crd_c_2,x=3,height=2,text="Mostra botões no canto inferior direito caso você não alcance facilmente toda a interface.",fg_bg=g_lg_fg_bg}

    en_show_sw(ini_cfg.FlowDetailView)

    local function submit_flow_opts()
        tmp_cfg.FlowDetailView = tool_ctl.en_flow_dtl.get_value()
        tmp_cfg.FlowViewSwitcher = tool_ctl.show_win_sw.get_value()
        tool_ctl.update_mon_reqs()
        crd_pane.set_value(3)
    end

    PushButton{parent=crd_c_2,y=14,text="\x1b Voltar",callback=function()crd_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=crd_c_2,x=41,y=14,text="Avançar \x1a",callback=submit_flow_opts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=crd_c_3,y=1,height=4,text="As telas de abertura (splash) ocultam a renderização inicial dos monitores, acelerando a inicialização. Recomenda-se manter ativado."}
    TextBox{parent=crd_c_3,y=5,height=4,text="Se tiver problemas na inicialização, desativar isso mostra informações de log adicionais na tela, ou você pode verificar o arquivo de log.",fg_bg=g_lg_fg_bg}

    tool_ctl.en_splash = Checkbox{parent=crd_c_3,y=9,default=ini_cfg.SplashScreen,label="Ativar Telas de Abertura",callback=en_show_sw,box_fg_bg=cpair(colors.lime,colors.black)}
    TextBox{parent=crd_c_3,x=28,y=9,text="novo!",fg_bg=cpair(colors.red,colors._INHERIT)}  ---@todo remove NEW tag on next revision

    local function submit_splash()
        tmp_cfg.SplashScreen = tool_ctl.en_splash.get_value()
        main_pane.set_value(5)
    end

    PushButton{parent=crd_c_3,y=14,text="\x1b Voltar",callback=function()crd_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=crd_c_3,x=41,y=14,text="Avançar \x1a",callback=submit_splash,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Monitores

    local mon_c_1 = Div{parent=mon_cfg,x=2,y=4,width=49}
    local mon_c_2 = Div{parent=mon_cfg,x=2,y=4,width=49}
    local mon_c_3 = Div{parent=mon_cfg,x=2,y=4,width=49}

    local mon_pane = MultiPane{parent=mon_cfg,y=4,panes={mon_c_1,mon_c_2,mon_c_3}}

    TextBox{parent=mon_cfg,y=2,text=" Configuração de Monitores",fg_bg=cpair(colors.black,colors.blue)}

    TextBox{parent=mon_c_1,y=1,height=5,text="Sua configuração requer os seguintes monitores. As alturas dos monitores principal e de fluxo dependem do número de unidades e resfriamento. Se inseriu o número manualmente, um * será exibido em cálculos potencialmente imprecisos."}
    local mon_reqs = ListBox{parent=mon_c_1,y=7,height=6,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local function next_from_reqs()
        -- desatribui monitores de unidade acima da contagem de unidades
        for i = tmp_cfg.UnitCount + 1, 4 do tmp_cfg.UnitDisplays[i] = nil end

        tool_ctl.gen_mon_list()
        mon_pane.set_value(2)
    end

    PushButton{parent=mon_c_1,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(4)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=mon_c_1,x=41,y=14,text="Avançar \x1a",callback=next_from_reqs,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=mon_c_2,y=1,height=5,text="Configure seus monitores abaixo. Você pode voltar à página anterior sem perder o progresso para conferir o que precisa. Todos esses monitores devem ser atribuídos antes de prosseguir."}

    local mon_list = ListBox{parent=mon_c_2,y=6,height=7,width=49,scroll_height=100,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local assign_err = TextBox{parent=mon_c_2,x=10,y=14,width=30,text="",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_monitors()
        if tmp_cfg.MainDisplay == nil then
            assign_err.set_value("Atribua o monitor principal.")
        elseif tmp_cfg.FlowDisplay == nil then
            assign_err.set_value("Atribua o monitor de fluxo.")
        elseif util.table_len(tmp_cfg.UnitDisplays) ~= tmp_cfg.UnitCount then
            for i = 1, tmp_cfg.UnitCount do
                if tmp_cfg.UnitDisplays[i] == nil then
                    assign_err.set_value("Atribua o monitor da unid. " .. i .. ".")
                    break
                end
            end
        else
            assign_err.hide(true)
            main_pane.set_value(6)
            return
        end

        assign_err.show()
    end

    PushButton{parent=mon_c_2,y=14,text="\x1b Voltar",callback=function()mon_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=mon_c_2,x=41,y=14,text="Avançar \x1a",callback=submit_monitors,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    local mon_desc = TextBox{parent=mon_c_3,y=1,height=4,text=""}

    local mon_unit_l, mon_unit = nil, nil ---@type TextBox, NumberField

    local mon_warn = TextBox{parent=mon_c_3,y=11,height=2,text="",fg_bg=cpair(colors.red,colors.lightGray)}

    ---@param val integer tipo de atribuição
    local function on_assign_mon(val)
        if not util.table_contains(self.mon_expect, val) then
            self.apply_mon.disable()
            mon_warn.set_value("Esta atribuição não cabe nas dimensões do monitor. Você precisará redimensionar o monitor para funcionar.")
            mon_warn.show()
        else
            self.apply_mon.enable()
            mon_warn.hide(true)
        end

        if val == 3 then
            mon_unit_l.show()
            mon_unit.show()
        else
            mon_unit_l.hide(true)
            mon_unit.hide(true)
        end

        local value = mon_unit.get_value()
        mon_unit.set_max(tmp_cfg.UnitCount)
        if value == "0" or value == nil then mon_unit.set_value(0) end
    end

    TextBox{parent=mon_c_3,y=6,width=10,text="Atribuição"}
    local mon_assign = RadioButton{parent=mon_c_3,y=7,default=1,options={"Monitor Principal","Monitor de Fluxo","Monitor de Unidade"},callback=on_assign_mon,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.blue}

    mon_unit_l = TextBox{parent=mon_c_3,x=22,y=6,width=10,text="ID Unidade"}
    mon_unit = NumberField{parent=mon_c_3,x=22,y=7,width=10,max_chars=2,min=1,max=4,fg_bg=bw_fg_bg}

    local mon_u_err = TextBox{parent=mon_c_3,x=10,y=14,width=31,text="Informe o ID de uma unidade.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    -- limpa todas as atribuições para um determinado monitor
    ---@param iface string
    local function purge_assignments(iface)
        if tmp_cfg.MainDisplay == iface then
            tmp_cfg.MainDisplay = nil
        elseif tmp_cfg.FlowDisplay == iface then
            tmp_cfg.FlowDisplay = nil
        else
            for i = 1, tmp_cfg.UnitCount do
                if tmp_cfg.UnitDisplays[i] == iface then tmp_cfg.UnitDisplays[i] = nil end
            end
        end
    end

    local function apply_monitor()
        local iface = self.mon_iface
        local type = mon_assign.get_value()
        local u_id = tonumber(mon_unit.get_value())

        if type == 1 then
            purge_assignments(iface)
            tmp_cfg.MainDisplay = iface
        elseif type == 2 then
            purge_assignments(iface)
            tmp_cfg.FlowDisplay = iface
        elseif u_id and u_id > 0 then
            purge_assignments(iface)
            tmp_cfg.UnitDisplays[u_id] = iface
        else
            mon_u_err.show()
            return
        end

        tool_ctl.gen_mon_list()
        mon_u_err.hide(true)
        mon_pane.set_value(2)
    end

    PushButton{parent=mon_c_3,y=14,text="\x1b Voltar",callback=function()mon_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    self.apply_mon = PushButton{parent=mon_c_3,x=41,y=14,min_width=9,text="Aplicar",callback=apply_monitor,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    --#endregion

    --#region Alto-falante

    local spkr_c = Div{parent=spkr_cfg,x=2,y=4,width=49}

    TextBox{parent=spkr_cfg,y=2,text=" Configuração do Alto-falante",fg_bg=cpair(colors.black,colors.cyan)}

    TextBox{parent=spkr_c,y=1,height=2,text="O coordenador usa um alto-falante para reproduzir sons de alarme."}
    TextBox{parent=spkr_c,y=4,height=3,text="Você pode alterar o volume de áudio padrão do alto-falante. O intervalo é de 0.0 a 3.0, onde 1.0 é o volume padrão."}

    tool_ctl.s_vol = NumberField{parent=spkr_c,y=8,width=9,max_chars=7,allow_decimal=true,default=ini_cfg.SpeakerVolume,min=0,max=3,fg_bg=bw_fg_bg}

    TextBox{parent=spkr_c,y=10,height=3,text="Nota: ondas senoidais de alarme têm meia escala para que múltiplos tons sejam necessários para atingir a escala total.",fg_bg=g_lg_fg_bg}

    local s_vol_err = TextBox{parent=spkr_c,x=10,y=14,width=30,text="Defina um volume.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}

    local function submit_vol()
        local vol = tonumber(tool_ctl.s_vol.get_value())
        if vol ~= nil then
            s_vol_err.hide(true)
            tmp_cfg.SpeakerVolume = vol
            main_pane.set_value(7)
        else s_vol_err.show() end
    end

    PushButton{parent=spkr_c,y=14,text="\x1b Voltar",callback=function()main_pane.set_value(5)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=spkr_c,x=41,y=14,text="Avançar \x1a",callback=submit_vol,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Funções Auxiliares e de Ferramenta

    -- atualiza lista de requisitos de monitores
    function tool_ctl.update_mon_reqs()
        local plural = tmp_cfg.UnitCount > 1

        local u_bt = tool_ctl.unit_bt_cnt

        -- visão principal

        if u_bt ~= nil then
            local row1_tall  = (u_bt[1][1] > 1) or (u_bt[1][2] > 2) or (u_bt[2] and (u_bt[2][1] > 1 or u_bt[2][2] > 2))
            local row1_short = (u_bt[1][1] == 0 and u_bt[1][2] == 1) and (u_bt[2] == nil or (u_bt[2][1] == 0 and u_bt[2][2] == 1))
            local row2_tall  = (u_bt[3] and (u_bt[3][1] > 1 or u_bt[3][2] > 2)) or (u_bt[4] and (u_bt[4][1] > 1 or u_bt[4][2] > 2))
            local row2_short = (u_bt[3] == nil or (u_bt[3][1] == 0 and u_bt[3][2] == 1)) and (u_bt[4] == nil or (u_bt[4][1] == 0 and u_bt[4][2] == 1))

            if tmp_cfg.UnitCount <= 2 then
                tool_ctl.main_mon_h = util.trinary(row1_tall, 5, 4)
            else
                -- apenas uma linha é alta e a outra baixa, ou ambas são altas? -> 5 ou 6; nenhuma é alta? -> 5
                if row1_tall or row2_tall then
                    tool_ctl.main_mon_h = util.trinary((row1_short and row2_tall) or (row1_tall and row2_short), 5, 6)
                else tool_ctl.main_mon_h = 5 end
            end
        else
            tool_ctl.main_mon_h = util.trinary(tmp_cfg.UnitCount <= 2, 4, 5)
        end

        -- visão de fluxo

        local no_tanks, only_top_tank, num_tanks = true, true, 0

        for i = 1, #tool_ctl.tank_list do
            if tool_ctl.tank_list[i] > 0 then
                no_tanks = false
                num_tanks = num_tanks + 1

                if i > 1 then only_top_tank = false end
            end
        end

        local compressed = tool_ctl.com_waste and (no_tanks or only_top_tank or (tool_ctl.tank_mode == 1 and num_tanks == 1))
        local req_height = math.max(tool_ctl.com_waste and (compressed and ((11 * tmp_cfg.UnitCount) + 13) or ((19 * tmp_cfg.UnitCount) + 4)) or (20 * tmp_cfg.UnitCount), 32)

        if tmp_cfg.FlowDetailView then
            req_height = math.max(req_height, 36)

            if u_bt ~= nil then
                for _, u in pairs(u_bt) do
                    req_height = math.max(req_height, math.max(6 + (26 * u[1]), 6 + (25 * u[2])))
                end
            end
        end

        tool_ctl.flow_mon_h = ({ core.min_block_size(0, req_height, 0.5) })[2]

        -- relatório

        local asterisk = util.trinary(tool_ctl.unit_bt_cnt == nil, "*", "")
        local m_at_least = util.trinary(tool_ctl.main_mon_h < 6, "no mín. ", "")
        local f_at_least = util.trinary(tool_ctl.flow_mon_h < 6, "no mín. ", "")

        mon_reqs.remove_all()

        TextBox{parent=mon_reqs,text="\x1a "..tmp_cfg.UnitCount.." Monitor"..util.trinary(plural,"es","").." de Visão de Unidade"}
        TextBox{parent=mon_reqs,text="  "..util.trinary(plural,"cada um ","").."deve ter 4 blocos larg. por 4 alt.",fg_bg=cpair(colors.gray,colors.white)}
        TextBox{parent=mon_reqs,text="\x1a 1 Monitor de Visão Principal"}
        TextBox{parent=mon_reqs,text="  deve ter 8 blocos larg. por "..m_at_least..tool_ctl.main_mon_h..asterisk.." alt.",fg_bg=cpair(colors.gray,colors.white)}
        TextBox{parent=mon_reqs,text="\x1a 1 Monitor de Visão de Fluxo"}
        TextBox{parent=mon_reqs,text="  deve ter 8 blocos larg. por "..f_at_least..tool_ctl.flow_mon_h.." alt.",fg_bg=cpair(colors.gray,colors.white)}
    end

    -- define/edita a atribuição de um monitor
    ---@param iface string
    ---@param device ppm_entry
    function self.edit_monitor(iface, device)
        self.mon_iface = iface

        local dev = device.dev
        local w, h = ppm.monitor_block_size(dev.getSize())

        local msg = "Este tamanho não corresponde a nenhuma tela necessária. Volte e redimensione-o, ou configure abaixo correndo o risco de não funcionar."

        self.mon_expect = {}
        mon_assign.set_value(1)
        mon_unit.set_value(0)

        if w == 4 and h == 4 then
            msg = "Este pode funcionar como monitor de unidade. Configure abaixo."
            self.mon_expect = { 3 }
            mon_assign.set_value(3)
        elseif w == 8 then
            if h >= tool_ctl.main_mon_h and h >= tool_ctl.flow_mon_h then
                msg = "Este pode funcionar como monitor principal ou monitor de fluxo. Configure abaixo."
                self.mon_expect = { 1, 2 }
                if tmp_cfg.MainDisplay then mon_assign.set_value(2) end
            elseif h >= tool_ctl.main_mon_h then
                msg = "Este pode funcionar como seu monitor principal. Configure abaixo."
                self.mon_expect = { 1 }
            elseif h >= tool_ctl.flow_mon_h then
                msg = "Este pode funcionar como seu monitor de fluxo. Configure abaixo."
                self.mon_expect = { 2 }
                mon_assign.set_value(2)
            end
        end

        -- sobrescreve se existir uma configuração
        if tmp_cfg.MainDisplay == iface then
            mon_assign.set_value(1)
        elseif tmp_cfg.FlowDisplay == iface then
            mon_assign.set_value(2)
        else
            for i = 1, tmp_cfg.UnitCount do
                if tmp_cfg.UnitDisplays[i] == iface then
                    mon_assign.set_value(3)
                    mon_unit.set_value(i)
                    break
                end
            end
        end

        on_assign_mon(mon_assign.get_value())

        mon_desc.set_value(util.c("Você selecionou '", iface, "', que tem tamanho em blocos de ", w, " larg. por ", h, " alt. ", msg))
        mon_pane.set_value(3)
    end

    -- gera a lista de monitores disponíveis
    function tool_ctl.gen_mon_list()
        mon_list.remove_all()

        local missing = { main = tmp_cfg.MainDisplay ~= nil, flow = tmp_cfg.FlowDisplay ~= nil, unit = {} }
        for i = 1, tmp_cfg.UnitCount do missing.unit[i] = tmp_cfg.UnitDisplays[i] ~= nil end

        -- lista monitores conectados
        local monitors = ppm.get_monitor_list()
        for iface, device in pairs(monitors) do
            local dev = device.dev  ---@cast dev Monitor

            dev.setTextScale(0.5)
            dev.setTextColor(colors.white)
            dev.setBackgroundColor(colors.black)
            dev.clear()
            dev.setCursorPos(1, 1)
            dev.setTextColor(colors.magenta)
            dev.write("Este e o monitor")
            dev.setCursorPos(1, 2)
            dev.setTextColor(colors.white)
            dev.write(iface)

            local assignment = "Livre"

            if tmp_cfg.MainDisplay == iface then
                assignment = "Princ."
                missing.main = false
            elseif tmp_cfg.FlowDisplay == iface then
                assignment = "Fluxo"
                missing.flow = false
            else
                for i = 1, tmp_cfg.UnitCount do
                    if tmp_cfg.UnitDisplays[i] == iface then
                        missing.unit[i] = false
                        assignment = "Unid " .. i
                        break
                    end
                end
            end

            local line = Div{parent=mon_list,y=1,height=1}

            TextBox{parent=line,y=1,width=6,text=assignment,fg_bg=cpair(util.trinary(assignment=="Livre",colors.red,colors.blue),colors.white)}
            TextBox{parent=line,x=8,y=1,text=iface}

            local w, h = ppm.monitor_block_size(dev.getSize())

            local function unset_mon()
                purge_assignments(iface)
                tool_ctl.gen_mon_list()
            end

            TextBox{parent=line,x=33,y=1,width=4,text=w.."x"..h,fg_bg=cpair(colors.black,colors.white)}
            PushButton{parent=line,x=37,y=1,min_width=5,height=1,text="DEF",callback=function()self.edit_monitor(iface,device)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
            local unset = PushButton{parent=line,x=42,y=1,min_width=7,height=1,text="LIMPAR",callback=unset_mon,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg,dis_fg_bg=cpair(colors.black,colors.gray)}

            if assignment == "Livre" then unset.disable() end
        end

        local dc_list = {} -- lista de monitores desconectados

        if missing.main then table.insert(dc_list, { "Princ.", tmp_cfg.MainDisplay }) end
        if missing.flow then table.insert(dc_list, { "Fluxo", tmp_cfg.FlowDisplay }) end
        for i = 1, tmp_cfg.UnitCount do
            if missing.unit[i] then table.insert(dc_list, { "Unid " .. i, tmp_cfg.UnitDisplays[i] }) end
        end

        -- adiciona monitores atribuídos mas não conectados
        for i = 1, #dc_list do
            local line = Div{parent=mon_list,y=1,height=1}

            TextBox{parent=line,y=1,width=6,text=dc_list[i][1],fg_bg=cpair(colors.blue,colors.white)}
            TextBox{parent=line,x=8,y=1,text="desconectado",fg_bg=cpair(colors.red,colors.white)}

            local function unset_mon()
                purge_assignments(dc_list[i][2])
                tool_ctl.gen_mon_list()
            end

            TextBox{parent=line,x=33,y=1,width=4,text="?x?",fg_bg=cpair(colors.black,colors.white)}
            PushButton{parent=line,x=37,y=1,min_width=5,height=1,text="DEF",callback=function()end,dis_fg_bg=cpair(colors.black,colors.gray)}.disable()
            PushButton{parent=line,x=42,y=1,min_width=7,height=1,text="LIMPAR",callback=unset_mon,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg,dis_fg_bg=cpair(colors.black,colors.gray)}
        end
    end

    --#endregion

    return crd_pane, mon_pane
end

return hmi
