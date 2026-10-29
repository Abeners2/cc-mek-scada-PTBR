--[[
Utilitário Instalador CC-MEK-SCADA (CCMSI)

Copyright (c) 2023 - 2026 Mikayla Fischler

A permissão é concedida, gratuitamente, a qualquer pessoa que obtenha uma cópia deste software e
arquivos de documentação associados (o "Software"), para lidar com o Software sem restrições,
incluindo, sem limitação, os direitos de usar, copiar, modificar, mesclar, publicar, distribuir, sublicenciar,
e/ou vender cópias do Software, e permitir que as pessoas a quem o Software é fornecido o façam.

O SOFTWARE É FORNECIDO "COMO ESTÁ", SEM GARANTIA DE QUALQUER TIPO, EXPRESSA OU IMPLÍCITA, INCLUINDO, MAS NÃO
SE LIMITANDO ÀS GARANTIAS DE COMERCIALIZAÇÃO, ADEQUAÇÃO A UMA FINALIDADE ESPECÍFICA E NÃO VIOLAÇÃO.
EM NENHUM CASO OS AUTORES OU DETENTORES DOS DIREITOS AUTORAIS SERÃO RESPONSÁVEIS POR QUALQUER RECLAMAÇÃO, DANOS OU OUTRA RESPONSABILIDADE,
SEJA EM UMA AÇÃO DE CONTRATO, ATO ILÍCITO OU DE OUTRA FORMA, DECORRENTE DE, FORA DE OU EM CONEXÃO COM O
SOFTWARE OU O USO OU OUTRAS NEGOCIAÇÕES NO SOFTWARE.
]]--

local ccs = require("cc.strings")

local CCMSI_VERSION = "2.5"

local IS_PKT = pocket ~= nil -- luacheck: ignore pocket

local INSTALL_DIR = "/.install-cache"
local DEPLOY_DIR = "https://mikaylafischler.github.io/cc-mek-scada/"
local MANIFEST_DIR = DEPLOY_DIR.."manifests/"
local BUILD_DIR = DEPLOY_DIR.."builds/"

local OPTS = { ... }

local mode, app, target, build_url, manifest_url

local out_w, out_h = term.getSize()

local function tsc(c) term.setTextColor(c) end
local function tbc(c) term.setBackgroundColor(c) end

local function red() tsc(colors.red) end
local function orange() tsc(colors.orange) end
local function yellow() tsc(colors.yellow) end
local function green() tsc(colors.green) end
local function cyan() tsc(colors.cyan) end
local function lblue() tsc(colors.lightBlue) end
local function blue() tsc(colors.blue) end
local function purple() tsc(colors.purple) end
local function white() tsc(colors.white) end
local function lgray() tsc(colors.lightGray) end

local function pln(msg) print(tostring(msg)) end

-- cópia simplificada e modificada de log.dmesg
local function print(msg)
	msg = tostring(msg)

	local cur_x, cur_y = term.getCursorPos()

	if cur_x == out_w then
		-- pular para a próxima linha
		cur_x = 1
		if cur_y == out_h then
			term.scroll(1)
			term.setCursorPos(1, cur_y)
		else
			term.setCursorPos(1, cur_y + 1)
		end
	end

	local lines, remaining, s_start, s_end, ln = {}, true, 1, out_w + 1 - cur_x, 1
	while remaining do
		local line = string.sub(msg, s_start, s_end)

		if line == "" then
			remaining = false
		else
			lines[ln] = line
			s_start = s_end + 1
			s_end = s_end + out_w
			ln = ln + 1
		end
	end

	for i = 1, #lines do
		cur_x, cur_y = term.getCursorPos()
		if i > 1 and cur_x > 1 then
			if cur_y == out_h then
				term.scroll(1)
				term.setCursorPos(1, cur_y)
			else term.setCursorPos(1, cur_y + 1) end
		end
		term.write(lines[i])
	end
end

-- redefinir o cursor para antes da impressão de s ocorrer
local function print_reset(s)
	local _, y = term.getCursorPos()
	for i = 1, #ccs.wrap(s, out_w) do
		term.setCursorPos(1, y - i);term.clearLine()
	end
end

