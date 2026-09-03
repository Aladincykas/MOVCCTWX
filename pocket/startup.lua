-- startup.lua -- pocket computer remote control, Basalt UI. Screen is
-- small (a Pocket Computer is only 26x20), so every screen here stays to
-- one simple list/button layout -- no pagination tricks beyond Prev/Next,
-- no nested menus.
--
-- Every command is sent as one rednet message: { action = "...", name =
-- "..." } on config.REMOTE_PROTOCOL, and the brain computer either allows
-- or rejects it based on its own REMOTE_ALLOWLIST -- this side has no way
-- to grant itself access, it can only ask and see whether the answer was
-- "ok".

local config = require("config")
local basalt = require("basalt")

local function openModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then
            rednet.open(name)
        end
    end
    if not rednet.isOpen() then
        error("No modem found/opened on this pocket computer.")
    end
end

local function findBrain()
    return rednet.lookup(config.REMOTE_PROTOCOL)
end

-- Sends one command and waits briefly for the brain's ok/reject reply.
-- Returns true, nil, status, playlist on success (status is the brain's
-- current _G.MOVCCTWX_STATUS snapshot, playlist its current
-- _G.MOVCCTWX_PLAYLIST -- see remote.lua -- both attached to every ack,
-- not just get_status's); false, reason on rejection/timeout.
-- extra: optional table of additional fields merged into the message
-- (playlist_add's `song`, for instance).
local function send(brainId, action, name, extra)
    local message = { action = action, name = name }
    if extra then for k, v in pairs(extra) do message[k] = v end end
    rednet.send(brainId, message, config.REMOTE_PROTOCOL)
    local senderId, reply = rednet.receive(config.REMOTE_PROTOCOL, 3)
    if senderId ~= brainId or type(reply) ~= "table" then
        return false, "no response (brain offline or out of range)"
    end
    if not reply.ok then
        return false, reply.reason or "rejected"
    end
    return true, nil, reply.status, reply.playlist
end

local function formatTime(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    local m = math.floor(seconds / 60)
    local s = seconds % 60
    return ("%d:%02d"):format(m, s)
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

local frame = basalt.createFrame()
frame:setBackground(colors.black)
local w, h = frame:getSize()

-- Same reuse-one-frame pattern as the brain computer -- createFrame()
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

local function flash(text, ok)
    clearFrameChildren(frame)
    frame:addLabel()
        :setText(text:sub(1, w))
        :setSize(w, 1)
        :setPosition(math.max(1, math.floor((w - math.min(#text, w)) / 2) + 1), 3)
        :setForeground(ok and colors.lime or colors.red)
        :setBackground(colors.black)
    frame:draw()
    sleep(1.2)
end

-- Paginated button list, shared by the Video and Music screens. Returns
-- the chosen item, or nil if the user went Back.
-- onAdd: optional -- if given, each row gets a small "+" button next to
-- it (playlist_add) alongside the row's own "play this" button, and a
-- Back button (not Prev/Next/+) closes the screen.
local function listScreen(title, items, labelFn, onAdd)
    local contentTop = 3
    local footerRow = h
    local perPage = math.max(1, footerRow - contentTop - 1)
    local page = 1
    local result = nil

    local function draw()
        clearFrameChildren(frame)
        if page > math.max(1, math.ceil(#items / perPage)) then page = 1 end
        local totalPages = math.max(1, math.ceil(#items / perPage))

        frame:addLabel():setText(title:sub(1, w)):setSize(w, 1):setPosition(1, 1)
            :setForeground(colors.lime):setBackground(colors.gray)
        frame:addLabel()
            :setText((#items == 0 and "(empty)" or ("%d -- pg %d/%d"):format(#items, page, totalPages)):sub(1, w))
            :setPosition(1, 2):setForeground(colors.lightGray):setBackground(colors.black)

        local addW = onAdd and 3 or 0
        local startIdx = (page - 1) * perPage + 1
        for i = 0, perPage - 1 do
            local idx = startIdx + i
            local item = items[idx]
            if item then
                local rowY = contentTop + i
                frame:addButton()
                    :setText(labelFn(item):sub(1, w - addW - 1))
                    :setPosition(1, rowY)
                    :setSize(w - addW, 1)
                    :setBackground(colors.gray)
                    :setForeground(colors.lime)
                    :onClick(function() result = item basalt.stop() end)
                if onAdd then
                    frame:addButton()
                        :setText("+")
                        :setPosition(w - addW + 1, rowY)
                        :setSize(addW, 1)
                        :setBackground(colors.lime)
                        :setForeground(colors.black)
                        :onClick(function() onAdd(item) draw() end)
                end
            end
        end

        local navW = math.max(4, math.floor((w - 6) / 3))
        frame:addButton():setText("<"):setPosition(1, footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page > 1 then page = page - 1 end draw() end)
        frame:addButton():setText(">"):setPosition(2 + navW, footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page < totalPages then page = page + 1 end draw() end)
        frame:addButton():setText("Back"):setPosition(w - navW + 1, footerRow):setSize(navW, 1)
            :setBackground(colors.red):setForeground(colors.white)
            :onClick(function() basalt.stop() end)

        frame:draw()
    end

    draw()
    basalt.run()
    return result
end

-- Now-playing transport screen: sends playpause/stop/volume commands, and
-- polls the brain once a second for live status (title/paused/elapsed/
-- volume). Back returns to the caller without stopping playback on the
-- brain side.
-- initialStatus: the status snapshot from the play_video/play_music call
-- that got us here, if any -- shown immediately instead of a blank first
-- frame while waiting for the first poll.
local function transportScreen(brainId, kind, name, initialStatus)
    local status = initialStatus
    local nameLabel, statusLabel, playPauseBtn

    -- Centers a label horizontally at row y, given its CURRENT text --
    -- called both at setup and every updateLabels() (the status line's
    -- text/length changes every poll, so it has to recenter every time,
    -- not just once).
    local function centerLabel(label, y, text)
        text = text:sub(1, w)
        label:setText(text)
        label:setPosition(math.max(1, math.floor((w - #text) / 2) + 1), y)
    end

    local function updateLabels()
        -- Prefer status.name (the brain's live, ACTUAL current title --
        -- e.g. once play_playlist starts really playing something) over
        -- the static `name` this screen was opened with -- that static
        -- value is sometimes just a placeholder like "Playlist" (the ack
        -- for play_playlist can arrive before _G.MOVCCTWX_STATUS on the
        -- brain has caught up to the real song), and it never updates on
        -- its own as the playlist auto-advances to a DIFFERENT song
        -- underneath. Confirmed in-game: title was stuck on "Playlist"
        -- for the whole session instead of following the actual song.
        local displayName = (status and status.screen == kind and status.name) or name
        centerLabel(nameLabel, 3, displayName)
        if status and status.screen == kind then
            centerLabel(statusLabel, 4, (status.paused and "|| " or "> ") .. formatTime(status.elapsedSec)
                .. "  " .. (status.volumePct or 0) .. "%")
            playPauseBtn:setText(status.paused and "Play" or "Pause")
        else
            centerLabel(statusLabel, 4, "(connecting...)")
        end
    end

    clearFrameChildren(frame)
    frame:addLabel():setText((kind == "video" and "DIDZIULIS EKRANAS" or "MUSIC"):sub(1, w))
        :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)
    nameLabel = frame:addLabel():setForeground(colors.white):setBackground(colors.black)
    statusLabel = frame:addLabel():setForeground(colors.lightGray):setBackground(colors.black)

    local btnW = math.max(4, math.floor((w - 4) / 2))
    playPauseBtn = frame:addButton():setText("--"):setPosition(1, 6):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, reason, newStatus = send(brainId, "playpause")
            if ok then status = newStatus updateLabels() else flash("Rejected: " .. tostring(reason), false) basalt.stop() end
        end)
    frame:addButton():setText("Stop"):setPosition(2 + btnW, 6):setSize(btnW, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function()
            local ok, reason = send(brainId, "stop")
            if not ok then flash("Rejected: " .. tostring(reason), false) end
            basalt.stop()
        end)

    frame:addButton():setText("Vol -"):setPosition(1, 8):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol-1")
            if ok then status = newStatus updateLabels() end
        end)
    frame:addButton():setText("Vol +"):setPosition(2 + btnW, 8):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol+1")
            if ok then status = newStatus updateLabels() end
        end)

    frame:addButton():setText("Back"):setPosition(1, h):setSize(w, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() basalt.stop() end)

    updateLabels()

    local stopped = false
    basalt.schedule(function()
        while not stopped do
            local ok, _, newStatus = send(brainId, "get_status")
            if ok then status = newStatus updateLabels() end
            sleep(1)
        end
    end)

    frame:draw()
    basalt.run()
    stopped = true
end

-- Playlist screen: view the current (shared -- see remote.lua/
-- musicplayer.lua) playlist, tap a song's X to remove it, Play All hands
-- off to the same transportScreen used for a single song
-- (musicplayer.lua's _G.MOVCCTWX_STATUS already reports whichever song is
-- CURRENTLY playing within the playlist, so the generic transport screen
-- just works here too, title and all).
-- playlist: the initial contents (from whatever get_status/play_* call
-- got us here) -- refetched after every remove so this stays accurate.
local function playlistScreen(brainId, playlist)
    local contentTop = 3
    -- 2 footer rows now, not 1 -- Prev/Next above, Play All/Back below --
    -- a playlist longer than one screenful used to just silently hide the
    -- extra songs with no way to see or remove them at all (confirmed:
    -- no pagination existed here, unlike every other list screen).
    local navRow = h - 1
    local footerRow = h
    local perPage = math.max(1, navRow - contentTop)
    local page = 1

    local function draw()
        clearFrameChildren(frame)
        local totalPages = math.max(1, math.ceil(#playlist / perPage))
        if page > totalPages then page = totalPages end
        frame:addLabel():setText(("PLAYLIST -- pg %d/%d"):format(page, totalPages):sub(1, w))
            :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)

        if #playlist == 0 then
            frame:addLabel():setText("(empty)"):setPosition(1, contentTop):setForeground(colors.gray):setBackground(colors.black)
            frame:addLabel():setText("Add from Music Player"):setPosition(1, contentTop + 1):setForeground(colors.gray):setBackground(colors.black)
        else
            local removeW = 3
            local startIdx = (page - 1) * perPage + 1
            for i = 0, perPage - 1 do
                local idx = startIdx + i
                local song = playlist[idx]
                if song then
                    local rowY = contentTop + i
                    frame:addLabel()
                        :setText(song.name:sub(1, w - removeW - 1))
                        :setPosition(1, rowY):setSize(w - removeW, 1)
                        :setForeground(colors.white):setBackground(colors.black)
                    frame:addButton():setText("X"):setPosition(w - removeW + 1, rowY):setSize(removeW, 1)
                        :setBackground(colors.red):setForeground(colors.white)
                        :onClick(function()
                            local ok, reason, _, newPlaylist = send(brainId, "playlist_remove", song.name)
                            if ok then playlist = newPlaylist or playlist draw()
                            else flash("Rejected: " .. tostring(reason), false) draw() end
                        end)
                end
            end
        end

        local navW = math.max(4, math.floor((w - 6) / 3))
        frame:addButton():setText("<"):setPosition(1, navRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page > 1 then page = page - 1 end draw() end)
        frame:addButton():setText(">"):setPosition(2 + navW, navRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page < totalPages then page = page + 1 end draw() end)

        local halfW = math.max(4, math.floor((w - 2) / 2))
        frame:addButton():setText("Play All"):setPosition(1, footerRow):setSize(halfW, 1)
            :setBackground(#playlist > 0 and colors.lime or colors.gray)
            :setForeground(#playlist > 0 and colors.black or colors.lightGray)
            :onClick(function()
                if #playlist == 0 then return end
                local ok, reason, status = send(brainId, "play_playlist")
                if ok then
                    basalt.stop()
                    transportScreen(brainId, "music", (status and status.name) or "Playlist", status)
                    local _, _, _, newPlaylist = send(brainId, "get_status")
                    playlist = newPlaylist or playlist
                    draw()
                    basalt.run()
                else
                    flash("Rejected: " .. tostring(reason), false)
                end
            end)
        frame:addButton():setText("Back"):setPosition(2 + halfW, footerRow):setSize(halfW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() basalt.stop() end)

        frame:draw()
    end

    draw()
    basalt.run()
end

-- ==== Main ====
openModem()
-- Was "Looking for " .. config.TITLE (config.TITLE is THIS pocket's OWN
-- name, "MOVCCTWX Remote" -- wrong thing to say here, it's the BRAIN
-- being searched for, not itself) -- also overflowed the 26-col screen
-- and got truncated mid-word ("...Remot"). Fixed wording, and short
-- enough to never need truncating regardless of screen width.
flash("Finding brain computer...", true)
local brainId = findBrain()
if not brainId then
    flash("Brain computer not found", false)
    error("No brain computer responded to rednet.lookup.", 0)
end

while true do
    clearFrameChildren(frame)
    frame:addLabel():setText(config.TITLE:sub(1, w)):setPosition(math.max(1, math.floor((w - #config.TITLE) / 2) + 1), 1)
        :setForeground(colors.lime):setBackground(colors.black)

    local buttonW = math.min(w - 2, 20)
    local bx = math.max(1, math.floor((w - buttonW) / 2) + 1)
    local chosen = nil

    frame:addButton():setText("Video Player"):setPosition(bx, 4):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "video" basalt.stop() end)
    frame:addButton():setText("Music Player"):setPosition(bx, 6):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "music" basalt.stop() end)
    frame:addButton():setText("Playlist"):setPosition(bx, 8):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "playlist" basalt.stop() end)
    frame:addButton():setText("Now Playing"):setPosition(bx, 10):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "nowplaying" basalt.stop() end)
    frame:addButton():setText("Quit"):setPosition(bx, 12):setSize(buttonW, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function() chosen = "quit" basalt.stop() end)

    frame:draw()
    basalt.run()

    if chosen == "video" then
        local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        local video = listScreen("VIDEOS", videos, function(v) return v.name end)
        if video then
            local ok, reason, status = send(brainId, "play_video", video.name)
            if ok then transportScreen(brainId, "video", video.name, status)
            else flash("Rejected: " .. tostring(reason), false) end
        end
    elseif chosen == "music" then
        local songs = fetchMergedManifest(config.MUSIC_LIBRARIES, "songs.json")
        local song = listScreen("MUSIC", songs, function(s) return s.name end, function(s)
            local ok, reason = send(brainId, "playlist_add", nil, { song = s })
            flash(ok and ("Added: " .. s.name) or ("Rejected: " .. tostring(reason)), ok)
        end)
        if song then
            local ok, reason, status = send(brainId, "play_music", song.name)
            if ok then transportScreen(brainId, "music", song.name, status)
            else flash("Rejected: " .. tostring(reason), false) end
        end
    elseif chosen == "playlist" then
        local ok, reason, _, playlist = send(brainId, "get_status")
        if ok then playlistScreen(brainId, playlist or {})
        else flash("Rejected: " .. tostring(reason), false) end
    elseif chosen == "nowplaying" then
        -- Checks what's ACTUALLY playing right now (could've been started
        -- from the computer itself, or a while ago from this same pocket)
        -- instead of only ever being reachable right after picking
        -- something -- status.screen is "video"/"music" only while
        -- something's actually playing; "menu"/"video_menu"/"music_menu"
        -- otherwise (see startup.lua/musicplayer.lua/videoplayer.lua on
        -- the brain for where each of those gets set).
        local ok, reason, status = send(brainId, "get_status")
        if not ok then
            flash("Rejected: " .. tostring(reason), false)
        elseif status and (status.screen == "video" or status.screen == "music") then
            transportScreen(brainId, status.screen, status.name or "?", status)
        else
            flash("Nothing playing right now", false)
        end
    elseif chosen == "quit" then
        break
    end
end

clearFrameChildren(frame)
frame:addLabel():setText((config.TITLE .. " stopped."):sub(1, w)):setPosition(1, 1):setForeground(colors.white):setBackground(colors.black)
frame:draw()
