-- musicplayer.lua -- touch-driven music library + player, built on Basalt.
--
-- This replaced an earlier version ported almost verbatim from the
-- original Pocket-Computer jukebox (music.lua), which was keyboard-only
-- (Up/Down/Enter/F5, a typed search box). That's unusable on an
-- installation meant to be operated by touching a wall-mounted monitor --
-- there's no keyboard there at all -- so this is a full rewrite: a
-- paginated, tappable song list (no search box, since there's nothing to
-- type on) and a Now Playing screen with Play/Pause/Stop/Volume buttons
-- instead of key bindings.

local dfpwm = require("cc.audio.dfpwm")
local basalt = require("basalt")
local settings = require("settings")

local M = {}

local function buildManifestUrls(config)
    local urls = {}
    for _, lib in ipairs(config.MUSIC_LIBRARIES) do
        table.insert(urls, ("https://raw.githubusercontent.com/%s/%s/%s/songs.json")
            :format(config.GITHUB_USER, lib.repo, lib.branch))
    end
    return urls
end

local function fetchSongs(manifestUrls)
    local songs = {}
    local errors = {}
    for _, manifestUrl in ipairs(manifestUrls) do
        local cacheBustUrl = manifestUrl .. "?t=" .. tostring(os.epoch("utc"))
        local response, err, failingResponse = http.get(cacheBustUrl)
        if not response then
            local code = failingResponse and failingResponse.getResponseCode
                and select(1, failingResponse.getResponseCode())
            if code ~= 404 then
                table.insert(errors, manifestUrl .. " -> " .. tostring(err))
            end
        else
            local body = response.readAll()
            response.close()
            local parsed = textutils.unserialiseJSON(body)
            if type(parsed) == "table" then
                for _, song in ipairs(parsed) do table.insert(songs, song) end
            else
                table.insert(errors, manifestUrl .. " -> invalid JSON")
            end
        end
    end
    return songs, errors
end

-- Wipes the physical screen AND resets Basalt's render cache, before
-- rebuilding a screen's widgets. clearFrameChildren alone is NOT enough:
-- Basalt only repaints cells it believes changed, judged against what IT
-- last drew. Two consecutive songs' Now Playing screens are nearly
-- identical (same title bar, same panel, same button labels in the same
-- places), so Basalt skips repainting all of that -- but the physical
-- screen was blanked in between, leaving those cells empty. The result:
-- only the parts that genuinely differ between songs (the song name, the
-- ticking timer) actually get drawn, and everything else vanishes --
-- confirmed in-game as exactly this, on the second song of a playlist.
-- setTerm() is what resets the cache so the next draw() treats every cell
-- as dirty. This is the same fix the original Komanda X project used for
-- the same class of bug (see its hub.lua notes on leftover/skipped
-- repaints).
local function resetScreen(mon, frame)
    mon.setBackgroundColor(colors.black)
    mon.clear()
    frame:setTerm(mon)
end

