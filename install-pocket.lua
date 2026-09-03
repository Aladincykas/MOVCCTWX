-- install-pocket.lua -- run this ONCE in-game on the pocket computer (the
-- one with a wireless modem crafted in). Downloads its files straight
-- into this pocket computer's root (startup.lua, config.lua, and a copy
-- of basalt.lua -- the pocket UI is Basalt-based too). Overwrites
-- whatever's already there, so re-running this after a code update just
-- re-pulls everything fresh.
--
-- Run in-game:
--   wget run https://raw.githubusercontent.com/Aladincykas/MOVCCTWX/main/install-pocket.lua

local GITHUB_USER = "Aladincykas"
local REPO = "MOVCCTWX"
local BRANCH = "main"

-- Absolute destination paths -- see install-brain.lua's comment on the
-- same FILES table for why relative paths here would be a real bug
-- (writes into whatever the shell's current directory happens to be,
-- instead of always overwriting the real files at root).
local FILES = {
    "/startup.lua",
    "/config.lua",
}

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/pocket/"):format(GITHUB_USER, REPO, BRANCH)

local function download(url, destPath)
    -- Deletes the old file first, THEN writes the new one, instead of
    -- just opening it in "w" mode (which already truncates -- this isn't
    -- fixing a real overwrite bug, fs.open("w") always replaces the full
    -- content). This exists to rule out any possibility of stale content
    -- surviving an install, full stop -- delete-then-recreate can't
    -- leave anything old behind, whatever the cause of a report was.
    if fs.exists(destPath) then fs.delete(destPath) end
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

print("Installing MOVCCTWX pocket remote files into / ...")

for _, absPath in ipairs(FILES) do
    print("  " .. absPath)
    download(BASE_URL .. absPath:sub(2), absPath)
end

-- basalt.lua isn't duplicated in pocket/ in the repo -- it's the exact
-- same vendored framework file the brain computer uses, so this just
-- reuses that copy instead of maintaining two identical files.
print("  /basalt.lua")
download(("https://raw.githubusercontent.com/%s/%s/%s/brain/basalt.lua"):format(GITHUB_USER, REPO, BRANCH), "/basalt.lua")

-- Same reasoning as install-brain.lua's matching comment: CC caches
-- loaded code in memory until reboot, so this reboots automatically
-- instead of relying on a separate manual step every time.
print("\nDone. Rebooting to load the new files (reboots always required --")
print("CC caches loaded code in memory until then)...")
print("Make sure a wireless modem is attached/crafted in first.")
sleep(1.5)
os.reboot()
