-- config.lua -- pocket computer remote settings. This is a SEPARATE
-- physical computer from the brain, so nothing here is require()'d across
-- from brain/config.lua -- keep the library lists in sync by hand if they
-- change (same GitHub repos, since both sides read the same manifests to
-- know what's playable).

return {
    TITLE = "MOVCCTWX Remote",

    GITHUB_USER = "Aladincykas",

    MUSIC_LIBRARIES = {
        { label = "Library 1", repo = "cctwmusics",  branch = "main" },
        { label = "Library 2", repo = "cctwmusics2", branch = "main" },
        { label = "Library 3", repo = "cctwmusics3", branch = "main" },
    },

    VIDEO_LIBRARIES = {
        { label = "Didziulis ekranas 1", repo = "MOVCCTW0", branch = "main" },
        { label = "Didziulis ekranas 2", repo = "MOVCCTW1", branch = "main" },
    },

    -- Must match the brain computer's config.REMOTE_PROTOCOL exactly, or
    -- rednet.lookup below will never find it.
    REMOTE_PROTOCOL = "movcctwx-remote",
}
