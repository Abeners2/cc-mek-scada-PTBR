local ppm         = require("scada-common.ppm")
local util        = require("scada-common.util")

local core        = require("graphics.core")

local Div         = require("graphics.elements.Div")
local ListBox     = require("graphics.elements.ListBox")
local MultiPane   = require("graphics.elements.MultiPane")
local TextBox     = require("graphics.elements.TextBox")

local PushButton  = require("graphics.elements.controls.PushButton")
local Radio2D     = require("graphics.elements.controls.Radio2D")
local RadioButton = require("graphics.elements.controls.RadioButton")

local NumberField = require("graphics.elements.form.NumberField")
local TextField   = require("graphics.elements.form.TextField")

---@class rtu_peri_definition
---@field unit integer|nil
---@field index integer|nil
---@field name string

local tri = util.trinary

local cpair = core.cpair

local ALIGN = core.ALIGN

local self = {
    peri_cfg_editing = false, ---@type integer|false

    p_assign = nil,   ---@type function

    ppm_devs = nil,   ---@type ListBox
    p_name_msg = nil, ---@type TextBox
    p_prompt = nil,   ---@type TextBox
    p_idx = nil,      ---@type NumberField
    p_unit = nil,     ---@type NumberField
    p_desc = nil,     ---@type TextBox
    p_fac_warn = nil, ---@type TextBox
    p_err = nil       ---@type TextBox
}

local peripherals = {}

local RTU_DEV_TYPES = { "solarNeutronActivator", "largeSolarNeutronActivator", "environmentDetector", "environment_detector", "reinforcedInductionPort", "draconic_rf_storage", "boilerValve", "turbineValve", "dynamicValve", "inductionPort", "spsPort" }
local NEEDS_UNIT = { "boilerValve", "turbineValve", "dynamicValve", "solarNeutronActivator", "largeSolarNeutronActivator", "environmentDetector", "environment_detector" }
local UNIT_OR_FACILITY = { "dynamicValve", "solarNeutronActivator", "largeSolarNeutronActivator", "environmentDetector", "environment_detector" }

