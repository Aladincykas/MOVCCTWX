-- startup.lua -- entry point for the brain computer.
-- Simple select menu on the computer's own screen (Basalt): Video player /
-- Music player. No idle timeouts, no background matrix/menu music, no
-- multi-screen state machine -- pick a screen, use it, go back.
--
-- The monitor wall (wall.lua) is opened lazily, the first time it's
-- actually needed -- by either Video or Music now, since both show their
-- full-screen visuals on the wall (see videoplayer.lua and
-- musicplayer.lua) and keep only text/controls on the computer's own
-- screen.
--
-- remote.lua's rednet listener runs the whole time, in parallel with
-- whatever's on screen, so the pocket computer can control this computer
-- no matter which screen is currently showing.

local config = require("config")
local basalt = require("basalt")
local remote = require("remote")
local settings = require("settings")

term.clear()
term.setCursorPos(1, 1)

local allSpeakers = { peripheral.find("speaker") }
local speakers = {}
for i = 1, math.min(#allSpeakers, config.MAX_SPEAKERS or 8) do
    speakers[i] = allSpeakers[i]
end
if #speakers == 0 then
    error("No speakers found on the network. Check they're connected via modem.")
end

_G.MOVCCTWX_TERMINATED = false
-- Live playback status, read by remote.lua and attached to every rednet
-- ack it sends -- lets the pocket computer show a real title/
-- paused-or-playing/elapsed/volume instead of static text. videoplayer.lua
-- and musicplayer.lua update this continuously while something's playing
-- (see their comments); everywhere else it's just {screen=...}.
_G.MOVCCTWX_STATUS = { screen = "menu" }
-- The playlist: a shared table (not scoped to one Music session, unlike
-- the old version) -- both the computer's own Playlist screen
-- (musicplayer.lua) and remote playlist_add/playlist_remove commands
-- (remote.lua) mutate this SAME table in place, so either side adding/
-- removing a song is immediately visible to the other. Each entry is a
-- full song table ({name=, url=...}), same shape as songs.json.
--
-- Persisted to disk (piggybacking on settings.lua's existing JSON store,
-- alongside the saved volume levels), not just kept in memory -- it used
-- to reset to empty on every single reboot, silently losing whatever had
-- been added, confirmed in-game as a real problem during a session with
-- many reinstall-triggered reboots. _G.MOVCCTWX_SAVE_PLAYLIST is called
-- by both mutation sites (remote.lua and musicplayer.lua's own Playlist
-- screen) after every add/remove -- re-reads the settings file fresh each
-- time rather than caching it, so this can't clobber a volume level saved
-- by the OTHER file in between.
do
    local saved = settings.load()
    _G.MOVCCTWX_PLAYLIST = (type(saved.playlist) == "table") and saved.playlist or {}
end
function _G.MOVCCTWX_SAVE_PLAYLIST()
    local saved = settings.load()
    saved.playlist = _G.MOVCCTWX_PLAYLIST
    settings.save(saved)
end

local frame = basalt.createFrame()
frame:setBackground(colors.black)

-- Ctrl+T doesn't propagate out of basalt.run() by itself (it swallows
-- "Terminated" via its own xpcall and just stops that one run() call) --
-- same fix as the reference project: a watcher coroutine using
-- os.pullEventRaw (which doesn't throw on terminate) sets a flag every
-- level checks after its own basalt.run()/player call returns.
basalt.schedule(function()
    while true do
        local event, key = os.pullEventRaw()
        if event == "terminate" or (event == "key" and key == keys.q) then
            _G.MOVCCTWX_TERMINATED = true
            basalt.stop()
            return
        end
    end
end)

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

-- Same reuse-one-frame pattern as the reference project: createFrame()
-- appends to a module-level list with no "destroy" call anywhere, so this
-- clears a frame's own children instead of leaking a new frame per screen.
-- Wipes the physical screen AND resets Basalt's render cache before a
-- screen is rebuilt -- see musicplayer.lua's identical helper for the
-- full explanation (short version: clearing the widgets alone isn't
-- enough, Basalt skips repainting cells it thinks are unchanged, which
-- makes near-identical consecutive screens render half-blank).
local function resetScreen()
    term.setBackgroundColor(colors.black)
    term.clear()
    frame:setTerm(term)
end

local function clearFrameChildren(f)
    local children = rawget(f, "_children")
    while children and #children > 0 do
        local child = children[#children]
        if child.destroy then child:destroy() end
        if children[#children] == child then f:removeChild(child) end
    end
end

local function fetchMergedManifest(libraries, manifestFile)
    local items = {}
    for _, lib in ipairs(libraries) do
        local url = ("https://raw.githubusercontent.com/%s/%s/%s/%s?t=%s")
            :format(config.GITHUB_USER, lib.repo, lib.branch, manifestFile, tostring(os.epoch("utc")))
        local response = http.get(url)
        if response then
            local body = response.readAll()
            response.close()
            local parsed = textutils.unserialiseJSON(body)
            if type(parsed) == "table" then
                for _, item in ipairs(parsed) do table.insert(items, item) end
            end
        end
    end
    return items
end

local wallInstance = nil
-- mode: "music" or "video" -- the wall runs at a different text scale for
-- each (see config.lua's WALL_TEXT_SCALE_MUSIC/VIDEO for why). Applied on
-- every call, not just the first, since the same wall gets handed back
-- and forth between the two.
local function getWall(mode)
    if not wallInstance then
        local wallModule = require("wall")
        wallInstance = wallModule.open(config)
    end
    local scale = (mode == "music" and config.WALL_TEXT_SCALE_MUSIC)
        or (mode == "video" and config.WALL_TEXT_SCALE_VIDEO)
    if scale then wallInstance.setScale(scale) end
    return wallInstance
end

-- ==== Main menu ====
local w, h = frame:getSize()
-- Bumped every time the menu opens. Basalt's schedules table is
-- module-level and never cleared between run() calls, so a coroutine
-- scheduled by one menu can still be resumed during a LATER run() -- which
-- for the idle clock would mean it drawing over a video that is playing.
-- Capturing the generation lets a stale one notice it is stale and return.
local menuGeneration = 0

local function runMainMenu()
    local chosen = nil
    menuGeneration = menuGeneration + 1
    local myGeneration = menuGeneration
    resetScreen()
    clearFrameChildren(frame)

    local title = config.TITLE
    local buttonW = math.min(w - 4, 22)
    local bx = math.max(1, math.floor((w - buttonW) / 2) + 1)

    -- Whole block (title + 3 buttons) centered vertically as one unit,
    -- not pinned near the top -- previously left a big dead gap below the
    -- buttons on a tall screen.
    local BLOCK_HEIGHT = 8 -- title(1) gap(2) 3 buttons w/ 1-row gaps between (5)
    local blockTop = math.max(2, math.floor((h - BLOCK_HEIGHT) / 2) + 1)
    local titleY = blockTop
    local btn1Y, btn2Y, btn3Y = titleY + 3, titleY + 5, titleY + 7

    frame:addLabel()
        :setText(title)
        :setPosition(math.max(1, math.floor((w - #title) / 2) + 1), titleY)
        :setForeground(colors.lime)
        :setBackground(colors.black)

    frame:addButton()
        :setText("VIDEO PLAYER")
        :setPosition(bx, btn1Y)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function() chosen = "video" basalt.stop() end)

    frame:addButton()
        :setText("MUSIC PLAYER")
        :setPosition(bx, btn2Y)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function() chosen = "music" basalt.stop() end)

    -- Checks _G.MOVCCTWX_STATUS directly (no rednet needed -- this IS the
    -- brain). Note: mainLoop can only ever be running runMainMenu() while
    -- screen == "menu", and _G.MOVCCTWX_STATUS is always set to
    -- {screen="menu"} right before that -- so seeing this button at all
    -- already means nothing is currently playing ON THIS COMPUTER. Unlike
    -- the pocket's Now Playing (a genuinely separate device that might
    -- not be following along), this exists mostly for UI parity; it's
    -- not being dishonest by usually saying "nothing playing" -- that's
    -- just always true here.
    frame:addButton()
        :setText("NOW PLAYING")
        :setPosition(bx, btn3Y)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function()
            resetScreen()
            clearFrameChildren(frame)
            local status = _G.MOVCCTWX_STATUS
            local msg = (status and (status.screen == "video" or status.screen == "music"))
                and ("Playing: " .. (status.name or "?"))
                or "Nothing playing right now"
            frame:addLabel()
                :setText(msg:sub(1, w))
                :setPosition(math.max(1, math.floor((w - math.min(#msg, w)) / 2) + 1), math.floor(h / 2))
                :setForeground(colors.lightGray):setBackground(colors.black)
            frame:addButton():setText("Back"):setPosition(bx, h - 1):setSize(buttonW, 1)
                :setBackground(colors.gray):setForeground(colors.lime)
                :onClick(function() chosen = "menu" basalt.stop() end)
            frame:draw()
        end)

    -- Remote menu-level commands (open a submenu, or jump straight into a
    -- named video/song) are handled by the single global watcher below
    -- (remoteMenuWatcher), not here -- see its comment for why a per-screen
    -- listener like this used to be, and why that was a real bug.

    -- Idle clock on the wall while this menu is up.
    --
    -- Twelve monitors sitting black is a waste of the most visible thing in
    -- the build, and the menu is where the brain spends most of its time.
    -- Scheduled rather than run inline so Basalt keeps handling clicks, and
    -- pcall'd so a wall problem (a monitor broken off, say) leaves the menu
    -- perfectly usable instead of taking it down -- the clock is decoration,
    -- the menu is not.
    basalt.schedule(function()
        if config.IDLE_CLOCK == false then return end
        local ok = pcall(function()
            local idlescreen = require("idlescreen")
            local wall = getWall("music")
            idlescreen.run(wall, function()
                -- A remote command exits the menu without setting `chosen`,
                -- and a stale coroutine from a previous menu must stop the
                -- moment a new one has started.
                return chosen ~= nil
                    or _G.MOVCCTWX_TERMINATED
                    or _G.MOVCCTWX_REMOTE_PENDING
                    or myGeneration ~= menuGeneration
            end)
        end)
        if not ok then return end
    end)

    frame:draw()
    basalt.run()

    -- Leave the wall black on the way out, or the clock's last frame stays
    -- burned there underneath whatever plays next.
    pcall(function()
        local wall = getWall("music")
        wall.setBackgroundColor(colors.black)
        wall.clear()
    end)

    if _G.MOVCCTWX_TERMINATED then return "quit" end
    return chosen or "video"
end

-- ==== Video: list + play ====
local function runVideoMenu()
    local videoplayer = require("videoplayer")
    local exitReason = nil
    local page = 1
    local ROW_STEP = 2
    local contentTop = 3
    local footerRow = h

    while not exitReason and not _G.MOVCCTWX_TERMINATED and not _G.MOVCCTWX_REMOTE_PENDING do
        local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        local selectedVideo = nil

        local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))
        local totalPages = math.max(1, math.ceil(#videos / perPage))

        local function draw()
            resetScreen()
            clearFrameChildren(frame)
            if page > totalPages then page = totalPages end

            frame:addLabel():setText((" DIDZIULIS EKRANAS -- SELECT A VIDEO "):sub(1, w))
                :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)

            frame:addLabel()
                :setText(#videos == 0 and "No videos yet." or ("%d video(s) -- page %d/%d"):format(#videos, page, totalPages))
                :setPosition(2, 2):setForeground(colors.lightGray):setBackground(colors.black)

            local startIdx = (page - 1) * perPage + 1
            for i = 0, perPage - 1 do
                local video = videos[startIdx + i]
                if video then
                    frame:addButton()
                        :setText(video.name:sub(1, w - 4))
                        :setPosition(2, contentTop + i * ROW_STEP)
                        :setSize(w - 2, 1)
                        :setBackground(colors.gray)
                        :setForeground(colors.lime)
                        :onClick(function() selectedVideo = video basalt.stop() end)
                end
            end

            local navW = math.min(math.floor((w - 8) / 3), 14)
            frame:addButton():setText("< Prev"):setPosition(2, footerRow):setSize(navW, 1)
                :setBackground(colors.gray):setForeground(colors.lime)
                :onClick(function() if page > 1 then page = page - 1 end draw() end)
            frame:addButton():setText("Next >"):setPosition(4 + navW, footerRow):setSize(navW, 1)
                :setBackground(colors.gray):setForeground(colors.lime)
                :onClick(function() if page < totalPages then page = page + 1 end draw() end)
            frame:addButton():setText("Back to Menu"):setPosition(w - math.min(w - 2, 16) + 1, footerRow)
                :setSize(math.min(w - 2, 16), 1):setBackground(colors.red):setForeground(colors.white)
                :onClick(function() exitReason = "menu" basalt.stop() end)
        end

        draw()
        frame:draw()
        basalt.run()

        if _G.MOVCCTWX_TERMINATED then return "quit" end
        if _G.MOVCCTWX_REMOTE_PENDING then return "menu" end

        if selectedVideo then
            local wall = getWall("video")
            videoplayer.play(wall, term, speakers, selectedVideo, config)
            if _G.MOVCCTWX_TERMINATED then return "quit" end
            if _G.MOVCCTWX_REMOTE_PENDING then return "menu" end
        end
    end

    if type(exitReason) == "string" and exitReason ~= "menu" then return exitReason end
    return "menu"
end

-- ==== Dispatch ====
-- Runs as one branch of the top-level parallel.waitForAny below, alongside
-- remoteLoop and remoteMenuWatcher -- see remoteMenuWatcher's comment for
-- how a remote menu-level command (open a submenu, or jump straight into a
-- named video/song) reaches this loop no matter which screen is currently
-- showing or blocking. This is the only branch that's ever expected to
-- actually return.
local function mainLoop()
    local screen = "menu"
    local pendingSongName = nil
    local pendingPlayAllPlaylist = false
    while true do
        -- A remote menu-level command always wins over whatever the
        -- just-finished screen returned -- see remoteMenuWatcher below.
        if _G.MOVCCTWX_REMOTE_PENDING and not _G.MOVCCTWX_TERMINATED then
            screen = _G.MOVCCTWX_REMOTE_TARGET
            _G.MOVCCTWX_REMOTE_PENDING = false
        end

        if type(screen) == "table" then
            if screen.screen == "video" then
                if screen.name then
                    local videoplayer = require("videoplayer")
                    local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
                    local match = nil
                    for _, v in ipairs(videos) do if v.name == screen.name then match = v end end
                    if match then videoplayer.play(getWall("video"), term, speakers, match, config) end
                end
                _G.MOVCCTWX_STATUS = { screen = "menu" }
                screen = "menu"
            else
                pendingSongName = screen.name
                pendingPlayAllPlaylist = screen.playAllPlaylist or false
                screen = "music"
            end
        elseif screen == "menu" then
            _G.MOVCCTWX_STATUS = { screen = "menu" }
            screen = runMainMenu()
        elseif screen == "video" then
            _G.MOVCCTWX_STATUS = { screen = "video_menu" }
            screen = runVideoMenu()
            _G.MOVCCTWX_STATUS = { screen = "menu" }
        elseif screen == "music" then
            clearFrameChildren(frame)
            _G.MOVCCTWX_STATUS = { screen = "music_menu" }
            local musicplayer = require("musicplayer")
            local exitReason = musicplayer.run(term, speakers, config, frame, pendingSongName, getWall("music"), pendingPlayAllPlaylist)
            pendingSongName = nil
            pendingPlayAllPlaylist = false
            _G.MOVCCTWX_STATUS = { screen = "menu" }
            screen = (exitReason == "quit") and "quit" or "menu"
        elseif screen == "quit" or _G.MOVCCTWX_TERMINATED then
            break
        else
            screen = "menu"
        end
    end
end

-- rednet listener for the pocket computer, alive for the whole program
-- lifetime (menu, video menu, video playback, music player all need
-- remote commands to reach them). parallel.waitForAny delivers every OS
-- event to both this and mainLoop, however deep either one's own nested
-- basalt.run()/parallel calls go, since CC's event queue is global -- so
-- this doesn't need to be threaded through every screen individually.
-- No modem attached shouldn't be fatal for a test run without a pocket
-- computer yet: log it and just park here instead of returning, since a
-- returning branch would end the whole parallel.waitForAny early.
local function remoteLoop()
    local ok, err = pcall(remote.listen, config)
    if not ok then
        print("Remote control disabled: " .. tostring(err))
    end
    while true do os.pullEventRaw() end
end

-- The 4 menu-level remote commands (open_video_menu, open_music_menu,
-- play_video, play_music) need to interrupt WHATEVER screen is currently
-- showing/blocking -- the main menu, the video list, an actively playing
-- video, or the music library/playlist/Now Playing screen -- and land on
-- the right one, not just be silently ignored if the "wrong" screen
-- happens to be active. A previous version had each screen listen for
-- these itself; that was a real bug (confirmed in-game: remote.lua still
-- replied "ok" since the command WAS delivered and allowlisted, but
-- runVideoMenu didn't recognize "play_music" at all, so nothing happened
-- and the pocket computer had no way to tell).
--
-- This single watcher is the only place that decides WHERE a remote
-- command should take the program (_G.MOVCCTWX_REMOTE_TARGET, read by
-- mainLoop above); it interrupts whichever screen is currently active via
-- two independent paths, since there are two fundamentally different
-- kinds of "currently active" here:
--   1. A Basalt screen (main menu, video list, music library/playlist) --
--      basalt.stop() unblocks its basalt.run() call directly.
--   2. A raw event-loop screen (videoplayer.play(), musicplayer's
--      playSong()) -- these don't call basalt.run() at all, but both
--      already listen for "movcctwx_remote_action" themselves (for
--      playpause/stop/volume) and treat these 4 action names as an
--      alias for "stop", so they unblock on their own via the exact same
--      event this watcher also reacts to.
-- Either way, once the active call returns, mainLoop's REMOTE_PENDING
-- check (at the top of its loop) takes over from there.
local function remoteMenuWatcher()
    while true do
        local _, action, name = os.pullEvent("movcctwx_remote_action")
        if action == "open_video_menu" then
            _G.MOVCCTWX_REMOTE_TARGET = "video"
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "open_music_menu" then
            _G.MOVCCTWX_REMOTE_TARGET = "music"
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "play_video" then
            _G.MOVCCTWX_REMOTE_TARGET = { screen = "video", name = name }
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "play_music" then
            _G.MOVCCTWX_REMOTE_TARGET = { screen = "music", name = name }
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "play_playlist" then
            _G.MOVCCTWX_REMOTE_TARGET = { screen = "music", playAllPlaylist = true }
            _G.MOVCCTWX_REMOTE_PENDING = true
        end
        if _G.MOVCCTWX_REMOTE_PENDING then
            pcall(basalt.stop)
        end
    end
end

_G.MOVCCTWX_REMOTE_PENDING = false
_G.MOVCCTWX_REMOTE_TARGET = nil

parallel.waitForAny(mainLoop, remoteLoop, remoteMenuWatcher)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print(config.TITLE .. " stopped.")
