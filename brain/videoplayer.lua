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
local function drawControls(screen, state, entry, totalDurationSec, dropPct, diag)
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
    -- How much video is being dropped to keep audio intact (see
    -- onVideoFrame). 0% means the wall is comfortably keeping up; a high,
    -- steady number means the encode is asking for more frames per second
    -- than this wall can physically draw, and re-encoding at a lower fps
    -- would give smoother motion than dropping does.
    if dropPct and dropPct > 0 then
        screen.setCursorPos(1, 3)
        screen.setTextColor(dropPct >= 25 and colors.orange or colors.lightGray)
        screen.write(("Praleista kadru: %d%%"):format(dropPct))
        screen.setTextColor(colors.white)
    end
    if diag then
        screen.setCursorPos(1, 4)
        screen.setTextColor(math.abs(diag.driftSec) >= 0.5 and colors.orange or colors.lightGray)
        screen.write(("drift %+.1fs  queue %d"):format(diag.driftSec, diag.queued))
        screen.setTextColor(colors.white)
    end
    screen.setCursorPos(1, 6)
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
    -- Wall-clock reference for the WHOLE video, used only for diagnostics.
    -- state.elapsedSec is derived from frame indices, so it advances at
    -- whatever rate decoding manages -- it cannot reveal that playback is
    -- running slower than real time. Comparing the two does.
    local playStartMs = os.epoch("utc")
    local pausedMs = 0
    local result = "done"

    -- Videos encoded from 2026-09-03 onward carry their audio as separate
    -- .dfpwm files (entry.audio) instead of interleaving it into the .32vid
    -- stream. That matters because interleaved audio can only be produced as
    -- fast as video frames are decoded AND drawn -- so anything that slows
    -- rendering (a big wall, a busy server) starves the speakers, heard as
    -- audio cutting out every couple of seconds even while the picture looks
    -- perfectly smooth. Confirmed in-game on the 12-monitor wall.
    --
    -- With a separate stream the audio coroutine reads its own HTTP response
    -- at its own pace, exactly like musicplayer.lua does, and nothing the
    -- renderer does can interrupt it.
    --
    -- Older videos have no entry.audio and still use the interleaved path
    -- below, so existing libraries keep working.
    local hasSeparateAudio = type(entry.audio) == "table" and #entry.audio > 0

    -- DFPWM is one bit per sample at 48kHz, i.e. exactly 6000 bytes per
    -- second, always. So the number of audio bytes handed to the speakers is
    -- an exact clock -- no timers, no drift, and it is the SAME clock the
    -- listener hears. When a separate audio stream exists it becomes the
    -- master clock and video follows it (dropping frames if it must), which
    -- is how real players work and the opposite of pacing audio to video.
    local DFPWM_BYTES_PER_SECOND = 6000
    local audioElapsedSec = 0
    local audioFinished = false

    -- Only the FIRST chunk is a real wait. Every chunk after it is fetched
    -- in the background while the previous one is still playing (see the
    -- prefetch branch inside the parallel block below), so there's no
    -- per-chunk "Loading part N/M..." pause between them -- the video just
    -- keeps going. Previously every chunk boundary meant a visible stall
    -- while that chunk downloaded, which got worse the shorter the
    -- segments were.
    -- The clock everything paces to. With separate audio that is real
    -- playback position; without it, the wall clock -- which is still more
    -- honest than counting frames, since a frame counter simply slows down
    -- along with playback and never reveals that it has fallen behind.
    -- Deliberately the wall clock and NOT the audio position, even when a
    -- separate audio track exists. Pacing video to audio sounds correct in
    -- theory, but on a wall that cannot render in real time it means the
    -- renderer is permanently behind and throws frames away instead of
    -- showing them. Audio still plays perfectly either way, because it runs
    -- in its own coroutine; the difference is only whether slow rendering
    -- shows up as smooth-but-behind (this) or as a slideshow (pacing to
    -- audio). audioElapsedSec is kept for the drift readout so the gap
    -- between the two stays visible.
    local function clockSec()
        return (os.epoch("utc") - playStartMs - pausedMs) / 1000
    end

    -- Streams entry.audio start to finish, independently of video decoding.
    -- Same shape as musicplayer.lua's proven loop: read a block, decode it,
    -- hand it to every speaker, and let playAudio's own back-pressure set the
    -- pace (it returns false while the buffer is full, so waiting on
    -- speaker_audio_empty naturally throttles this loop to real time).
    local function streamAudio()
        if not hasSeparateAudio then return end
        local dfpwm = require("cc.audio.dfpwm")
        local bytesQueued = 0
        local audioStartMs = nil
        for _, url in ipairs(entry.audio) do
            if state.stopRequested then break end
            local response = http.get(url, nil, true)
            if not response then break end
            -- A fresh decoder per file: DFPWM is stateful, and each file was
            -- encoded as its own stream, so state must not carry across.
            local decoder = dfpwm.make_decoder()
            while not state.stopRequested do
                local data = response.read(16 * 1024)
                if not data then break end
                while state.paused and not state.stopRequested do
                    os.pullEvent("video_control")
                end
                if state.stopRequested then break end
                local chunk = decoder(data)
                local funcs = {}
                for _, speaker in ipairs(speakers) do
                    funcs[#funcs + 1] = function()
                        while not state.stopRequested and not speaker.playAudio(chunk, state.volume) do
                            os.pullEvent("speaker_audio_empty")
                        end
                    end
                end
                if #funcs > 0 then parallel.waitForAll(table.unpack(funcs)) end
                bytesQueued = bytesQueued + #data
                if audioStartMs == nil then audioStartMs = os.epoch("utc") end
                -- Position is the WALL CLOCK since playback began, not the
                -- byte count -- audio plays at exactly real time, so once it
                -- has started the clock is the truth.
                --
                -- Counting queued bytes overestimates instead: playAudio
                -- returns as soon as a block is accepted, not when it has been
                -- heard, and the speaker accepts several blocks before it
                -- reports full. Measured in-game, that put this clock 2.5s
                -- ahead of the sound -- and since video paces to it, every
                -- frame looked 2.5s late and got dropped trying to catch up to
                -- a time that had not happened yet.
                --
                -- Still clamped to what has actually been queued, so a stall
                -- in fetching cannot let the clock run past real audio.
                local byBytes = bytesQueued / DFPWM_BYTES_PER_SECOND
                local byClock = (os.epoch("utc") - audioStartMs - pausedMs) / 1000
                audioElapsedSec = math.max(0, math.min(byClock, byBytes))
            end
            response.close()
        end
        audioFinished = true
    end

    drawStatus(screen, ("Loading %s..."):format(entry.name))
    local file = fetchChunkToMemory(entry.chunks[1])
    local nextFile = nil

    for chunkIndex = 1, #entry.chunks do
        if state.stopRequested then break end

        -- Normally already prefetched. This only runs if a prefetch
        -- failed (it's pcall'd below, so a hiccup downgrades to fetching
        -- here rather than killing playback).
        if not file then
            drawStatus(screen, ("Loading %s (part %d/%d)..."):format(entry.name, chunkIndex, #entry.chunks))
            file = fetchChunkToMemory(entry.chunks[chunkIndex])
        end

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
        local lastPalette, lastRows = {}, {}
        local framesPlayed = 0
        local framesDropped = 0
        local lastControlsDraw = 0

        local audioQueue = {}
        local audioQueueTail = 0
        local audioQueueHead = 1
        local decodeFinished = false

        local handlers = {
            shouldStop = function() return state.stopRequested end,
            onHeader = function(_, _, headerFps)
                fps = headerFps
            end,
            onVideoFrame = function(frame, frameIndex)
                if state.paused then
                    -- Time spent paused is not playback falling behind, so
                    -- it has to come out of the drift figure below.
                    local pauseBeganMs = os.epoch("utc")
                    while state.paused and not state.stopRequested do
                        os.pullEvent("video_control")
                    end
                    pausedMs = pausedMs + (os.epoch("utc") - pauseBeganMs)
                end
                if state.stopRequested then return end

                -- Draw only if this frame is still roughly on time.
                --
                -- Rendering one wall frame is up to 480 monitor calls (120
                -- rows x 4 column monitors) and at 25fps has 40ms to do it
                -- in. When it can't, drawing every frame anyway means the
                -- decode loop -- which also feeds the speakers, since audio
                -- and video are interleaved in the same stream -- falls
                -- permanently behind real time. The speaker buffer then
                -- drains before the next chunk arrives, heard as audio
                -- cutting out every couple of seconds. Confirmed in-game on
                -- a 324x120 wall at 25fps.
                --
                -- A dropped video frame is far less noticeable than a gap in
                -- the sound, so lateness is paid for in frames rather than
                -- audio, and the loop can catch back up instead of sliding
                -- further behind.
                --
                -- Skipping deliberately does NOT touch lastPalette/lastRows:
                -- those describe what is actually on the wall, the wall still
                -- holds the last frame drawn, so the caches stay truthful and
                -- the next frame that does get drawn diffs against reality.
                local dueSec = cumulativeSec + (frameIndex - 1) / fps
                -- Every frame is drawn, in order. Dropping late frames to
                -- chase the audio clock was tried and made things visibly
                -- worse: the wall renders slower than real time, so it never
                -- caught up and simply skipped nearly everything. Drawing all
                -- of them means video runs behind the sound on a slow wall --
                -- but it LOOKS right, and looking right is what matters here.
                drawFrame(wall, frame, lastPalette, lastRows)
                state.elapsedSec = dueSec
                framesPlayed = frameIndex

                -- Controls redraw at ~2Hz, not every video frame -- the
                -- computer's own screen isn't the thing being paced to fps.
                -- _G.MOVCCTWX_STATUS is read by remote.lua and attached to
                -- every rednet ack it sends, so the pocket computer's
                -- transport screen can show live title/paused/elapsed/
                -- volume without a separate round trip.
                local now = os.epoch("utc")
                if now - lastControlsDraw > 500 then
                    local dropPct = framesPlayed > 0
                        and math.floor(framesDropped / framesPlayed * 100 + 0.5) or 0
                    -- drift > 0 means the media clock is BEHIND real time,
                    -- i.e. decoding cannot keep up and the speakers will run
                    -- dry no matter how the dispatcher behaves. queued is how
                    -- many decoded audio chunks are waiting to be played: if
                    -- drift is ~0 and queued stays at 0, the gap is in
                    -- production; if queued grows, it is in dispatch.
                    local diag = {
                        driftSec = hasSeparateAudio and (state.elapsedSec - audioElapsedSec) or 0,
                        queued = audioQueueTail - audioQueueHead + 1,
                    }
                    drawControls(screen, state, entry, entry.durationSec or 0, dropPct, diag)
                    _G.MOVCCTWX_STATUS = {
                        screen = "video",
                        name = entry.name,
                        paused = state.paused,
                        elapsedSec = state.elapsedSec,
                        volumePct = math.floor(state.volume / state.maxVolume * 100 + 0.5),
                    }
                    lastControlsDraw = now
                end

                -- Pace to the frame schedule WITHOUT spending a whole game
                -- tick on every frame.
                --
                -- os.sleep's resolution is one tick (50ms), so ANY sleep --
                -- even os.sleep(1/25), which asks for 40ms -- costs at least
                -- 50ms. Sleeping once per frame therefore caps playback at
                -- 20fps no matter how fast the decode and draw actually are.
                -- A 25fps video then runs ~20% slower than real time, and
                -- since the speakers play at real time regardless, audio
                -- chunks arrive later and later and the buffer keeps running
                -- dry. That is heard as audio cutting out constantly while
                -- the video itself looks perfectly smooth -- confirmed
                -- in-game, and the reason frame-dropping alone did not fix
                -- it: dropping made drawing cheaper, but the per-frame sleep
                -- was the thing setting the ceiling.
                --
                -- So sleep only when there is a full tick or more to wait.
                -- Otherwise yield through a queued event, which hands control
                -- to the audio dispatcher and input coroutines without
                -- costing a tick.
                while not state.stopRequested do
                    local aheadSec = (cumulativeSec + frameIndex / fps) - clockSec()
                    if aheadSec <= 0 then break end
                    if aheadSec >= 0.05 then
                        os.sleep(aheadSec)
                    else
                        -- Under one game tick left. os.sleep cannot resolve
                        -- finer than a tick, so sleeping here would overshoot
                        -- and cap playback below the encoded frame rate; yield
                        -- through a queued event instead, which lets the audio
                        -- and input coroutines run without costing a tick.
                        os.queueEvent("kx_frame_yield")
                        os.pullEvent("kx_frame_yield")
                        break
                    end
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
                -- Only started for the first chunk: entry.audio covers the
                -- WHOLE video, not one chunk, so it must keep streaming
                -- straight across chunk boundaries rather than restarting.
                function()
                    if chunkIndex == 1 then streamAudio() end
                end,
                function()
                    decodeModule.decode(file, handlers)
                    cumulativeSec = cumulativeSec + framesPlayed / fps
                    decodeFinished = true
                    os.queueEvent("kx_audio_wake")
                end,
                function() -- audio dispatcher: drains the queue, fans each chunk out
                    -- to every networked speaker in sync (waits for each speaker's own
                    -- speaker_audio_empty ack, with a 3s per-speaker timeout).
                    local head = audioQueueHead
                    while true do
                        while head > audioQueueTail do
                            if state.stopRequested or decodeFinished then return end
                            os.pullEvent("kx_audio_wake")
                        end
                        local chunk = audioQueue[head]
                        audioQueue[head] = nil
                        head = head + 1
                        audioQueueHead = head
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
                            -- startup.lua's remoteMenuWatcher treats these 4
                            -- as "go somewhere else" -- from in here that's
                            -- indistinguishable from a plain stop: halt this
                            -- video and hand control back to runVideoMenu's
                            -- outer loop, which then honors the real target.
                            if action == "open_video_menu" or action == "open_music_menu"
                                or action == "play_video" or action == "play_music" then
                                action = "stop"
                            end
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
                end,
                function() -- prefetch the NEXT chunk while this one plays
                    local nextUrl = entry.chunks[chunkIndex + 1]
                    if not nextUrl then return end
                    -- pcall'd on purpose: a failed prefetch must not take
                    -- down playback of the chunk currently on screen. The
                    -- loop just fetches it normally next time round
                    -- instead (with the loading message), same as before.
                    local ok, result = pcall(fetchChunkToMemory, nextUrl)
                    if ok then nextFile = result end
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

        -- Hand the already-downloaded next chunk to the next iteration.
        file = nextFile
        nextFile = nil
    end

    wall.setBackgroundColor(colors.black)
    wall.clear()
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()
    return result
end

return M
