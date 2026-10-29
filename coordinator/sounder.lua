--
-- Alarme Sonoro
--

local audio = require("scada-common.audio")
local log   = require("scada-common.log")

---@class sounder
local sounder = {}

local alarm_ctl = {
    speaker = nil,  ---@type Speaker
    volume = 0.5,
    stream = audio.new_stream()
}

-- inicia o áudio ou continua o áudio quando o buffer esvaziar
---@return boolean success successfully added buffer to audio output
local function play()
    if not alarm_ctl.playing then
        alarm_ctl.playing = true
        return sounder.continue()
    else return true end
end

-- inicializa o sistema de alarme do anunciador
---@param speaker Speaker speaker peripheral
---@param volume number speaker volume
function sounder.init(speaker, volume)
    alarm_ctl.speaker = speaker
    alarm_ctl.speaker.stop()
    alarm_ctl.volume = volume
    alarm_ctl.stream.stop()

    audio.generate_tones()
end

-- reconecta o periférico de alto-falante
---@param speaker Speaker speaker peripheral
function sounder.reconnect(speaker)
    alarm_ctl.speaker = speaker
    alarm_ctl.playing = false
    alarm_ctl.stream.stop()
end

-- define os tons de alarme
---@param states { [TONE]: boolean } alarm tone commands from supervisor
function sounder.set(states)
    -- define estados dos tons
    for id = 1, #states do alarm_ctl.stream.set_active(id, states[id]) end

    -- recalcula a saída se necessário, então reproduz o áudio se disponível
    if alarm_ctl.stream.is_recompute_needed() then alarm_ctl.stream.compute_buffer() end
    if alarm_ctl.stream.any_active() then play() else sounder.stop() end
end

-- para todo o áudio e limpa o buffer de saída
function sounder.stop()
    alarm_ctl.playing = false
    alarm_ctl.speaker.stop()
    alarm_ctl.stream.stop()
end

-- continua o áudio quando o buffer esvaziar
---@return boolean success successfully added buffer to audio output
function sounder.continue()
    local success = false

    if alarm_ctl.playing then
        if alarm_ctl.speaker ~= nil and alarm_ctl.stream.has_next_block() then
            success = alarm_ctl.speaker.playAudio(alarm_ctl.stream.get_next_block(), alarm_ctl.volume)
            if not success then log.error("SOUNDER: error playing audio") end
        end
    end

    return success
end

return sounder
