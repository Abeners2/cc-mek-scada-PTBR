local log     = require("scada-common.log")
local util    = require("scada-common.util")

local databus = require("reactor-plc.databus")
local plc     = require("reactor-plc.plc")

local SLOW_RAMP_mB_s     = 5.0
local FAST_SWITCH_mB_s   = 40.0
local FAST_MAX_PERCENT_s = 0.02

local FUEL_LIMIT_INIT    = 0.4  -- inicia monitoramento de alta velocidade em 40%
local FUEL_LIMIT_START   = 0.3  -- inicia limitação em 30%
local FUEL_LIMIT_RELEASE = 0.4  -- para limitação ao atingir 40%
local FUEL_LIMIT_EMA_A   = 0.05 -- alfa do filtro EMA

local spctl = {}

---@enum RAMP_STATES
local STATES = {
    STOPPED = 1,
    INIT = 2,
    SLOW_RAMP_UP = 3,
    SLOW_RAMP_DOWN = 4,
    STABLE_WAIT = 5,
    CCOOL_MON = 6,
    FAST_RAMP_UP = 7,
    FAST_RAMP_DOWN = 8
}

local STATE_NAMES = {
    "STOPPED",
    "INIT",
    "SLOW_RAMP_UP",
    "SLOW_RAMP_DOWN",
    "STABLE_WAIT",
    "CCOOL_MON",
    "FAST_RAMP_UP",
    "FAST_RAMP_DOWN"
}

local _spctl = {
    -- leituras do reator e outras estatísticas
    ---@class _spctl_data
    data = {
        tps = 0.0,
        tick_time = 0,
        max_br = 0.0,
        burn_rate = 0.0,
        act_rate = 0.0,
        fuel = 0.0,
        fuel_fill = 0.0,
        ccool_fill = 0.0
    },

    -- controle de rampa

    fast_ramp_en = false,
    fast_ramping = false,   -- uma vez que passamos pelas fases de verificação, não repete até redefinir

    last_sp = 0.0,
    last_ccool = 0.0,

    last_change = 0,
    next_state = STATES.STOPPED, ---@type RAMP_STATES
    last_state = STATES.STOPPED, ---@type RAMP_STATES

    -- limitação de taxa de queima baseada em combustível

    fuel_limit_en = false,

    fuel_monitoring = false,
    fuel_limiting = false,

    last_mon_check = 0,
    last_fuel_filt = 0.0,

    d_fuel = 0.0,
    d_fuel_mBt = 0.0,

    fuel_filt = util.ema_filter(FUEL_LIMIT_EMA_A),
    rate_filt = util.ema_filter(FUEL_LIMIT_EMA_A),
    tick_filt = util.ema_filter(FUEL_LIMIT_EMA_A)
}

local rps       = nil ---@type rps
local plc_state = nil ---@type plc_state
local setpoints = nil ---@type plc_setpoints
local limits    = nil ---@type plc_limits

-- inicializa com dados da memória compartilhada
---@param smem plc_shared_memory
function spctl.init(smem)
    rps       = smem.plc_sys.rps
    plc_state = smem.plc_state
    setpoints = smem.setpoints
    limits    = smem.limits

    _spctl.fast_ramp_en  = plc.config.FastRamp
    _spctl.fuel_limit_en = plc.config.FuelAutoLimiting
end

--#region Ramp Control

