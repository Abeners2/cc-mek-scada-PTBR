local comms = require("scada-common.comms")
local log   = require("scada-common.log")
local util  = require("scada-common.util")

local ioctl = require("pocket.ioctl")

local PROTOCOL = comms.PROTOCOL
local DEVICE_TYPE = comms.DEVICE_TYPE
local ESTABLISH_ACK = comms.ESTABLISH_ACK
local MGMT_TYPE = comms.MGMT_TYPE
local CRDN_TYPE = comms.CRDN_TYPE
local UNIT_COMMAND = comms.UNIT_COMMAND
local FAC_COMMAND = comms.FAC_COMMAND

local LINK_STATE = ioctl.LINK_STATE

local pocket = {}

local MQ__RENDER_DATA = {
    LOAD_APP = 1
}

pocket.MQ__RENDER_DATA = MQ__RENDER_DATA

---@type pkt_config
---@diagnostic disable-next-line: missing-fields
local config = {}

pocket.config = config

-- carrega a configuracao do pocket
function pocket.load_config()
    if not settings.load("/pocket.settings") then return false end

    config.GreenPuPellet = settings.get("GreenPuPellet")
    config.TempScale = settings.get("TempScale")
    config.EnergyScale = settings.get("EnergyScale")

    config.SVR_Channel = settings.get("SVR_Channel")
    config.CRD_Channel = settings.get("CRD_Channel")
    config.PKT_Channel = settings.get("PKT_Channel")
    config.ConnTimeout = settings.get("ConnTimeout")
    config.TrustedRange = settings.get("TrustedRange")
    config.AuthKey = settings.get("AuthKey")

    config.LogMode = settings.get("LogMode")
    config.LogPath = settings.get("LogPath")
    config.LogDebug = settings.get("LogDebug")

    local cfv = util.new_validator()

    cfv.assert_type_bool(config.GreenPuPellet)
    cfv.assert_type_int(config.TempScale)
    cfv.assert_range(config.TempScale, 1, 4)
    cfv.assert_type_int(config.EnergyScale)
    cfv.assert_range(config.EnergyScale, 1, 3)

    cfv.assert_channel(config.SVR_Channel)
    cfv.assert_channel(config.CRD_Channel)
    cfv.assert_channel(config.PKT_Channel)
    cfv.assert_type_num(config.ConnTimeout)
    cfv.assert_min(config.ConnTimeout, 2)
    cfv.assert_type_num(config.TrustedRange)
    cfv.assert_min(config.TrustedRange, 0)
    cfv.assert_type_str(config.AuthKey)

    if type(config.AuthKey) == "string" then
        local len = string.len(config.AuthKey)
        cfv.assert(len == 0 or len >= 8)
    end

    cfv.assert_type_int(config.LogMode)
    cfv.assert_range(config.LogMode, 0, 1)
    cfv.assert_type_str(config.LogPath)
    cfv.assert_type_bool(config.LogDebug)

    return cfv.valid()
end

---@enum POCKET_APP_ID
local APP_ID = {
    -- UI principal
    ROOT = 1,
    LOADER = 2,
    -- apps principais
    UNITS = 3,
    FACILITY = 4,
    CONTROL = 5,
    PROCESS = 6,
    WASTE = 7,
    GUIDE = 8,
    ABOUT = 9,
    RADMON = 10,
    BUILD = 11,
    -- apps de diagnostico
    ALARMS = 12,
    COMPS = 13,
    -- contagem
    NUM_APPS = 13
}

pocket.APP_ID = APP_ID

---@class nav_tree_page
---@field _p nav_tree_page|nil pagina pai
---@field _c nav_tree_page[] paginas filhas
---@field nav_to function funcao para navegar para esta pagina
---@field switcher function|nil funcao para alternar entre filhas
---@field tasks function[] tarefas executadas enquanto visualiza esta pagina

