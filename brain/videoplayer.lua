-- videoplayer.lua -- full-screen 32vid playback on the monitor wall (see
-- wall.lua), with playback status/controls on the computer's own screen
-- instead. The wall is a passive display only -- no buttons, no touch
-- handling live on it. Adapted from the single-monitor Komanda X player;
-- see vendor/32vid-decode.lua's header before touching decode logic.

local decodeModule = require("vendor.32vid-decode")
local settings = require("settings")

local M = {}

local function drawStatus(screen, text)
    local w, h = screen.getSize()
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    screen.setCursorPos(x, math.floor(h / 2))
    screen.write(text)
end

-- Downloads a chunk straight into memory and returns a "file"-like table
-- (read/seek/close) the decoder can use directly -- never touches the
-- computer's own (tiny) disk quota.
local function fetchChunkToMemory(url)
    local cacheBustUrl = url .. (url:find("?") and "&" or "?") .. "t=" .. tostring(os.epoch("utc"))
    local response, err = http.get(cacheBustUrl, nil, true)
    if not response then
        error("Failed to download video chunk: " .. tostring(err))
    end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then
        error("Downloaded video chunk was empty (0 bytes) -- check the chunk actually has data.")
    end

    local pos = 1
    local file = {}
    -- file.read() with NO argument must return ONE byte as a number
    -- (0-255) or nil at EOF -- the decoder's ANS reader relies on this.
    function file.read(n)
        if pos > #body then return nil end
        if n == nil then
            local b = body:byte(pos)
            pos = pos + 1
            return b
        end
        local piece = body:sub(pos, pos + n - 1)
        pos = pos + #piece
        return piece
    end
    function file.seek()
        return pos - 1
    end
    function file.close() end
    return file
end

local function formatTime(seconds)
    if seconds < 0 then seconds = 0 end
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
end

-- One status line on the computer's own screen: title, play/pause state,
-- elapsed/remaining, volume, and the key controls. No touch targets --
-- input here is keyboard (at the computer) or a remote command relayed
-- from the pocket computer via remote.lua.
local function drawControls(screen, state, entry, totalDurationSec)
    local elapsed = state.elapsedSec
    local remaining = math.max(0, totalDurationSec - elapsed)
    local pct = math.floor(state.volume / state.maxVolume * 100 + 0.5)

    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()
    screen.setCursorPos(1, 1)
    screen.write(("Playing: %s"):format(entry.name))
    screen.setCursorPos(1, 2)
    screen.write(("%s %s / -%s   Vol %d%%"):format(
        state.paused and "PAUSED" or "PLAYING", formatTime(elapsed), formatTime(remaining), pct))
    screen.setCursorPos(1, 4)
    screen.write("[space] play/pause  [s] stop  [left/right] volume  [q] quit")
end

