--
-- Constantes de Sistema e Segurança
--

---@class scada_constants
local constants = {}

--#region Reactor Protection System (on the PLC) Limits

---@class _rps_constants
local rps = {}

rps.MAX_DAMAGE_PERCENT      = 90   -- dano >= 90%
rps.MAX_DAMAGE_TEMPERATURE  = 1200 -- temp >= 1200K
rps.MIN_COOLANT_FILL        = 0.10 -- nível < 10%
rps.MAX_WASTE_FILL          = 0.95 -- nível > 95%
rps.MAX_HEATED_COOLANT_FILL = 0.95 -- nível > 95%

constants.RPS_LIMITS = rps

--#endregion

--#region Annunciator Limits

---@class _annunciator_constants
local annunc = {}

annunc.RCSFlowLow_H2O     = -3.2    -- fluxo < -3.2 mB/s
annunc.RCSFlowLow_NA      = -2.0    -- fluxo < -2.0 mB/s
annunc.CoolantLevelLow    = 0.4     -- nível < 40%
annunc.OpTempTolerance    = 5       -- temp alta se >= temp operacional + X
annunc.ReactorHighDeltaT  = 50      -- taxa > 50K/s
annunc.FuelLevelLow       = 0.05    -- nível <= 5%
annunc.WasteLevelHigh     = 0.80    -- nível >= 80%
annunc.WaterLevelLow      = 0.4     -- nível < 40%
annunc.SteamFeedMismatch  = 10      -- diferença de ±10mB entre o fluxo total de refrigerante e a taxa total de entrada de vapor
annunc.SFM_MaxSteamDT_H20 = 2.0     -- fluxo > 2.0 mB/s
annunc.SFM_MinWaterDT_H20 = -3.0    -- fluxo < -3.0 mB/s
annunc.SFM_MaxSteamDT_NA  = 2.0     -- fluxo > 2.0 mB/s
annunc.SFM_MinWaterDT_NA  = -2.0    -- fluxo < -2.0 mB/s
annunc.RadiationWarning   = 0.00001 -- 10 uSv/h

constants.ANNUNCIATOR_LIMITS = annunc

--#endregion

--#region Supervisor Alarm Limits

---@class _alarm_constants
local alarms = {}

-- alarmes da unidade

alarms.HIGH_WASTE     = 0.85      -- nível > 85%
alarms.HIGH_RADIATION = 0.00005   -- 50 uSv/h, ainda não causa dano, mas não é bom

-- alarmes da instalação

alarms.CHARGE_HIGH      = 1.0     -- quando atingir ou ultrapassar 100% de carga
alarms.CHARGE_RE_ENABLE = 0.95    -- quando ficar abaixo de 95% de carga
alarms.FAC_HIGH_RAD     = 0.00001 -- 10 uSv/h

constants.ALARM_LIMITS = alarms

--#endregion

--#region Supervisor Redstone Activation Thresholds

---@class _rs_threshold_constants
local rs = {}

rs.ENERGY_CHARGE_LOW  = 0.05 -- limite de ativação (menor que) para F_CHARGE_LOW
rs.ENERGY_CHARGE_HIGH = 0.95 -- limite de ativação (maior que) para F_CHARGE_HIGH
rs.AUX_COOL_ENABLE    = 0.85 -- limite de ativação (menor ou igual a) para U_AUX_COOL
rs.AUX_COOL_DISABLE   = 1.00 -- limite de desativação (maior ou igual a) para U_AUX_COOL

constants.RS_THRESHOLDS = rs

--#endregion

--#region Supervisor Constants

constants.ENERGY_MISMATCH_TOL = 0.01

-- mínimo de 3 segundos de retorno para produção de Pu
constants.PU_FALLBACK_MIN_TIME_MS = 3000

-- milissegundos até que o fluxo de refrigerante seja considerado estável o suficiente para ativar certas verificações de refrigerante
constants.FLOW_STABILITY_DELAY_MS = 10000

-- assume que um núcleo de energia não está formado/ativado se esta quantidade de energia gerada (das turbinas)
-- for excedida enquanto o núcleo de energia reporta zero FE armazenado, zero entrada e zero saída
constants.ENERGY_CORE_UNFORMED_LIM_FE = 5

-- Notas sobre Radiação
-- - radiação de fundo 0.0000001 Sv/h (99.99 nSv/h)
-- - radiação de "tom verde" 0.00001 Sv/h (10 uSv/h)
-- - radiação danosa 0.00006 Sv/h (60 uSv/h)

constants.LOW_RADIATION       = 0.00001
constants.HAZARD_RADIATION    = 0.00006
constants.HIGH_RADIATION      = 0.001
constants.VERY_HIGH_RADIATION = 0.1
constants.SEVERE_RADIATION    = 8.0
constants.EXTREME_RADIATION   = 100.0

-- RTT nominal é o ping (0ms a 10ms normalmente) + 150ms para o tick do loop principal do SV

constants.WARN_RTT = 300 -- 2x mais longo que o esperado c/ 0 de ping
constants.HIGH_RTT = 500 -- 3.33x mais longo que o esperado c/ 0 de ping

--#endregion

--#region Mekanism Configuration Constants

---@class _mek_constants
local mek = {}

-- referências de ajuste do controlador
-- NÃO MODIFIQUE, este é o sistema de referência, não o seu sistema

mek.STANDARD_FE_PER_MB = 80000
mek.REF_TURBINE_FLOW   = 4896000
mek.REF_TURBINE_CAP    = 108416000

-- constantes fixas do Mekanism (não configuráveis)

mek.BASE_BOIL_TEMP          = 373.15 -- HeatUtils.BASE_BOIL_TEMP
mek.STEAM_ENERGY_EFF        = 0.2    -- HeatUtils.getSteamEnergyEfficiency

mek.BOILER_CASING_HEAT_CAP  = 50     -- BoilerMultiblockData.CASING_HEAT_CAPACITY

mek.SODIUM_CONDUCTIVITY     = 1
mek.SODIUM_THERMAL_ENTHALPY = 5

-- constantes configuráveis do Mekanism

mek.WATER_THERMAL_ENTHALPY = 10 -- maxEnergyPerSteam

-- AVISO: os valores a seguir são sobrescritos pela configuração do Mekanism no Supervisor

mek.JOULES_PER_MB          = 1000000 -- energyPerFissionFuel
mek.TURBINE_GAS_PER_TANK   = 64000   -- turbineGasPerTank
mek.TURBINE_DISPERSER_FLOW = 1280    -- turbineDisperserGasFlow
mek.TURBINE_VENT_FLOW      = 32000   -- turbineVentGasFlow

constants.mek = mek

--#endregion

return constants
