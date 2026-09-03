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
--
-- The VIDEO playlist alongside it works the same way, with one deliberate
-- difference: its entries hold only { name = ... }, never the manifest entry
-- itself. A film's entry carries a couple of hundred chunk URLs, so keeping
-- whole entries would push hundreds of kilobytes through settings.json on
-- every add AND through every rednet ack, since each one carries the
-- playlists. Names are resolved against the manifest at play time, which also
-- means a video deleted from its repo is skipped rather than failing to
-- download halfway through the queue.
do
    local saved = settings.load()
    _G.MOVCCTWX_PLAYLIST = (type(saved.playlist) == "table") and saved.playlist or {}
    _G.MOVCCTWX_VIDEO_PLAYLIST = (type(saved.videoPlaylist) == "table") and saved.videoPlaylist or {}
end
function _G.MOVCCTWX_SAVE_PLAYLIST()
    local saved = settings.load()
    saved.playlist = _G.MOVCCTWX_PLAYLIST
    settings.save(saved)
end
function _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
    local saved = settings.load()
    saved.videoPlaylist = _G.MOVCCTWX_VIDEO_PLAYLIST
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

-- Returns the merged list, plus the labels of any libraries that did not
-- load.
--
-- A library that 404s, times out, or comes back as something other than JSON
-- used to vanish from the list silently. That is indistinguishable from "my
-- upload never arrived", which is the single most confusing failure this
-- project has -- so the caller now says how many libraries are missing
-- instead of quietly showing a short list.
--
-- Entries without a usable name are dropped here too. One malformed record
-- used to take down the whole menu on `video.name:sub(...)`, losing access to
-- every other video in the library along with it.
local function fetchMergedManifest(libraries, manifestFile)
    local items = {}
    local failed = {}
    for _, lib in ipairs(libraries) do
        local url = ("https://raw.githubusercontent.com/%s/%s/%s/%s?t=%s")
            :format(config.GITHUB_USER, lib.repo, lib.branch, manifestFile, tostring(os.epoch("utc")))
        local ok, response = pcall(http.get, url)
        local parsed = nil
        if ok and response then
            local body = response.readAll()
            response.close()
            parsed = textutils.unserialiseJSON(body)
        end
        if type(parsed) == "table" then
            for _, item in ipairs(parsed) do
                if type(item) == "table" and type(item.name) == "string" then
                    -- Which library an entry came from. Prefixed so it can
                    -- never collide with a field the manifest itself defines.
                    item.__films = lib.films == true
                    item.__library = lib.label
                    table.insert(items, item)
                end
            end
        else
            table.insert(failed, lib.label or lib.repo)
        end
    end
    return items, failed
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

-- Does this entry ship a subtitle file?
local function hasSubtitles(entry)
    return type(entry.subs) == "string" and entry.subs ~= ""
end

-- Asks whether to show subtitles. Returns true, false, or nil for "go back".
--
-- Only reached when the video actually HAS subtitles -- anything without
-- them plays straight away, which is what keeps the extra tap tolerable on
-- the ones that do.
local function askSubtitles(entry)
    local answer, backed = nil, false
    resetScreen()
    clearFrameChildren(frame)

    local buttonW = math.min(w - 4, 28)
    local bx = math.max(1, math.floor((w - buttonW) / 2) + 1)
    local top = math.max(2, math.floor((h - 9) / 2) + 1)

    frame:addLabel():setText(entry.name:sub(1, w - 2))
        :setPosition(2, top):setForeground(colors.white):setBackground(colors.black)
    frame:addLabel():setText("This one has subtitles.")
        :setPosition(2, top + 1):setForeground(colors.lightGray):setBackground(colors.black)

    frame:addButton():setText("Play WITH subtitles"):setPosition(bx, top + 3):setSize(buttonW, 1)
        :setBackground(colors.lime):setForeground(colors.black)
        :onClick(function() answer = true basalt.stop() end)
    frame:addButton():setText("Play without"):setPosition(bx, top + 5):setSize(buttonW, 1)
        :setBackground(colors.gray):setForeground(colors.lime)
        :onClick(function() answer = false basalt.stop() end)
    frame:addButton():setText("Back"):setPosition(bx, top + 7):setSize(buttonW, 1)
        :setBackground(colors.red):setForeground(colors.white)
        :onClick(function() backed = true basalt.stop() end)

    frame:addLabel():setText("[t] toggles them mid-video too.")
        :setPosition(2, math.min(h, top + 9)):setForeground(colors.gray):setBackground(colors.black)

    frame:draw()
    basalt.run()
    if backed or _G.MOVCCTWX_TERMINATED or _G.MOVCCTWX_REMOTE_PENDING then return nil end
    return answer
end