-- lastPalette / lastRows dedupe redraws to what actually changed since the
-- previous frame -- this is what keeps the wall's real blit throughput
-- manageable at video framerates (a static region doesn't get re-sent).
local function drawFrame(wall, image, lastPalette, lastRows)
    for i, v in ipairs(image.palette) do
        local prev = lastPalette[i]
        if not prev or prev[1] ~= v[1] or prev[2] ~= v[2] or prev[3] ~= v[3] then
            wall.setPaletteColor(2 ^ (i - 1), v[1], v[2], v[3])
            lastPalette[i] = v
        end
    end
    for y, r in ipairs(image) do
        local prevRow = lastRows[y]
        if not prevRow or prevRow[1] ~= r[1] or prevRow[2] ~= r[2] or prevRow[3] ~= r[3] then
            wall.setCursorPos(1, y)
            wall.blit(r[1], r[2], r[3])
            lastRows[y] = r
        end
    end
end

-- CC:Tweaked's real default 16-color palette (Colour.java values).
local DEFAULT_PALETTE_RGB = {
    [0] = 0xF0F0F0, 0xF2B233, 0xE57FD8, 0x99B2F2,
    0xDEDE6C, 0x7FCC19, 0xF2B2CC, 0x4C4C4C,
    0x999999, 0x4C99B2, 0xB266E5, 0x3366CC,
    0x7F664C, 0x57A64E, 0xCC4C4C, 0x111111,
}
local function resetPalette(wall)
    for i = 0, 15 do
        wall.setPaletteColor(2 ^ i, DEFAULT_PALETTE_RGB[i])
    end
end

-- Plays every chunk of `entry` ({name, chunks, width, height, fps,
-- durationSec}) in order onto `wall` (see wall.lua), with status/controls
-- on `screen` (the computer's own terminal). Returns "done" when playback
-- finishes normally, or "stopped" on user/remote stop.
function M.play(wall, screen, speakers, entry, config)
    local savedSettings = settings.load()
    local state = {
        paused = false,
        stopRequested = false,
        volume = savedSettings.videoVolume or config.DEFAULT_VOLUME,
        maxVolume = config.MAX_VOLUME,
        elapsedSec = 0,
    }

    local cumulativeSec = 0
    local result = "done"

    for chunkIndex, url in ipairs(entry.chunks) do
        if state.stopRequested then break end

        drawStatus(screen, ("Loading %s (part %d/%d)..."):format(entry.name, chunkIndex, #entry.chunks))

        local file = fetchChunkToMemory(url)
        drawStatus(screen, ("Decoding %s (part %d/%d)..."):format(entry.name, chunkIndex, #entry.chunks))

        local function saveVolume()
            savedSettings.videoVolume = state.volume
            settings.save(savedSettings)
        end
        local function adjustVolume(deltaFraction)
            local step = deltaFraction * state.maxVolume
            state.volume = math.max(0, math.min(state.maxVolume, state.volume + step))
            saveVolume()
        end

        local fps = 10
        local frameStart = os.epoch("utc")
        local lastPalette, lastRows = {}, {}
        local framesPlayed = 0
        local lastControlsDraw = 0

        local audioQueue = {}
        local audioQueueTail = 0
        local decodeFinished = false

        local handlers = {
            shouldStop = function() return state.stopRequested end,
            onHeader = function(_, _, headerFps)
                fps = headerFps
                frameStart = os.epoch("utc")
            end,
            onVideoFrame = function(frame, frameIndex)
                while state.paused and not state.stopRequested do
                    os.pullEvent("video_control")
                    frameStart = os.epoch("utc") - (frameIndex - 1) / fps * 1000
                end
                if state.stopRequested then return end

                drawFrame(wall, frame, lastPalette, lastRows)
                state.elapsedSec = cumulativeSec + (frameIndex - 1) / fps
                framesPlayed = frameIndex

                -- Controls redraw at ~2Hz, not every video frame -- the
                -- computer's own screen isn't the thing being paced to fps.
                local now = os.epoch("utc")
                if now - lastControlsDraw > 500 then
                    drawControls(screen, state, entry, entry.durationSec or 0)
                    lastControlsDraw = now
                end

                while os.epoch("utc") < frameStart + (frameIndex + 1) / fps * 1000 do
                    os.sleep(1 / fps)
                    if state.stopRequested then break end
                end
            end,
            onAudioChunk = function(chunk)
                if state.stopRequested then return end
                audioQueueTail = audioQueueTail + 1
                audioQueue[audioQueueTail] = chunk
                os.queueEvent("kx_audio_wake")
            end,
        }

        local playOk, playErr = pcall(function()
            parallel.waitForAll(
                function()
                    decodeModule.decode(file, handlers)
                    cumulativeSec = cumulativeSec + framesPlayed / fps
                    decodeFinished = true
                    os.queueEvent("kx_audio_wake")
                end,
                function() -- audio dispatcher: drains the queue, fans each chunk out
                    -- to every networked speaker in sync (waits for each speaker's own
                    -- speaker_audio_empty ack, with a 3s per-speaker timeout).
                    local head = 1
                    while true do
                        while head > audioQueueTail do
                            if state.stopRequested or decodeFinished then return end
                            os.pullEvent("kx_audio_wake")
                        end
                        local chunk = audioQueue[head]
                        audioQueue[head] = nil
                        head = head + 1
                        if chunk and not state.stopRequested and #speakers > 0 then
                            local funcs = {}
                            for _, speaker in ipairs(speakers) do
                                funcs[#funcs + 1] = function()
                                    while not state.stopRequested and not speaker.playAudio(chunk, state.volume) do
                                        local timerId = os.startTimer(3)
                                        local gaveUp = false
                                        repeat
                                            local ev2, a = os.pullEvent()
                                            if ev2 == "speaker_audio_empty" and a == peripheral.getName(speaker) then
                                                break
                                            elseif ev2 == "timer" and a == timerId then
                                                gaveUp = true
                                                break
                                            end
                                        until state.stopRequested
                                        if gaveUp or state.stopRequested then break end
                                    end
                                end
                            end
                            parallel.waitForAll(table.unpack(funcs))
                        end
                    end
                end,
                function() -- input: keyboard at the computer, or a remote command
                    -- relayed by remote.lua as a "movcctwx_remote_action" event
                    -- (already allowlist-checked before it ever gets queued).
                    while not state.stopRequested and not decodeFinished do
                        local event, a = os.pullEvent()
                        local action = nil

                        if event == "key" then
                            if a == keys.q then
                                _G.MOVCCTWX_TERMINATED = true
                                error("Terminated", 0)
                            elseif a == keys.space then action = "playpause"
                            elseif a == keys.s then action = "stop"
                            elseif a == keys.left then action = "vol-1"
                            elseif a == keys.right then action = "vol+1"
                            end
                        elseif event == "movcctwx_remote_action" then
                            action = a
                        end

                        if action == "playpause" then
                            state.paused = not state.paused
                            os.queueEvent("video_control")
                        elseif action == "stop" then
                            state.stopRequested = true
                            os.queueEvent("video_control")
                        elseif action == "vol-1" then adjustVolume(-0.01)
                        elseif action == "vol+1" then adjustVolume(0.01)
                        elseif action == "vol-10" then adjustVolume(-0.10)
                        elseif action == "vol+10" then adjustVolume(0.10)
                        end
                    end
                end
            )
        end)

        for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
        resetPalette(wall)

        if not playOk then
            if tostring(playErr):find("Terminated") then
                wall.setBackgroundColor(colors.black)
                wall.clear()
                error(playErr, 0)
            end
            drawStatus(screen, "Playback error: " .. tostring(playErr))
            os.sleep(2)
            result = "done"
            break
        end

        if state.stopRequested then
            result = "stopped"
            break
        end
    end

    wall.setBackgroundColor(colors.black)
    wall.clear()
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()
    return result
end

return M
