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
-- = "..." } (name only used by play_video/play_music).
--
-- Run M.listen(config) as one branch of parallel.waitForAny/waitForAll
-- alongside whatever menu/player loop is active -- it never returns on its
-- own.

local M = {}

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
                os.queueEvent("movcctwx_remote_action", message.action, message.name)
                rednet.send(senderId, { ok = true }, config.REMOTE_PROTOCOL)
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
