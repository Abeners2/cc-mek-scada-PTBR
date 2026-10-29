local function println(message) print(tostring(message)) end
local function print(message) term.write(tostring(message)) end

local opts = { ... }
local mode, app

local function red() term.setTextColor(colors.red) end
local function orange() term.setTextColor(colors.orange) end
local function yellow() term.setTextColor(colors.yellow) end
local function green() term.setTextColor(colors.green) end
local function blue() term.setTextColor(colors.blue) end
local function white() term.setTextColor(colors.white) end
local function lgray() term.setTextColor(colors.lightGray) end

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
    local response = read();any_key()
    if response == "" then return default
    elseif response == "Y" or response == "y" then return true
    elseif response == "N" or response == "n" then return false
    else return nil end
end

-- ler o arquivo de manifesto local
local function read_local_manifest()
    local local_ok = false
    local local_manifest = {}
    local imfile = fs.open("install_manifest.json", "r")
    if imfile ~= nil then
        local_ok, local_manifest = pcall(function () return textutils.unserializeJSON(imfile.readAll()) end)
        imfile.close()
    end
    return local_ok, local_manifest
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

    -- fazer uma lista de todos os arquivos
    for _, files in pairs(manifest.files) do for i = 1, #files do table.insert(list, files[i]) end end

    for i = 1, #list do
        local split = {}
---@diagnostic disable-next-line: discard-returns
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
    for _, val in pairs(ls) do
        local path = dir.."/"..val
        if fs.isDir(path) then
            _clean_dir(path, tree[val])
            if #fs.list(path) == 0 then fs.delete(path);println("excluído "..path) end
        elseif (not _in_array(val, tree)) and (val ~= "config.lua" ) then
            fs.delete(path)
            println("excluído "..path)
        end
    end
end

-- percorrer diretórios do aplicativo/comuns para excluir arquivos não utilizados
local function clean(manifest)
    local log = nil
    if fs.exists(app..".settings") and settings.load(app..".settings") then
        log = settings.get("LogPath")
        if log:sub(1, 1) == "/" then log = log:sub(2) end
    end

    local tree = gen_tree(manifest, log)

    table.insert(tree, "install_manifest.json")
    table.insert(tree, "ccmsim.lua")

    local ls = fs.list("/")
    for _, val in pairs(ls) do
        if fs.isDriveRoot(val) then
            yellow();println("montagem ignorada '"..val.."'")
        elseif fs.isDir(val) then
            if tree[val] ~= nil then lgray();_clean_dir("/"..val, tree[val])
            else white(); if ask_y_n("excluir o diretório não utilizado '"..val.."'") then lgray();_clean_dir("/"..val) end end
            if #fs.list(val) == 0 then fs.delete(val);lgray();println("diretório vazio excluído '"..val.."'") end
        elseif not _in_array(val, tree) and (string.find(val, ".settings") == nil) then
            white();if ask_y_n("excluir o arquivo não utilizado '"..val.."'") then fs.delete(val);lgray();println("excluído "..val) end
        end
    end

    white()
end

-- obter e validar opções de linha de comando

println("-- Gerenciador de Instalação CC Mekanism SCADA (Off-Line) --")

if #opts == 0 or opts[1] == "help" then
    println("uso: ccmsim <modo>")
    println("<modo>")
    lgray()
    println(" check     - verificar suas versões instaladas")
    println(" update-rm - excluir tudo exceto a configuração,")
    println("             para que você possa enviar arquivos para uma")
    println("             nova atualização off-line de dois arquivos")
    println(" uninstall - excluir todos os arquivos do app e configuração")
    return
else
    mode = get_opt(opts[1], { "check", "update-rm", "uninstall" })
    if mode == nil then
        red();println("Modo não reconhecido.");white()
        return
    end
end

-- executar modo selecionado
if mode == "check" then
    local local_ok, manifest = read_local_manifest()
    if not local_ok then
        yellow();println("falha ao carregar informações da instalação local");white()
    end

    -- listar todas as versões
    for key, value in pairs(manifest.versions) do
        term.setTextColor(colors.purple)
        print(string.format("%-14s", "["..key.."]"))
        blue();println(value);white()
    end
elseif mode == "update-rm" or mode == "uninstall" then
    local ok, manifest = read_local_manifest()
    if not ok then
        red();println("Erro ao analisar o manifesto de instalação local.");white()
        return
    end

    app = manifest.depends[#manifest.depends]

    if mode == "uninstall" then
        orange();println("Desinstalando todos os arquivos do app...")
    else
        orange();println("Excluindo todos os arquivos do app exceto a configuração...")
    end

    -- pedir confirmação
    if not ask_y_n("Continuar", false) then return end

    -- excluir arquivos não utilizados primeiro
    clean(manifest)

    local file_list = manifest.files
    local dependencies = manifest.depends

    -- excluir todos os arquivos instalados
    lgray()
    for _, dependency in pairs(dependencies) do
        local files = file_list[dependency]
        for _, file in pairs(files) do
            if fs.exists(file) then fs.delete(file);println("excluído "..file) end
        end

        local folder = files[1]
        while true do
            local dir = fs.getDir(folder)
            if dir == "" or dir == ".." then break else folder = dir end
        end

        if fs.isDir(folder) then
            fs.delete(folder)
            println("diretório excluído "..folder)
        end
    end

    -- excluir arquivo de log
    local log_deleted = false
    local settings_file = app..".settings"

    if fs.exists(settings_file) and settings.load(settings_file) then
        local log = settings.get("LogPath")
        if log ~= nil then
            log_deleted = true
            if fs.exists(log) then
                fs.delete(log)
                println("arquivo de log excluído "..log)
            end
        end
    end

    if not log_deleted then
        red();println("Falha ao excluir o arquivo de log (ele pode não existir).");lgray()
    end

    if mode == "uninstall" then
        if fs.exists(settings_file) then
            fs.delete(settings_file);println("excluído "..settings_file)
        end

        fs.delete("install_manifest.json")
        println("excluído install_manifest.json")

        fs.delete("ccmsim.lua")
        println("excluído ccmsim.lua")
    end

    green();println("Concluído!")
end

white()