-- inicializa a rampa, ou define imediatamente se aceitável
---@param cur_br number requested burn rate
local function ramp_init(cur_br)
    _spctl.last_sp = setpoints.burn_rate

    -- atualiza sem rampa se a alteração for <= 2.5 mB/t
    if math.abs(setpoints.burn_rate - cur_br) > 2.5 then
        local new_state = _spctl.next_state

        if _spctl.next_state == STATES.STOPPED then
            log.debug(util.c("SPCTL: iniciando rampa de taxa de queima de ", cur_br, " mB/t para ", setpoints.burn_rate, " mB/t"))

            new_state = STATES.INIT

            _spctl.fast_ramping = false
        else
            log.debug(util.c("SPCTL: rampa de taxa de queima de ", cur_br, " mB/t para ", setpoints.burn_rate, " mB/t (setpoint atualizado)"))

            -- atualiza para a direção e fase apropriadas
            -- isso só impactará o controlador se for uma mudança de estado
            if setpoints.burn_rate > cur_br then
                -- precisa subir a rampa
                if _spctl.fast_ramp_en and ((cur_br >= FAST_SWITCH_mB_s) or _spctl.fast_ramping) then
                    if _spctl.fast_ramping then
                        -- definição direta para rampa rápida é aprovada
                        new_state = STATES.FAST_RAMP_UP
                    elseif _spctl.next_state ~= STATES.STABLE_WAIT and _spctl.next_state ~= STATES.CCOOL_MON then
                        new_state = STATES.STABLE_WAIT
                    end
                else
                    new_state = STATES.SLOW_RAMP_UP
                end
            else
                -- precisa descer a rampa
                if _spctl.fast_ramp_en and ((cur_br >= FAST_SWITCH_mB_s) or _spctl.fast_ramping) then
                    new_state = STATES.FAST_RAMP_DOWN
                else
                    new_state = STATES.SLOW_RAMP_DOWN
                end
            end
        end

        if new_state ~= _spctl.next_state then
            log.debug("SPCTL: estado de ramp_init() alterado para " .. (STATE_NAMES[new_state] or "UNKNOWN"))

            _spctl.next_state = new_state
            _spctl.last_change = os.clock()
        end
    elseif _spctl.fuel_limiting then
        local lim_br = math.min(setpoints.burn_rate, limits.fuel_max_burn)
        plc_state.limit_force_ramp = false

        log.debug(util.c("SPCTL: definindo taxa de queima diretamente para ", lim_br, " mB/t (limitacao ativa, setpoint e ", setpoints.burn_rate, ")"))
        _spctl.new_br = lim_br

        if _spctl.next_state == STATES.STOPPED then
            setpoints.burn_rate_en = false
        end
    else
        plc_state.limit_force_ramp = false

        log.debug(util.c("SPCTL: definindo taxa de queima diretamente para ", setpoints.burn_rate, " mB/t"))
        _spctl.new_br = setpoints.burn_rate

        if _spctl.next_state == STATES.STOPPED then
            setpoints.burn_rate_en = false
        end
    end
end

-- redefine estados e rastreamento do último valor
local function ramp_reset()
    _spctl.last_sp    = 0
    _spctl.last_ccool = 0
    _spctl.next_state = STATES.STOPPED
    _spctl.last_state = STATES.STOPPED

    _spctl.fast_ramping = false
end

