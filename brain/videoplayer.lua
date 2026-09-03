-- videoplayer.lua -- full-screen 32vid playback on the monitor wall (see
-- wall.lua), with playback status/controls on the computer's own screen
-- instead. The wall is a passive display only -- no buttons, no touch
-- handling live on it. Adapted from the single-monitor Komanda X player;
-- see vendor/32vid-decode.lua's header before touching decode logic.

local decodeModule = require("vendor.32vid-decode")
local subtitleModule = require("subtitles")
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
local function drawControls(screen, state, entry, totalDurationSec, diag)
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
    if diag then
        screen.setCursorPos(1, 4)
        local stalled = (diag.stalledSec or 0) >= 1.5
        screen.setTextColor(stalled and colors.red or colors.lightGray)
        -- drift: picture position minus where the player believes the sound
        -- is (+ = picture ahead). buf: audio handed to the speakers but not
        -- yet heard -- the real latency, which drift alone cannot show.
        screen.write(("%s %d/%d drift %+.1fs buf %.1fs")
            :format(diag.phase or "?", diag.chunk or 0, diag.chunkCount or 0,
                diag.driftSec or 0, diag.bufSec or 0))
        if stalled then
            screen.setCursorPos(1, 5)
            screen.write(("NEJUDA %.1fs"):format(diag.stalledSec))
        end
        screen.setTextColor(colors.white)
    end
    screen.setCursorPos(1, 7)
    screen.write("[space] play/pause  [s] stop  [left/right] volume  [t] subtitles  [q] quit")
end