-- mostrar progresso e porcentagem na parte inferior da tela
local function show_progress(p)
	local _, y = term.getCursorPos()
	term.setCursorPos(1, out_h)

	print(string.format("%3.0f%% ", p*100))
	local pb = math.floor(p*(out_w-6))

	tbc(colors.lightBlue);tsc(colors.black)
	print(string.rep("\x80", pb))
	tbc(colors.black)

	term.setCursorPos(1, y);lgray()
end

-- ocultar progresso e porcentagem na parte inferior da tela
local function hide_progress()
	local _, y = term.getCursorPos()
	term.setCursorPos(1, out_h)
	tbc(colors.black);white()
	term.clearLine()
	term.setCursorPos(1, y)
end

-- obter opção de linha de comando na lista
local function get_opt(opt, options)
	for _, v in pairs(options) do if opt == v then return v end end
	return nil
end

-- aguardar o pressionamento de qualquer tecla
local function any_key() os.pullEvent("key_up") end

-- perguntar ao usuário sim ou não
local function ask_y_n(question, default)
	print(question)
	if default == true then print(" (Y/n)? ") else print(" (y/N)? ") end
	white()
	local r = read();any_key()
	if r == "" then return default
	elseif r == "Y" or r == "y" then return true
	elseif r == "N" or r == "n" then return false
	else return nil end
end

-- obter números de versão principal, secundária e de correção (major, minor, patch)
local function v_nums(v)
	local a, b, c = v:match("^[vV]?(%d+)%.(%d+)%.?(%d*)$")
	return tonumber(a), tonumber(b), tonumber(c) or 0
end

-- 1 = atualização, 0 = igual, -1 = reversão (downgrade)
local function is_update(l, r)
	local l1, l2, l3 = v_nums(l)
	local r1, r2, r3 = v_nums(r)

	if r1 ~= l1 then return (r1 > l1 and 1) or -1 end
	if r2 ~= l2 then return (r2 > l2 and 1) or -1 end
	if r3 ~= l3 then return (r3 > l3 and 1) or -1 end
	return 0
end

-- mensagem de versão do pacote
local function pkg_v_msg(n, m, va, vb)
	purple();print("["..n.."] ");white()
	if m == "\x1e" then cyan() elseif m == "\x1f" then red() end
	print(m.." ");blue()
	if vb then print(va);white();print(" \x1a ");blue();pln(vb) else pln(va) end
	white()
end

-- mensagem de informação/aviso do pacote
local function pkg_msg(n, m, w)
	purple();print("["..n.."] ")
	if w then yellow() else white() end
	pln(m.." ")
end

-- indicar ações a serem tomadas com base nas diferenças dos pacotes para instalações/atualizações
local function show_pkg_change(name, v)
	if v.v_local then
		local is_up = is_update(v.v_local, v.v_remote)
		if is_up ~= 0 then
			local updn = (is_up > 0) and (IS_PKT and "\x1e" or "atualizando") or (IS_PKT and "\x1f" or "revertendo")
			pkg_v_msg(name, updn, v.v_local, v.v_remote)
		elseif mode == "install" then
			pkg_v_msg(name, IS_PKT and "reinstalar" or "reinstalando", v.v_local)
		end
	else pkg_v_msg(name, IS_PKT and "instalar" or "nova instalação de", v.v_remote) end

	return v.v_local ~= v.v_remote
end

-- ler o arquivo de manifesto local
local function read_local_manifest()
	local ok, manifest, f = false, {}, fs.open("install_manifest.json", "r")
	if f ~= nil then
		ok, manifest = pcall(function () return textutils.unserializeJSON(f.readAll()) end)
		f.close()
	end
	return ok, manifest
end

-- ler o manifesto do GitHub
local function read_remote_manifest()
	local resp, err = http.get(manifest_url)
	if resp == nil then
		orange();pln("Falha ao ler o manifesto de instalação do GitHub, não é possível atualizar ou instalar.")
		red();pln("Erro HTTP: "..err);white()
		return false, {}
	end

	local ok, manifest = pcall(function () return textutils.unserializeJSON(resp.readAll()) end)
	if not ok then red();pln("erro ao analisar o manifesto de instalação remoto");white() end

	return ok, manifest
end

-- registrar o manifesto de instalação local
local function write_install_manifest(manifest, deps)
	local versions = {}
	for k, v in pairs(manifest.versions) do
		local is_dep = false
		for _, dep in pairs(deps) do
			if (k == "bootloader" and dep == "system") or k == dep then
				is_dep = true;break
			end
		end
		if k == app or k == "comms" or is_dep then versions[k] = v end
	end

	manifest.versions = versions

	local f = fs.open("install_manifest.json", "w")
	f.write(textutils.serializeJSON(manifest));f.close()
