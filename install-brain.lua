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
    "/wallviz.lua",
    "/idlescreen.lua",
    "/videoplayer.lua",
    "/settings.lua",
    "/basalt.lua",
    "/vendor/32vid-decode.lua",
}

-- Resolves the branch to the exact commit it currently points at, and
-- downloads everything from THAT commit's URLs rather than the branch's.
--
-- This is not belt-and-braces, it is the only thing that works. GitHub's
-- raw CDN caches for five minutes and does NOT include the query string in
-- its cache key -- so the "?t=<timestamp>" trick this installer used, and
-- the "?nocache=N" people add by hand, bust nothing at all. Verified
-- directly: a request with a fresh random query still came back
-- "X-Cache: HIT" with the previous version's byte count, while the API
-- reported the new size. That is the whole explanation for a long run of
-- "I reinstalled and it is still the old code".
--
-- A commit-pinned URL is a different path per commit, so it can never
-- serve a stale copy. The API call itself is not CDN-cached this way.
local function resolveCommit()
    local response = http.get(
        ("https://api.github.com/repos/%s/%s/commits/%s"):format(GITHUB_USER, REPO, BRANCH),
        { Accept = "application/vnd.github.sha" })
    if not response then return nil end
    local sha = response.readAll()
    response.close()
    if type(sha) ~= "string" then return nil end
    sha = sha:gsub("%s", "")
    if #sha < 7 then return nil end
    return sha
end

local COMMIT = resolveCommit()
if COMMIT then
    print("Installing from commit " .. COMMIT:sub(1, 7))
else
    -- Falling back to the branch means the CDN may hand back something up to
    -- five minutes old. Said out loud, because silently installing stale code
    -- is exactly the failure this is here to prevent.
    print("WARNING: could not resolve the commit -- falling back to the")
    print("branch, which may serve a cached copy up to 5 minutes old.")
end
local REF = COMMIT or BRANCH

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/brain/"):format(GITHUB_USER, REPO, REF)

local function download(url, destPath)
    -- Deletes the old file first, THEN writes the new one, instead of
    -- just opening it in "w" mode (which already truncates -- this isn't
    -- fixing a real overwrite bug, fs.open("w") always replaces the full
    -- content). This exists to rule out any possibility of stale content
    -- surviving an install, full stop -- delete-then-recreate can't
    -- leave anything old behind, whatever the cause of a report was.
    if fs.exists(destPath) then fs.delete(destPath) end
    local response, err = http.get(url)
    if not response then
        error(("Failed to download %s: %s"):format(url, tostring(err)))
    end
    local body = response.readAll()
    response.close()
    if not body or #body == 0 then
        error(("Downloaded %s but it was EMPTY -- refusing to overwrite."):format(url))
    end
    local f = fs.open(destPath, "w")
    f.write(body)
    f.close()
    -- Report the size actually written. "I reinstalled and it still behaves
    -- like the old version" has come up more than once, and without this
    -- there is no way to tell whether the file on disk changed at all --
    -- a stale cache, a failed write and a genuine no-op all look identical.
    -- Comparing this number against the file on GitHub settles it instantly.
    return #body
end

print("Installing MOVCCTWX brain computer files into / ...")
if not fs.exists("/vendor") then fs.makeDir("/vendor") end

for _, absPath in ipairs(FILES) do
    local size = download(BASE_URL .. absPath:sub(2), absPath)
    print(("  %s  %d B"):format(absPath, size))
end

-- CC:Tweaked caches require()'d modules in memory for the whole computer
-- session, not per-program-run -- overwriting the files on disk above
-- does NOT make a currently-loaded module re-read itself. Without a
-- reboot, running startup.lua again just keeps using whatever was already
-- in memory from before this install, which reads as "the update didn't
-- take" even though the new files ARE correctly on disk (confirmed
-- in-game as exactly this, more than once). Rebooting automatically here
-- removes that whole class of confusion instead of relying on remembering
-- a separate manual step every time.
print("\nDone. Rebooting to load the new files (reboots always required --")
print("CC caches loaded code in memory until then)...")
sleep(1.5)
os.reboot()
