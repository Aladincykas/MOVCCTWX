-- startup.lua -- pocket computer remote control. Plain term UI on purpose
-- (no Basalt) -- the pocket screen is small and this only ever needs a
-- vertical list + a few key bindings, so a whole UI framework isn't worth
-- shipping to it.
--
-- Every command is sent as one rednet message: { action = "...", name =
-- "..." } on config.REMOTE_PROTOCOL, and the brain computer either allows
-- or rejects it based on its own REMOTE_ALLOWLIST -- this side has no way
-- to grant itself access, it can only ask and see whether the answer was
-- "ok".

local config = require("config")

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
    local id = rednet.lookup(config.REMOTE_PROTOCOL)
    return id
end

-- Sends one command and waits briefly for the brain's ok/reject reply.
-- Returns true, nil, status on success (status is the brain's current
-- _G.MOVCCTWX_STATUS snapshot -- see remote.lua -- attached to every ack,
-- not just get_status's); false, reason on rejection/timeout.
local function send(brainId, action, name)
    rednet.send(brainId, { action = action, name = name }, config.REMOTE_PROTOCOL)
    local senderId, message = rednet.receive(config.REMOTE_PROTOCOL, 3)
    if senderId ~= brainId or type(message) ~= "table" then
        return false, "no response (brain offline or out of range)"
    end
    if not message.ok then
        return false, message.reason or "rejected"
    end
    return true, nil, message.status
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

local function centerText(y, text, fg)
    local w = term.getSize()
    term.setCursorPos(math.max(1, math.floor((w - #text) / 2) + 1), y)
    if fg then term.setTextColor(fg) end
    term.write(text)
end

local function flash(text, ok)
    term.setBackgroundColor(colors.black)
    term.clear()
    centerText(3, text, ok and colors.lime or colors.red)
    os.sleep(1.2)
end

-- Simple up/down/enter list picker. Returns the chosen item, or nil if the
-- user backed out with Q.
local function pickFromList(title, items, labelFn)
    local w, h = term.getSize()
    local top = 3
    local perPage = h - top - 1
    local selected = 1
    local scroll = 0

    while true do
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        centerText(1, title, colors.lime)
        if #items == 0 then
            centerText(top, "(empty)", colors.gray)
        else
            if selected < scroll + 1 then scroll = selected - 1 end
            if selected > scroll + perPage then scroll = selected - perPage end
            for i = 1, math.min(perPage, #items - scroll) do
                local idx = scroll + i
                local item = items[idx]
                term.setCursorPos(1, top + i - 1)
                if idx == selected then
                    term.setBackgroundColor(colors.gray)
                    term.setTextColor(colors.lime)
                else
                    term.setBackgroundColor(colors.black)
                    term.setTextColor(colors.white)
                end
                term.clearLine()
                term.write((" " .. labelFn(item)):sub(1, w))
            end
        end
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.lightGray)
        term.setCursorPos(1, h)
        term.clearLine()
        term.write("Up/Down Enter=play Q=back")

        local event, key = os.pullEvent("key")
        if key == keys.up then
            selected = math.max(1, selected - 1)
        elseif key == keys.down then
            selected = math.min(#items, selected + 1)
        elseif key == keys.enter and #items > 0 then
            return items[selected]
        elseif key == keys.q then
            return nil
        end
    end
end

-- Now-playing transport screen: sends playpause/stop/volume commands, and
-- polls the brain once a second for live status (title/paused/elapsed/
-- volume) so this doesn't just sit there as static instructions -- every
-- command's own response ALSO carries a fresh status snapshot (see
-- send()), so the display updates immediately on a keypress too, not just
-- on the next poll tick.
-- Q returns to the list without stopping playback on the brain side.
-- initialStatus: the status snapshot from the play_video/play_music call
-- that got us here, if any -- shown immediately instead of a blank first
-- frame while waiting for the first poll.
local function transportScreen(brainId, kind, name, initialStatus)
    local status = initialStatus

    local function draw()
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        centerText(2, kind == "video" and "DIDZIULIS EKRANAS" or "MUSIC", colors.lime)
        centerText(4, name:sub(1, term.getSize()), colors.white)
        if status and status.screen == kind then
            centerText(5, (status.paused and "|| PAUSED  " or "> PLAYING  ") .. formatTime(status.elapsedSec), colors.lightGray)
            centerText(6, ("Volume: %d%%"):format(status.volumePct or 0), colors.lightGray)
        else
            centerText(5, "(connecting...)", colors.gray)
        end
        centerText(8, "space=play/pause  s=stop", colors.lightGray)
        centerText(9, "left/right=volume  q=back", colors.lightGray)
    end

    draw()
    local pollTimer = os.startTimer(1)
    while true do
        local event, p1 = os.pullEvent()

        if event == "timer" and p1 == pollTimer then
            local ok, _, newStatus = send(brainId, "get_status")
            if ok then status = newStatus end
            draw()
            pollTimer = os.startTimer(1)
        elseif event == "key" then
            local action = nil
            if p1 == keys.space then action = "playpause"
            elseif p1 == keys.s then action = "stop"
            elseif p1 == keys.left then action = "vol-1"
            elseif p1 == keys.right then action = "vol+1"
            elseif p1 == keys.q then return
            end
            if action then
                local ok, reason, newStatus = send(brainId, action)
                if not ok then flash("Rejected: " .. tostring(reason), false) return end
                if action == "stop" then return end
                status = newStatus
                draw()
            end
        end
    end
end

-- ==== Main ====
openModem()
flash("Looking for " .. config.TITLE .. "...", true)
local brainId = findBrain()
if not brainId then
    flash("Brain computer not found on " .. config.REMOTE_PROTOCOL, false)
    error("No brain computer responded to rednet.lookup.", 0)
end

while true do
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    centerText(2, config.TITLE, colors.lime)
    centerText(5, "1) Video Player", colors.white)
    centerText(6, "2) Music Player", colors.white)
    centerText(8, "Q) Quit", colors.lightGray)

    local event, key = os.pullEvent("key")
    if key == keys.one then
        local videos = fetchMergedManifest(config.VIDEO_LIBRARIES, "videos.json")
        local video = pickFromList("VIDEOS", videos, function(v) return v.name end)
        if video then
            local ok, reason, status = send(brainId, "play_video", video.name)
            if ok then transportScreen(brainId, "video", video.name, status)
            else flash("Rejected: " .. tostring(reason), false) end
        end
    elseif key == keys.two then
        local songs = fetchMergedManifest(config.MUSIC_LIBRARIES, "songs.json")
        local song = pickFromList("MUSIC", songs, function(s) return s.name end)
        if song then
            local ok, reason, status = send(brainId, "play_music", song.name)
            if ok then transportScreen(brainId, "music", song.name, status)
            else flash("Rejected: " .. tostring(reason), false) end
        end
    elseif key == keys.q then
        break
    end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
