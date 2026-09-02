-- startup.lua -- entry point for the brain computer.
-- Simple select menu on the computer's own screen (Basalt): Video player /
-- Music player. No idle timeouts, no background matrix/menu music, no
-- multi-screen state machine -- pick a screen, use it, go back.
--
-- The monitor wall (wall.lua) is only opened lazily, right before the
-- first video plays, so picking Music never has to find/validate all 12
-- wall monitors at all.
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

    -- Remote commands work from the main menu too: open a submenu, or jump
    -- straight into a named video/song without touching the computer.
    safeSchedule(function()
        while not chosen and not _G.MOVCCTWX_TERMINATED do
            local _, action, name = os.pullEventRaw("movcctwx_remote_action")
            if action == "open_video_menu" then chosen = "video" basalt.stop()
            elseif action == "open_music_menu" then chosen = "music" basalt.stop()
            elseif action == "play_video" then chosen = { screen = "video", name = name } basalt.stop()
            elseif action == "play_music" then chosen = { screen = "music", name = name } basalt.stop()
            end
        end
    end)

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

    while not exitReason and not _G.MOVCCTWX_TERMINATED do
        local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        local selectedVideo = nil

        local function playByName(name)
            for _, v in ipairs(videos) do
                if v.name == name then return v end
            end
            return nil
        end

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

        safeSchedule(function()
            while not selectedVideo and not exitReason and not _G.MOVCCTWX_TERMINATED do
                local _, action, name = os.pullEventRaw("movcctwx_remote_action")
                if action == "open_music_menu" then exitReason = "music" basalt.stop()
                elseif action == "play_video" then
                    local v = playByName(name)
                    if v then selectedVideo = v basalt.stop() end
                end
            end
        end)

        frame:draw()
        basalt.run()

        if _G.MOVCCTWX_TERMINATED then return "quit" end

        if selectedVideo then
            local wall = getWall()
            videoplayer.play(wall, term, speakers, selectedVideo, config)
            if _G.MOVCCTWX_TERMINATED then return "quit" end
        end
    end

    if type(exitReason) == "string" and exitReason ~= "menu" then return exitReason end
    return "menu"
end

-- ==== Dispatch ====
-- Runs as one branch of the top-level parallel.waitForAny below, alongside
-- remoteLoop -- see that function for why it's structured that way. This
-- is the only branch that's ever expected to actually return.
local function mainLoop()
    local screen = "video"
    local pendingSongName = nil
    while true do
        if type(screen) == "table" then
            -- Remote "play X directly" from the main menu, before any
            -- submenu was ever opened.
            if screen.screen == "video" then
                local videoplayer = require("videoplayer")
                local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
                local match = nil
                for _, v in ipairs(videos) do if v.name == screen.name then match = v end end
                if match then videoplayer.play(getWall(), term, speakers, match, config) end
                screen = "video"
            else
                pendingSongName = screen.name
                screen = "music"
            end
        elseif screen == "video" then
            screen = runVideoMenu()
        elseif screen == "music" then
            clearFrameChildren(frame)
            local musicplayer = require("musicplayer")
            local exitReason = musicplayer.run(term, speakers, config, frame, pendingSongName)
            pendingSongName = nil
            screen = (exitReason == "quit") and "quit" or "video"
        elseif screen == "quit" or _G.MOVCCTWX_TERMINATED then
            break
        else
            screen = "video"
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

parallel.waitForAny(mainLoop, remoteLoop)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print(config.TITLE .. " stopped.")
