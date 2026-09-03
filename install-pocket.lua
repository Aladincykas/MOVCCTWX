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

local BASE_URL = ("https://raw.githubusercontent.com/%s/%s/%s/pocket/"):format(GITHUB_USER, REPO, REF)

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
download(("https://raw.githubusercontent.com/%s/%s/%s/brain/basalt.lua"):format(GITHUB_USER, REPO, REF), "/basalt.lua")

-- config.lua comes from brain/ as well, rather than a second copy under
-- pocket/. There used to be one, with a comment telling whoever edited it
-- to keep the library lists in sync by hand -- and that is precisely what
-- went wrong: a video repo was renamed on the brain, the pocket kept
-- pointing at the old one, and newly uploaded videos simply did not appear
-- on the remote. Both computers read the same manifests, so they must read
-- the same list of repos, and the only way to guarantee that is for there
-- to be one file. Everything the pocket needs (TITLE, GITHUB_USER, the
-- library lists, REMOTE_PROTOCOL) is already in the brain's config; the
-- extra keys it carries are simply unused here.
print("  /config.lua")
download(("https://raw.githubusercontent.com/%s/%s/%s/brain/config.lua"):format(GITHUB_USER, REPO, REF), "/config.lua")

-- Same reasoning as install-brain.lua's matching comment: CC caches
-- loaded code in memory until reboot, so this reboots automatically
-- instead of relying on a separate manual step every time.
print("\nDone. Rebooting to load the new files (reboots always required --")
print("CC caches loaded code in memory until then)...")
print("Make sure a wireless modem is attached/crafted in first.")
sleep(1.5)
os.reboot()