-- lastPalette / lastRows dedupe redraws to what actually changed since the
-- previous frame -- this is what keeps the wall's real blit throughput
-- manageable at video framerates (a static region doesn't get re-sent).
local function drawFrame(wall, image, lastPalette, lastRows, patches)
    for i, v in ipairs(image.palette) do
        local prev = lastPalette[i]
        if not prev or prev[1] ~= v[1] or prev[2] ~= v[2] or prev[3] ~= v[3] then
            wall.setPaletteColor(2 ^ (i - 1), v[1], v[2], v[3])
            lastPalette[i] = v
        end
    end
    for y, r in ipairs(image) do
        local text, fg, bg = r[1], r[2], r[3]
        -- Subtitles are spliced into the frame's OWN rows rather than blitted
        -- on top afterwards, because wall.blit always writes a whole row
        -- starting at column 1 -- it has no partial-row write to layer with.
        --
        -- Splicing also keeps this cache honest: what is remembered is exactly
        -- what went to the monitor, so when a cue ends the row differs from the
        -- remembered one again and gets redrawn by itself. Blitting the box
        -- separately would leave the cache describing the video underneath, and
        -- the subtitle would never be cleared.
        local patch = patches and patches[y]
        if patch then
            local head, tail = patch.x - 1, patch.x + #patch.text
            text = text:sub(1, head) .. patch.text .. text:sub(tail)
            fg = fg:sub(1, head) .. patch.fg .. fg:sub(tail)
            bg = bg:sub(1, head) .. patch.bg .. bg:sub(tail)
        end
        local prevRow = lastRows[y]
        if not prevRow or prevRow[1] ~= text or prevRow[2] ~= fg or prevRow[3] ~= bg then
            wall.setCursorPos(1, y)
            wall.blit(text, fg, bg)
            -- An UNPATCHED row stores the decoder's own row table, exactly as
            -- this did before subtitles existed. Allocating a fresh table for
            -- every row of every frame instead would be 2400 short-lived
            -- tables a second at 20fps on 120 rows, and the garbage collector
            -- runs on the same single Lua thread as decoding and drawing.
            -- Only the handful of rows a subtitle actually covers pay that.
            lastRows[y] = patch and { text, fg, bg } or r
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
function M.play(wall, screen, speakers, entry, config, opts)
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

    -- The last laid-out cue and the palette colours it was drawn with, so an
    -- unchanged subtitle is not rebuilt on every frame.
    local lastCue, lastPatches, lastTextHex, lastBoxHex = nil, nil, nil, nil

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

    -- Subtitles ship as one small file of their own (entry.subs) and are drawn
    -- here in the monitor's own font, never burned into the picture.
    --
    -- Burning them in was tried and measured first: at the wall's real output
    -- resolution the text has to be about a third of the frame tall before it
    -- survives the downscale and the dither to 16 colours, and even then it
    -- comes out soft. Drawn here it costs a few text rows, stays sharp over any
    -- scene, can be switched off mid-video, and adds about 50KB to an entire
    -- film instead of inflating every single chunk.
    --
    -- Fetched once, up front: a film's cue file is smaller than any one video
    -- chunk, and doing it here means it can never interrupt playback later.
    local subtitleCursor, subtitleScale = nil, nil
    -- The menu asks per video when one actually HAS subtitles, and passes
    -- the answer in. Written out rather than folded into an `and`/`or` chain
    -- because the answer can legitimately be false, which such a chain would
    -- silently turn back into the config default.
    local subtitlesOn
    if opts and opts.subtitles ~= nil then
        subtitlesOn = opts.subtitles and true or false
    else
        subtitlesOn = config.SUBTITLES ~= false
    end
    if type(entry.subs) == "string" and entry.subs ~= "" then
        local ok = pcall(function()
            local url = entry.subs .. (entry.subs:find("?") and "&" or "?")
                .. "t=" .. tostring(os.epoch("utc"))
            local response = http.get(url)
            if not response then error("no response") end
            local body = response.readAll()
            response.close()
            local cues = subtitleModule.parse(body or "")
            if #cues > 0 then
                subtitleCursor = subtitleModule.newCursor(cues)
                local wallW, wallH = wall.getSize()
                subtitleScale = subtitleModule.scaleFor(wallW, wallH)
            end
        end)
        -- A missing or malformed subtitle file must never stop the film. This
        -- is the one part of playback that is purely additive.
        if not ok then subtitleCursor = nil end
    end

    -- DFPWM is one bit per sample at 48kHz, i.e. exactly 6000 bytes per
    -- second, always. So the number of audio bytes handed to the speakers is
    -- an exact clock -- no timers, no drift, and it is the SAME clock the
    -- listener hears. When a separate audio stream exists it becomes the
    -- master clock and video follows it (dropping frames if it must), which
    -- is how real players work and the opposite of pacing audio to video.
    local DFPWM_BYTES_PER_SECOND = 6000
    local audioElapsedSec = 0
    -- How far into the soundtrack has been HANDED to the speakers, as opposed
    -- to audioElapsedSec which is how far has been heard. The gap between the
    -- two is what is sitting in the speaker's buffer -- i.e. how far behind
    -- the sound you hear is from where the player thinks it is.
    local audioQueuedSec = 0
    -- When audioElapsedSec last actually moved. The picture paces to the
    -- sound, so if the audio stream stalls -- a slow read, a hiccup fetching
    -- the next part -- the clock it follows simply stops, and the video
    -- freezes for exactly as long as the stall lasts. Tracking this lets the
    -- picture carry on rather than waiting indefinitely.
    -- The audio clock as a SPAN, not a stored number: where the current
    -- uninterrupted run of playback started, and when. Position is then
    -- computed live from the wall clock whenever it is asked for.
    --
    -- Storing a value and refreshing it per audio block does not work: a
    -- block is over a second of sound, so the clock sat frozen between
    -- updates and then jumped. The picture paces to it, so it stalled and
    -- rushed, over and over -- subtle but visible as the video speeding up
    -- and slowing down. Audio plays at exactly real time, so elapsed real
    -- time since the span began IS the position, continuously.
    local audioSpanStartSec = nil
    local audioSpanStartMs = nil
    local audioFrozenSec = 0
    local audioFinished = false
    -- Set if the audio stream dies. Audio is a convenience; the video is the
    -- point -- so a failed fetch or a dropped connection must leave the
    -- picture playing rather than ending the whole thing.
    local audioError = nil

    -- How much audio may sit in the speakers unheard. playAudio accepts
    -- blocks until its own buffer is full, which turned out to be nearly six
    -- seconds -- so the loop gulped audio far faster than real time and that
    -- whole backlog became latency between the player and your ears.
    --
    -- Feeding is now paced to the listener instead: enough buffered to ride
    -- out a slow fetch, not so much that the sound lags behind the picture.
    -- Raised from 1.5s: this is how long a stall the speakers can ride out
    -- before you hear silence, and rare dropouts on a busy server were
    -- getting through. Costs nothing that matters -- the picture paces to the
    -- sound, so they stay in step whatever the buffer depth, and pause
    -- discards it instantly either way.
    local AUDIO_BUFFER_TARGET_SEC = 3.0
    -- Set when the last video chunk is done, so the audio stream stops with
    -- it rather than holding playback open to the end of the soundtrack.
    local videoDone = false
    -- Progress the status coroutine reports on. It runs independently of
    -- decoding, so the computer's screen keeps updating even when decoding
    -- has stopped -- which is the difference between "the whole computer
    -- froze" and "here is exactly where it stopped".
    local phase = "starting"
    local currentChunk = 0
    local lastFrameMs = os.epoch("utc")

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
        -- With a separate audio track, the SOUND is the reference: it plays at
        -- real time and it is what the viewer is actually synchronised to.
        -- Otherwise the picture ends up ahead by however long the first chunk
        -- took to download -- the video clock starts when playback is asked
        -- for, the audio clock when audio genuinely begins. Measured in-game
        -- at +3.4s, which is exactly what that download cost.
        --
        -- This is used ONLY to decide whether to WAIT. Frames are never
        -- dropped to chase it: pacing video to audio and skipping late frames
        -- was tried and produced a slideshow, because the renderer could not
        -- catch up and so skipped nearly everything. Waiting when ahead is
        -- safe; skipping when behind is not.
        if hasSeparateAudio then
            -- Paused, or between spans (re-opening the stream after a pause):
            -- hold the last known position rather than letting it drift on.
            if state.paused or not audioSpanStartMs then return audioFrozenSec end
            return audioSpanStartSec + (os.epoch("utc") - audioSpanStartMs) / 1000
        end
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
        local BLOCK = 16 * 1024

        -- posSec is the position in the soundtrack that has actually been
        -- HEARD, and it only moves while sound is coming out. Audio plays at
        -- exactly real time, so within one uninterrupted span the wall clock
        -- is the truth; a pause simply ends the span and starts a new one.
        --
        -- Counting bytes handed to playAudio does not work for this: it
        -- returns as soon as a block is accepted rather than when it is
        -- heard, and the speaker accepts several ahead, so the count runs
        -- seconds in front of the sound.
        local posSec = 0

        local function stopSpeakers()
            for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
        end

        -- How much of the SOUNDTRACK the parts already finished account for,
        -- counted in bytes consumed rather than in time elapsed.
        local partsPlayedSec = 0

        for _, url in ipairs(entry.audio) do
            if state.stopRequested or videoDone then break end

            -- This used to be `posSec`, and that was wrong in a way only long
            -- videos show. The feed deliberately runs AUDIO_BUFFER_TARGET_SEC
            -- ahead of what has actually been heard, so at the moment a part's
            -- HTTP response runs out, posSec is about three seconds SHORT of
            -- that part's real end. The next part then started its clock three
            -- seconds behind the truth, the picture computed that it was three
            -- seconds ahead, and it waited -- freezing at the seam for as long
            -- as the buffer, once per audio part.
            --
            -- Audio parts are about forty minutes each (CHUNK_TARGET_BYTES at
            -- a flat 6000 bytes per second), so this only bites on a film or a
            -- full episode, and it compounds at every seam after the first.
            local partStartSec = partsPlayedSec
            local reopenAtByte = 0
            local partFinished = false
            -- Bytes this part turned out to hold, known only once it runs out.
            local partBytes = 0

            while not partFinished and not state.stopRequested and not videoDone do
                -- Resuming re-requests the file from the byte the listener
                -- actually got to. DFPWM is a constant 6000 bytes per second,
                -- so that offset is exact arithmetic -- no seeking, no
                -- guessing, and nothing is skipped or repeated across a pause.
                local headers = nil
                if reopenAtByte > 0 then
                    headers = { Range = ("bytes=%d-"):format(reopenAtByte) }
                end
                local response = http.get(url, headers, true)
                if not response then break end

                -- A fresh decoder per span: DFPWM is stateful, and a resumed
                -- request starts mid-stream.
                local decoder = dfpwm.make_decoder()
                local spanStartMs = os.epoch("utc")
                local spanStartSec = partStartSec + reopenAtByte / DFPWM_BYTES_PER_SECOND
                local spanBytes = 0
                posSec = spanStartSec
                audioQueuedSec = spanStartSec
                audioSpanStartSec, audioSpanStartMs = spanStartSec, spanStartMs
                audioFrozenSec = spanStartSec
                local pausedHere = false

                while not state.stopRequested and not videoDone do
                    if state.paused then pausedHere = true break end

                    -- Hold off while the speakers are already well supplied.
                    -- posSec advances in real time as the sound is heard, so
                    -- this settles at roughly AUDIO_BUFFER_TARGET_SEC ahead.
                    while not state.stopRequested and not state.paused and not videoDone
                        and (audioQueuedSec - posSec) > AUDIO_BUFFER_TARGET_SEC do
                        os.sleep(0.1)
                        posSec = spanStartSec + (os.epoch("utc") - spanStartMs) / 1000
                        audioElapsedSec = posSec
                    end
                    if state.paused then pausedHere = true break end

                    local data = response.read(BLOCK)
                    if not data then
                        partFinished = true
                        -- reopenAtByte covers everything consumed before the
                        -- last resume, spanBytes everything since.
                        partBytes = reopenAtByte + spanBytes
                        break
                    end

                    local chunk = decoder(data)
                    local funcs = {}
                    for _, speaker in ipairs(speakers) do
                        funcs[#funcs + 1] = function()
                            while not state.stopRequested and not state.paused do
                                if speaker.playAudio(chunk, state.volume) then return end
                                -- Waits for the speaker to make room, but wakes
                                -- on video_control too. Waiting only on
                                -- speaker_audio_empty meant a pause could not
                                -- be noticed until the speaker had chewed
                                -- through everything it was holding -- several
                                -- seconds, felt as pause simply not working.
                                repeat
                                    local ev = os.pullEvent()
                                until ev == "speaker_audio_empty" or ev == "video_control"
                                    or state.paused or state.stopRequested
                            end
                        end
                    end
                    if #funcs > 0 then parallel.waitForAll(table.unpack(funcs)) end
                    -- Re-checked here so a pause that arrived mid-write takes
                    -- effect now rather than after another block is queued.
                    if state.paused then pausedHere = true break end

                    spanBytes = spanBytes + #data
                    audioQueuedSec = spanStartSec + spanBytes / DFPWM_BYTES_PER_SECOND
                    -- Only for the readouts and the feed throttle below; the
                    -- clock the picture follows is computed live in clockSec.
                    posSec = spanStartSec + (os.epoch("utc") - spanStartMs) / 1000
                    audioElapsedSec = posSec
                    audioFrozenSec = posSec
                end

                response.close()

                if pausedHere then
                    -- Pausing has to DISCARD what the speaker is holding, not
                    -- just stop feeding it. playAudio queues several seconds
                    -- ahead, so without this the sound carried on playing well
                    -- after the picture stopped.
                    stopSpeakers()
                    posSec = spanStartSec + (os.epoch("utc") - spanStartMs) / 1000
                    audioElapsedSec = posSec
                    audioFrozenSec = posSec
                    -- Ends the span: the clock holds at audioFrozenSec until a
                    -- new span starts, instead of running on while silent.
                    audioSpanStartMs = nil
                    -- Buffer was just discarded, so nothing is pending.
                    audioQueuedSec = posSec
                    reopenAtByte = math.max(0,
                        math.floor((posSec - partStartSec) * DFPWM_BYTES_PER_SECOND))
                    while state.paused and not state.stopRequested do
                        os.pullEvent("video_control")
                    end
                end
            end

            -- Only advanced for a part that genuinely ran to its end. A part
            -- abandoned because playback stopped must not push the clock
            -- forward by a length nobody heard.
            if partFinished then
                partsPlayedSec = partStartSec + partBytes / DFPWM_BYTES_PER_SECOND
            end
        end
        audioFinished = true
    end

    -- An upload that failed partway can leave an entry in videos.json with an
    -- empty chunk list. Reaching fetchChunkToMemory(nil) from there threw out
    -- of M.play, past runVideoMenu (which does not pcall it) and out of
    -- startup.lua altogether -- one bad entry took down the whole brain.
    if type(entry.chunks) ~= "table" or #entry.chunks == 0 then
        drawStatus(screen, ("\"%s\" has no chunks -- re-upload it."):format(entry.name))
        os.sleep(2.5)
        return "done"
    end

    -- Claim the wall for the whole of playback, so the menu's idle clock
    -- cannot draw over a video even if its coroutine outlives the menu --
    -- Basalt's schedules table is module-level and never cleared, so that is
    -- a real possibility rather than a theoretical one.
    _G.MOVCCTWX_WALL_BUSY = true

    drawStatus(screen, ("Loading %s..."):format(entry.name))
    -- pcall'd because this sits BETWEEN claiming the wall and the pcall that
    -- guards the rest of playback. A GitHub hiccup on the very first chunk
    -- used to throw straight out of here, which both crashed the brain and
    -- left MOVCCTWX_WALL_BUSY stuck true -- so the idle clock stayed dead for
    -- the rest of the session even after a reboot back into the menu.
    local fetchedOk, file = pcall(fetchChunkToMemory, entry.chunks[1])
    if not fetchedOk then
        _G.MOVCCTWX_WALL_BUSY = false
        drawStatus(screen, "Could not load: " .. tostring(file))
        os.sleep(2.5)
        return "done"
    end
    local nextFile = nil

    -- The chunk loop and the audio stream run alongside each other for the
    -- whole video. Starting the audio inside a chunk's own parallel block
    -- deadlocked playback: that block waits for every branch, and the audio
    -- branch covers the entire soundtrack -- so once the first chunk's video
    -- ended, the picture froze there until the whole song had finished, while
    -- audio carried on. Confirmed in-game.
    local function videoLoop()
        for chunkIndex = 1, #entry.chunks do
            if state.stopRequested then break end
            currentChunk = chunkIndex

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
                        lastFrameMs = os.epoch("utc")
                    end
                    if state.stopRequested then return end

                    local dueSec = cumulativeSec + (frameIndex - 1) / fps
                    -- Every frame is drawn, in order. Dropping late frames to
                    -- chase the audio clock was tried and made things visibly
                    -- worse: the wall renders slower than real time, so it never
                    -- caught up and simply skipped nearly everything. Drawing all
                    -- of them means video runs behind the sound on a slow wall --
                    -- but it LOOKS right, and looking right is what matters here.
                    -- Cues are timed against the SOURCE video and dueSec is
                    -- this frame's own position in it, so the words always match
                    -- the picture they were written for, even when the picture
                    -- is running behind the sound on a slow wall.
                    local patches = nil
                    if subtitleCursor and subtitlesOn then
                        local cue = subtitleCursor:at(dueSec)
                        if cue then
                            -- Laying a cue out again every frame would rebuild
                            -- an identical grid of cells twenty times a second.
                            -- A cue stays up for seconds, so it is built once
                            -- and reused until it changes -- or until the
                            -- palette does, since the two colours it is drawn
                            -- with come from the frame's own palette.
                            local textHex, boxHex = subtitleModule.contrastPair(frame.palette)
                            if cue ~= lastCue or textHex ~= lastTextHex or boxHex ~= lastBoxHex then
                                local wallW, wallH = wall.getSize()
                                lastPatches = subtitleModule.patches(
                                    subtitleModule.layout(cue, wallW, wallH, subtitleScale),
                                    textHex, boxHex)
                                lastCue, lastTextHex, lastBoxHex = cue, textHex, boxHex
                            end
                            patches = lastPatches
                        else
                            lastCue, lastPatches = nil, nil
                        end
                    end
                    drawFrame(wall, frame, lastPalette, lastRows, patches)
                    state.elapsedSec = dueSec
                    framesPlayed = frameIndex

                    lastFrameMs = os.epoch("utc")

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

            phase = "playing"
            local playOk, playErr = pcall(function()
                parallel.waitForAll(
                    function()
                        decodeModule.decode(file, handlers)
                        cumulativeSec = cumulativeSec + framesPlayed / fps
                        decodeFinished = true
                        os.queueEvent("kx_audio_wake")
                    end,
                    function() -- audio dispatcher: drains the queue, fans each chunk out
                        -- Nothing feeds this queue when audio is a separate
                        -- stream, so it would sit blocked on an event that
                        -- never comes until decoding happens to end. One less
                        -- coroutine that can hold up the chunk boundary.
                        if hasSeparateAudio then return end
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
                                elseif a == keys.t then action = "subtitles"
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
                            elseif action == "subtitles" then
                                subtitlesOn = not subtitlesOn
                                -- The rows the box covered still hold its cells
                                -- in the row cache, and the video underneath may
                                -- not have changed there, so nothing would
                                -- repaint them. Dropping the cache forces the
                                -- next frame to redraw every row.
                                for y in pairs(lastRows) do lastRows[y] = nil end
                                lastCue, lastPatches = nil, nil
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

            phase = "chunk end"
            -- NOT stopped when audio is a separate stream: those same speakers
            -- are mid-way through playing the continuous soundtrack, and
            -- stopping them here would cut it at every chunk boundary (and can
            -- leave the audio coroutine waiting for a speaker_audio_empty that
            -- never arrives, because the buffer was discarded rather than
            -- played out). Only the old interleaved path needs this.
            if not hasSeparateAudio then
                for _, speaker in ipairs(speakers) do pcall(speaker.stop) end
            end
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
        videoDone = true
    end

    -- Redraws the computer's own screen on a timer of its own, rather than
    -- from inside the frame handler. Previously the only thing that drew the
    -- controls was onVideoFrame, so anything that stopped decoding also froze
    -- the display -- and a frozen screen looks identical whether playback has
    -- deadlocked, stalled on a download, or simply ended. This separates
    -- "what is on screen" from "is decoding running", and reports the phase
    -- and how long it has been since the last frame, so a stall names itself.
    local function statusLoop()
        while not state.stopRequested and not videoDone do
            -- Nothing decodes while paused, so lastFrameMs stops moving and
            -- a pause would otherwise be reported as a freeze.
            -- An audio failure is silent by nature, so it has to be said out
            -- loud or it just looks like the speakers stopped working.
            if audioError then phase = "GARSAS NUTRUKO" end
            local stalledMs = state.paused and 0 or (os.epoch("utc") - lastFrameMs)
            drawControls(screen, state, entry, entry.durationSec or 0, {
                driftSec = hasSeparateAudio and (state.elapsedSec - audioElapsedSec) or 0,
                bufSec = hasSeparateAudio and math.max(0, audioQueuedSec - audioElapsedSec) or 0,
                phase = phase,
                chunk = currentChunk,
                chunkCount = #entry.chunks,
                stalledSec = stalledMs / 1000,
            })
            _G.MOVCCTWX_STATUS = {
                screen = "video",
                name = entry.name,
                paused = state.paused,
                elapsedSec = state.elapsedSec,
                volumePct = math.floor(state.volume / state.maxVolume * 100 + 0.5),
            }
            os.sleep(0.5)
        end
    end

    -- pcall'd so the speakers get silenced even when playback exits by
    -- error -- notably [q], which raises "Terminated" to unwind all the way
    -- out of the menus.
    -- Each branch is individually pcall'd. Only the video loop is allowed to
    -- end playback: an error anywhere in waitForAll propagates out of ALL of
    -- them, so without this a transient http failure while fetching audio, or
    -- one bad draw in the status line, closed the video outright. Confirmed
    -- in-game as playback simply disappearing mid-video.
    local ranOk, runErr = pcall(parallel.waitForAll,
        videoLoop,
        function()
            local ok, err = pcall(streamAudio)
            if not ok then audioError = tostring(err) end
        end,
        function()
            -- Only decoration; never a reason to stop.
            pcall(statusLoop)
        end)

    -- Blanking the wall must never be what takes the program down. A monitor
    -- broken off its network mid-video makes every call on the wrapped
    -- peripheral throw, and this runs on the way OUT of playback -- including
    -- on the error path, where an unguarded throw here would replace whatever
    -- actually went wrong with a peripheral error. A monitor block has been
    -- physically broken on this build before, so this is not hypothetical.
    local function clearWall()
        pcall(function()
            wall.setBackgroundColor(colors.black)
            wall.clear()
        end)
    end

    _G.MOVCCTWX_WALL_BUSY = false

    -- Stopping playback has to DISCARD what the speakers are holding, not
    -- just stop supplying them. There is up to AUDIO_BUFFER_TARGET_SEC of
    -- audio queued ahead at any moment, so without this the soundtrack
    -- carried on for a couple of seconds after quitting, over whatever menu
    -- had already come back up.
    for _, speaker in ipairs(speakers) do pcall(speaker.stop) end

    if not ranOk then
        clearWall()
        screen.setBackgroundColor(colors.black)
        screen.setTextColor(colors.white)
        screen.clear()
        _G.MOVCCTWX_STATUS = { screen = "video_menu" }
        -- Ctrl+T has to keep unwinding all the way out, as it would anywhere
        -- else. Anything else is reported and handed back to the menu, rather
        -- than thrown at whatever called us -- a video failing is not a reason
        -- for the whole program to fall over.
        if tostring(runErr):find("Terminated") then error(runErr, 0) end
        drawStatus(screen, "Playback error: " .. tostring(runErr))
        os.sleep(2)
        return "done"
    end

    clearWall()
    screen.setBackgroundColor(colors.black)
    screen.setTextColor(colors.white)
    screen.clear()
    -- Hand the remote a status that says playback is OVER. Without this the
    -- last frame's status stayed on _G.MOVCCTWX_STATUS with screen="video",
    -- so the pocket kept polling, kept being told a video was playing, and
    -- sat on its transport screen showing a frozen final timestamp with no
    -- way back except Back. musicplayer.lua has always done this on exit;
    -- videoplayer never did.
    _G.MOVCCTWX_STATUS = { screen = "video_menu" }
    return result
end

return M
