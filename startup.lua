local BOOTLOADER_VERSION = "1.3"

print("BOOTLOADER SCADA V" .. BOOTLOADER_VERSION)
print("BOOT> PROCURANDO POR APLICAÇÕES...")

local exit_code

if fs.exists("reactor-plc/startup.lua") then
    print("BOOT> EXECUTANDO INICIALIZAÇÃO DO REACTOR PLC")
    exit_code = shell.execute("reactor-plc/startup")
elseif fs.exists("rtu/startup.lua") then
    print("BOOT> EXECUTANDO INICIALIZAÇÃO DO RTU")
    exit_code = shell.execute("rtu/startup")
elseif fs.exists("supervisor/startup.lua") then
    print("BOOT> EXECUTANDO INICIALIZAÇÃO DO SUPERVISOR")
    exit_code = shell.execute("supervisor/startup")
elseif fs.exists("coordinator/startup.lua") then
    print("BOOT> EXECUTANDO INICIALIZAÇÃO DO COORDENADOR")
    exit_code = shell.execute("coordinator/startup")
elseif fs.exists("pocket/startup.lua") then
    print("BOOT> EXECUTANDO INICIALIZAÇÃO DO POCKET")
    exit_code = shell.execute("pocket/startup")
else
    print("BOOT> NENHUMA INICIALIZAÇÃO SCADA ENCONTRADA")
    print("BOOT> SAIR")
    return false
end

if not exit_code then print("BOOT> A APLICAÇÃO FALHOU (CRASH)") end

return exit_code