-- criar a visualização de configuração de periféricos
---@param tool_ctl _rtu_cfg_tool_ctl
---@param main_pane MultiPane
---@param cfg_sys [ rtu_config, rtu_config, rtu_config, table, function ]
---@param peri_cfg Div
---@param style { [string]: cpair }
---@return MultiPane peri_pane, string[] NEEDS_UNIT
function peripherals.create(tool_ctl, main_pane, cfg_sys, peri_cfg, style)
    local settings_cfg, ini_cfg, tmp_cfg, _, load_settings = cfg_sys[1], cfg_sys[2], cfg_sys[3], cfg_sys[4], cfg_sys[5]

    local bw_fg_bg      = style.bw_fg_bg
    local g_lg_fg_bg    = style.g_lg_fg_bg
    local nav_fg_bg     = style.nav_fg_bg
    local btn_act_fg_bg = style.btn_act_fg_bg
    local btn_dis_fg_bg = style.btn_dis_fg_bg

    --#region Periféricos

    local peri_c_1 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_2 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_3 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_4 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_5 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_6 = Div{parent=peri_cfg,x=2,y=4,width=49}
    local peri_c_7 = Div{parent=peri_cfg,x=2,y=4,width=49}

    local peri_pane = MultiPane{parent=peri_cfg,y=4,panes={peri_c_1,peri_c_2,peri_c_3,peri_c_4,peri_c_5,peri_c_6,peri_c_7}}

    TextBox{parent=peri_cfg,y=2,text=" Conexões de Periféricos",fg_bg=cpair(colors.black,colors.purple)}

    local peri_list = ListBox{parent=peri_c_1,y=1,height=12,width=49,scroll_height=1000,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    local function peri_revert()
        tmp_cfg.Peripherals = tool_ctl.deep_copy_peri(ini_cfg.Peripherals)
        tool_ctl.gen_peri_summary()
    end

    local function peri_apply()
        settings.set("Peripherals", tmp_cfg.Peripherals)

        if settings.save("/rtu.settings") then
            load_settings(settings_cfg, true)
            load_settings(ini_cfg)
            peri_pane.set_value(5)

            -- para retornar à lista a partir da tela salva
            tmp_cfg.Peripherals = tool_ctl.deep_copy_peri(ini_cfg.Peripherals)
            tool_ctl.gen_peri_summary()
        else
            peri_pane.set_value(6)
        end
    end

    PushButton{parent=peri_c_1,y=14,text="\x1b Ant.",callback=function()main_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    local peri_revert_btn = PushButton{parent=peri_c_1,x=8,y=14,min_width=16,text="Reverter Alter.",callback=peri_revert,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    PushButton{parent=peri_c_1,x=35,y=14,min_width=7,text="Adic. +",callback=function()peri_pane.set_value(2)end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}
    local peri_apply_btn = PushButton{parent=peri_c_1,x=43,y=14,min_width=7,text="Aplicar",callback=peri_apply,fg_bg=cpair(colors.black,colors.green),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}

    TextBox{parent=peri_c_2,y=1,text="Selecione um dos dispositivos abaixo para usar."}

    self.ppm_devs = ListBox{parent=peri_c_2,y=3,height=10,width=49,scroll_height=1000,fg_bg=bw_fg_bg,nav_fg_bg=g_lg_fg_bg,nav_active=cpair(colors.black,colors.gray)}

    PushButton{parent=peri_c_2,y=14,text="\x1b Ant.",callback=function()peri_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_2,x=8,y=14,min_width=10,text="Manual +",callback=function()peri_pane.set_value(3)end,fg_bg=cpair(colors.black,colors.orange),active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_2,x=26,y=14,min_width=24,text="Não vejo meu disposit.!",callback=function()peri_pane.set_value(7)end,fg_bg=cpair(colors.black,colors.yellow),active_fg_bg=btn_act_fg_bg}

    TextBox{parent=peri_c_7,y=1,height=10,text="Certifique-se de que seu dispositivo está tocando a RTU ou conectado via modems cabeados. Deve haver um modem cabeado em um lado da RTU e outro no dispositivo, conectados por um cabo. O modem no dispositivo precisa ser clicado com o botão direito para conectá-lo (sua borda ficará vermelha) e o nome aparecerá no chat."}
    TextBox{parent=peri_c_7,y=9,height=4,text="Se ainda não aparecer, pode não ser compatível. Atualmente apenas Caldeiras, Turbinas, Tanques Dinâmicos, SNAs, SPSs, Matrizes de Indução e Detectores de Ambiente são suportados."}
    PushButton{parent=peri_c_7,y=14,text="\x1b Voltar",callback=function()peri_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    local new_peri_attrs = { "", "" }
    local function new_peri(name, type)
        new_peri_attrs = { name, type }
        self.peri_cfg_editing = false

        self.p_err.hide(true)
        self.p_name_msg.set_value("Configurando periférico em '" .. name .. "':")

        self.p_fac_warn.hide(true)

        local function reposition(prompt, idx_x, idx_max, unit_x, unit_y, desc_y)
            self.p_prompt.set_value(prompt)

            self.p_idx.reposition(idx_x, 4)
            self.p_idx.enable()
            self.p_idx.set_max(idx_max)
            self.p_idx.show()

            self.p_unit.reposition(unit_x, unit_y)
            self.p_unit.enable()
            self.p_unit.show()

            self.p_desc.hide(true)
            self.p_desc.reposition(1, desc_y)
            self.p_desc.show()
        end

        if type == "boilerValve" then
            reposition("Da unidade de reator #    , #      (caldeira).", 31, 2, 23, 4, 7)
            self.p_assign_btn.hide(true)
            self.p_desc.set_value("Cada unidade pode ter no máximo 2 caldeiras. A caldeira #1 aparece primeiro no monitor principal, seguida pela #2 abaixo dela. As numerações são por unidade (unidade 1 e 2 teriam ambas uma caldeira #1) e podem ser divididas entre múltiplas RTUs.")
        elseif type == "turbineValve" then
            reposition("Da unidade de reator #    , #      (turbina).", 31, 3, 23, 4, 7)
            self.p_assign_btn.hide(true)
            self.p_desc.set_value("Cada unidade pode ter no máximo 3 turbinas. A turbina #1 aparece primeiro no monitor principal, seguida pela #2 e #3 abaixo dela. As numerações são por unidade (unidade 1 e 2 teriam ambas uma turbina #1) e podem ser divididas entre múltiplas RTUs.")
        elseif type == "solarNeutronActivator" or type == "largeSolarNeutronActivator" then
            reposition("Este SNA é para o sistema abaixo.", 1, 1, 17, 6, 8)
            self.p_idx.hide(true)

            self.p_assign_btn.show()
            self.p_assign_btn.redraw()

            if self.p_assign_btn.get_value() == 1 then
                self.p_fac_warn.show()
            else self.p_fac_warn.hide(true) end

            self.p_desc.set_value("Muitos dispositivos (ex: excesso de SNAs) podem causar lag. Em um dia limpo, a taxa \"\x1aMAX\" no monitor de fluxo mostra o máximo de resíduos que os SNAs podem processar. SNAs suficientes para 2x-3x a taxa máxima de queima da unidade bastam.")
        elseif type == "dynamicValve" then
            reposition("Tanque dinamico do sistema #     abaixo.", 29, 4, 17, 6, 8)
            self.p_assign_btn.show()
            self.p_assign_btn.redraw()

            if self.p_assign_btn.get_value() == 1 then
                self.p_idx.enable()
                self.p_unit.disable()
            else
                self.p_idx.set_value(1)
                self.p_idx.disable()
                self.p_unit.enable()
            end

            self.p_desc.set_value("Cada unidade de reator pode ter no máximo 1 tanque e a instalação até 4. Cada tanque da instalação deve ter um # único de 1 a 4, independentemente de onde estiver conectado. Apenas um total de 4 tanques pode ser exibido no monitor de fluxo.")
        elseif type == "environmentDetector" or type == "environment_detector" then
            reposition("Detector amb. p/ o sistema #     abaixo.", 29, 99, 17, 6, 8)
            self.p_assign_btn.show()
            self.p_assign_btn.redraw()
            if self.p_assign_btn.get_value() == 1 then self.p_unit.disable() else self.p_unit.enable() end
            self.p_desc.set_value("Você pode conectar mais de um detector de ambiente para uma unidade específica ou para a instalação. Nesse caso, a leitura máxima de radiação entre os atribuídos a essa unidade ou instalação será usada para alarmes e exibição.")
        elseif type == "inductionPort" or type == "reinforcedInductionPort" or type == "spsPort" or type == "draconic_rf_storage" then
            self.p_idx.hide(true)
            self.p_unit.hide(true)
            self.p_assign_btn.hide(true)

            self.p_desc.hide(true)
            self.p_desc.reposition(1, 7)
            self.p_desc.show()

            if type == "spsPort" then
                self.p_prompt.set_value("Este é o SPS para a instalação.")
                self.p_desc.set_value("Só pode haver um SPS por rede SCADA, então ele será atribuído como o único SPS da instalação. Deve haver apenas um SPS em todas as RTUs que você possui.")
            else
                self.p_prompt.set_value(tri(type == "draconic_rf_storage", "Este é o núcleo de energia da instalação.", "Esta é a matriz de indução da instalação."))
                self.p_desc.set_value("Só pode haver um sistema de armazenamento de energia por rede SCADA, atribuído como o único da instalação. Deve haver apenas uma matriz de indução OU um núcleo de energia em todas as suas RTUs.")
            end
        else
            assert(false, "tipo de periférico inválido após validação de tipo")
        end

        peri_pane.set_value(4)
    end

    -- atualizar lista de periféricos
    function tool_ctl.update_peri_list()
        local alternate = true
        local mounts = ppm.list_mounts()

        -- filtrar periféricos em uso
        for _, v in ipairs(tmp_cfg.Peripherals) do mounts[v.name] = nil end

        self.ppm_devs.remove_all()
        for name, entry in pairs(mounts) do
            if util.table_contains(RTU_DEV_TYPES, entry.type) then
                local bkg = tri(alternate, colors.white, colors.lightGray)

                ---@cast entry ppm_entry
                local line = Div{parent=self.ppm_devs,height=2,fg_bg=cpair(colors.black,bkg)}
                PushButton{parent=line,y=1,min_width=9,alignment=ALIGN.LEFT,height=1,text="> SELEC.",callback=function()new_peri(name,entry.type)end,fg_bg=cpair(colors.black,colors.purple),active_fg_bg=cpair(colors.white,colors.black)}
                TextBox{parent=line,x=11,y=1,text=name,fg_bg=cpair(colors.black,bkg)}
                TextBox{parent=line,x=11,y=2,text=entry.type,fg_bg=cpair(colors.gray,bkg)}

                alternate = not alternate
            end
        end
    end

    tool_ctl.update_peri_list()

    TextBox{parent=peri_c_3,y=1,height=2,text="Isto é para usuários avançados. Se não encontrou seu dispositivo, clique em 'Não vejo meu disposit.!'."}
    TextBox{parent=peri_c_3,y=4,height=4,text="Nome do Periférico"}
    local p_name = TextField{parent=peri_c_3,y=5,width=49,height=1,max_len=128,fg_bg=bw_fg_bg}
    local p_type = Radio2D{parent=peri_c_3,y=7,rows=6,columns=2,default=1,options=RTU_DEV_TYPES,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.purple}
    local man_p_err = TextBox{parent=peri_c_3,x=8,y=14,width=35,text="Insira um nome de periférico.",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}
    man_p_err.hide(true)

    local function submit_manual_peri()
        local name = p_name.get_value()
        if string.len(name) > 0 then
            tool_ctl.entering_manual = true
            man_p_err.hide(true)
            new_peri(name, RTU_DEV_TYPES[p_type.get_value()])
        else man_p_err.show() end
    end

    PushButton{parent=peri_c_3,y=14,text="\x1b Ant.",callback=function()peri_pane.set_value(2)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_3,x=44,y=14,text="Prox \x1a",callback=submit_manual_peri,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    self.p_name_msg = TextBox{parent=peri_c_4,y=1,height=2,text=""}
    self.p_prompt = TextBox{parent=peri_c_4,y=4,height=2,text=""}
    self.p_idx = NumberField{parent=peri_c_4,x=31,y=4,width=4,max_chars=2,min=1,max=2,default=1,fg_bg=bw_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    self.p_assign_btn = RadioButton{parent=peri_c_4,y=5,default=1,options={"a instalação","unid. reator #"},callback=function(v)self.p_assign(v)end,radio_colors=cpair(colors.lightGray,colors.black),select_color=colors.purple}
    self.p_fac_warn = TextBox{parent=peri_c_4,y=5,x=22,height=2,alignment=ALIGN.CENTER,text="requer 'Resíduo Comb. da Instal.' no Supervisor",fg_bg=cpair(colors.red,colors._INHERIT),hidden=true}

    self.p_unit = NumberField{parent=peri_c_4,x=23,y=4,width=4,max_chars=2,min=1,max=4,default=1,fg_bg=bw_fg_bg,dis_fg_bg=btn_dis_fg_bg}
    self.p_unit.disable()

    function self.p_assign(opt)
        if opt == 1 then
            self.p_unit.disable()
            if new_peri_attrs[2] == "dynamicValve" then
                self.p_idx.enable()
            elseif new_peri_attrs[2] == "solarNeutronActivator" or new_peri_attrs[2] == "largeSolarNeutronActivator" then
                self.p_fac_warn.show()
            end
        else
            self.p_unit.enable()
            if new_peri_attrs[2] == "dynamicValve" then
                self.p_idx.set_value(1)
                self.p_idx.disable()
            elseif new_peri_attrs[2] == "solarNeutronActivator" or new_peri_attrs[2] == "largeSolarNeutronActivator" then
                self.p_fac_warn.hide(true)
            end
        end
    end

    self.p_desc = TextBox{parent=peri_c_4,y=7,height=6,text="",fg_bg=g_lg_fg_bg}

    self.p_err = TextBox{parent=peri_c_4,x=8,y=14,width=32,text="",fg_bg=cpair(colors.red,colors.lightGray),hidden=true}
    self.p_err.hide(true)

    local function back_from_peri_opts()
        if self.peri_cfg_editing ~= false then
            peri_pane.set_value(1)
        elseif tool_ctl.entering_manual then
            peri_pane.set_value(3)
        else
            peri_pane.set_value(2)
        end

        tool_ctl.entering_manual = false
    end

    local function save_peri_entry()
        local peri_name = new_peri_attrs[1]
        local peri_type = new_peri_attrs[2]

        local unit, index = nil, nil

        local for_facility = self.p_assign_btn.get_value() == 1
        local u = tonumber(self.p_unit.get_value())
        local idx = tonumber(self.p_idx.get_value())

        if util.table_contains(NEEDS_UNIT, peri_type) then
            if util.table_contains(UNIT_OR_FACILITY, peri_type) and for_facility then
                -- pular
            elseif not (util.is_int(u) and u > 0 and u < 5) then
                self.p_err.set_value("ID da unid. deve ser de 1 a 4.")
                self.p_err.show()
                return
            else unit = u end
        end

        if peri_type == "boilerValve" then
            if not (idx == 1 or idx == 2) then
                self.p_err.set_value("Índice deve ser 1 ou 2.")
                self.p_err.show()
                return
            else index = idx end
        elseif peri_type == "turbineValve" then
            if not (idx == 1 or idx == 2 or idx == 3) then
                self.p_err.set_value("Índice deve ser 1, 2 ou 3.")
                self.p_err.show()
                return
            else index = idx end
        elseif peri_type == "dynamicValve" and for_facility then
            if not (util.is_int(idx) and idx > 0 and idx < 5) then
                self.p_err.set_value("Índice deve ser de 1 a 4.")
                self.p_err.show()
                return
            else index = idx end
        elseif peri_type == "dynamicValve" then
            index = 1
        elseif peri_type == "environmentDetector" or peri_type == "environment_detector" then
            if not (util.is_int(idx) and idx > 0) then
                self.p_err.set_value("Índice deve ser maior que 0.")
                self.p_err.show()
                return
            else index = idx end
        end

        self.p_err.hide(true)

        ---@type rtu_peri_definition
        local def = { name = peri_name, unit = unit, index = index }

        if self.peri_cfg_editing == false then
            table.insert(tmp_cfg.Peripherals, def)
        else
            def.name = tmp_cfg.Peripherals[self.peri_cfg_editing].name
            tmp_cfg.Peripherals[self.peri_cfg_editing] = def
        end

        peri_pane.set_value(1)
        tool_ctl.gen_peri_summary()
        tool_ctl.update_peri_list()

        self.p_idx.set_value(1)
    end

    PushButton{parent=peri_c_4,y=14,text="\x1b Ant.",callback=back_from_peri_opts,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_4,x=41,y=14,min_width=9,text="Confirmar",callback=save_peri_entry,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg}

    TextBox{parent=peri_c_5,y=1,text="Configurações salvas!"}
    PushButton{parent=peri_c_5,y=14,text="\x1b Voltar",callback=function()peri_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_5,x=44,y=14,min_width=6,text="Início",callback=function()tool_ctl.go_home()end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    TextBox{parent=peri_c_6,y=1,height=5,text="Falha ao salvar o arquivo de configurações.\n\nPode não haver espaço suficiente para a modificação ou as permissões de arquivo do servidor podem estar negando gravações."}
    PushButton{parent=peri_c_6,y=14,text="\x1b Voltar",callback=function()peri_pane.set_value(1)end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}
    PushButton{parent=peri_c_6,x=44,y=14,min_width=6,text="Início",callback=function()tool_ctl.go_home()end,fg_bg=nav_fg_bg,active_fg_bg=btn_act_fg_bg}

    --#endregion

    --#region Funções de Ferramenta

    ---@param def rtu_peri_definition
    ---@param idx integer
    ---@param type string
    local function edit_peri_entry(idx, def, type)
        -- definir entradas ANTES de chamar new_peri()
        if def.index ~= nil then self.p_idx.set_value(def.index) end
        if def.unit == nil then
            self.p_assign_btn.set_value(1)
        else
            self.p_unit.set_value(def.unit)
            self.p_assign_btn.set_value(2)
        end

        new_peri(def.name, type)

        -- definir modo de edição DEPOIS de new_peri()
        self.peri_cfg_editing = idx
    end

    local function delete_peri_entry(idx)
        table.remove(tmp_cfg.Peripherals, idx)
        tool_ctl.gen_peri_summary()
        tool_ctl.update_peri_list()
    end

    -- gerar a lista de resumo de periféricos
    function tool_ctl.gen_peri_summary()
        peri_list.remove_all()

        local modified = #ini_cfg.Peripherals ~= #tmp_cfg.Peripherals

        for i = 1, #tmp_cfg.Peripherals do
            local def = tmp_cfg.Peripherals[i]

            local t = ppm.get_type(def.name)
            local t_str = "<desconectado> (conecte p/ editar)"
            local disconnected = t == nil

            if not disconnected then t_str = "[" .. t .. "]" end

            local desc = "  \x1a "

            if type(def.index) == "number" then
                desc = desc .. "#" .. def.index .. " "
            end

            if type(def.unit) == "number" then
                desc = desc .. "para a unidade " .. def.unit
            else
                desc = desc .. "para a instalação"
            end

            local entry = Div{parent=peri_list,height=3}
            TextBox{parent=entry,y=1,text="@ "..def.name,fg_bg=cpair(colors.black,colors.white)}
            TextBox{parent=entry,y=2,text="  \x1a "..t_str,fg_bg=cpair(colors.gray,colors.white)}
            TextBox{parent=entry,y=3,text=desc,fg_bg=cpair(colors.gray,colors.white)}
            local edit_btn = PushButton{parent=entry,x=41,y=2,min_width=8,height=1,text="EDITAR",callback=function()edit_peri_entry(i,def,t or "")end,fg_bg=cpair(colors.black,colors.blue),active_fg_bg=btn_act_fg_bg,dis_fg_bg=btn_dis_fg_bg}
            PushButton{parent=entry,x=41,y=3,min_width=8,height=1,text="EXCLUIR",callback=function()delete_peri_entry(i)end,fg_bg=cpair(colors.black,colors.red),active_fg_bg=btn_act_fg_bg}

            if disconnected then edit_btn.disable() end

            if not modified then
                local a = ini_cfg.Peripherals[i]
                local b = tmp_cfg.Peripherals[i]

                modified = (a.unit ~= b.unit) or (a.index ~= b.index) or (a.name ~= b.name)
            end
        end

        if modified then
            peri_revert_btn.enable()
            peri_apply_btn.enable()
        else
            peri_revert_btn.disable()
            peri_apply_btn.disable()
        end
    end

    --#endregion

    return peri_pane, NEEDS_UNIT
end

return peripherals