-- Same pattern as hub.lua's clearFrameChildren -- see the comment there for
-- why frames get reused instead of recreated (createFrame() never gets
-- cleaned up, and its click router keeps dispatching to every frame it's
-- ever created, forever).
local function clearFrameChildren(frame)
    local children = rawget(frame, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then frame:removeChild(child) end
    end
end

local function formatTime(seconds)
    seconds = math.floor(seconds)
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
end

-- Use instead of plain sleep(seconds) inside playSong()'s background
-- coroutines (wall-viz, status-tick). Basalt's `schedules` table is a
-- single list shared across EVERY basalt.run() call, never cleared
-- between them -- a coroutine suspended in plain sleep() only wakes on
-- its own specific timer, so if a song ends mid-sleep, that coroutine
-- stays dormant in schedules (not yet aware it should stop) until its
-- timer happens to fire, which can land during a LATER song's
-- basalt.run() session instead of this one. If that coroutine's
-- post-loop cleanup does something global (wall-viz's does: it blacks
-- out and clears the WHOLE wall on exit), that cleanup then runs in the
-- middle of the NEXT song's own wall output -- confirmed in-game as
-- exactly this, during playlist auto-advance (a black band torn across
-- an otherwise-correct plasma frame). Waking on "music_control" too
-- (queued by every stop/pause path) means the coroutine notices and
-- finishes essentially the same tick playback actually stops, not up to
-- `seconds` later.
local function waitTick(seconds)
    local timerId = os.startTimer(seconds)
    while true do
        local event, id = os.pullEvent()
        if (event == "timer" and id == timerId) or event == "music_control" then return end
    end
end

-- Use instead of basalt.schedule() everywhere in this file. Plain sleep()
-- (an os.sleep alias) is just os.pullEvent("timer") under the hood, which
-- THROWS on a terminate event no matter what filter it's given, and
-- Basalt resumes scheduled coroutines in reverse registration order -- so
-- any coroutine using plain sleep() could throw first and abort that
-- whole resume pass before hub.lua's terminate watcher ever got a turn.
-- Wrapping every scheduled function's body in its own pcall means each
-- one independently notices its own termination and cooperatively sets
-- the shared flag + stops, regardless of Basalt's resume order. See the
-- matching note in hub.lua next to safeSchedule there.
local function safeSchedule(fn)
    return basalt.schedule(function()
        local ok, err = pcall(fn)
        if not ok then
            if tostring(err):find("Terminated") then
                _G.MOVCCTWX_TERMINATED = true
            end
            pcall(basalt.stop)
        end
    end)
end

-- `frame` is ONE Basalt frame shared across the whole hub (hub.lua creates
-- it once via basalt.createFrame(mon) and passes it into every screen).
-- Two separate frame objects wrapping the same monitor each keep their
-- own independent redraw buffer -- confirmed in-game: using a separate
-- libraryFrame and nowPlayingFrame rendered as "a complete mess" that
-- "overwrites to black screen" when switching between the library and Now
-- Playing, since switching frames doesn't repaint over the other frame's
-- leftover pixels. One shared frame, cleared and rebuilt for whichever
-- screen is active, avoids that entirely.
-- startSongName: optional -- when given, jumps straight into playing that
-- song (matched by exact name against the merged library) instead of
-- opening the library screen first, for remote "play this specific song"
-- commands. Falls through to the normal library screen if no match.
-- wall: the 12-monitor wall (see wall.lua), used for the full-screen
-- equalizer while a song plays. Text/controls always stay on `mon`
-- (the computer's own screen) regardless of whether a wall was given.
-- startWithPlaylist: optional -- when true, immediately plays through the
-- current playlist (see below) instead of opening the library screen
-- first, for a remote "play_playlist" command. Falls through to the
-- normal library screen if the playlist is empty.
function M.run(mon, speakers, config, frame, startSongName, wall, startWithPlaylist)
    -- Claim the wall for the whole session, so the menu's idle clock cannot
    -- draw over the visuals if its coroutine outlives the menu -- Basalt's
    -- schedules table is module-level and never cleared, so that is a real
    -- possibility rather than a theoretical one.
    _G.MOVCCTWX_WALL_BUSY = true
    local w, h = mon.getSize()
    local manifestUrls = buildManifestUrls(config)

    -- Declared here (not down by the library loop) so playSong()'s closure
    -- below can set it directly -- an idle timeout firing WHILE a song is
    -- playing needs to force all the way out to the main menu, not just
    -- back to the library screen.
    local exitReason = nil

    -- The playlist: a table of song tables (same shape as entries from
    -- songs.json), built up by tapping songs on the "Add to Playlist"
    -- screen OR by a remote playlist_add command. This is a SHARED,
    -- program-lifetime table (_G.MOVCCTWX_PLAYLIST, initialized once in
    -- startup.lua) -- not a fresh local like the old single-session
    -- version -- so a song added remotely while sitting on the main menu
    -- (nothing "playlist" even open yet) is still there next time Music
    -- is entered, and the computer's own Playlist screen and remote
    -- commands are always looking at the exact same list. There's still
    -- no persistence to disk -- it resets if the whole computer reboots.
    local playlist = _G.MOVCCTWX_PLAYLIST

    -- Idle watcher: reusable, but scheduled FRESH inside whichever
    -- basalt.run() session is actually pumping events (once at the top of
    -- the library loop, once at the top of playSong), rather than trying to
    -- keep ONE watcher coroutine alive across two separate basalt.run()
    -- calls. A single coroutine scheduled once used to sit suspended
    -- between the library's run() and playSong's own run() -- Basalt's
    -- `schedules` table is never cleared between run() calls so it wasn't
    -- literally dead, but it only gets resumed (and can only make forward
    -- progress) while SOME run() loop is actively dispatching events, and a
    -- long-idle Now Playing screen with nothing else scheduling frequent
    -- events made that unreliable in practice (confirmed in-game: idle
    -- timeout wasn't firing while a song was left playing). Rescheduling
    -- fresh inside the run() that's actually live removes that ambiguity
    -- entirely. `lastActivityMs` is a shared upvalue so activity carries
    -- over between the library and Now Playing without resetting the clock
    -- just because the screen changed.
    local lastActivityMs = os.epoch("utc")
    -- Bumped every time startIdleWatcher() is called (once per screen
    -- switch -- library, Now Playing, playlist, add-songs). Each watcher
    -- captures its OWN generation number and checks whether a newer one
    -- has since taken over on every event; without this, every screen
    -- switch schedules another watcher without ever stopping the previous
    -- one -- Basalt's shared `schedules` table keeps servicing all of them
    -- fine (they don't deadlock/leak the way hub.lua's video-menu watcher
    -- could -- see the matching note there), but over a long session with
    -- many songs played, they'd pile up as pure redundant overhead,
    -- literally identical work done over and over on every single future
    -- event for the rest of the session. Capping it to effectively one
    -- live watcher at a time avoids that slow accumulation.
    -- Also checked below alongside the generation number -- covers the ONE
    -- case the generation counter alone doesn't: the very LAST watcher
    -- started (whichever screen the player exits M.run() from) never gets
    -- superseded by a newer one, since M.run() just returns to hub.lua
    -- instead of switching to another screen of its own. Without this, that
    -- last watcher would keep running (and could eventually call
    -- basalt.stop() on whatever UNRELATED screen -- main menu, video menu
    -- -- happens to be active by the time its idle timeout elapses, since
    -- Basalt's schedules table is shared across the whole hub, not scoped
    -- to this one module).
    local idleWatcherGen = 0
    local function startIdleWatcher(onIdle)
        idleWatcherGen = idleWatcherGen + 1
        local myGen = idleWatcherGen
        safeSchedule(function()
            local timeoutMs = (config.MUSIC_MENU_IDLE_TIMEOUT_SEC or 300) * 1000
            while myGen == idleWatcherGen and not exitReason do
                local timerId = os.startTimer(5)
                repeat
                    local event, p1 = os.pullEventRaw()
                    if event == "terminate" then
                        _G.MOVCCTWX_TERMINATED = true
                        for _, spk in ipairs(speakers) do pcall(spk.stop) end
                        basalt.stop()
                        return
                    elseif event == "monitor_touch" or event == "key" or event == "char" or event == "mouse_click" then
                        lastActivityMs = os.epoch("utc")
                    end
                until (event == "timer" and p1 == timerId) or myGen ~= idleWatcherGen or exitReason
                if myGen ~= idleWatcherGen or exitReason then return end
                if os.epoch("utc") - lastActivityMs > timeoutMs then
                    onIdle()
                    return
                end
            end
        end)
    end

    -- ==== Now Playing screen ====
    -- Split by design: the computer's own screen shows just text (song
    -- name, playing/paused + elapsed time, volume) and the transport
    -- buttons -- no visuals. The big visual instead renders full-screen
    -- across the whole 12-monitor wall (see the wall-viz coroutine below),
    -- using wall.lua's row-blit (the same mechanism videoplayer.lua uses
    -- for video frames) so it correctly spans all 12 monitors as one
    -- surface, not just one tile. See wallviz.lua for the actual visual
    -- styles (bars/wave/3 plasma variants) -- it starts on a style picked
    -- from the song name, then rotates to the next one roughly once a
    -- minute (see the wall-viz coroutine below).
    local wallviz = require("wallviz")

    -- backLabel: text for the footer button that returns without finishing
    -- the song (defaults to "Back to Library"; playlist playback passes
    -- "Back to Playlist" instead so the label matches where it actually
    -- goes back to). Returns "finished" if the song played to the end on
    -- its own, or "stopped" if the user hit Stop/the back button -- the
    -- playlist-playback loop below uses this to decide whether to
    -- auto-advance to the next track or stop the whole playlist.
    local function playSong(song, backLabel)
        backLabel = backLabel or "Back to Library"
        local f = frame

        -- Retires whichever idle watcher was running on the screen that
        -- led into this song (library or playlist) WITHOUT starting a
        -- replacement -- playback itself deliberately never gets its own
        -- idle watcher (see the note by basalt.run() below). Bumping the
        -- generation is enough on its own to make that old watcher notice
        -- a mismatch and exit on its next event. Missing this was a real
        -- bug: that watcher's own 300s timer kept running through playback
        -- untouched, and once it fired it called basalt.stop() -- which
        -- only ends the CURRENT basalt.run() (kicking the state machine
        -- back to the main menu), it has no idea the DFPWM streaming
        -- coroutine even exists, let alone that it should stop too. Result
        -- (confirmed in-game): thrown back to the main menu mid-song while
        -- the audio just kept on playing regardless.
        idleWatcherGen = idleWatcherGen + 1

        -- Reassigned by drawNowPlaying() -- read by the status-tick loop
        -- below (playPauseBtn's text) and the remote handler above it.
        -- centerWidth is also set there (the left portion of the screen,
        -- once the playlist sidebar claims the right side) -- falls back
        -- to the full width until drawNowPlaying() has run once.
        local nameLabel, statusLabel, volLabel, playPauseBtn, statusY
        local centerWidth = w

        local function centerLabel(label, y, text, color)
            text = text:sub(1, centerWidth)
            label:setText(text)
            if color then label:setForeground(color) end
            label:setPosition(math.max(1, math.floor((centerWidth - #text) / 2) + 1), y)
        end

        -- Volume persists across songs/sessions (a saved settings file, not
        -- an in-memory default) -- it used to reset to config.DEFAULT_VOLUME
        -- every single time, which was loud and annoying on a public
        -- installation.
        local savedSettings = settings.load()
        local state = {
            paused = false,
            stopRequested = false,
            -- Real wall-clock elapsed time (like the video player's
            -- os.epoch-paced clock), NOT inferred from DFPWM byte count.
            -- The old version divided bytes-read-so-far by 6000 (the
            -- DFPWM-at-48kHz byte rate) -- mathematically reasonable, but
            -- it counted bytes as soon as they were DOWNLOADED, not as
            -- they were actually PLAYED, so it could run ahead of (or
            -- behind) what was actually audible rather than tracking real
            -- time. elapsedMs only advances while actually playing
            -- (paused time doesn't count), accumulated in small real
            -- deltas by the status-label tick below.
            elapsedMs = 0,
            lastTickMs = os.epoch("utc"),
            volume = savedSettings.musicVolume or config.DEFAULT_VOLUME,
        }
        local playReason = "finished" -- overwritten to "stopped" by Stop/back below

        local updateVolLabel -- defined below, referenced by drawNowPlaying
        local adjustVolume -- setVolume(delta) is a FRACTION of MAX_VOLUME (e.g. 0.05 = "+5%")

        -- Computer screen: text + transport controls only, no visuals --
        -- the equalizer lives on the wall instead (wallViz below). One
        -- fixed layout, drawn once (no immersive toggle -- that was the
        -- old single-screen version's way of making room for a bigger
        -- equalizer, which doesn't apply once the equalizer isn't on this
        -- screen at all).
        local function drawNowPlaying()
            resetScreen(mon, frame)
            clearFrameChildren(frame)

            f:addLabel()
                :setText((" NOW PLAYING "):sub(1, w))
                :setSize(w, 1)
                :setPosition(1, 1)
                :setForeground(colors.lime)
                :setBackground(colors.gray)

            local buttonW = math.min(math.floor((w - 6) / 2), 16)
            local nameY = 3
            statusY = nameY + 2
            local volY = statusY + 2
            local btnRow1Y = volY + 3
            local btnRow2Y = btnRow1Y + 2
            local btnRow3Y = btnRow2Y + 2
            local btnRow4Y = btnRow3Y + 2

            -- Playlist sidebar on the right, in whatever room is left over
            -- once the controls (centered within the LEFT portion now,
            -- not the full width) are laid out -- only on a screen wide
            -- enough for it to be readable (>=8 cols); a narrow screen
            -- just skips it rather than cramming in unreadable text.
            local leftW = math.max(buttonW * 2 + 4, math.floor(w * 0.62))
            local rightX = leftW + 2
            local rightW = w - rightX + 1
            local showPlaylist = rightW >= 8
            local bx = math.max(1, math.floor((leftW - (buttonW * 2 + 2)) / 2) + 1)
            centerWidth = showPlaylist and leftW or w

            if showPlaylist then
                -- Solid gray panel behind the whole sidebar, not just
                -- individual text rows on the same black as everything
                -- else -- one full-width blank label per row, drawn
                -- first so the text labels below sit on top of it.
                for row = 1, h do
                    f:addLabel():setText((" "):rep(rightW)):setSize(rightW, 1)
                        :setPosition(rightX, row):setBackground(colors.gray)
                end

                -- Text starts 1 column in from the panel's own left edge,
                -- not flush against it -- was reading as "hugging the
                -- wall" with zero left margin.
                local textX, textW = rightX + 1, rightW - 1
                f:addLabel():setText(("PLAYLIST (%d)"):format(#playlist):sub(1, textW)):setSize(textW, 1)
                    :setPosition(textX, 1):setForeground(colors.lime):setBackground(colors.gray)
                if #playlist == 0 then
                    f:addLabel():setText(("(empty)"):sub(1, textW)):setSize(textW, 1)
                        :setPosition(textX, 3):setForeground(colors.lightGray):setBackground(colors.gray)
                else
                    -- Rows 3..h-1 are available for entries (row 1 is the
                    -- header, row h is left as breathing room at the
                    -- bottom of the panel). If the playlist has more
                    -- songs than fit, the last visible row becomes a
                    -- "+N more" hint instead of silently cutting off with
                    -- no indication there's anything past what's shown --
                    -- there's no real scrolling here (the sidebar draws
                    -- once per song, not on a timer), so a hint is the
                    -- honest version of a scrollbar for a static list.
                    local capacity = math.max(1, h - 3)
                    local shown = math.min(#playlist, capacity)
                    local hasMore = #playlist > capacity
                    if hasMore then shown = capacity - 1 end
                    for i = 1, shown do
                        f:addLabel():setText(playlist[i].name:sub(1, textW)):setSize(textW, 1)
                            :setPosition(textX, 2 + i):setForeground(colors.white):setBackground(colors.gray)
                    end
                    if hasMore then
                        f:addLabel():setText(("+%d more"):format(#playlist - shown):sub(1, textW)):setSize(textW, 1)
                            :setPosition(textX, 2 + shown + 1):setForeground(colors.lightGray):setBackground(colors.gray)
                    end
                end
            end

            nameLabel = f:addLabel():setForeground(colors.white):setBackground(colors.black)
            centerLabel(nameLabel, nameY, song.name:sub(1, w - 2))
            statusLabel = f:addLabel():setForeground(colors.white):setBackground(colors.black)
            centerLabel(statusLabel, statusY, "Loading...")
            volLabel = f:addLabel():setForeground(colors.lime):setBackground(colors.black)

            function updateVolLabel()
                local pct = math.floor(state.volume / config.MAX_VOLUME * 100 + 0.5)
                centerLabel(volLabel, volY, ("Volume: %d%%"):format(pct))
            end
            updateVolLabel()

            function adjustVolume(deltaFraction)
                local step = deltaFraction * config.MAX_VOLUME
                state.volume = math.max(0, math.min(config.MAX_VOLUME, state.volume + step))
                updateVolLabel()
                savedSettings.musicVolume = state.volume
                settings.save(savedSettings)
            end

            playPauseBtn = f:addButton()
                :setText(state.paused and "Play" or "Pause")
                :setPosition(bx, btnRow1Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function(self)
                    state.paused = not state.paused
                    self:setText(state.paused and "Play" or "Pause")
                    os.queueEvent("music_control")
                end)

            f:addButton()
                :setText("Stop")
                :setPosition(bx + buttonW + 2, btnRow1Y)
                :setSize(buttonW, 1)
                :setBackground(colors.red)
                :setForeground(colors.white)
                :onClick(function()
                    playReason = "stopped"
                    state.stopRequested = true
                    os.queueEvent("music_control")
                end)

            f:addButton()
                :setText("Vol -1%")
                :setPosition(bx, btnRow2Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(-0.01) end)

            f:addButton()
                :setText("Vol +1%")
                :setPosition(bx + buttonW + 2, btnRow2Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(0.01) end)

            f:addButton()
                :setText("Vol -5%")
                :setPosition(bx, btnRow3Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(-0.05) end)

            f:addButton()
                :setText("Vol +5%")
                :setPosition(bx + buttonW + 2, btnRow3Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(0.05) end)

            f:addButton()
                :setText("Vol -20%")
                :setPosition(bx, btnRow4Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(-0.20) end)

            f:addButton()
                :setText("Vol +20%")
                :setPosition(bx + buttonW + 2, btnRow4Y)
                :setSize(buttonW, 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function() adjustVolume(0.20) end)

            f:addButton()
                :setText(backLabel)
                :setPosition(2, h)
                :setSize(math.min(w - 2, 20), 1)
                :setBackground(colors.gray)
                :setForeground(colors.lime)
                :onClick(function()
                    playReason = "stopped"
                    state.stopRequested = true
                    os.queueEvent("music_control")
                end)

            f:draw()
        end

        drawNowPlaying()

        -- Full-screen equalizer on the monitor wall, independent of the
        -- computer's own Basalt screen above -- runs for as long as this
        -- song plays. `wall` is nil if M.run() was called without one
        -- (shouldn't happen via brain/startup.lua's normal flow, but this
        -- degrades to "no wall visuals" instead of erroring if it ever is).
        if wall then
            safeSchedule(function()
                local wallW, wallH = wall.getSize()
                -- Starts on a style picked deterministically from the song
                -- name (so a given song still always OPENS the same way),
                -- then rotates to the next one roughly once a minute of
                -- actual (non-paused) playback -- a long song doesn't just
                -- sit on one look the whole time. STYLE_SWITCH_MS is wall
                -- time, not paused-aware -- if paused for a long stretch,
                -- it can switch immediately on resume; not worth the extra
                -- bookkeeping to track paused-adjusted duration for a
                -- purely decorative effect.
                local STYLE_SWITCH_MS = 60 * 1000
                local styleIndex = wallviz.startIndexForSong(song.name)
                local style = wallviz.new(styleIndex)
                style.init(wallW, wallH)
                wall.setBackgroundColor(colors.black)
                wall.clear()
                wallviz.resetCache() -- the clear wiped every row; see resetCache
                local nextSwitchMs = os.epoch("utc") + STYLE_SWITCH_MS
                local lastFrameMs = os.epoch("utc")

                -- Redraw interval scales with how big the wall actually
                -- is, instead of one fixed rate. CC's Lua is
                -- single-threaded: this coroutine, the DFPWM streaming
                -- loop and the speaker dispatcher all share one CPU
                -- budget between yields, and a redraw's cost is
                -- proportional to the wall's cell count. 0.1s at the
                -- default size already starved the audio coroutine badly
                -- enough to be audible; at WALL_TEXT_SCALE 0.5 the same
                -- wall has FOUR times the cells, so a fixed rate that's
                -- fine at one scale is far too aggressive at the other.
                -- Backing off automatically means changing the scale
                -- doesn't silently reintroduce audio stutter.
                -- The actual wall (4x3 monitors at scale 1.0 = 324x120 =
                -- 38,880 cells) gets the fastest tier. 0.1s is affordable
                -- now that rows are diffed (unchanged rows cost nothing)
                -- and the audio decodes a chunk ahead, so the visuals no
                -- longer have to be starved to keep sound clean. Only a
                -- much bigger wall (scale 0.5 quadruples this to 155,520)
                -- needs to back off.
                --
                -- The styles animate by REAL TIME (they're handed dt
                -- below), not by a fixed step per frame, so changing these
                -- numbers changes smoothness without changing how fast the
                -- animation actually moves.
                local cells = wallW * wallH
                local frameInterval = (cells <= 50000 and 0.1)
                    or (cells <= 120000 and 0.2)
                    or 0.35
                while not state.stopRequested do
                    if not state.paused and os.epoch("utc") >= nextSwitchMs then
                        styleIndex = styleIndex + 1
                        style = wallviz.new(styleIndex)
                        style.init(wallW, wallH)
                        wall.setBackgroundColor(colors.black)
                        wall.clear()
                        wallviz.resetCache() -- the clear wiped every row; see resetCache
                        nextSwitchMs = os.epoch("utc") + STYLE_SWITCH_MS
                    end
                    -- Real elapsed time since the last frame, not the
                    -- nominal interval -- if a frame took longer than
                    -- planned (busy tick), the animation advances by the
                    -- time that actually passed instead of stuttering.
                    local nowMs = os.epoch("utc")
                    local dt = math.min(0.5, (nowMs - lastFrameMs) / 1000)
                    lastFrameMs = nowMs

                    style.step(wallW, wallH, state.paused, dt)
                    if not state.paused then style.draw(wall, wallW, wallH) end
                    -- waitTick, not plain sleep() -- see its own comment
                    -- for why: this coroutine needs to notice
                    -- state.stopRequested THE SAME TICK it's set, not up
                    -- to 0.15s later, or it can survive into the NEXT
                    -- song's basalt.run() session and wipe ITS wall
                    -- output mid-playback (confirmed in-game during
                    -- playlist auto-advance).
                    waitTick(frameInterval)
                end
                wall.setBackgroundColor(colors.black)
                wall.clear()
                wallviz.resetCache() -- the clear wiped every row; see resetCache
            end)
        end

        -- Remote commands from the pocket computer (relayed as
        -- "movcctwx_remote_action" by remote.lua, already allowlist-checked
        -- before it's ever queued) -- same action names and the same
        -- state/adjustVolume the on-screen buttons use, so a remote
        -- playpause/stop/volume command works identically to tapping the
        -- button.
        safeSchedule(function()
            -- Unfiltered pullEvent, not os.pullEvent("movcctwx_remote_action")
            -- -- a filtered pullEvent only ever wakes for that ONE event
            -- type, so if this song ends WITHOUT a remote command ever
            -- arriving (the normal case), this coroutine would never get
            -- resumed again at all, staying suspended in Basalt's
            -- schedules table indefinitely and only noticing
            -- state.stopRequested (and self-terminating) whenever some
            -- FUTURE remote command happens to arrive -- possibly during
            -- a LATER song, where its stale `action` handling could fire
            -- against the wrong song's state. Reacting to "music_control"
            -- (queued by every stop/pause path below) closes that gap.
            while not state.stopRequested do
                local event, action = os.pullEvent()
                if event == "movcctwx_remote_action" then
                    -- startup.lua's remoteMenuWatcher treats these 4 as
                    -- "go somewhere else" -- from in here that's
                    -- indistinguishable from a plain stop: halt this
                    -- song, hand control back to M.run()'s outer loop
                    -- (guarded below by MOVCCTWX_REMOTE_PENDING), which
                    -- returns up to mainLoop, which then honors the real
                    -- target.
                    if action == "open_video_menu" or action == "open_music_menu"
                        or action == "play_video" or action == "play_music" then
                        action = "stop"
                    end
                    if action == "playpause" then
                        state.paused = not state.paused
                        if playPauseBtn then playPauseBtn:setText(state.paused and "Play" or "Pause") end
                        os.queueEvent("music_control")
                    elseif action == "stop" then
                        playReason = "stopped"
                        state.stopRequested = true
                        os.queueEvent("music_control")
                    elseif action == "vol-1" then adjustVolume(-0.01)
                    elseif action == "vol+1" then adjustVolume(0.01)
                    elseif action == "vol-10" then adjustVolume(-0.10)
                    elseif action == "vol+10" then adjustVolume(0.10)
                    end
                end
                -- "music_control" (or any other event) just loops back
                -- around to re-check state.stopRequested -- see this
                -- coroutine's opening comment for why that alone matters.
            end
        end)

        safeSchedule(function()
            local response, err = http.get(song.url, nil, true)
            if not response then
                centerLabel(statusLabel, statusY, "ERROR: " .. tostring(err))
                sleep(1.5)
                state.stopRequested = true
                os.queueEvent("music_control") -- see the natural-end path's comment on why this matters
                basalt.stop()
                return
            end

            local decoder = dfpwm.make_decoder()
            local chunkSize = 16 * 1024

            -- How long to wait for a speaker to report room before treating it
            -- as gone. Generous on purpose: a merely BUSY speaker was being
            -- given up on at 3s and skipped, which is what broke multi-speaker
            -- sync. A genuinely dead one still gets dropped, just not a slow
            -- one on a laggy tick.
            local SPEAKER_ACK_TIMEOUT_SEC = 10

            -- Speakers that stopped acknowledging. Indexes into `speakers`.
            local deadSpeakers = {}

            -- Decode-ahead (double buffering). The old loop was strictly
            -- sequential: push a buffer, WAIT for speaker_audio_empty,
            -- then read+decode the next chunk, then push. But
            -- speaker_audio_empty fires when the speaker has already
            -- DRAINED -- so the decode (16KB of pure-Lua DFPWM work, not
            -- cheap) happened while the speaker had nothing left to play.
            -- That silence is exactly the "audio cuts for a split second"
            -- report. Now the NEXT chunk is decoded as a parallel branch
            -- alongside the push/wait for the CURRENT one: the decode is
            -- CPU-bound and never yields, so it completes while the
            -- speaker branch is blocked waiting for its ack -- meaning
            -- the next buffer is already sitting ready the instant the
            -- speaker asks for more.
            local function readNext()
                local c = response.read(chunkSize)
                if not c then return nil end
                return decoder(c)
            end

            local buffer = readNext()
            -- Held across a pause so the block that was interrupted can be
            -- replayed rather than lost, and so the already-decoded next block
            -- is not thrown away and read twice.
            local pendingNext = nil
            local pausedMidBlock = false

            while not state.stopRequested and buffer do
                if state.paused then
                    -- Silence NOW. Pausing has to discard what the speakers
                    -- are holding, not merely stop supplying them: playAudio
                    -- queues a whole block ahead, which at this size is 2.7
                    -- seconds of music that would otherwise keep playing after
                    -- you pressed pause.
                    for _, spk in ipairs(speakers) do pcall(spk.stop) end
                end
                while state.paused and not state.stopRequested do
                    os.pullEvent("music_control")
                end
                if state.stopRequested then break end

                -- Dispatch to every speaker IN PARALLEL, not one at a time.
                -- The old version looped speakers sequentially, each
                -- blocking (potentially waiting on speaker_audio_empty)
                -- before the NEXT speaker even got this chunk -- fine with
                -- a couple of speakers, but the delay compounds with every
                -- speaker added, and confirmed in-game as real desync once
                -- more speakers joined ("not every speaker sound the
                -- same and gets delayed"). Same fix already applied to
                -- video playback's audio dispatch: fan out with
                -- parallel.waitForAll, each speaker waiting only for ITS
                -- OWN ack (filtered by peripheral name -- an unfiltered
                -- wait could resume on a DIFFERENT speaker's empty event
                -- and retry too early), with a 3s timeout so one dead
                -- speaker among many can't stall the whole song.
                pausedMidBlock = false
                -- Already decoded before the pause -- reusing it avoids
                -- reading the same bytes twice, which would skip a block.
                local nextBuffer = pendingNext
                if #speakers > 0 then
                    local funcs = {}
                    for speakerIndex, speaker in ipairs(speakers) do
                        funcs[#funcs + 1] = function()
                            if deadSpeakers[speakerIndex] then return end
                            if state.paused then pausedMidBlock = true return end
                            while not state.stopRequested and not state.paused do
                                if speaker.playAudio(buffer, state.volume) then return end
                                -- Waits for THIS speaker's own ack (an
                                -- unfiltered wait could resume on a different
                                -- speaker's empty event and retry too early),
                                -- but also wakes on music_control -- otherwise
                                -- a pause goes unnoticed until the speaker has
                                -- played out its whole buffer, which is 2.7
                                -- seconds of audio at this block size. That is
                                -- the pause "not reacting" you feel.
                                local timerId = os.startTimer(SPEAKER_ACK_TIMEOUT_SEC)
                                local gaveUp = false
                                repeat
                                    local ev, a = os.pullEvent()
                                    if ev == "speaker_audio_empty" and a == peripheral.getName(speaker) then
                                        break
                                    elseif ev == "music_control" then
                                        break
                                    elseif ev == "timer" and a == timerId then
                                        gaveUp = true
                                        break
                                    end
                                until state.stopRequested
                                if gaveUp then
                                    -- Drop this speaker for the rest of the
                                    -- song rather than skipping one buffer on
                                    -- it. Skipping was the old behaviour and it
                                    -- is what desynced them: that speaker loses
                                    -- a block the others played, so it runs
                                    -- permanently offset, and every further
                                    -- timeout widens the gap. Losing one
                                    -- speaker cleanly is far better than every
                                    -- speaker slowly drifting apart.
                                    deadSpeakers[speakerIndex] = true
                                    return
                                end
                                if state.stopRequested then return end
                                if state.paused then pausedMidBlock = true return end
                            end
                        end
                    end
                    -- Added LAST on purpose: the speaker branches above get
                    -- resumed first (so playAudio fires immediately), then
                    -- this one runs its decode while they're parked waiting
                    -- for their acks.
                    if not nextBuffer then
                        funcs[#funcs + 1] = function() nextBuffer = readNext() end
                    end
                    parallel.waitForAll(table.unpack(funcs))
                else
                    nextBuffer = nextBuffer or readNext()
                end

                if pausedMidBlock then
                    -- This block was cut off part-way through. Keep it and
                    -- play it again on resume: repeating a fraction of a
                    -- second is far less noticeable than dropping nearly
                    -- three seconds of the song out of the middle.
                    pendingNext = nextBuffer
                else
                    pendingNext = nil
                    buffer = nextBuffer
                end
            end

            response.close()
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            -- Set even on a NATURAL end (the song just finished, nobody
            -- pressed Stop) -- the wall-viz, remote-handler and status-tick
            -- coroutines above/below all loop on "not state.stopRequested",
            -- and without this they'd never notice the song ended and would
            -- leak: still suspended, still getting resumed on every future
            -- event for the rest of the session, the same class of bug
            -- fixed elsewhere in this project (see hub.lua's video-menu
            -- idle-watcher and this file's own idle-watcher generation
            -- counter).
            state.stopRequested = true
            -- Also queue "music_control" here, same as the explicit
            -- stop/pause paths do -- waitTick() (used by the wall-viz and
            -- status-tick coroutines) only wakes up EARLY when it hears
            -- this event; without it here, a NATURAL song end (nobody
            -- pressed Stop -- the common case during playlist
            -- auto-advance) left those coroutines to notice
            -- stopRequested only on their next slow regular timer tick,
            -- same race as before just for a different trigger. Missing
            -- this was the actual remaining cause of controls/playlist
            -- sidebar occasionally rendering wrong right after a playlist
            -- song finished on its own and the next one started.
            os.queueEvent("music_control")
            basalt.stop()
        end)

        safeSchedule(function()
            while not state.stopRequested do
                -- Real wall-clock elapsed time -- only advances while
                -- actually playing (a real delta each tick, so pausing
                -- genuinely freezes it instead of it drifting from
                -- inferred data rates). See the state table's comment
                -- above for why this replaced byte-count-based timing.
                local nowMs = os.epoch("utc")
                if not state.paused then
                    state.elapsedMs = state.elapsedMs + (nowMs - state.lastTickMs)
                end
                state.lastTickMs = nowMs

                centerLabel(statusLabel, statusY,
                    (state.paused and "|| PAUSED  " or "> PLAYING  ") .. formatTime(state.elapsedMs / 1000))
                if playPauseBtn then playPauseBtn:setText(state.paused and "Play" or "Pause") end

                -- Read by remote.lua and attached to every rednet ack it
                -- sends, so the pocket computer's transport screen can show
                -- live title/paused/elapsed/volume without a separate
                -- round trip.
                _G.MOVCCTWX_STATUS = {
                    screen = "music",
                    name = song.name,
                    paused = state.paused,
                    elapsedSec = state.elapsedMs / 1000,
                    volumePct = math.floor(state.volume / config.MAX_VOLUME * 100 + 0.5),
                }

                waitTick(0.3) -- see waitTick's own comment
            end
        end)

        -- Deliberately NOT calling startIdleWatcher() here. Idle timeout
        -- means "sitting on a menu, not doing anything" -- while a song
        -- (or a whole playlist) is actively playing, the system genuinely
        -- IS doing something even if nobody's touched the screen in a
        -- while; that's normal listening, not idle. Confirmed in-game as a
        -- real problem: playback got kicked back to the main menu mid-song
        -- purely because nobody had touched anything, cutting off music
        -- that was working exactly as intended. The idle watcher still
        -- applies normally on the library/playlist/add-songs SELECTION
        -- screens below (where sitting there really is doing nothing) --
        -- it resumes the moment playback ends and one of those screens is
        -- shown again.

        basalt.run()
        -- Reset here, not left to whoever called playSong() -- covers
        -- every call site (library, playlist auto-advance, a remote
        -- "play this song" direct-entry) in one place, so "Now Playing"
        -- can never show a frozen, already-finished song just because
        -- you're back on a selection screen instead of having left Music
        -- entirely (that's the only other place this got reset before).
        _G.MOVCCTWX_STATUS = { screen = "music_menu" }
        return playReason
    end

    -- Plays every song on the playlist in order (auto-advancing), same
    -- logic the Playlist screen's "Play All" button already used -- pulled
    -- out into its own function so both that button AND a remote
    -- "play_playlist" command (see startWithPlaylist below) can trigger
    -- the exact same behavior instead of duplicating it.
    local function playThroughPlaylist()
        local i = 1
        while i <= #playlist and not exitReason and not _G.MOVCCTWX_TERMINATED and not _G.MOVCCTWX_REMOTE_PENDING do
            local reason = playSong(playlist[i], "Back to Playlist")
            if reason ~= "finished" then break end
            i = i + 1
        end
    end

    -- ==== Library list (paginated, tappable rows) ====
    local ROW_STEP = 2 -- 1 row for the button + 1 row gap, for touch accuracy and readability
    local contentTop = 4
    local footerRow = h
    local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))

    local songs, loadErrors = fetchSongs(manifestUrls)
    local page = 1
    local selectedSong = nil -- set by a song button's onClick, read by the loop below AFTER run() returns
    -- Which screen the state machine loop at the bottom shows next --
    -- "library" (default), "playlist", or "addSongs". Set by a footer
    -- button's onClick alongside basalt.stop(), same pattern as
    -- selectedSong.
    local nextScreen = nil

    local function drawLibrary()
        resetScreen(mon, frame)
        clearFrameChildren(frame)
        local f = frame
        local totalPages = math.max(1, math.ceil(#songs / perPage))
        if page > totalPages then page = totalPages end

        f:addLabel()
            :setText((" MUSIC LIBRARY "):sub(1, w))
            :setSize(w, 1)
            :setPosition(1, 1)
            :setForeground(colors.lime)
            :setBackground(colors.gray)

        if #loadErrors > 0 then
            f:addLabel()
                :setText(("Load error(s): %d -- showing what loaded"):format(#loadErrors))
                :setPosition(2, 2)
                :setForeground(colors.red)
                :setBackground(colors.black)
        else
            f:addLabel()
                :setText(("%d song(s) -- page %d/%d"):format(#songs, page, totalPages))
                :setPosition(2, 2)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        end

        if #songs == 0 then
            f:addLabel()
                :setText("No songs found.")
                :setPosition(2, contentTop)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        else
            local startIdx = (page - 1) * perPage + 1
            for i = 0, perPage - 1 do
                local idx = startIdx + i
                local song = songs[idx]
                if song then
                    f:addButton()
                        :setText(song.name:sub(1, w - 4))
                        :setPosition(2, contentTop + i * ROW_STEP)
                        :setSize(w - 2, 1)
                        :setBackground(colors.gray)
                        :setForeground(colors.lime)
                        :onClick(function()
                            -- MUST NOT call playSong() (and its basalt.run())
                            -- directly from here -- we're still inside THIS
                            -- frame's own active basalt.run() call, and
                            -- basalt.run() errors ("Basalt is already
                            -- running") if called again before the outer
                            -- one has actually returned. Same pattern as
                            -- runVideoMenu in hub.lua: just record the
                            -- selection and stop; the loop below calls
                            -- playSong() only once run() has truly exited.
                            selectedSong = song
                            basalt.stop()
                        end)
                end
            end
        end

        -- 5 buttons total (4 nav + Main Menu) -- the nav group's width is
        -- computed to always leave real room before Main Menu's own
        -- right-anchored position, instead of a fixed width that assumed a
        -- much wider (old wall-monitor) screen. On this computer's own
        -- narrower terminal, that fixed width put Main Menu's button
        -- exactly on top of Playlist's -- both existed, but Main Menu
        -- (added last, so drawn on top) silently covered Playlist
        -- entirely, making it invisible and unclickable. Confirmed
        -- in-game: the footer only ever showed 4 buttons.
        local mainMenuW = math.min(w - 2, 12)
        local mainMenuX = w - mainMenuW + 1
        local navGap = 1
        local navAreaW = (mainMenuX - 2) - 2 -- up to 2 cols clear before Main Menu
        local navW = math.max(6, math.floor((navAreaW - 3 * navGap) / 4))
        local function navX(i) return 2 + (i - 1) * (navW + navGap) end

        f:addButton()
            :setText("< Prev")
            :setPosition(navX(1), footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if page > 1 then page = page - 1 end
                drawLibrary()
            end)

        f:addButton()
            :setText("Next >")
            :setPosition(navX(2), footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if page < totalPages then page = page + 1 end
                drawLibrary()
            end)

        f:addButton()
            :setText("Refresh")
            :setPosition(navX(3), footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                songs, loadErrors = fetchSongs(manifestUrls)
                page = 1
                drawLibrary()
            end)

        f:addButton()
            :setText("Playlist")
            :setPosition(navX(4), footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                nextScreen = "playlist"
                basalt.stop()
            end)

        f:addButton()
            :setText("Main Menu")
            :setPosition(mainMenuX, footerRow)
            :setSize(mainMenuW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                exitReason = "menu"
                basalt.stop()
            end)
    end

    -- ==== Playlist screen (paginated, per-row Remove) ====
    -- Its own perPage, one ROW_STEP smaller than the library's -- this
    -- screen has an EXTRA footer row (Play All / Back, above the
    -- Prev/Next/+Add row) that the library screen doesn't, so reusing the
    -- library's perPage would let the last content row overlap it.
    local playlistPerPage = math.max(1, math.floor((footerRow - ROW_STEP - contentTop) / ROW_STEP))
    local playlistPage = 1
    local playlistAction = nil -- set by a footer button: "play" | "add" | "back"

    local function drawPlaylist()
        resetScreen(mon, frame)
        clearFrameChildren(frame)
        local f = frame
        local totalPages = math.max(1, math.ceil(#playlist / playlistPerPage))
        if playlistPage > totalPages then playlistPage = totalPages end

        f:addLabel()
            :setText((" PLAYLIST "):sub(1, w))
            :setSize(w, 1)
            :setPosition(1, 1)
            :setForeground(colors.lime)
            :setBackground(colors.gray)

        f:addLabel()
            :setText(#playlist == 0 and "Empty -- tap + Add Songs below."
                or ("%d song(s) -- page %d/%d"):format(#playlist, playlistPage, totalPages))
            :setPosition(2, 2)
            :setForeground(colors.lightGray)
            :setBackground(colors.black)

        -- Each row: the song name (tap does nothing, it's just a label)
        -- plus a small red "X" remove button at the right edge of the row.
        local removeW = 3
        local startIdx = (playlistPage - 1) * playlistPerPage + 1
        for i = 0, playlistPerPage - 1 do
            local idx = startIdx + i
            local song = playlist[idx]
            if song then
                local rowY = contentTop + i * ROW_STEP
                f:addLabel()
                    :setText(song.name:sub(1, w - removeW - 3))
                    :setPosition(2, rowY)
                    :setSize(w - removeW - 2, 1)
                    :setForeground(colors.white)
                    :setBackground(colors.black)
                f:addButton()
                    :setText("X")
                    :setPosition(w - removeW, rowY)
                    :setSize(removeW, 1)
                    :setBackground(colors.red)
                    :setForeground(colors.white)
                    :onClick(function()
                        table.remove(playlist, idx)
                        _G.MOVCCTWX_SAVE_PLAYLIST()
                        drawPlaylist()
                    end)
            end
        end

        local navW = math.min(math.floor((w - 8) / 3), 14)
        f:addButton()
            :setText("< Prev")
            :setPosition(2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if playlistPage > 1 then playlistPage = playlistPage - 1 end
                drawPlaylist()
            end)

        f:addButton()
            :setText("Next >")
            :setPosition(4 + navW, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if playlistPage < totalPages then playlistPage = playlistPage + 1 end
                drawPlaylist()
            end)

        f:addButton()
            :setText("+ Add Songs")
            :setPosition(6 + navW * 2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                playlistAction = "add"
                basalt.stop()
            end)

        local playW = math.min(w - 2, 16)
        f:addButton()
            :setText("Play All")
            :setPosition(2, footerRow - ROW_STEP)
            :setSize(playW, 1)
            :setBackground(#playlist > 0 and colors.lime or colors.gray)
            :setForeground(#playlist > 0 and colors.black or colors.lightGray)
            :onClick(function()
                if #playlist > 0 then
                    playlistAction = "play"
                    basalt.stop()
                end
            end)

        f:addButton()
            :setText("Back")
            :setPosition(2 + playW + 2, footerRow - ROW_STEP)
            :setSize(playW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                playlistAction = "back"
                basalt.stop()
            end)
    end

    -- ==== Add-to-Playlist screen: same song list, tap = add, not play ====
    local addPage = 1

    local function drawAddSongs()
        resetScreen(mon, frame)
        clearFrameChildren(frame)
        local f = frame
        local totalPages = math.max(1, math.ceil(#songs / perPage))
        if addPage > totalPages then addPage = totalPages end

        f:addLabel()
            :setText((" ADD TO PLAYLIST "):sub(1, w))
            :setSize(w, 1)
            :setPosition(1, 1)
            :setForeground(colors.lime)
            :setBackground(colors.gray)

        f:addLabel()
            :setText(("Tap a song to add it -- Playlist: %d song(s)"):format(#playlist))
            :setPosition(2, 2)
            :setForeground(colors.lightGray)
            :setBackground(colors.black)

        if #songs == 0 then
            f:addLabel()
                :setText("No songs found.")
                :setPosition(2, contentTop)
                :setForeground(colors.lightGray)
                :setBackground(colors.black)
        else
            local startIdx = (addPage - 1) * perPage + 1
            for i = 0, perPage - 1 do
                local idx = startIdx + i
                local song = songs[idx]
                if song then
                    f:addButton()
                        :setText(song.name:sub(1, w - 4))
                        :setPosition(2, contentTop + i * ROW_STEP)
                        :setSize(w - 2, 1)
                        :setBackground(colors.gray)
                        :setForeground(colors.lime)
                        :onClick(function()
                            table.insert(playlist, song)
                            _G.MOVCCTWX_SAVE_PLAYLIST()
                            drawAddSongs() -- redraw in place -- the counter above updates, stays on this screen
                        end)
                end
            end
        end

        local navW = math.min(math.floor((w - 8) / 3), 14)
        f:addButton()
            :setText("< Prev")
            :setPosition(2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if addPage > 1 then addPage = addPage - 1 end
                drawAddSongs()
            end)

        f:addButton()
            :setText("Next >")
            :setPosition(4 + navW, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                if addPage < totalPages then addPage = addPage + 1 end
                drawAddSongs()
            end)

        f:addButton()
            :setText("Done")
            :setPosition(6 + navW * 2, footerRow)
            :setSize(navW, 1)
            :setBackground(colors.gray)
            :setForeground(colors.lime)
            :onClick(function()
                basalt.stop()
            end)
    end

    -- Same reuse-the-frame pattern as hub.lua's runVideoMenu: rebuild and
    -- run whichever screen is current, act on what its buttons set, then
    -- loop back around fresh. The idle watcher is (re)scheduled fresh each
    -- pass on every screen -- see startIdleWatcher's comment up top for why
    -- -- and shares lastActivityMs across all of them so activity carries
    -- over no matter which screen is showing.
    if startSongName then
        local matches = fetchSongs(manifestUrls)
        local match = nil
        for _, s in ipairs(matches) do
            if s.name == startSongName then match = s break end
        end
        if match then playSong(match) end
    elseif startWithPlaylist and #playlist > 0 then
        playThroughPlaylist()
    end

    local screen = "library" -- "library" | "playlist" | "addSongs"
    -- MOVCCTWX_REMOTE_PENDING (set by startup.lua's remoteMenuWatcher) ends
    -- this loop the same way exitReason/TERMINATED do -- a remote
    -- menu-level command (e.g. "play_video" while sitting on the library
    -- screen) calls basalt.stop() to unblock whichever basalt.run() below
    -- is currently active, and this guard is what actually lets M.run()
    -- notice that and return instead of just redrawing the same screen
    -- again next iteration.
    while not exitReason and not _G.MOVCCTWX_TERMINATED and not _G.MOVCCTWX_REMOTE_PENDING do
        local idleStop = function()
            exitReason = exitReason or "idle"
            for _, spk in ipairs(speakers) do pcall(spk.stop) end
            basalt.stop()
        end

        if screen == "library" then
            selectedSong = nil
            nextScreen = nil
            drawLibrary()
            frame:draw()
            startIdleWatcher(idleStop)
            basalt.run()

            if nextScreen then
                screen = nextScreen
            elseif selectedSong and not _G.MOVCCTWX_TERMINATED then
                playSong(selectedSong)
            end
        elseif screen == "playlist" then
            playlistAction = nil
            drawPlaylist()
            frame:draw()
            startIdleWatcher(idleStop)
            basalt.run()

            if playlistAction == "add" then
                screen = "addSongs"
            elseif playlistAction == "back" then
                screen = "library"
            elseif playlistAction == "play" and #playlist > 0 and not _G.MOVCCTWX_TERMINATED then
                playThroughPlaylist()
                -- Whether it played through to the end, got stopped, or
                -- one song errored out, land back on the playlist screen
                -- (not the library) -- exitReason (idle/quit/menu) still
                -- overrides this via the outer while condition above.
                screen = "playlist"
            end
        elseif screen == "addSongs" then
            drawAddSongs()
            frame:draw()
            startIdleWatcher(idleStop)
            basalt.run()
            screen = "playlist" -- Done always returns to the playlist view
        end
    end

    _G.MOVCCTWX_WALL_BUSY = false
    return _G.MOVCCTWX_TERMINATED and "quit" or exitReason
end

return M
