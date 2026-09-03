-- remote.lua -- brain-side rednet listener for pocket computer control.
--
-- Opens every wireless modem found, hosts REMOTE_PROTOCOL, and runs a
-- receive loop that checks the sender's computer ID against
-- config.REMOTE_ALLOWLIST before doing anything. Anything from an ID not
-- on the list is dropped -- never turned into an action, never
-- acknowledged beyond a rejection reply, so an unapproved pocket computer
-- can't control playback or even confirm it exists as a listener.
--
-- Approved commands get turned into a "movcctwx_remote_action" event with
-- (action, name) as the event's arguments -- videoplayer.lua and
-- musicplayer.lua listen for the plain transport actions (playpause, stop,
-- vol+1, vol-1, vol+10, vol-10) alongside their normal keyboard input, and
-- startup.lua's menu loop listens for the menu-level ones (open_video_menu,
-- open_music_menu, play_video/play_music with a `name`), so a remote
-- command is handled exactly like sitting at the computer, whichever
-- screen happens to be active.
--
-- Expected message shape from the pocket computer: { action = "...", name
-- = "..." } (name only used by play_video/play_music/playlist_remove),
-- or { action = "playlist_add", song = {name=, url=...} } (the pocket
-- already has the full song table from its own manifest fetch, so it
-- sends that directly instead of making the brain re-fetch/re-look-up).
--
-- get_status, playlist_add/playlist_remove and their video_ equivalents are
-- all "reads/local mutations", not commands -- handled entirely INLINE below,
-- never turned
-- into a movcctwx_remote_action event, because they don't need to
-- interrupt or navigate whatever screen is currently showing (unlike
-- play_video/play_music/play_playlist, which do, and go through the
-- normal event -> startup.lua's remoteMenuWatcher path same as before).
-- _G.MOVCCTWX_PLAYLIST is a plain shared table (see startup.lua) -- both
-- these handlers and the computer's own Playlist screen
-- (musicplayer.lua) mutate the SAME table in place.
--
-- Every ack carries the CURRENT _G.MOVCCTWX_STATUS and
-- _G.MOVCCTWX_PLAYLIST snapshots (status kept up to date by
-- videoplayer.lua/musicplayer.lua while something's playing -- see their
-- comments), so the pocket computer can show live title/paused/elapsed/
-- volume and the current playlist contents without a second round-trip
-- after every command.
--
-- Run M.listen(config) as one branch of parallel.waitForAny/waitForAll
-- alongside whatever menu/player loop is active -- it never returns on its
-- own.

local M = {}

local NO_NAVIGATE_ACTIONS = {
    get_status = true,
    playlist_add = true, playlist_remove = true,
    video_playlist_add = true, video_playlist_remove = true,
}

local function handlePlaylistAdd(song)
    if type(song) ~= "table" or not song.name then return end
    for _, existing in ipairs(_G.MOVCCTWX_PLAYLIST) do
        if existing.name == song.name then return end -- already on the playlist
    end
    table.insert(_G.MOVCCTWX_PLAYLIST, song)
    _G.MOVCCTWX_SAVE_PLAYLIST()
end

-- The video queue holds NAMES only, never manifest entries -- a film's entry
-- is a couple of hundred chunk URLs, and this table is persisted to disk and
-- attached to every ack. startup.lua resolves a name against the library when
-- it actually comes to play it.
local function handleVideoPlaylistAdd(name)
    if type(name) ~= "string" or name == "" then return end
    for _, existing in ipairs(_G.MOVCCTWX_VIDEO_PLAYLIST) do
        if existing.name == name then return end
    end
    table.insert(_G.MOVCCTWX_VIDEO_PLAYLIST, { name = name })
    _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
end

local function handleVideoPlaylistRemove(name)
    for i, existing in ipairs(_G.MOVCCTWX_VIDEO_PLAYLIST) do
        if existing.name == name then
            table.remove(_G.MOVCCTWX_VIDEO_PLAYLIST, i)
            _G.MOVCCTWX_SAVE_VIDEO_PLAYLIST()
            return
        end
    end
end

local function handlePlaylistRemove(name)
    for i, existing in ipairs(_G.MOVCCTWX_PLAYLIST) do
        if existing.name == name then
            table.remove(_G.MOVCCTWX_PLAYLIST, i)
            _G.MOVCCTWX_SAVE_PLAYLIST()
            return
        end
    end
end

local function openModems()
    local opened = false
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and not rednet.isOpen(name) then
            rednet.open(name)
            opened = true
        end
    end
    if not opened and not rednet.isOpen() then
        error("No wireless modem found/opened -- attach one to pair with the pocket computer.")
    end
end

local function isAllowed(config, senderId)
    for _, id in ipairs(config.REMOTE_ALLOWLIST) do
        if id == senderId then return true end
    end
    return false
end

function M.listen(config)
    openModems()
    rednet.host(config.REMOTE_PROTOCOL, config.TITLE)

    while true do
        local senderId, message = rednet.receive(config.REMOTE_PROTOCOL)
        if type(message) == "table" and message.action then
            if isAllowed(config, senderId) then
                if message.action == "playlist_add" then
                    handlePlaylistAdd(message.song)
                elseif message.action == "playlist_remove" then
                    handlePlaylistRemove(message.name)
                elseif message.action == "video_playlist_add" then
                    handleVideoPlaylistAdd(message.name)
                elseif message.action == "video_playlist_remove" then
                    handleVideoPlaylistRemove(message.name)
                elseif not NO_NAVIGATE_ACTIONS[message.action] then
                    -- Third argument is a per-command option -- currently only
                    -- play_video's subtitle answer, which has to survive the
                    -- trip because the pocket asks the question and the brain
                    -- is what acts on it.
                    os.queueEvent("movcctwx_remote_action", message.action, message.name, message.subtitles)
                end
                rednet.send(senderId, {
                    ok = true,
                    status = _G.MOVCCTWX_STATUS,
                    playlist = _G.MOVCCTWX_PLAYLIST,
                    videoPlaylist = _G.MOVCCTWX_VIDEO_PLAYLIST,
                }, config.REMOTE_PROTOCOL)
            else
                -- Not on the allowlist -- reject, and print the ID so the
                -- owner can add it to config.lua's REMOTE_ALLOWLIST without
                -- having to go dig for it separately.
                print(("Remote control rejected from computer #%d (not on REMOTE_ALLOWLIST)."):format(senderId))
                rednet.send(senderId, { ok = false, reason = "not allowlisted" }, config.REMOTE_PROTOCOL)
            end
        end
    end
end

return M