-- executa o loop do controlador de rampa de setpoint
---@param cur_br number current burn rate
---@param cur_ccool number coolant filled percentage (0 to 1)
---@param elapsed_s number seconds elapsed in the ramp
local function ramp_run(cur_br, cur_ccool, elapsed_s)
    local now        = os.clock()
    local state_time = now - _spctl.last_change
    local state      = _spctl.next_state
    local new_state  = _spctl.next_state
    local new_br     = cur_br

    if state == STATES.INIT then
        log.debug(util.c("SPCTL: inicializando para modo de rampa de taxa de queima ", util.trinary(_spctl.fast_ramp_en, "rapida", "lenta")))

        -- transição para a direção e fase apropriadas
        if setpoints.burn_rate > cur_br then
            -- precisa subir a rampa
            if _spctl.fast_ramp_en and (cur_br >= FAST_SWITCH_mB_s) then
                new_state = STATES.STABLE_WAIT
            else
                new_state = STATES.SLOW_RAMP_UP
            end
        else
            -- precisa descer a rampa
            if _spctl.fast_ramp_en and (cur_br >= FAST_SWITCH_mB_s) then
                new_state = STATES.FAST_RAMP_DOWN
            else
                new_state = STATES.SLOW_RAMP_DOWN
            end
        end
    elseif state == STATES.SLOW_RAMP_UP then
        -- sobe a rampa lentamente
        new_br = cur_br + (SLOW_RAMP_mB_s * elapsed_s)
        if new_br > setpoints.burn_rate then new_br = setpoints.burn_rate end

        -- transição para fora da rampa lenta após atingir o limite
        if _spctl.fast_ramp_en and (new_br >= FAST_SWITCH_mB_s) then
            new_br = FAST_SWITCH_mB_s

            new_state = STATES.STABLE_WAIT
        end
    elseif state == STATES.SLOW_RAMP_DOWN then
        -- desce a rampa lentamente
        new_br = cur_br - (SLOW_RAMP_mB_s * elapsed_s)
        if new_br < setpoints.burn_rate then new_br = setpoints.burn_rate end
    elseif state == STATES.STABLE_WAIT then
        -- aguarda no mínimo 2 segundos para ajudar na estabilidade do fluxo
        -- isso ajuda a detectar problemas antes de subir demais
        if state_time >= 2 then
            new_state = STATES.CCOOL_MON
        end
    elseif state == STATES.CCOOL_MON then
        -- não avança até que o refrigerante não esteja diminuindo
        if cur_ccool >= _spctl.last_ccool then
            new_state = STATES.FAST_RAMP_UP

            _spctl.fast_ramping = true
        end
    elseif state == STATES.FAST_RAMP_UP then
        -- avança por uma porcentagem da taxa máxima de queima
        local scaler = math.min(FAST_MAX_PERCENT_s, FAST_MAX_PERCENT_s * (state_time / 5.0)) * elapsed_s
        local step   = scaler * _spctl.data.max_br

        -- desacelera o passo se estivermos perdendo refrigerante
        if cur_ccool < 0.8 then
            -- mapeia 0.4-0.8 para 0-1
            local a = (cur_ccool - 0.4) * 2.5

            -- desacelera conforme nos aproximamos da condição de baixo refrigerante
            step = step * a
        end

        -- o mínimo é a taxa lenta, mantém o comportamento antigo
        -- se superaquecermos, será suave e recuperável, então o usuário poderá resolver o problema de refrigerante em vez de ver o reator não subir a rampa
        step = math.max(SLOW_RAMP_mB_s * elapsed_s, step)

        -- não excede o setpoint
        new_br = math.min(cur_br + step, setpoints.burn_rate)

        -- log.debug(util.sprintf("SPCTL: scaler[%f] cur_ccool[%f] step[%f] new_br[%f]", scaler, cur_ccool, step, new_br))
    elseif state == STATES.FAST_RAMP_DOWN then
        -- avança por uma porcentagem da taxa máxima de queima
        local scaler = math.min(FAST_MAX_PERCENT_s, FAST_MAX_PERCENT_s * (state_time / 5.0)) * elapsed_s
        local step   = scaler * _spctl.data.max_br

        -- o mínimo é a taxa lenta, mantém o comportamento antigo
        step = math.max(SLOW_RAMP_mB_s * elapsed_s, step)

        -- não cai abaixo do setpoint
        new_br = math.max(cur_br - step, setpoints.burn_rate)

        -- log.debug(util.sprintf("SPCTL: scaler[%f] cur_ccool[%f] step[%f] new_br[%f]", scaler, cur_ccool, step, new_br))
    end

    -- define a taxa de queima
    _spctl.new_br = math.min(new_br, limits.fuel_max_burn)

    -- libera a rampa forçada se o alvo for menor que o atual
    if plc_state.limit_force_ramp and (new_br < cur_br) then
        log.info("SPCTL: recuperacao em rampa da limitacao de queima de combustivel liberada")
        plc_state.limit_force_ramp = false
    end

    if _spctl.new_br ~= setpoints.burn_rate then
        -- atualiza os valores rastreados e continua
        _spctl.last_ccool = cur_ccool
    else
        new_state = STATES.STOPPED

        -- libera a rampa forçada
        if plc_state.limit_force_ramp then
            log.info("SPCTL: recuperacao em rampa da limitacao de queima de combustivel concluida")
            plc_state.limit_force_ramp = false
        end
    end

    -- gerenciamento de mudança de estado
    if new_state ~= state then
        log.debug("SPCTL: estado alterado para " .. (STATE_NAMES[new_state] or "UNKNOWN"))

        _spctl.next_state  = new_state
        _spctl.last_change = now
    end
end

---@param reactor FissionReactor
---@param elapsed_s number nominal iteration elapsed time reference
local function ramp_update(reactor, elapsed_s)
    -- verifica se devemos iniciar a rampa
    if setpoints.burn_rate_en and (setpoints.burn_rate ~= _spctl.last_sp) and rps.is_active() then
        parallel.waitForAll(
            function () _spctl.data.burn_rate = reactor.getBurnRate() end,
            function () _spctl.data.max_br    = reactor.getMaxBurnRate() end
        )

        local cur_br = _spctl.data.burn_rate

        if (type(cur_br) == "number") and (type(_spctl.data.max_br) == "number") and (setpoints.burn_rate ~= cur_br) then
            ramp_init(cur_br)
        end
    end

    -- minimiza operações quando não está em execução
    if _spctl.next_state ~= STATES.STOPPED then
        -- ajusta a taxa de queima (setpoints.burn_rate)
        if setpoints.burn_rate_en then
            local cur_br, ccool = _spctl.data.burn_rate, _spctl.data.ccool_fill

            if not rps.is_active() then
                log.info("SPCTL: rampa abortada (reator inativo)")
                setpoints.burn_rate_en = false
                ramp_reset()
            else
                if (type(cur_br) == "number") and (type(ccool) == "number") then
                    ramp_run(cur_br, ccool, elapsed_s)
                else
                    log.error(util.c("SPCTL: execucao do loop ignorada devido a dados invalidos (cur_br = ", cur_br, ",cur_ccool = ", ccool, ")"))
                end
            end
        else
            log.info("SPCTL: rampa cancelada")
            ramp_reset()
        end
    elseif setpoints.burn_rate_en then
        log.info(util.c("SPCTL: rampa concluida (setpoint de ", setpoints.burn_rate, " mB/t)"))
        setpoints.burn_rate_en = false
        ramp_reset()
    end