-- inicializa o sistema de navegacao de paginas
---@param smem pkt_shared_memory
function pocket.init_nav(smem)
    local self = {
        pane = nil,          ---@type AppMultiPane|MultiPane|nil
        sidebar = nil,       ---@type Sidebar|nil
        apps = {},           ---@type pocket_app[]
        containers = {},     ---@type Container[]
        help_map = {},       ---@type { [string]: function }
        help_return = nil,   ---@type POCKET_APP_ID|nil
        loader_return = nil, ---@type POCKET_APP_ID|nil
        cur_app = APP_ID.ROOT
    }

    self.cur_page = self.root

    ---@class pocket_nav
    local nav = {}

    -- define o elemento painel raiz para alternar entre apps
    ---@param root_pane MultiPane
    function nav.set_pane(root_pane) self.pane = root_pane end

    -- vincula o elemento da barra lateral
    ---@param sidebar Sidebar
    function nav.set_sidebar(sidebar) self.sidebar = sidebar end

    -- registra um app
    ---@param app_id POCKET_APP_ID ID do app
    ---@param container Container elemento que contem este app (geralmente um Div)
    ---@param pane? AppMultiPane|MultiPane multipane se for um app simples com paineis, entao nav_to deve ser um numero
    ---@param require_sv? boolean true para especificar se este app deve ser descarregado quando a conexao com o supervisor for perdida
    ---@param require_api? boolean true para especificar se este app deve ser descarregado quando a conexao com a API for perdida
    function nav.register_app(app_id, container, pane, require_sv, require_api)
        ---@class pocket_app
        local app = {
            loaded = false,
            cur_page = nil,    ---@type nav_tree_page|nil
            pane = pane,
            paned_pages = {},  ---@type nav_tree_page[]
            sidebar_items = {} ---@type sidebar_entry[]
        }

        app.load = function () app.loaded = true end
        app.unload = function () app.loaded = false end

        -- verifica quais conexoes este app requer (para descarregamento)
        ---@return boolean requires_sv, boolean requires_api
        function app.check_requires() return require_sv or false, require_api or false end

        -- verifica se alguma conexao e necessaria (para carregamento)
        function app.requires_conn() return require_sv or require_api or false end

        -- definicao atrasada do painel se nao estava pronto no inicio
        ---@param root_pane AppMultiPane|MultiPane multipane
        function app.set_root_pane(root_pane)
            app.pane = root_pane
        end

        -- configura a barra lateral
        ---@param items sidebar_entry[]
        function app.set_sidebar(items)
            app.sidebar_items = items
            -- modifica a barra lateral apenas se este app ainda estiver aberto
            if self.cur_app == app_id then
                if self.sidebar then self.sidebar.update(items) end
            end
        end

        -- funcao executada no carregamento inicial na memoria
        ---@param on_load function callback
        function app.set_load(on_load)
            app.load = function ()
                app.loaded = true   -- deve sinalizar primeiro para evitar tentativas repetidas
                on_load()
            end
        end

        -- funcao executada para encerrar o app
        ---@param on_unload function callback
        function app.set_unload(on_unload)
            app.unload = function ()
                app.loaded = false
                on_unload()
            end
        end

        -- se um painel foi fornecido, alterna entre paginas numeradas
        ---@param idx integer indice da pagina
        function app.switcher(idx)
            if app.paned_pages[idx] then
                app.paned_pages[idx].nav_to()
            end
        end

        -- cria uma nova entrada de pagina na arvore de navegacao do app
        ---@param parent nav_tree_page|nil pagina pai ou nil para definir como raiz
        ---@param nav_to function|integer funcao para navegar para esta pagina ou indice do painel
        ---@return nav_tree_page new_page esta nova pagina
        function app.new_page(parent, nav_to)
            ---@type nav_tree_page
            local page = { _p = parent, _c = {}, nav_to = function () end, switcher = function () end, tasks = {} }

            if parent == nil and app.cur_page == nil then
                app.cur_page = page
            end

            if type(nav_to) == "number" then
                app.paned_pages[nav_to] = page

                function page.nav_to()
                    app.cur_page = page
                    if app.pane then app.pane.set_value(nav_to) end
                end
            else
                function page.nav_to()
                    app.cur_page = page
                    nav_to()
                end
            end

            -- alterna entre filhas
            ---@param id integer ID da filha
            function page.switcher(id) if page._c[id] then page._c[id].nav_to() end end

            if parent ~= nil then
                table.insert(page._p._c, page)
            end

            return page
        end

        -- exclui paginas em paineis e limpa a pagina atual
        function app.delete_pages()
            app.paned_pages = {}
            app.cur_page = nil
        end

        -- obtem a pagina ativa no momento
        function app.get_current_page() return app.cur_page end

        -- tenta navegar para cima na arvore
        ---@return boolean success true se navegou para cima com sucesso
        function app.nav_up()
            local parent = app.cur_page._p
            if parent then parent.nav_to() end
            return parent ~= nil
        end

        self.apps[app_id] = app
        self.containers[app_id] = container

        return app
    end

    -- abre um app
    ---@param app_id POCKET_APP_ID
    ---@param on_ready? function
    function nav.open_app(app_id, on_ready)
        -- redefine o retorno de ajuda ao sair de um app
        if app_id == APP_ID.ROOT then self.help_return = nil end

        local app = self.apps[app_id]
        if app then
            local p_comms = smem.pkt_sys.pocket_comms
            local req_sv, req_api = app.check_requires()

            if (req_sv and not p_comms.is_sv_linked()) or (req_api and not p_comms.is_api_linked()) then
                -- informa conexoes necessarias
                ioctl.get_db().loader_require = { sv = req_sv, api = req_api }
                ioctl.get_db().ps.toggle("loader_reqs")

                -- exibe o carregador de app
                self.loader_return = app_id
                app_id = APP_ID.LOADER
                app = self.apps[app_id]
            else self.loader_return = nil end

            if not app.loaded then smem.q.mq_render.push_data(MQ__RENDER_DATA.LOAD_APP, { app_id, on_ready }) end

            self.cur_app = app_id
            self.pane.set_value(app_id)

            if #app.sidebar_items > 0 then
                self.sidebar.update(app.sidebar_items)
            end

            if app.loaded and on_ready then on_ready() end
        else
            log.debug("tried to open unknown app")
        end
    end

    -- vai para o inicio (abre o app da tela inicial)
    function nav.go_home() nav.open_app(APP_ID.ROOT) end

    -- abre o app que estava aguardando conexao
    function nav.on_loader_connected()
        if self.loader_return then
            nav.open_app(self.loader_return)
        end
    end

    -- carrega um determinado app
    ---@param app_id POCKET_APP_ID
    function nav.load_app(app_id)
        self.apps[app_id].load()
    end

    -- descarrega apps dependentes da API
    function nav.unload_api()
        for id, app in pairs(self.apps) do
            local _, api = app.check_requires()
            if app.loaded and api then
                if id == self.cur_app then nav.open_app(APP_ID.ROOT) end
                app.unload()
            end
        end
    end

    -- descarrega apps dependentes do supervisor
    function nav.unload_sv()
        for id, app in pairs(self.apps) do
            local sv, _ = app.check_requires()
            if app.loaded and sv then
                if id == self.cur_app then nav.open_app(APP_ID.ROOT) end
                app.unload()
            end
        end
    end

    -- obtem uma lista dos containers de apps (geralmente elementos Div)
    function nav.get_containers() return self.containers end

    -- obtem a pagina ativa no momento
    ---@return nav_tree_page|nil
    function nav.get_current_page()
        return self.apps[self.cur_app].get_current_page()
    end

    -- tenta navegar para cima dentro do app ativo, caso contrario abre a pagina inicial<br>
    -- exceto que voltara ao app anterior se sair do app de ajuda apos usar open_help
    function nav.nav_up()
        -- retorna da ajuda se foi aberta com open_help
        if self.help_return then
            nav.open_app(self.help_return)
            self.help_return = nil
            return
        end

        local app = self.apps[self.cur_app]
        log.debug("attempting app nav up for app " .. self.cur_app)

        if not app.nav_up() then
            log.debug("internal app nav up failed, going to home screen")
            nav.open_app(APP_ID.ROOT)
        end
    end

    -- abre o app de ajuda para mostrar a referencia de uma chave
    function nav.open_help(key)
        self.help_return = self.cur_app

        nav.open_app(APP_ID.GUIDE, function ()
            if self.help_map[key] then self.help_map[key]() end
        end)
    end

    -- vincula o mapa de ajuda do app de guia
    ---@param map { [string]: function }
    function nav.link_help(map) self.help_map = map end

    return nav
