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
local function getWall()
    if not wallInstance then
        local wallModule = require("wall")
        wallInstance = wallModule.open(config)
    end
    return wallInstance
end

-- ==== Main menu ====
local w, h = frame:getSize()
local function runMainMenu()
    local chosen = nil
    clearFrameChildren(frame)

    local title = config.TITLE
    local buttonW = math.min(w - 4, 22)
    local bx = math.max(1, math.floor((w - buttonW) / 2) + 1)

    frame:addLabel()
        :setText(title)
        :setPosition(math.max(1, math.floor((w - #title) / 2) + 1), 2)
        :setForeground(colors.lime)
        :setBackground(colors.black)

    frame:addButton()
        :setText("VIDEO PLAYER")
        :setPosition(bx, 5)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function() chosen = "video" basalt.stop() end)

    frame:addButton()
        :setText("MUSIC PLAYER")
        :setPosition(bx, 7)
        :setSize(buttonW, 1)
        :setBackground(colors.gray)
        :setForeground(colors.lime)
        :onClick(function() chosen = "music" basalt.stop() end)

    -- Remote menu-level commands (open a submenu, or jump straight into a
    -- named video/song) are handled by the single global watcher below
    -- (remoteMenuWatcher), not here -- see its comment for why a per-screen
    -- listener like this used to be, and why that was a real bug.

    frame:draw()
    basalt.run()

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
            local wall = getWall()
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
                    if match then videoplayer.play(getWall(), term, speakers, match, config) end
                end
                _G.MOVCCTWX_STATUS = { screen = "menu" }
                screen = "menu"
            else
                pendingSongName = screen.name
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
            local exitReason = musicplayer.run(term, speakers, config, frame, pendingSongName, getWall())
            pendingSongName = nil
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