end

-- tentar no máximo 3 vezes baixar um arquivo do repositório e gravar no diretório base w_path
---@return 0|1|2|3 sucesso 0: ok, 1: falha no download, 2: falha ao abrir arquivo, 3: sem espaço
local function http_get_file(file, w_path)
	for i = 1, 3 do
		local dl, err = http.get(build_url..file)
		if dl then
			if i > 1 then green();pln("sucesso!");lgray() end

			local f = fs.open(w_path..file, "w")
			if not f then return 2 end

			local ok, msg = pcall(function() f.write(dl.readAll()) end)
			f.close()
			if not ok then
				if string.find(msg or "", "Out of space") ~= nil then
					red();pln("[sem espaço]");lgray()
					return 3
				else return 2 end
			end
			break
		else
			red();pln("Erro HTTP: "..err)
			if i < 3 then
				lgray();print("> tentando novamente...")
				os.sleep(i/3)
			else return 1 end
		end
	end
	return 0
end

-- construir recursivamente uma árvore a partir do manifesto de arquivos
local function gen_tree(manifest, log)
	local function _tree_add(tree, split)
		if #split > 1 then
			local name = table.remove(split, 1)
			if tree[name] == nil then tree[name] = {} end
			table.insert(tree[name], _tree_add(tree[name], split))
		else return split[1] end
		return nil
	end

	local list, tree = { log }, {}

	for _, files in pairs(manifest.files) do for i = 1, #files do table.insert(list, files[i]) end end

	for i = 1, #list do
		local split = {}
		string.gsub(list[i], "([^/]+)", function(c) split[#split + 1] = c end)
		if #split == 1 then table.insert(tree, list[i])
		else table.insert(tree, _tree_add(tree, split)) end
	end

	return tree
end

local function _in_array(val, array)
	for _, v in pairs(array) do if v == val then return true end end
	return false
end

local function _clean_dir(dir, tree)
	if tree == nil then tree = {} end
	local ls = fs.list(dir)
	for _, l in pairs(ls) do
		local path = dir.."/"..l
		if fs.isDir(path) then
			_clean_dir(path, tree[l])
			if #fs.list(path) == 0 then fs.delete(path);pln("excluído "..path) end
		elseif (not _in_array(l, tree)) and l ~= "config.lua" then
			fs.delete(path);pln("excluído "..path)
		end
	end
end

-- percorrer diretórios do aplicativo/comuns para excluir arquivos não utilizados
local function clean(manifest)
	local log, cfg = nil, app..".settings"
	if fs.exists(cfg) and settings.load(cfg) then
		log = settings.get("LogPath")
		if log:sub(1, 1) == "/" then log = log:sub(2) end
	end

	local tree = gen_tree(manifest, log)

	table.insert(tree, "install_manifest.json")
	table.insert(tree, "ccmsi.lua")

	local ls = fs.list("/")
	for _, val in pairs(ls) do
		if fs.isDriveRoot(val) then
			yellow();pln("montagem ignorada '"..val.."'")
		elseif fs.isDir(val) then
			if tree[val] ~= nil then lgray();_clean_dir("/"..val, tree[val])
			else white(); if ask_y_n("excluir o diretório não utilizado '"..val.."'") then lgray();_clean_dir("/"..val) end end
			if #fs.list(val) == 0 then fs.delete(val);lgray();pln("diretório vazio excluído '"..val.."'") end
		elseif not _in_array(val, tree) and (string.find(val, ".settings") == nil) then
			white();if ask_y_n("excluir o arquivo não utilizado '"..val.."'") then fs.delete(val);lgray();pln("excluído "..val) end
		end
	end

	white()
end

-- cabeçalho de inicialização

tsc(colors.magenta)
if IS_PKT then pln("- Instalador SCADA v"..CCMSI_VERSION.." -")
else pln("-- Instalador ComputerCraft Mekanism SCADA v"..CCMSI_VERSION.." --") end
white()

-- lidar com opções de linha de comando

if #OPTS == 0 or OPTS[1] == "help" then
	pln("uso: ccmsi <modo> <app> <branch>")

	blue();pln("<modo>")
	if IS_PKT then
		lgray();pln(" check - verificar mais recente\n install - nova instalação\n update - atualizar app\n uninstall - remover app")
		blue();pln("<app>")
		lgray();pln(" pocket\n installer (apenas atualização)")
		blue();pln("<branch>")
	else
		lgray();pln(" check       - verificar versões mais recentes disponíveis")
		yellow();pln("               ccmsi check <branch> (pular <app>)")
		lgray();pln(" install     - nova instalação\n update      - atualizar arquivos\n uninstall   - excluir arquivos INCLUINDO config/logs")
		blue();print("<app>");cyan();pln(" omita para detectar automaticamente o app instalado")
		lgray();pln(" reactor-plc - Firmware do CLP do Reator de Fissão\n rtu         - Firmware do Gateway RTU\n supervisor  - Aplicação do servidor Supervisor\n coordinator - Aplicação do Coordenador\n pocket      - Aplicação Pocket\n installer   - Instalador CCMSI (apenas atualização)")
		blue();print("<branch>");cyan();pln(" omita para 'main'")
	end
	lgray();pln(" main (padrão) | devel");white()

	return
else
	mode = get_opt(OPTS[1], { "check", "install", "update", "uninstall" })
	if mode == nil then
		red();pln("Modo inválido.");white()
		return
	end

	local next_opt = 3
	local apps = { "reactor-plc", "rtu", "supervisor", "coordinator", "pocket", "installer" }
	app = get_opt(OPTS[2], apps)
	if app == nil then
		for _, a in pairs(apps) do
			if fs.isDir(a) then app, next_opt = a, 2 end
		end
	end

	if app == nil and mode ~= "check" then
		red();pln("Aplicação inválida.");white()
		return
	elseif mode == "check" then
		next_opt = 2
	elseif app == "installer" and mode ~= "update" then
		red();pln("O instalador suporta apenas 'update'.");white()
		return
	end

	target = OPTS[next_opt] or "main"
	if target ~= "main" and target ~= "devel" then
		red();pln("Branch de destino inválida.");white()
		return
	end

	manifest_url = MANIFEST_DIR..target.."/install_manifest.json"
	build_url = BUILD_DIR..target.."/"
end

-- operação principal

local ok, r_manifest, l_manifest

if mode == "check" then
	ok, r_manifest = read_remote_manifest()
	if not ok then return end

	ok, l_manifest = read_local_manifest()
	if not ok then
		yellow();pln("falha ao carregar informações da instalação local");white()
		l_manifest = { versions = { installer = CCMSI_VERSION } }
	else
		l_manifest.versions.installer = CCMSI_VERSION
	end

	if not IS_PKT then pln("") end

	-- listar todas as versões
	for k, r_v in pairs(r_manifest.versions) do
		local l_v, tag = l_manifest.versions[k], string.format("%-14s", "["..k.."]")
		purple()

		if k == "installer" or (ok and (l_v ~= nil)) then
			if IS_PKT then print("["..k.."] ");blue();pln(l_v)
			else print(tag);blue();print(l_v);white();print(" -") end

			if r_v ~= l_v then
				if is_update(l_v, r_v) > 0 then cyan();print(" \x1e ")
				else red();print(" \x1f ") end
				print(r_v);white();pln(" disponível")
			else green();print(" \x07");white();pln(" atualizado") end
		elseif not (IS_PKT and _in_array(k, { "reactor-plc", "rtu", "supervisor", "coordinator" })) then
			if IS_PKT then print("["..k.."] ");lgray();pln("não instalado")
			else print(tag);lgray();print("não instalado");white();print(" -") end
			lblue();print(" \x04 "..r_v);white();pln(" disponível")
		end
	end

	if r_manifest.versions.installer ~= l_manifest.versions.installer and not IS_PKT then
		yellow();pln("\nUma versão diferente do instalador está disponível, é FORTEMENTE recomendado atualizar (use 'ccmsi update installer').");white()
	end
elseif mode == "install" or mode == "update" then
	local update_installer = app == "installer"

	ok, r_manifest = read_remote_manifest()
	if not ok then return end

	local ver = {
		app = { v_local = nil, v_remote = nil, changed = false },
		boot = { v_local = nil, v_remote = nil, changed = false },
		comms = { v_local = nil, v_remote = nil, changed = false },
		common = { v_local = nil, v_remote = nil, changed = false },
		graphics = { v_local = nil, v_remote = nil, changed = false },
		lockbox = { v_local = nil, v_remote = nil, changed = false }
	}

	-- tentar carregar versões locais
	ok, l_manifest = read_local_manifest()
	if ok then
		ver.boot.v_local = l_manifest.versions.bootloader
		ver.app.v_local = l_manifest.versions[app]
		ver.comms.v_local = l_manifest.versions.comms
		ver.common.v_local = l_manifest.versions.common
		ver.graphics.v_local = l_manifest.versions.graphics
		ver.lockbox.v_local = l_manifest.versions.lockbox

		if l_manifest.versions[app] == nil and not update_installer then
			red();pln("Outra aplicação já está instalada, por favor desinstale-a antes de instalar uma nova aplicação.");white()
			return
		end
	elseif mode == "update" and not update_installer then
		red();pln("Falha ao carregar informações da instalação local, não é possível atualizar.");white()
		return
	end

	-- tratamento de atualização do instalador
	if r_manifest.versions.installer ~= CCMSI_VERSION then
		if not update_installer then yellow();pln("Uma versão diferente do instalador está disponível, é FORTEMENTE recomendado atualizar para ela.");white() end
		if update_installer or ask_y_n("Gostaria de atualizá-lo agora", true) then
			lgray();pln("GET ccmsi.lua")
			local dl, err = http.get(build_url.."ccmsi.lua")

			if dl == nil then
				red();pln("Erro HTTP: "..err)
				pln("Falha no download do instalador.")
			else
				local f = fs.open(debug.getinfo(1, "S").source:sub(2), "w") -- este arquivo
				f.write(dl.readAll());f.close()
				green();pln("Instalador atualizado com sucesso.")
			end

			white()
			return
		end
	elseif update_installer then
		green();pln("O instalador já está atualizado.");white()
		return
	end

	ver.boot.v_remote = r_manifest.versions.bootloader
	ver.app.v_remote = r_manifest.versions[app]
	ver.comms.v_remote = r_manifest.versions.comms
	ver.common.v_remote = r_manifest.versions.common
	ver.graphics.v_remote = r_manifest.versions.graphics
	ver.lockbox.v_remote = r_manifest.versions.lockbox

	green()
	if mode == "install" then print("Instalando arquivos de ") else print("Atualizando arquivos de ") end
	pln(app.."...");white()

	ver.boot.changed = show_pkg_change("bootloader", ver.boot)
	ver.common.changed = show_pkg_change("common", ver.common)
	ver.comms.changed = show_pkg_change("comms", ver.comms)
	if ver.comms.changed and ver.comms.v_local ~= nil then
		pkg_msg("comms", "todos os dispositivos na rede devem ser atualizados", true)
	end
	ver.app.changed = show_pkg_change(app, ver.app)
	ver.graphics.changed = show_pkg_change("graphics", ver.graphics)
	ver.lockbox.changed = show_pkg_change("lockbox", ver.lockbox)

	-- iniciar instalação/atualização

	local space_req = r_manifest.sizes.manifest
	local space_avail = fs.getFreeSpace("/")

	local file_list, size_list = r_manifest.files, r_manifest.sizes
	local deps, sf_deps = r_manifest.depends[app], {}

	table.insert(deps, app)

	-- função auxiliar para verificar se uma dependência não foi alterada
	local function unchanged(dep)
		if dep == "system" then return not ver.boot.changed
		elseif dep == "graphics" then return not ver.graphics.changed
		elseif dep == "lockbox" then return not ver.lockbox.changed
		elseif dep == "common" then return not (ver.common.changed or ver.comms.changed)
		elseif dep == app then return not ver.app.changed
		else return true end
	end

	local any_change = false

	for _, dep in pairs(deps) do
		table.insert(sf_deps, dep)
		local size = size_list[dep]
		space_req = space_req + size
		any_change = any_change or not unchanged(dep)
	end

	if mode == "update" and not any_change then
		yellow();pln("Nada a fazer, tudo já está atualizado!");white()
		return
	end

	-- pedir confirmação
	if not ask_y_n("Continuar", false) then return end

	local single_file_mode = space_avail < space_req

	local success = true

	-- excluir um arquivo se a capitalização mudar para que funcione no Windows
	---@param path string
	local function mitigate_case(path)
		local dir, file = fs.getDir(path), fs.getName(path)
		if not fs.isDir(dir) then return end
		for _, p in ipairs(fs.list(dir)) do
			if string.lower(p) == string.lower(file) then
				if p ~= file then fs.delete(path) end
				return
			end
		end
	end

	---@param dl_stat 1|2|3 status do download
	---@param file string nome do arquivo
	---@param attempt integer tentativa recursiva #
	---@param sf_install function função do instalador para recursão
	local function handle_dl_fail(dl_stat, file, attempt, sf_install)
		red()
		if dl_stat == 1 then
			pln("falha ao baixar "..file)
		elseif dl_stat > 1 then
			if dl_stat == 2 then pln("erro no sistema de arquivos com "..file) else pln("espaço insuficiente para "..file) end
			if attempt == 1 then
				orange();pln("tentando a operação novamente...");white()
				sf_install(2)
			elseif attempt == 2 then
				yellow()
				if dl_stat == 2 then pln("Ocorreu um erro ao gravar em um arquivo.") else pln("Espaço disponível insuficiente.") end
				lgray()
				if dl_stat == 2 then
					pln("Isso pode ocorrer devido a espaço disponível insuficiente ou problemas de permissão de arquivo. O instalador pode tentar excluir agora arquivos não utilizados pelo sistema SCADA.")
				else pln("O instalador pode tentar excluir agora arquivos não utilizados pelo sistema SCADA.") end
				white()
				if not ask_y_n("Continuar", false) then
					success = false
					return
				end
				clean(r_manifest)
				sf_install(3)
			elseif attempt == 3 then
				yellow()
				if dl_stat == 2 then pln("Ocorreu novamente um erro ao gravar em um arquivo.") else pln("Espaço disponível insuficiente.") end
				lgray()
				if dl_stat == 2 then
					pln("Isso pode ocorrer devido a espaço disponível insuficiente ou problemas de permissão de arquivo. Por favor, exclua quaisquer arquivos não utilizados que você tenha neste computador e tente novamente. Não exclua o arquivo "..app..".settings a menos que deseje reconfigurar.")
				else pln("Por favor, exclua quaisquer arquivos não utilizados que você tenha neste computador e tente novamente. Não exclua o arquivo "..app..".settings a menos que deseje reconfigurar.") end
				white()
				success = false
			end
		end
	end

	-- rotina de atualização de arquivo único: percorrer todos os arquivos e substituir um por um
	---@param attempt integer tentativa recursiva #
	local function sf_install(attempt)
		if attempt > 1 then os.sleep(2.0) end

		local abort_attempt = false
		success = true

		for k, dep in pairs(sf_deps) do
			if mode == "update" and unchanged(dep) then
				pkg_msg(dep, "pulando instalação de pacote inalterado", true)
				sf_deps[k] = nil
			else
				pkg_msg(dep, IS_PKT and "instalando..." or "instalando pacote...")
				lgray()

				-- a partir da segunda tentativa, excluir o diretório antes de começar
				if attempt >= 2 then
					if dep == "common" then
						if fs.exists("/scada-common") then
							fs.delete("/scada-common");pln("excluído /scada-common")
						end
					elseif dep ~= "system" then
						if fs.exists("/"..dep) then
							fs.delete("/"..dep);pln("excluído /"..dep)
						end
					end
				end

				local files, n = file_list[dep], 1
				for _, file in pairs(files) do
					local s = "GET "..file
					pln(s)
					mitigate_case(file)
					local dl_stat = http_get_file(file, "/")
					if dl_stat ~= 0 then
						abort_attempt = true
---@diagnostic disable-next-line: param-type-mismatch
						handle_dl_fail(dl_stat, file, attempt, sf_install)
						break
					end
					show_progress(n/#files)
					n = n + 1
					print_reset(s)
				end

				hide_progress()
				if not abort_attempt then pkg_msg(dep, "instalado!");sf_deps[k] = nil end
				term.clearLine()
			end
			if abort_attempt or not success then break end
		end
	end

	-- lidar com atualização/instalação
	if single_file_mode then sf_install(1)
	else
		if fs.exists(INSTALL_DIR) then fs.delete(INSTALL_DIR);fs.makeDir(INSTALL_DIR) end

		-- baixar todas as dependências
		for _, dep in pairs(deps) do
			if mode == "update" and unchanged(dep) then
				pkg_msg(dep, "pulando download de pacote inalterado", true)
			else
				pkg_msg(dep, IS_PKT and "baixando..." or "baixando pacote...")
				lgray()

				local files, n = file_list[dep], 1
				for _, file in pairs(files) do
					local s = "GET "..file
					pln(s)
					local dl_stat = http_get_file(file, INSTALL_DIR.."/")
					success = dl_stat == 0
					if dl_stat == 1 then
						red();pln("falha ao baixar "..file)
						break
					elseif dl_stat == 2 then
						red();pln("erro no sistema de arquivos com "..file)
						break
					elseif dl_stat == 3 then
						-- isso não deve ocorrer neste modo
						red();pln("espaço insuficiente para "..file)
						break
					end
					show_progress(n/#files)
					n = n + 1
					print_reset(s)
				end

				hide_progress()
				if success then pkg_msg(dep, IS_PKT and "baixado!" or "download concluído!") end
				term.clearLine()
			end
			if not success then break end
		end

		-- copiar arquivos baixados (instalação)
		if success then
			for _, dep in pairs(deps) do
				if mode == "update" and unchanged(dep) then
					pkg_msg(dep, "pulando instalação de pacote inalterado", true)
				else
					pkg_msg(dep, IS_PKT and "instalando..." or "instalando pacote...")
					lgray()

					local files = file_list[dep]
					for _, file in pairs(files) do
						local temp_file = INSTALL_DIR.."/"..file
						mitigate_case(file)
						if fs.exists(file) then fs.delete(file) end
						fs.move(temp_file, file)
					end

					pkg_msg(dep, "instalado!")
				end
			end
		end

		fs.delete(INSTALL_DIR)
	end

	if success then
		write_install_manifest(r_manifest, deps)
		green()
		if mode == "install" then print("Instalação") else print("Atualização") end
		pln(" concluída com sucesso.")
		white();pln("Pronto para limpar arquivos não utilizados, pressione qualquer tecla para continuar...")
		any_key();clean(r_manifest)
		white();pln("Concluído.")
	else
		red()
		if single_file_mode then
			if mode == "install" then print("A instalação") else print("A atualização") end
			pln(" falhou, arquivos podem ter sido ignorados.")
		else
			if mode == "install" then pln("A instalação falhou.")
			else orange();pln("A atualização falhou, os arquivos existentes não foram modificados.") end
		end
	end
elseif mode == "uninstall" then
	ok, l_manifest = read_local_manifest()
	if not ok then
		red();pln("Erro ao analisar o manifesto de instalação local.");white()
		return
	end

	if l_manifest.versions[app] == nil then
		red();pln("Erro: '"..app.."' não está instalado.")
		return
	end

	orange();pln("Desinstalando todos os arquivos de "..app.."...");white()

	-- pedir confirmação
	if not ask_y_n("Continuar", false) then return end

	-- excluir arquivos não utilizados primeiro
	clean(l_manifest)

	local file_list = l_manifest.files
	local deps = l_manifest.depends[app]

	table.insert(deps, app)

	-- excluir todos os arquivos instalados
	lgray()
	for _, dep in pairs(deps) do
		local files = file_list[dep]
		for _, file in pairs(files) do
			if fs.exists(file) then fs.delete(file);pln("excluído "..file) end
		end

		local folder = files[1]
		while true do
			local dir = fs.getDir(folder)
			if dir == "" or dir == ".." then break else folder = dir end
		end

		if fs.isDir(folder) then
			fs.delete(folder);pln("diretório excluído "..folder)
		end
	end

	-- excluir arquivo de log
	local log_deleted, cfg = false, app..".settings"
	if fs.exists(cfg) and settings.load(cfg) then
		local log = settings.get("LogPath")
		if log ~= nil then
			log_deleted = true
			if fs.exists(log) then
				fs.delete(log);pln("arquivo de log excluído "..log)
			end
		end
	end

	if not log_deleted then
		red();pln("Falha ao excluir o arquivo de log (ele pode não existir).");lgray()
	end

	if fs.exists(cfg) then
		fs.delete(cfg);pln("excluído "..cfg)
	end

	fs.delete("install_manifest.json")
	pln("excluído install_manifest.json")

	green();pln("Concluído!")
end

white()
