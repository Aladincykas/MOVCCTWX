-- install-pocket.lua -- run this ONCE in-game on the pocket computer (the
-- one with a wireless modem crafted in). Downloads its 2 files straight
-- into this pocket computer's root. Overwrites whatever's already there,
-- so re-running this after a code update just re-pulls everything fresh.
--
-- Run in-game:
--   wget run https://raw.githubusercontent.com/Aladincykas/MOVCCTWX/main/install-pocket.lua

local GITHUB_USER = "Aladincykas"
local REPO = "MOVCCTWX"
local BRANCH = "main"

local FILES = {
    "startup.lua",
    "config.lua",
}

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/pocket/"):format(GITHUB_USER, REPO, BRANCH)

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

print("Installing MOVCCTWX pocket remote files...")

for _, relPath in ipairs(FILES) do
    print("  " .. relPath)
    download(BASE_URL .. relPath, relPath)
end

print("\nDone. Run 'startup.lua' now, or reboot to auto-start it.")
print("Make sure a wireless modem is attached/crafted in first.")