end

-- comunicacoes do pocket com coordenador + supervisor
---@nodiscard
---@param version string versao do pocket
---@param nic nic dispositivo de interface de rede
---@param sv_watchdog watchdog
---@param api_watchdog watchdog
---@param nav pocket_nav
function pocket.comms(version, nic, sv_watchdog, api_watchdog, nav)
    local self = {
        sv = {
            linked = false,
            addr = comms.BROADCAST,
            seq_num = util.time_ms() * 10, -- unico por par, reiniciar nao reutilizara seq nums devido a taxa de mensagens
            r_seq_num = nil,               ---@type nil|integer
            last_est_ack = ESTABLISH_ACK.ALLOW
        },
        api = {
            linked = false,
            addr = comms.BROADCAST,
            seq_num = util.time_ms() * 10, -- unico por par, reiniciar nao reutilizara seq nums devido a taxa de mensagens
            r_seq_num = nil,               ---@type nil|integer
            last_est_ack = ESTABLISH_ACK.ALLOW
        },
        establish_delay_counter = 0
    }

    comms.set_trusted_range(config.TrustedRange)

    -- FUNCOES PRIVADAS --

    -- configura canais de rede
    nic.closeAll()
    nic.open(config.PKT_Channel)

    -- envia um pacote de gerenciamento ao supervisor
    ---@param msg_type MGMT_TYPE
    ---@param msg table
    local function _send_sv(msg_type, msg)
        local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

        mgmt.make(msg_type, msg)
        frame.make(self.sv.addr, self.sv.seq_num, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

        nic.transmit(config.SVR_Channel, config.PKT_Channel, frame)
        self.sv.seq_num = self.sv.seq_num + 1
    end

    -- envia um pacote de gerenciamento ao coordenador
    ---@param msg_type MGMT_TYPE
    ---@param msg table
    local function _send_crd(msg_type, msg)
        local frame, mgmt = comms.scada_frame(), comms.mgmt_container()

        mgmt.make(msg_type, msg)
        frame.make(self.api.addr, self.api.seq_num, PROTOCOL.SCADA_MGMT, mgmt.raw_packet())

        nic.transmit(config.CRD_Channel, config.PKT_Channel, frame)
        self.api.seq_num = self.api.seq_num + 1
    end

    -- envia um pacote de API ao coordenador
    ---@param msg_type CRDN_TYPE
    ---@param msg table
    local function _send_api(msg_type, msg)
        local frame, crdn = comms.scada_frame(), comms.crdn_container()

        crdn.make(msg_type, msg)
        frame.make(self.api.addr, self.api.seq_num, PROTOCOL.SCADA_CRDN, crdn.raw_packet())

        nic.transmit(config.CRD_Channel, config.PKT_Channel, frame)
        self.api.seq_num = self.api.seq_num + 1
    end

    -- tenta estabelecer conexao com o supervisor
    local function _send_sv_establish()
        self.sv.r_seq_num = nil
        _send_sv(MGMT_TYPE.ESTABLISH, { comms.version, version, DEVICE_TYPE.PKT })
    end

    -- tenta estabelecer conexao com a API do coordenador
    local function _send_api_establish()
        self.api.r_seq_num = nil
        _send_crd(MGMT_TYPE.ESTABLISH, { comms.version, version, DEVICE_TYPE.PKT, comms.api_version })
    end

    -- confirmacao de keep alive ao supervisor
    ---@param srv_time integer
    local function _send_sv_keep_alive_ack(srv_time)
        _send_sv(MGMT_TYPE.KEEP_ALIVE, { srv_time, util.time() })
    end

    -- confirmacao de keep alive ao coordenador
    ---@param srv_time integer
    local function _send_api_keep_alive_ack(srv_time)
        _send_crd(MGMT_TYPE.KEEP_ALIVE, { srv_time, util.time() })
    end

    -- FUNCOES PUBLICAS --

    ---@class pocket_comms
    local public = {}

    -- fecha a conexao com o supervisor
    function public.close_sv()
        sv_watchdog.cancel()
        nav.unload_sv()

        if self.sv.linked then
            self.sv.linked = false
            _send_sv(MGMT_TYPE.CLOSE, {})
        end

        self.sv.r_seq_num = nil
        self.sv.addr = comms.BROADCAST
    end

    -- fecha a conexao com o servidor de API do coordenador
    function public.close_api()
        api_watchdog.cancel()
        nav.unload_api()

        if self.api.linked then
            self.api.linked = false
            _send_crd(MGMT_TYPE.CLOSE, {})
        end

        self.api.r_seq_num = nil
        self.api.addr = comms.BROADCAST
    end

    -- fecha as conexoes com os servidores
    function public.close()
        public.close_sv()
        public.close_api()
    end

    -- tenta reconectar se algum dos links dependentes nao estiver ativo
    function public.link_update()
        if not (self.sv.linked and self.api.linked) then
            if self.api.linked then
                ioctl.report_link_state(LINK_STATE.API_LINK_ONLY, false, nil)
            elseif self.sv.linked then
                ioctl.report_link_state(LINK_STATE.SV_LINK_ONLY, nil, false)
            else
                ioctl.report_link_state(LINK_STATE.UNLINKED, false, false)
            end

            if self.establish_delay_counter <= 0 then
                if not self.api.linked then _send_api_establish() end
                if not self.sv.linked then _send_sv_establish() end
                self.establish_delay_counter = 4
            else
                self.establish_delay_counter = self.establish_delay_counter - 1
            end
        end
    end

    -- supervisor obtem tons de alarme ativos
    function public.diag__get_alarm_tones()
        if self.sv.linked then _send_sv(MGMT_TYPE.DIAG_TONE_GET, {}) end
    end

    -- supervisor testa tons de alarme por tom
    ---@param id TONE|0 ID do tom, ou 0 para parar todos
    ---@param state boolean estado do tom
    function public.diag__set_alarm_tone(id, state)
        if self.sv.linked then _send_sv(MGMT_TYPE.DIAG_TONE_SET, { id, state }) end
    end

    -- supervisor testa tons de alarme por alarme
    ---@param id ALARM|0 ID do alarme, 0 para parar todos
    ---@param state boolean estado do alarme
    function public.diag__set_alarm(id, state)
        if self.sv.linked then _send_sv(MGMT_TYPE.DIAG_ALARM_SET, { id, state }) end
    end

    -- supervisor obtem computadores conectados
    function public.diag__get_computers()
        if self.sv.linked then _send_sv(MGMT_TYPE.INFO_LIST_CMP, {}) end
    end

    -- coordenador obtem dados do app de instalacao
    function public.api__get_facility()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_FAC_DTL, {}) end
    end

    -- coordenador obtem dados da unidade
    function public.api__get_unit(unit)
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_UNIT, { unit }) end
    end

    -- coordenador obtem dados do app de controle
    function public.api__get_control()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_CTRL, {}) end
    end

    -- coordenador obtem dados do app de processo
    function public.api__get_process()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_PROC, {}) end
    end

    -- coordenador obtem dados do app de rejeitos
    function public.api__get_waste()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_WASTE, {}) end
    end

    -- coordenador obtem dados do app de radiacao
    function public.api__get_rad()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_RAD, {}) end
    end

    -- coordenador obtem dados do app de construcao
    function public.api__get_build()
        if self.api.linked then _send_api(CRDN_TYPE.API_GET_BUILD, {}) end
    end

    -- envia um comando da instalacao
    ---@param cmd FAC_COMMAND comando
    ---@param option any? opcao opcional para os comandos que aceitam opcoes (como modo de rejeitos)
    function public.send_fac_command(cmd, option)
        _send_api(CRDN_TYPE.FAC_CMD, { cmd, option })
    end

    -- envia a configuracao de controle automatico de processo com comando de iniciar
    ---@param auto_cfg auto_ctl_cfg
    function public.send_auto_start(auto_cfg)
        _send_api(CRDN_TYPE.FAC_CMD, { FAC_COMMAND.START, table.unpack(auto_cfg) })
    end

    -- envia um comando de unidade
    ---@param cmd UNIT_COMMAND comando
    ---@param unit integer ID da unidade
    ---@param option any? opcao opcional para comandos com opcoes (como taxa de queima)
    function public.send_unit_command(cmd, unit, option)
        _send_api(CRDN_TYPE.UNIT_CMD, { cmd, unit, option })
    end

    -- interpreta um pacote
    ---@param side string
    ---@param sender integer
    ---@param reply_to integer
    ---@param message any
    ---@param distance integer
    ---@return mgmt_packet|crdn_packet|nil packet
    function public.parse_packet(side, sender, reply_to, message, distance)
        local frame = nic.receive(side, sender, reply_to, message, distance)

        local pkt = nil
        if frame then
            if frame.protocol() == PROTOCOL.SCADA_MGMT then
                pkt = comms.mgmt_container().decode(frame)
            elseif frame.protocol() == PROTOCOL.SCADA_CRDN then
                pkt = comms.crdn_container().decode(frame)
            else
                log.debug("attempted parse of illegal packet type " .. frame.protocol(), true)
            end
        end

        return pkt
    end

    ---@param packet mgmt_packet|crdn_packet
    ---@param length integer
    ---@param max integer?
    ---@return boolean
    local function _check_length(packet, length, max)
        local ok = util.trinary(max == nil, packet.length == length, packet.length >= length and packet.length <= (max or 0))
        if not ok then
            local fmt = "[comms] RX_PACKET{r_chan=%d,proto=%d,type=%d}: packet length mismatch -> expect %d != actual %d"
            log.debug(util.sprintf(fmt, packet.scada_frame.remote_channel(), packet.scada_frame.protocol(), packet.type, length, packet.length))
        end
        return ok
    end

    ---@param packet mgmt_packet|crdn_packet
    local function _fail_type(packet)
        local fmt = "[comms] RX_PACKET{r_chan=%d,proto=%d,type=%d}: unrecognized packet type"
        log.debug(util.sprintf(fmt, packet.scada_frame.remote_channel(), packet.scada_frame.protocol(), packet.type))
    end

    -- trata um pacote
    ---@param packet mgmt_packet|crdn_packet|nil
    function public.handle_packet(packet)
        local diag = ioctl.get_db().diag
        local ps   = ioctl.get_db().ps

        if packet ~= nil then
            local l_chan   = packet.scada_frame.local_channel()
            local r_chan   = packet.scada_frame.remote_channel()
            local protocol = packet.scada_frame.protocol()
            local src_addr = packet.scada_frame.src_addr()

            if l_chan ~= config.PKT_Channel then
                log.debug("received packet on unconfigured channel " .. l_chan, true)
            elseif r_chan == config.CRD_Channel then
                -- verifica numero de sequencia
                if self.api.r_seq_num == nil then
                    self.api.r_seq_num = packet.scada_frame.seq_num() + 1
                elseif self.api.r_seq_num ~= packet.scada_frame.seq_num() then
                    log.warning("sequence out-of-order (API): next = " .. self.api.r_seq_num .. ", new = " .. packet.scada_frame.seq_num())
                    return
                elseif self.api.linked and (src_addr ~= self.api.addr) then
                    log.debug("received packet from unknown computer " .. src_addr .. " while linked (API expected " .. self.api.addr ..
                              "); channel in use by another system?")
                    return
                else
                    self.api.r_seq_num = packet.scada_frame.seq_num() + 1
                end

                -- alimenta o watchdog ao receber numero de sequencia valido
                api_watchdog.feed()

                if protocol == PROTOCOL.SCADA_CRDN then
                    ---@cast packet crdn_packet
                    if self.api.linked then
                        if packet.type == CRDN_TYPE.FAC_CMD then
                            -- confirmacao de comando da instalacao
                            if packet.length >= 2 then
                                local cmd = packet.data[1]
                                local ack = packet.data[2] == true

                                if cmd == FAC_COMMAND.SCRAM_ALL then
                                    ioctl.get_db().facility.scram_ack(ack)
                                elseif cmd == FAC_COMMAND.STOP then
                                    ioctl.get_db().facility.stop_ack(ack)
                                elseif cmd == FAC_COMMAND.START then
                                    ioctl.get_db().facility.start_ack(ack)
                                elseif cmd == FAC_COMMAND.ACK_ALL_ALARMS then
                                    ioctl.get_db().facility.ack_alarms_ack(ack)
                                elseif cmd == FAC_COMMAND.SET_WASTE_MODE then
                                elseif cmd == FAC_COMMAND.SET_PU_FB then
                                elseif cmd == FAC_COMMAND.SET_SPS_LP then
                                else
                                    log.debug(util.c("received facility command ack with unknown command ", cmd))
                                end
                            else
                                log.debug("SCADA_CRDN facility command ack packet length mismatch")
                            end
                        elseif packet.type == CRDN_TYPE.UNIT_CMD then
                            -- confirmacao de comando da unidade
                            if packet.length == 3 then
                                local cmd = packet.data[1]
                                local unit_id = packet.data[2]
                                local ack = packet.data[3] == true

                                local unit = ioctl.get_db().units[unit_id]  ---@type pkt_io_unit

                                if unit ~= nil then
                                    if cmd == UNIT_COMMAND.SCRAM then
                                        unit.scram_ack(ack)
                                    elseif cmd == UNIT_COMMAND.START then
                                        unit.start_ack(ack)
                                    elseif cmd == UNIT_COMMAND.RESET_RPS then
                                        unit.reset_rps_ack(ack)
                                    elseif cmd == UNIT_COMMAND.ACK_ALL_ALARMS then
                                        unit.ack_alarms_ack(ack)
                                    else
                                        log.debug(util.c("received unsupported unit command ack for command ", cmd))
                                    end
                                end
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_FAC then
                            if _check_length(packet, 9) then
                                ioctl.rx.record_facility_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_FAC_DTL then
                            if _check_length(packet, 12) then
                                ioctl.rx.record_fac_detail_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_UNIT then
                            if _check_length(packet, 13) and type(packet.data[1]) == "number" and ioctl.get_db().units[packet.data[1]] then
                                ioctl.rx.record_unit_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_BUILD then
                            if _check_length(packet, #ioctl.get_db().units + 1) then
                                ioctl.rx.record_build_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_CTRL then
                            if _check_length(packet, #ioctl.get_db().units) then
                                ioctl.rx.record_control_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_PROC then
                            if _check_length(packet, #ioctl.get_db().units + 1) then
                                ioctl.rx.record_process_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_WASTE then
                            if _check_length(packet, #ioctl.get_db().units + 1) then
                                ioctl.rx.record_waste_data(packet.data)
                            end
                        elseif packet.type == CRDN_TYPE.API_GET_RAD then
                            if _check_length(packet, #ioctl.get_db().units + 1) then
                                ioctl.rx.record_radiation_data(packet.data)
                            end
                        else _fail_type(packet) end
                    else
                        log.debug("discarding coordinator SCADA_CRDN packet before linked")
                    end
                elseif protocol == PROTOCOL.SCADA_MGMT then
                    ---@cast packet mgmt_packet
                    if self.api.linked then
                        if packet.type == MGMT_TYPE.KEEP_ALIVE then
                            -- requisicao de keep alive recebida, ecoa de volta
                            if _check_length(packet, 1) then
                                local timestamp = packet.data[1]
                                local trip_time = util.time() - timestamp

                                if trip_time > 750 then
                                    log.warning("pocket coordinator KEEP_ALIVE trip time > 750ms (" .. trip_time .. "ms)")
                                end

                                -- log.debug("pocket coordinator TT = " .. trip_time .. "ms")

                                _send_api_keep_alive_ack(timestamp)

                                ioctl.report_crd_tt(trip_time)
                            end
                        elseif packet.type == MGMT_TYPE.CLOSE then
                            -- trata fechamento de sessao
                            api_watchdog.cancel()
                            nav.unload_api()
                            self.api.linked = false
                            self.api.r_seq_num = nil
                            self.api.addr = comms.BROADCAST
                            log.info("coordinator server connection closed by remote host")
                        else _fail_type(packet) end
                    elseif packet.type == MGMT_TYPE.ESTABLISH then
                        -- conexao com coordenador estabelecida
                        if _check_length(packet, 1, 2) then
                            local est_ack = packet.data[1]

                            if est_ack == ESTABLISH_ACK.ALLOW then
                                if packet.length == 2 then
                                    local fac_config = packet.data[2]

                                    if type(fac_config) == "table" and #fac_config == 4 then
                                        -- obtem a configuracao
                                        local conf = { num_units = fac_config[1], cooling = fac_config[2], com_waste = fac_config[3], ess = fac_config[4] }

                                        ioctl.init_fac(conf)

                                        log.info("coordinator connection established")
                                        self.establish_delay_counter = 0
                                        self.api.linked = true
                                        self.api.addr = src_addr

                                        ioctl.report_crd_link_error("")

                                        if self.sv.linked then
                                            ioctl.report_link_state(LINK_STATE.LINKED, nil, self.api.addr)
                                        else
                                            ioctl.report_link_state(LINK_STATE.API_LINK_ONLY, nil, self.api.addr)
                                        end
                                    else
                                        log.debug("invalid facility configuration table received from coordinator, establish failed")
                                    end
                                else
                                    log.debug("received coordinator establish allow without facility configuration")
                                end
                            else
                                if self.api.last_est_ack ~= est_ack then
                                    if est_ack == ESTABLISH_ACK.DENY then
                                        log.info("coordinator connection denied")
                                        ioctl.report_crd_link_error("acesso negado")
                                    elseif est_ack == ESTABLISH_ACK.COLLISION then
                                        log.info("coordinator connection denied due to collision")
                                        ioctl.report_crd_link_error("colisao")
                                    elseif est_ack == ESTABLISH_ACK.BAD_VERSION then
                                        log.info("coordinator comms version mismatch")
                                        ioctl.report_crd_link_error("versao comms incompativel")
                                    elseif est_ack == ESTABLISH_ACK.BAD_API_VERSION then
                                        log.info("coordinator api version mismatch")
                                        ioctl.report_crd_link_error("versao API incompativel")
                                    else
                                        log.debug("coordinator SCADA_MGMT establish packet reply unsupported")
                                        ioctl.report_crd_link_error("resposta desconhecida")
                                    end
                                end

                                -- desvincula
                                self.api.addr = comms.BROADCAST
                                self.api.linked = false
                            end

                            self.api.last_est_ack = est_ack
                        end
                    else
                        log.debug("discarding coordinator non-link SCADA_MGMT packet before linked")
                    end
                else
                    log.debug("illegal packet type " .. protocol .. " from coordinator", true)
                end
            elseif r_chan == config.SVR_Channel then
                -- verifica numero de sequencia
                if self.sv.r_seq_num == nil then
                    self.sv.r_seq_num = packet.scada_frame.seq_num() + 1
                elseif self.sv.r_seq_num ~= packet.scada_frame.seq_num() then
                    log.warning("sequence out-of-order (SVR): next = " .. self.sv.r_seq_num .. ", new = " .. packet.scada_frame.seq_num())
                    return
                elseif self.sv.linked and (src_addr ~= self.sv.addr) then
                    log.debug("received packet from unknown computer " .. src_addr .. " while linked (SVR expected " .. self.sv.addr ..
                                "); channel in use by another system?")
                    return
                else
                    self.sv.r_seq_num = packet.scada_frame.seq_num() + 1
                end

                -- alimenta o watchdog ao receber numero de sequencia valido
                sv_watchdog.feed()

                -- trata pacote
                if protocol == PROTOCOL.SCADA_MGMT then
                    ---@cast packet mgmt_packet
                    if self.sv.linked then
                        if packet.type == MGMT_TYPE.KEEP_ALIVE then
                            -- requisicao de keep alive recebida, ecoa de volta
                            if _check_length(packet, 1) then
                                local timestamp = packet.data[1]
                                local trip_time = util.time() - timestamp

                                if trip_time > 750 then
                                    log.warning("pocket supervisor KEEP_ALIVE trip time > 750ms (" .. trip_time .. "ms)")
                                end

                                -- log.debug("pocket supervisor TT = " .. trip_time .. "ms")

                                _send_sv_keep_alive_ack(timestamp)

                                ioctl.report_svr_tt(trip_time)
                            end
                        elseif packet.type == MGMT_TYPE.CLOSE then
                            -- trata fechamento de sessao
                            sv_watchdog.cancel()
                            nav.unload_sv()
                            self.sv.linked = false
                            self.sv.r_seq_num = nil
                            self.sv.addr = comms.BROADCAST
                            log.info("supervisor server connection closed by remote host")
                        elseif packet.type == MGMT_TYPE.DIAG_TONE_GET then
                            if _check_length(packet, 8) then
                                for i = 1, #packet.data do
                                    ps.publish("alarm_tone_" .. i, packet.data[i] == true)
                                end
                            end
                        elseif packet.type == MGMT_TYPE.DIAG_TONE_SET then
                            if packet.length == 1 and packet.data[1] == false then
                                ps.publish("alarm_ready_warn", "teste negado")
                                log.debug("supervisor SCADA diag tone set failed")
                            elseif packet.length == 2 and type(packet.data[2]) == "table" then
                                local ready = packet.data[1]
                                local states = packet.data[2]

                                ps.publish("alarm_ready_warn", util.trinary(ready, "", "sistema ocupado"))

                                for i = 1, #states do
                                    if diag.tone_test.tone_buttons[i] ~= nil then
                                        diag.tone_test.tone_buttons[i].set_value(states[i] == true)
                                        ps.publish("alarm_tone_" .. i, states[i] == true)
                                    end
                                end
                            else
                                log.debug("supervisor SCADA diag tone set packet length/type mismatch")
                            end
                        elseif packet.type == MGMT_TYPE.DIAG_ALARM_SET then
                            if packet.length == 1 and packet.data[1] == false then
                                ps.publish("alarm_ready_warn", "teste negado")
                                log.debug("supervisor SCADA diag alarm set failed")
                            elseif packet.length == 2 and type(packet.data[2]) == "table" then
                                local ready = packet.data[1]
                                local states = packet.data[2]

                                ps.publish("alarm_ready_warn", util.trinary(ready, "", "sistema ocupado"))

                                for i = 1, #states do
                                    if diag.tone_test.alarm_buttons[i] ~= nil then
                                        diag.tone_test.alarm_buttons[i].set_value(states[i] == true)
                                    end
                                end
                            else
                                log.debug("supervisor SCADA diag alarm set packet length/type mismatch")
                            end
                        elseif packet.type == MGMT_TYPE.INFO_LIST_CMP then
                            ioctl.rx.record_network_data(packet.data)
                        else _fail_type(packet) end
                    elseif packet.type == MGMT_TYPE.ESTABLISH then
                        -- conexao com supervisor estabelecida
                        if _check_length(packet, 1) then
                            local est_ack = packet.data[1]

                            if est_ack == ESTABLISH_ACK.ALLOW then
                                log.info("supervisor connection established")
                                self.establish_delay_counter = 0
                                self.sv.linked = true
                                self.sv.addr = src_addr

                                ioctl.report_svr_link_error("")

                                if self.api.linked then
                                    ioctl.report_link_state(LINK_STATE.LINKED, self.sv.addr, nil)
                                else
                                    ioctl.report_link_state(LINK_STATE.SV_LINK_ONLY, self.sv.addr, nil)
                                end
                            else
                                if self.sv.last_est_ack ~= est_ack then
                                    if est_ack == ESTABLISH_ACK.DENY then
                                        log.info("supervisor connection denied")
                                        ioctl.report_svr_link_error("acesso negado")
                                    elseif est_ack == ESTABLISH_ACK.COLLISION then
                                        log.info("supervisor connection denied due to collision")
                                        ioctl.report_svr_link_error("colisao")
                                    elseif est_ack == ESTABLISH_ACK.BAD_VERSION then
                                        log.info("supervisor comms version mismatch")
                                        ioctl.report_svr_link_error("versao comms incompativel")
                                    else
                                        log.debug("supervisor SCADA_MGMT establish packet reply unsupported")
                                        ioctl.report_svr_link_error("resposta desconhecida")
                                    end
                                end

                                -- desvincula
                                self.sv.addr = comms.BROADCAST
                                self.sv.linked = false
                            end

                            self.sv.last_est_ack = est_ack
                        end
                    else
                        log.debug("discarding supervisor non-link SCADA_MGMT packet before linked")
                    end
                else _fail_type(packet) end
            else
                log.debug("received packet from unconfigured channel " .. r_chan, true)
            end
        end
    end

    -- verifica se ainda estamos conectados ao supervisor
    ---@nodiscard
    function public.is_sv_linked() return self.sv.linked end

    -- verifica se ainda estamos conectados ao coordenador
    ---@nodiscard
    function public.is_api_linked() return self.api.linked end

    -- verifica se ainda estamos conectados ao supervisor e ao coordenador
    ---@nodiscard
    function public.is_linked() return self.sv.linked and self.api.linked end

    return public
end

return pocket
