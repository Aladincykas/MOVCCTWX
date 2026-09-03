-- install-brain.lua -- run this ONCE in-game on the brain computer (the
-- Advanced Computer that will own the menu/players -- not a pocket
-- computer, not a wall monitor). Downloads every file straight from
-- GitHub into this computer's root, flat (except vendor/), so
-- require("config") etc resolve without any subfolder wrapper. Overwrites
-- whatever's already there, so re-running this after a code update just
-- re-pulls everything fresh.
--
-- Run in-game:
--   wget run https://raw.githubusercontent.com/Aladincykas/MOVCCTWX/main/install-brain.lua

local GITHUB_USER = "Aladincykas"
local REPO = "MOVCCTWX"
local BRANCH = "main"

-- Absolute destination paths ("/config.lua" etc), NOT relative ones --
-- a relative fs path resolves against the SHELL's current directory,
-- which depends on where you happen to be standing (cd-wise) when you run
-- this, not where startup.lua actually lives. A relative path here could
-- silently write into some other directory instead of overwriting the
-- real files at root, leaving root's stale files (e.g. an old config.lua)
-- in place with no error at all -- confirmed as the real cause of a
-- "reinstalled but still using the old WALL_MONITOR_NAMES" report.
-- Leading "/" always means root, regardless of current directory.
local FILES = {
    "/startup.lua",
    "/config.lua",
    "/wall.lua",
    "/remote.lua",
    "/musicplayer.lua",
    "/videoplayer.lua",
    "/settings.lua",
    "/basalt.lua",
    "/vendor/32vid-decode.lua",
}

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/brain/"):format(GITHUB_USER, REPO, BRANCH)

local function download(url, destPath)
    local response, err = http.get(url .. "?t=" .. tostring(os.epoch("utc")))
    if not response then
        error(("Failed to download %s: %s"):format(url, tostring(err)))
    end
    local body = response.readAll()
    response.close()
    local f = fs.open(destPath, "w")
    f.write(body)
    f.close()
end

print("Installing MOVCCTWX brain computer files into / ...")
if not fs.exists("/vendor") then fs.makeDir("/vendor") end

for _, absPath in ipairs(FILES) do
    print("  " .. absPath)
    download(BASE_URL .. absPath:sub(2), absPath)
end

print("\nDone. Edit config.lua's WALL_MONITOR_NAMES to match your 12 monitors")
print("(peripheral.getNames() lists them), then run 'startup.lua' or reboot.")
