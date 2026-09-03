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
-- Returns true, nil, status, playlist, videoPlaylist on success (status is
-- the brain's current _G.MOVCCTWX_STATUS snapshot, and the two queues its
-- _G.MOVCCTWX_PLAYLIST / _G.MOVCCTWX_VIDEO_PLAYLIST -- see remote.lua, all
-- three are attached to every ack, not just get_status's); false, reason on
-- rejection/timeout.
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
    return true, nil, reply.status, reply.playlist, reply.videoPlaylist
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
                for _, item in ipairs(parsed) do
                    if type(item) == "table" and type(item.name) == "string" then
                        -- Which library it came from. The pocket needs this
                        -- for the same reason the brain does: a film cannot
                        -- go in the video queue. Prefixed so it can never
                        -- collide with a real manifest field.
                        item.__films = lib.films == true
                        table.insert(items, item)
                    end
                end
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
-- Wipes the physical screen AND resets Basalt's render cache before a
-- screen is rebuilt. Clearing the widgets alone isn't enough -- Basalt
-- only repaints cells it believes changed since IT last drew them, so two
-- near-identical consecutive screens can render half-blank. Same fix (and
-- same root cause) as the brain computer's resetScreen.
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

local function flash(text, ok)
    resetScreen()
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
-- Each entry gets TWO rows instead of one.
--
-- A pocket screen is 26 characters wide and video names routinely run past
-- that, so a single row could only ever show the first two thirds of a title
-- -- "My life be like -- Tokyo D" tells you nothing about which Tokyo Drift
-- video it is, and two similarly-named entries truncate to the same text.
-- Splitting on a space where possible keeps whole words together.
--
-- The cost is half as many entries per page, which is why the page counter
-- and the arrows already exist.
local ROWS_PER_ITEM = 2

-- Splits `text` across at most ROWS_PER_ITEM lines of `width`, breaking at a
-- space rather than mid-word where one is available near the break.
local function wrapLabel(text, width)
    local lines = {}
    local rest = text
    for _ = 1, ROWS_PER_ITEM do
        if #rest <= width then
            if #rest > 0 then lines[#lines + 1] = rest end
            rest = ""
            break
        end
        -- Look for a space in the last third of the line: nearer than that
        -- and breaking there wastes more space than the tidy break is worth.
        local cut = nil
        for i = width, math.floor(width * 0.6), -1 do
            if rest:sub(i, i) == " " then cut = i break end
        end
        cut = cut or width
        lines[#lines + 1] = rest:sub(1, cut):gsub("%s+$", "")
        rest = rest:sub(cut + 1):gsub("^%s+", "")
    end
    -- Anything still left over genuinely does not fit; mark it rather than
    -- cutting silently, so a truncated name is never mistaken for the
    -- whole one.
    if #rest > 0 and #lines > 0 then
        local last = lines[#lines]
        lines[#lines] = last:sub(1, math.max(1, width - 3)) .. "..."
    end
    return lines
end

-- addAllowed/addText: optional. addAllowed(item) decides whether THIS row
-- gets an add button at all (films cannot be queued), addText(item) gives its
-- caption so it can show whether the item is already queued. The three
-- reserved columns stay reserved either way, so rows keep a common width and
-- the list does not visibly ripple as items go in and out of the queue.
local function listScreen(title, items, labelFn, onAdd, addAllowed, addText)
    local contentTop = 3
    local footerRow = h
    local perPage = math.max(1, math.floor((footerRow - contentTop - 1) / ROWS_PER_ITEM))
    local page = 1
    local result = nil

    local function draw()
        resetScreen()
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
                local rowY = contentTop + i * ROWS_PER_ITEM
                local lines = wrapLabel(labelFn(item), w - addW - 1)
                -- One button spanning both rows, so tapping either line picks
                -- the item -- two separate buttons would leave the second
                -- line looking clickable but dead.
                local btn = frame:addButton()
                    :setPosition(1, rowY)
                    :setSize(w - addW, ROWS_PER_ITEM)
                    :setBackground(colors.gray)
                    :setForeground(colors.lime)
                    :onClick(function() result = item basalt.stop() end)
                btn:setText(lines[1] or "")
                -- Basalt centres a multi-row button's single text line, so
                -- the second line is drawn as its own label on top of the
                -- button's background rather than fighting that layout.
                if lines[2] then
                    btn:setSize(w - addW, 1)
                    frame:addButton()
                        :setText(lines[2])
                        :setPosition(1, rowY + 1)
                        :setSize(w - addW, 1)
                        :setBackground(colors.gray)
                        :setForeground(colors.lime)
                        :onClick(function() result = item basalt.stop() end)
                end
                if onAdd and (not addAllowed or addAllowed(item)) then
                    frame:addButton()
                        :setText(addText and addText(item) or "+")
                        :setPosition(w - addW + 1, rowY)
                        :setSize(addW, ROWS_PER_ITEM)
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
-- Asks whether to show subtitles, for a video that has them.
--
-- The brain asks the same question on its own screen; this is the remote's
-- copy, because starting a film from the pocket must not silently decide it.
-- Returns true, false, or nil for "go back".
local function askSubtitles(video)
    local answer, backed = nil, false
    resetScreen()
    clearFrameChildren(frame)

    frame:addLabel():setText(("SUBTITLES"):sub(1, w)):setSize(w, 1):setPosition(1, 1)
        :setForeground(colors.lime):setBackground(colors.gray)

    local titleLines = wrapLabel(video.name, w)
    frame:addLabel():setText(titleLines[1] or ""):setPosition(1, 3)
        :setForeground(colors.white):setBackground(colors.black)
    frame:addLabel():setText(titleLines[2] or ""):setPosition(1, 4)
        :setForeground(colors.white):setBackground(colors.black)

    frame:addButton():setText("With subtitles"):setPosition(1, 6):setSize(w, 1)
        :setBackground(colors.lime):setForeground(colors.black)
        :onClick(function() answer = true basalt.stop() end)
    frame:addButton():setText("Without"):setPosition(1, 8):setSize(w, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() answer = false basalt.stop() end)
    frame:addButton():setText("Back"):setPosition(1, 10):setSize(w, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function() backed = true basalt.stop() end)

    frame:draw()
    basalt.run()
    if backed then return nil end
    return answer
end

local function transportScreen(brainId, kind, name, initialStatus)
    local status = initialStatus
    local nameLabel, nameLabel2, statusLabel, playPauseBtn
    local playlistHeader, playlistLabels = nil, {}

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
        -- Two rows, same as the list screen: at 26 characters wide a single
        -- row cut "My life be like - Tokyo Drift Video" down to something
        -- that could be any of several videos.
        local titleLines = wrapLabel(displayName, w)
        centerLabel(nameLabel, 3, titleLines[1] or "")
        centerLabel(nameLabel2, 4, titleLines[2] or "")
        if status and status.screen == kind then
            centerLabel(statusLabel, 5, (status.paused and "|| " or "> ") .. formatTime(status.elapsedSec)
                .. "  " .. (status.volumePct or 0) .. "%")
            playPauseBtn:setText(status.paused and "Play" or "Pause")
        else
            centerLabel(statusLabel, 5, "(connecting...)")
        end
    end

    resetScreen()
    clearFrameChildren(frame)
    frame:addLabel():setText((kind == "video" and "DIDZIULIS EKRANAS" or "MUSIC"):sub(1, w))
        :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)
    nameLabel = frame:addLabel():setForeground(colors.white):setBackground(colors.black)
    nameLabel2 = frame:addLabel():setForeground(colors.white):setBackground(colors.black)
    statusLabel = frame:addLabel():setForeground(colors.lightGray):setBackground(colors.black)

    -- Button pairs centered as a GROUP, not started hard against column 1
    -- -- with a fixed x=1 start the pair ended short of the right edge and
    -- read as shoved to the left.
    local btnW = math.max(4, math.floor((w - 4) / 2))
    local pairW = btnW * 2 + 2
    local bx = math.max(1, math.floor((w - pairW) / 2) + 1)
    local bx2 = bx + btnW + 2
    playPauseBtn = frame:addButton():setText("--"):setPosition(bx, 7):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, reason, newStatus = send(brainId, "playpause")
            if ok then status = newStatus updateLabels() else flash("Rejected: " .. tostring(reason), false) basalt.stop() end
        end)
    frame:addButton():setText("Stop"):setPosition(bx2, 7):setSize(btnW, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function()
            local ok, reason = send(brainId, "stop")
            if not ok then flash("Rejected: " .. tostring(reason), false) end
            basalt.stop()
        end)

    -- Coarse volume on its own row above the fine one. The 1% steps are
    -- unusable on their own: the scale runs to 300%, so moving from 80% to
    -- a normal 33% took forty-odd taps. The brain already understood
    -- vol-10/vol+10 for exactly this -- only the remote never offered them.
    frame:addButton():setText("Vol --"):setPosition(bx, 9):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.orange)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol-10")
            if ok then status = newStatus updateLabels() end
        end)
    frame:addButton():setText("Vol ++"):setPosition(bx2, 9):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.orange)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol+10")
            if ok then status = newStatus updateLabels() end
        end)

    frame:addButton():setText("Vol -"):setPosition(bx, 11):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol-1")
            if ok then status = newStatus updateLabels() end
        end)
    frame:addButton():setText("Vol +"):setPosition(bx2, 11):setSize(btnW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function()
            local ok, _, newStatus = send(brainId, "vol+1")
            if ok then status = newStatus updateLabels() end
        end)

    frame:addButton():setText("Back"):setPosition(1, h):setSize(w, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() basalt.stop() end)

    -- Compact playlist view in the gap between the volume row and Back --
    -- the computer's Now Playing screen has one, the pocket didn't have
    -- ANYTHING playlist-related on this screen at all. Fixed set of label
    -- widgets created once (rows 10..h-1), text-only updates on every
    -- poll tick instead of recreating them -- avoids the same kind of
    -- per-tick widget churn/redraw cost that caused the audio-jump issue
    -- on the computer's wall visuals.
    --
    -- Shown for BOTH kinds now that videos have a queue of their own. It
    -- used to be music-only, because on a video the header could only ever
    -- read "Queue (0)" -- a permanently empty box taking up half the remote's
    -- screen and implying a feature that did not exist. That reasoning still
    -- holds when the video queue happens to be empty, so updatePlaylist
    -- blanks the whole block in that case rather than showing an empty one.
    local plTop, plBottom = 13, h - 1
    local plCapacity = math.max(0, plBottom - plTop)
    if plCapacity > 0 then
        playlistHeader = frame:addLabel():setPosition(1, plTop):setForeground(colors.lime):setBackground(colors.black)
        for i = 1, plCapacity do
            playlistLabels[i] = frame:addLabel():setPosition(1, plTop + i):setForeground(colors.white):setBackground(colors.black)
        end
    end

    -- Header and each queued song are centered (recentered on every
    -- update, since the text length changes as the queue changes) to
    -- match how the title/status above them are laid out.
    local function updatePlaylist(playlist)
        if not playlistHeader then return end
        playlist = playlist or {}
        -- Nothing queued: draw no header either, so a film plays against a
        -- clean screen instead of an empty box captioned "Queue (0)".
        if #playlist == 0 then
            centerLabel(playlistHeader, plTop, "")
            for i = 1, plCapacity do centerLabel(playlistLabels[i], plTop + i, "") end
            return
        end
        centerLabel(playlistHeader, plTop, ("Queue (%d)"):format(#playlist))
        for i = 1, plCapacity do
            local song = playlist[i]
            centerLabel(playlistLabels[i], plTop + i, song and song.name or "")
        end
    end

    updateLabels()
    updatePlaylist(nil)

    local stopped = false
    -- Whether the brain has confirmed, at least once, that it really is
    -- playing what this screen was opened for. Until it has, a mismatched
    -- status just means the brain hasn't started yet -- only AFTER seeing it
    -- play does a mismatch mean playback has ended.
    local sawPlaying = (initialStatus and initialStatus.screen == kind) or false

    basalt.schedule(function()
        while not stopped do
            local ok, _, newStatus, newPlaylist, newVideoPlaylist = send(brainId, "get_status")
            if ok then
                status = newStatus
                if kind == "video" then newPlaylist = newVideoPlaylist end
                if newStatus and newStatus.screen == kind then
                    sawPlaying = true
                elseif sawPlaying then
                    -- Playback finished (or was stopped from the computer).
                    -- Close this screen instead of sitting on it showing a
                    -- timestamp frozen at the end of the video, which looked
                    -- exactly like the remote having hung.
                    stopped = true
                    basalt.stop()
                    return
                end
                updateLabels()
                updatePlaylist(newPlaylist)
            end
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
local function playlistScreen(brainId, playlist, kind)
    local contentTop = 3
    -- 2 footer rows now, not 1 -- Prev/Next above, Play All/Back below --
    -- a playlist longer than one screenful used to just silently hide the
    -- extra songs with no way to see or remove them at all (confirmed:
    -- no pagination existed here, unlike every other list screen).
    local navRow = h - 1
    local footerRow = h
    local perPage = math.max(1, navRow - contentTop)
    local page = 1

    -- The same screen drives both queues; only the action names, the heading
    -- and the "where do I add things" hint differ.
    local isVideo = kind == "video"
    local removeAction = isVideo and "video_playlist_remove" or "playlist_remove"
    local playAction = isVideo and "play_video_playlist" or "play_playlist"
    local heading = isVideo and "VIDEO QUEUE" or "PLAYLIST"
    local emptyHint = isVideo and "Add from Video Player" or "Add from Music Player"

    local function draw()
        resetScreen()
        clearFrameChildren(frame)
        local totalPages = math.max(1, math.ceil(#playlist / perPage))
        if page > totalPages then page = totalPages end
        frame:addLabel():setText(("%s -- pg %d/%d"):format(heading, page, totalPages):sub(1, w))
            :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)

        if #playlist == 0 then
            frame:addLabel():setText(("(empty)"):sub(1, w)):setPosition(1, contentTop):setForeground(colors.gray):setBackground(colors.black)
            frame:addLabel():setText(emptyHint:sub(1, w)):setPosition(1, contentTop + 1):setForeground(colors.gray):setBackground(colors.black)
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
                            local ok, reason, _, newPlaylist, newVideoPlaylist = send(brainId, removeAction, song.name)
                            if isVideo then newPlaylist = newVideoPlaylist end
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
                local ok, reason, status = send(brainId, playAction)
                if ok then
                    basalt.stop()
                    transportScreen(brainId, isVideo and "video" or "music",
                        (status and status.name) or heading, status)
                    local _, _, _, newPlaylist, newVideoPlaylist = send(brainId, "get_status")
                    if isVideo then newPlaylist = newVideoPlaylist end
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
    resetScreen()
    clearFrameChildren(frame)

    local buttonW = math.min(w - 2, 20)
    local bx = math.max(1, math.floor((w - buttonW) / 2) + 1)
    local chosen = nil

    -- Whole block (title + 5 buttons) centered vertically as one unit
    -- rather than pinned to the top with all the empty space dumped at
    -- the bottom.
    local BLOCK_HEIGHT = 16 -- title(1) gap(2) 7 buttons w/ 1-row gaps (13)
    local blockTop = math.max(1, math.floor((h - BLOCK_HEIGHT) / 2) + 1)
    local titleY = blockTop
    local btnY = {
        blockTop + 3, blockTop + 5, blockTop + 7, blockTop + 9,
        blockTop + 11, blockTop + 13, blockTop + 15,
    }

    frame:addLabel():setText(config.TITLE:sub(1, w))
        :setPosition(math.max(1, math.floor((w - math.min(#config.TITLE, w)) / 2) + 1), titleY)
        :setForeground(colors.lime):setBackground(colors.black)

    frame:addButton():setText("Video Player"):setPosition(bx, btnY[1]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "video" basalt.stop() end)
    -- Films browse separately from clips, same as on the computer. Which
    -- repos hold them is config.lua's `films` flag, which the pocket reads
    -- from the very same file the brain does.
    frame:addButton():setText("Movies / Series"):setPosition(bx, btnY[2]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "movies" basalt.stop() end)
    frame:addButton():setText("Music Player"):setPosition(bx, btnY[3]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "music" basalt.stop() end)
    -- "Playlist" was ambiguous the moment videos got one of their own.
    frame:addButton():setText("Music Queue"):setPosition(bx, btnY[4]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "playlist" basalt.stop() end)
    frame:addButton():setText("Video Queue"):setPosition(bx, btnY[5]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "videoplaylist" basalt.stop() end)
    frame:addButton():setText("Now Playing"):setPosition(bx, btnY[6]):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() chosen = "nowplaying" basalt.stop() end)
    frame:addButton():setText("Quit"):setPosition(bx, btnY[7]):setSize(buttonW, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function() chosen = "quit" basalt.stop() end)

    frame:draw()
    basalt.run()

    if chosen == "video" or chosen == "movies" then
        local filmsOnly = chosen == "movies"
        local all = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        local videos = {}
        for _, v in ipairs(all) do
            if (v.__films == true) == filmsOnly then videos[#videos + 1] = v end
        end

        -- Only the clip list can queue anything, so only it needs to know
        -- what is on the queue. Fetched once and kept in step locally as
        -- items go on and off, rather than a round trip per row.
        local queued = {}
        local onAdd = nil
        if not filmsOnly then
            local _, _, _, _, queue = send(brainId, "get_status")
            for _, item in ipairs(queue or {}) do queued[item.name] = true end
            onAdd = function(v)
                local action = queued[v.name] and "video_playlist_remove" or "video_playlist_add"
                local ok, reason = send(brainId, action, v.name)
                if ok then queued[v.name] = not queued[v.name]
                else flash("Rejected: " .. tostring(reason), false) end
            end
        end

        local video = listScreen(filmsOnly and "MOVIES / SERIES" or "VIDEOS", videos,
            function(v) return (v.subs and "[S] " or "") .. v.name end,
            onAdd,
            function(v) return not v.__films end,
            function(v) return queued[v.name] and "-" or "+" end)
        if video then
            -- Asked on the remote, then carried to the brain with the play
            -- command -- whoever started playback is who gets asked.
            local subtitles = nil
            local go = true
            if type(video.subs) == "string" and video.subs ~= "" then
                subtitles = askSubtitles(video)
                go = subtitles ~= nil
            end
            if go then
                local ok, reason, status = send(brainId, "play_video", video.name, { subtitles = subtitles })
                if ok then transportScreen(brainId, "video", video.name, status)
                else flash("Rejected: " .. tostring(reason), false) end
            end
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
        if ok then playlistScreen(brainId, playlist or {}, "music")
        else flash("Rejected: " .. tostring(reason), false) end
    elseif chosen == "videoplaylist" then
        local ok, reason, _, _, videoPlaylist = send(brainId, "get_status")
        if ok then playlistScreen(brainId, videoPlaylist or {}, "video")
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