end

--#endregion

--#region Fuel Burn Rate Limiting

-- atualiza a limitação de taxa de queima baseada em combustível e o monitoramento de combustível
---@param tick integer
---@param reactor FissionReactor
local function update_fuel_rate_limiting(tick, reactor)
    local fuel_fill = nil ---@type number|nil
    local data      = _spctl.data

    if _spctl.fuel_monitoring and (type(data.fuel) == "number") and (type(data.act_rate) == "number") then
        fuel_fill = data.fuel_fill

        local elapsed_s = (util.time_s() - _spctl.last_mon_check)
        _spctl.last_mon_check = util.time_s()

        -- mais provável de obter um tick completo verificando de duas maneiras, então fazemos a média das verificações
        local tps_avg = (data.tps + (1000 / data.tick_time)) / 2

        -- atualiza os filtros EMA
        _spctl.fuel_filt.update(data.fuel)
        _spctl.rate_filt.update(data.act_rate)
        _spctl.tick_filt.update(elapsed_s * tps_avg)

        -- calcula a variação de combustível em mB/t
        _spctl.d_fuel     = _spctl.fuel_filt.get() - _spctl.last_fuel_filt
        _spctl.d_fuel_mBt = _spctl.d_fuel / _spctl.tick_filt.get()

        local limit       = math.max(0.01, _spctl.rate_filt.get() + _spctl.d_fuel_mBt)

        if _spctl.fuel_limiting then
            limits.reportable_max_burn = limit
            limits.fuel_max_burn = limit
        else
            limits.reportable_max_burn = false
            limits.fuel_max_burn = math.huge
        end

        -- log.debug(util.sprintf("SPCTL: elapsed[%f] tps[%f] tps_avg[%f] divisor[%f] fuel[%f] fuel_f[%f] d_fuel[%f] d_fuel_mBt[%f] act_rate[%f] act_rate_f[%f] limit[%f]",
        --     elapsed_s, data.tps, tps_avg, elapsed_s * tps_avg, data.fuel, _spctl.fuel_filt.get(), d_fuel, d_fuel_mBt, data.act_rate, _spctl.rate_filt.get(), limit))

        _spctl.last_fuel_filt = _spctl.fuel_filt.get()
    elseif tick % 5 == 0 then
        fuel_fill = reactor.getFuelFilledPercentage()
    end

    -- altera o estado conforme o nível de combustível
    if fuel_fill then
        if (fuel_fill > FUEL_LIMIT_RELEASE) and (_spctl.fuel_monitoring or _spctl.fuel_limiting) then
            if _spctl.fuel_limiting and not plc_state.limit_force_ramp then
                log.info("SPCTL: forcando comandos automaticos em rampa para recuperacao do limite de queima (limite liberado)")
                plc_state.limit_force_ramp = true
            end

            _spctl.fuel_monitoring = false
            _spctl.fuel_limiting = false

            limits.reportable_max_burn = false
            limits.fuel_max_burn = math.huge

            _spctl.d_fuel = 0
            _spctl.d_fuel_mBt = 0

            log.info("SPCTL: monitoramento de combustivel encerrado / limite liberado")
        elseif _spctl.fuel_monitoring and (not _spctl.fuel_limiting) and (fuel_fill < FUEL_LIMIT_START) then
            _spctl.fuel_limiting = true

            log.info("SPCTL: limite de combustivel ativado")
        elseif (not _spctl.fuel_monitoring) and (fuel_fill < FUEL_LIMIT_INIT) then
            _spctl.fuel_monitoring = true

            _spctl.last_mon_check = util.time_s()

            _spctl.fuel_filt.reset()
            _spctl.rate_filt.reset()
            _spctl.tick_filt.reset()

            log.info("SPCTL: iniciou monitoramento de estatisticas de combustivel, aproximando-se do limite")
        end
    end
end

--#endregion