-- Plays every video on the video playlist in order.
--
-- Shared by the Play All button and the remote's play_video_playlist, so
-- both behave identically. Subtitles follow config.SUBTITLES here rather
-- than prompting: stopping between queued clips to ask a question would
-- defeat the point of a queue.
local function playVideoPlaylist(videoplayer, videos)
    local playlist = _G.MOVCCTWX_VIDEO_PLAYLIST
    local i = 1
    while i <= #playlist and not _G.MOVCCTWX_TERMINATED and not _G.MOVCCTWX_REMOTE_PENDING do
        local match = nil
        for _, v in ipairs(videos) do
            if v.name == playlist[i].name then match = v break end
        end
        if match then
            local reason = videoplayer.play(getWall("video"), term, speakers, match, config)
            -- "stopped" means somebody pressed stop, which should end the
            -- whole queue rather than move to the next one.
            if reason ~= "done" then break end
        end
        i = i + 1
    end
end

local function runVideoMenu()
    local videoplayer = require("videoplayer")
    local exitReason = nil
    local screen = "library"
    local ROW_STEP = 2
    local contentTop = 3
    local footerRow = h
    local playlist = _G.MOVCCTWX_VIDEO_PLAYLIST

    local videos, loadErrors = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")

    local page, playlistPage, addPage = 1, 1, 1
    local selectedVideo, nextScreen, playlistAction = nil, nil, nil

    -- Only clips can be queued. See config.lua's VIDEO_LIBRARIES comment.
    local function addable()
        local out = {}
        for _, v in ipairs(videos) do
            if not v.__films then out[#out + 1] = v end
        end
        return out
    end

    local function onPlaylist(name)
        for _, item in ipairs(playlist) do
            if item.name == name then return true end
        end
        return false
    end

    local function addToPlaylist(video)
        if onPlaylist(video.name) then return false end
        -- Only the name: see the MOVCCTWX_VIDEO_PLAYLIST comment at the top.
        table.insert(playlist, { name = video.name })
        _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
        return true
    end

    -- Four footer buttons plus a right-anchored exit, sized from the real
    -- screen width. The old fixed widths left about four free columns on this
    -- computer's terminal, which is not enough for another button.
    local backW = math.min(12, math.max(6, math.floor(w * 0.22)))
    local navW = math.max(6, math.floor((w - 4 - backW - 2) / 3))
    local navX = { 2, 3 + navW, 4 + navW * 2 }
    -- Right-anchored. Deliberately NOT max()'d against where the nav row
    -- ends: on a screen too narrow for all four, overlapping is recoverable
    -- and being pushed off the right edge is not.
    local backX = w - backW + 1

    local perPage = math.max(1, math.floor((footerRow - contentTop) / ROW_STEP))
    -- The playlist screen carries an extra footer row (Play All / Back) above
    -- the navigation one, so it fits one row fewer than the library does.
    local playlistPerPage = math.max(1, math.floor((footerRow - ROW_STEP - contentTop) / ROW_STEP))

    local function header(text, subtitle, subtitleColor)
        frame:addLabel():setText(text:sub(1, w))
            :setSize(w, 1):setPosition(1, 1):setForeground(colors.lime):setBackground(colors.gray)
        frame:addLabel():setText(subtitle:sub(1, w))
            :setPosition(2, 2):setForeground(subtitleColor or colors.lightGray):setBackground(colors.black)
    end

    local drawLibrary, drawPlaylist, drawAddVideos

    function drawLibrary()
        resetScreen()
        clearFrameChildren(frame)
        local totalPages = math.max(1, math.ceil(#videos / perPage))
        if page > totalPages then page = totalPages end

        local note, noteColor
        if #loadErrors > 0 then
            note = ("%d video(s) -- %d librar(ies) did not load"):format(#videos, #loadErrors)
            noteColor = colors.red
        elseif #videos == 0 then
            note = "No videos yet."
        else
            note = ("%d video(s) -- page %d/%d"):format(#videos, page, totalPages)
        end
        header(" DIDZIULIS EKRANAS -- SELECT A VIDEO ", note, noteColor)

        local addW = 3
        local startIdx = (page - 1) * perPage + 1
        for i = 0, perPage - 1 do
            local video = videos[startIdx + i]
            if video then
                local rowY = contentTop + i * ROW_STEP
                -- A film gets the whole row; a clip gives up three columns to
                -- its queue button.
                local rowW = video.__films and (w - 2) or (w - 2 - addW - 1)
                local label = video.name
                if hasSubtitles(video) then label = label .. " [S]" end
                frame:addButton()
                    :setText(label:sub(1, rowW - 2))
                    :setPosition(2, rowY)
                    :setSize(rowW, 1)
                    :setBackground(colors.gray)
                    :setForeground(colors.lime)
                    :onClick(function() selectedVideo = video basalt.stop() end)
                if not video.__films then
                    local queued = onPlaylist(video.name)
                    frame:addButton()
                        :setText(queued and "-" or "+")
                        :setPosition(w - addW, rowY)
                        :setSize(addW, 1)
                        :setBackground(queued and colors.lime or colors.gray)
                        :setForeground(queued and colors.black or colors.lime)
                        :onClick(function()
                            if onPlaylist(video.name) then
                                for j, item in ipairs(playlist) do
                                    if item.name == video.name then table.remove(playlist, j) break end
                                end
                                _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
                            else
                                addToPlaylist(video)
                            end
                            drawLibrary()
                        end)
                end
            end
        end

        frame:addButton():setText("< Prev"):setPosition(navX[1], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page > 1 then page = page - 1 end drawLibrary() end)
        frame:addButton():setText("Next >"):setPosition(navX[2], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if page < totalPages then page = page + 1 end drawLibrary() end)
        frame:addButton():setText(("Queue (%d)"):format(#playlist)):setPosition(navX[3], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() nextScreen = "playlist" basalt.stop() end)
        frame:addButton():setText("Menu"):setPosition(backX, footerRow):setSize(backW, 1)
            :setBackground(colors.red):setForeground(colors.white)
            :onClick(function() exitReason = "menu" basalt.stop() end)
    end

    function drawPlaylist()
        resetScreen()
        clearFrameChildren(frame)
        local totalPages = math.max(1, math.ceil(#playlist / playlistPerPage))
        if playlistPage > totalPages then playlistPage = totalPages end

        header(" VIDEO QUEUE ",
            #playlist == 0 and "Empty -- tap + Add below."
                or ("%d video(s) -- page %d/%d"):format(#playlist, playlistPage, totalPages))

        local removeW = 3
        local startIdx = (playlistPage - 1) * playlistPerPage + 1
        for i = 0, playlistPerPage - 1 do
            local idx = startIdx + i
            local item = playlist[idx]
            if item then
                local rowY = contentTop + i * ROW_STEP
                -- A queued name whose video is no longer in any library is
                -- shown greyed rather than hidden, so it can be removed
                -- rather than silently skipped forever at play time.
                local stillThere = false
                for _, v in ipairs(videos) do
                    if v.name == item.name then stillThere = true break end
                end
                frame:addLabel()
                    :setText((("%d. %s"):format(idx, item.name)):sub(1, w - removeW - 3))
                    :setPosition(2, rowY)
                    :setSize(w - removeW - 2, 1)
                    :setForeground(stillThere and colors.white or colors.gray)
                    :setBackground(colors.black)
                frame:addButton()
                    :setText("X")
                    :setPosition(w - removeW, rowY)
                    :setSize(removeW, 1)
                    :setBackground(colors.red)
                    :setForeground(colors.white)
                    :onClick(function()
                        table.remove(playlist, idx)
                        _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
                        drawPlaylist()
                    end)
            end
        end

        frame:addButton():setText("< Prev"):setPosition(navX[1], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if playlistPage > 1 then playlistPage = playlistPage - 1 end drawPlaylist() end)
        frame:addButton():setText("Next >"):setPosition(navX[2], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if playlistPage < totalPages then playlistPage = playlistPage + 1 end drawPlaylist() end)
        frame:addButton():setText("+ Add"):setPosition(navX[3], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() playlistAction = "add" basalt.stop() end)

        local topRow = footerRow - ROW_STEP
        local halfW = math.max(6, math.floor((w - 3) / 2))
        frame:addButton():setText("Play All"):setPosition(2, topRow):setSize(halfW, 1)
            :setBackground(#playlist > 0 and colors.lime or colors.gray)
            :setForeground(#playlist > 0 and colors.black or colors.lightGray)
            :onClick(function()
                if #playlist > 0 then playlistAction = "play" basalt.stop() end
            end)
        frame:addButton():setText("Back"):setPosition(3 + halfW, topRow):setSize(halfW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() playlistAction = "back" basalt.stop() end)
    end

    function drawAddVideos()
        resetScreen()
        clearFrameChildren(frame)
        local pool = addable()
        local totalPages = math.max(1, math.ceil(#pool / perPage))
        if addPage > totalPages then addPage = totalPages end

        header(" ADD TO VIDEO QUEUE ",
            #pool == 0 and "No clips available (films cannot be queued)."
                or ("%d clip(s) -- page %d/%d -- queue: %d"):format(#pool, addPage, totalPages, #playlist))

        local startIdx = (addPage - 1) * perPage + 1
        for i = 0, perPage - 1 do
            local video = pool[startIdx + i]
            if video then
                local queued = onPlaylist(video.name)
                frame:addButton()
                    :setText(((queued and "* " or "  ") .. video.name):sub(1, w - 4))
                    :setPosition(2, contentTop + i * ROW_STEP)
                    :setSize(w - 2, 1)
                    :setBackground(queued and colors.lime or colors.gray)
                    :setForeground(queued and colors.black or colors.lime)
                    :onClick(function()
                        -- Tap again to take it back off, so a mistap costs one
                        -- tap rather than a trip to the queue screen.
                        if onPlaylist(video.name) then
                            for j, item in ipairs(playlist) do
                                if item.name == video.name then table.remove(playlist, j) break end
                            end
                            _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
                        else
                            addToPlaylist(video)
                        end
                        drawAddVideos()
                    end)
            end
        end

        frame:addButton():setText("< Prev"):setPosition(navX[1], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if addPage > 1 then addPage = addPage - 1 end drawAddVideos() end)
        frame:addButton():setText("Next >"):setPosition(navX[2], footerRow):setSize(navW, 1)
            :setBackground(colors.gray):setForeground(colors.lime)
            :onClick(function() if addPage < totalPages then addPage = addPage + 1 end drawAddVideos() end)
        frame:addButton():setText("Done"):setPosition(backX, footerRow):setSize(backW, 1)
            :setBackground(colors.red):setForeground(colors.white)
            :onClick(function() playlistAction = "back" basalt.stop() end)
    end

    while not exitReason and not _G.MOVCCTWX_TERMINATED and not _G.MOVCCTWX_REMOTE_PENDING do
        selectedVideo, nextScreen, playlistAction = nil, nil, nil

        if screen == "library" then
            drawLibrary()
        elseif screen == "playlist" then
            drawPlaylist()
        else
            drawAddVideos()
        end
        frame:draw()
        basalt.run()

        if _G.MOVCCTWX_TERMINATED then return "quit" end
        if _G.MOVCCTWX_REMOTE_PENDING then return "menu" end

        if selectedVideo then
            -- Asked here, not inside the player: the player is a raw event
            -- loop with the wall already handed to it, and a Basalt screen
            -- cannot be opened from in there.
            local subtitleChoice = nil
            local go = true
            if hasSubtitles(selectedVideo) then
                subtitleChoice = askSubtitles(selectedVideo)
                go = subtitleChoice ~= nil
            end
            if go then
                videoplayer.play(getWall("video"), term, speakers, selectedVideo, config,
                    { subtitles = subtitleChoice })
                if _G.MOVCCTWX_TERMINATED then return "quit" end
                if _G.MOVCCTWX_REMOTE_PENDING then return "menu" end
                -- Something may have been uploaded while that was playing.
                videos, loadErrors = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
            end
        elseif nextScreen then
            screen = nextScreen
        elseif playlistAction == "play" then
            playVideoPlaylist(videoplayer, videos)
            if _G.MOVCCTWX_TERMINATED then return "quit" end
            if _G.MOVCCTWX_REMOTE_PENDING then return "menu" end
            videos, loadErrors = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        elseif playlistAction == "add" then
            screen = "addVideos"
        elseif playlistAction == "back" then
            screen = (screen == "addVideos") and "playlist" or "library"
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
                local videoplayer = require("videoplayer")
                local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
                if screen.playAllPlaylist then
                    playVideoPlaylist(videoplayer, videos)
                elseif screen.name then
                    local match = nil
                    for _, v in ipairs(videos) do if v.name == screen.name then match = v end end
                    if match then
                        videoplayer.play(getWall("video"), term, speakers, match, config,
                            { subtitles = screen.subtitles })
                    end
                end
                _G.MOVCCTWX_STATUS = { screen = "menu" }
                -- Checked HERE, not left to the loop's own quit branch: that
                -- branch sits BELOW the "menu" one, so quitting out of a
                -- remotely started video used to drop straight back into the
                -- main menu -- and with the terminate watcher already spent,
                -- Ctrl+T no longer worked there.
                screen = _G.MOVCCTWX_TERMINATED and "quit" or "menu"
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
        -- The third value is a per-command option: for play_video it is the
        -- pocket's subtitle answer (true/false), absent for everything else.
        -- A plain boolean rather than a table, since os.queueEvent's handling
        -- of table arguments is not something worth depending on here.
        local _, action, name, option = os.pullEvent("movcctwx_remote_action")
        if action == "open_video_menu" then
            _G.MOVCCTWX_REMOTE_TARGET = "video"
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "open_music_menu" then
            _G.MOVCCTWX_REMOTE_TARGET = "music"
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "play_video" then
            _G.MOVCCTWX_REMOTE_TARGET = { screen = "video", name = name, subtitles = option }
            _G.MOVCCTWX_REMOTE_PENDING = true
        elseif action == "play_video_playlist" then
            _G.MOVCCTWX_REMOTE_TARGET = { screen = "video", playAllPlaylist = true }
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