-- atualiza o controlador de setpoint
---@param reactor FissionReactor
---@param tick integer tick counter
---@param nom_elapsed_s number nominal iteration elapsed time reference
function spctl.update(reactor, tick, nom_elapsed_s)
    _spctl.new_br = nil

    local update_5Hz = tick % 2 == 0

    -- obtém todos os dados em um tick em vez de 2+ vezes
    if _spctl.fuel_monitoring or (_spctl.next_state ~= STATES.STOPPED) or (databus.en_diag and update_5Hz) then
        local t_start, t_end = util.time_ms(), 0

        parallel.waitForAll(
            function () _spctl.data.tps        = util.get_tps() end,
            function () _spctl.data.burn_rate  = reactor.getBurnRate() end,
            function () _spctl.data.ccool_fill = reactor.getCoolantFilledPercentage() end,
            function () _spctl.data.fuel_fill  = reactor.getFuelFilledPercentage() end,
            function () _spctl.data.act_rate   = reactor.getActualBurnRate() end,
            function ()
                _spctl.data.fuel = (reactor.getFuel() or { amount = nil }).amount
                t_end            = util.time_ms()
            end
        )

        _spctl.data.tick_time = t_end - t_start
    end

    -- controle de rampa
    if update_5Hz then
        ramp_update(reactor, nom_elapsed_s)
    end

    -- limitação de taxa de combustível
    if plc_state.auto_ctl and _spctl.fuel_limit_en then
        update_fuel_rate_limiting(tick, reactor)
    elseif _spctl.fuel_monitoring then
        limits.reportable_max_burn = false
        limits.fuel_max_burn       = math.huge

        _spctl.fuel_monitoring = false
        _spctl.fuel_limiting   = false
    end

    -- aplica nova taxa se definida, caso contrário limita periodicamente se necessário
    if _spctl.new_br then
        reactor.setBurnRate(math.min(_spctl.new_br, limits.fuel_max_burn))
    elseif plc_state.auto_ctl and _spctl.fuel_limiting and update_5Hz and (_spctl.next_state == STATES.STOPPED) then
        local cur_br = _spctl.data.burn_rate

        if cur_br > limits.fuel_max_burn then
            reactor.setBurnRate(math.min(setpoints.burn_rate, limits.fuel_max_burn))
        elseif cur_br < setpoints.burn_rate then
            -- precisamos trazer a taxa de volta para cima, mas não queremos que ela salte agressivamente
            -- usa o controlador de rampa para isso
            if not (plc_state.limit_force_ramp and setpoints.burn_rate_en) then
                log.info("SPCTL: iniciando recuperacao em rampa da limitacao de queima de combustivel")
                plc_state.limit_force_ramp = true
                setpoints.burn_rate_en = true
            end
        end
    end

    -- registra diagnósticos mostrados no painel frontal, apenas quando essa página está ativa
    if update_5Hz and databus.en_diag then
        local publish = databus.ps.publish

        publish("spctl_ramp_active", setpoints.burn_rate_en)

        publish("spctl_ramp_sp", setpoints.burn_rate)

        publish("spctl_ramp_init", _spctl.next_state == STATES.INIT)
        publish("spctl_ramp_sru", _spctl.next_state == STATES.SLOW_RAMP_UP)
        publish("spctl_ramp_srd", _spctl.next_state == STATES.SLOW_RAMP_DOWN)
        publish("spctl_ramp_sw", _spctl.next_state == STATES.STABLE_WAIT)
        publish("spctl_ramp_cm", _spctl.next_state == STATES.CCOOL_MON)
        publish("spctl_ramp_fru", _spctl.next_state == STATES.FAST_RAMP_UP)
        publish("spctl_ramp_frd", _spctl.next_state == STATES.FAST_RAMP_DOWN)

        publish("spctl_limit_mon", _spctl.fuel_monitoring)
        publish("spctl_limit_lim", _spctl.fuel_limiting)
        publish("spctl_limit_fr", plc_state.limit_force_ramp)

        publish("spctl_limit_dfuel", _spctl.d_fuel)
        publish("spctl_limit_dfuelmbt", _spctl.d_fuel_mBt)
        publish("spctl_limit_limit", limits.fuel_max_burn)

        publish("spctl_limit_fuel_filt", _spctl.fuel_filt.get())
        publish("spctl_limit_rate_filt", _spctl.rate_filt.get())
        publish("spctl_limit_tick_filt", _spctl.tick_filt.get())

        publish("spctl_data_tps", _spctl.data.tps)
        publish("spctl_data_tick", _spctl.data.tick_time)
    end
end

return spctl
