-- config.lua -- central settings for the brain computer.

return {
    TITLE = "MOVCCTWX",

    GITHUB_USER = "Aladincykas",

    -- Same merge pattern as the reference project: every repo listed here
    -- gets fetched and merged into one browsable library.
    MUSIC_LIBRARIES = {
        { label = "Library 1", repo = "cctwmusics",  branch = "main" },
        { label = "Library 2", repo = "cctwmusics2", branch = "main" },
        { label = "Library 3", repo = "cctwmusics3", branch = "main" },
    },

    VIDEO_LIBRARIES = {
        { label = "Didziulis ekranas 1", repo = "MOVCCTW0", branch = "main" },
        { label = "Didziulis ekranas 2", repo = "MOVCCTW1", branch = "main" },
    },

    -- The 4x3 monitor wall. Row-major, left-to-right then top-to-bottom,
    -- confirmed against the real wall via brain/identify-monitors.lua.
    WALL_COLUMNS = 4,
    WALL_ROWS = 3,
    WALL_MONITOR_NAMES = {
        "monitor_299", "monitor_307", "monitor_308", "monitor_300",
        "monitor_298", "monitor_297", "monitor_301", "monitor_304",
        "monitor_306", "monitor_305", "monitor_302", "monitor_303",
    },
    -- Text scale for the wall. 1.0 gives 81x40 characters per 8x6 monitor,
    -- so 324x120 across the whole 4x3 wall.
    --
    -- 0.5 is available (CC's smallest scale = the most characters, 648x240
    -- here) but isn't used for either mode:
    --   * Music visuals gain nothing from it -- they're big abstract bars
    --     and colour fields, and 4x the cells is 4x the render work per
    --     frame competing with audio on CC's single Lua thread.
    --   * Video can't afford it at all: ~58x the old single monitor's data
    --     per frame at 25fps, and .32vid chunks too big for GitHub to
    --     accept unless segments get so short playback constantly stalls.
    --
    -- Kept as two separate settings because the wall CAN switch between
    -- them at runtime (wall.setScale, applied per mode in startup.lua), so
    -- either can be changed on its own without touching the other.
    --
    -- Videos must be ENCODED at the matching size (324x120) -- addmedia
    -- does that automatically when you pick "Didziulis ekranas".
    WALL_TEXT_SCALE_MUSIC = 1.0,
    WALL_TEXT_SCALE_VIDEO = 1.0,
    -- Fallback for anything that opens the wall without saying which mode.
    WALL_TEXT_SCALE = 1.0,

    -- rednet protocol string shared with the pocket computer(s).
    REMOTE_PROTOCOL = "movcctwx-remote",
    -- Computer IDs allowed to send remote commands. Test setup: owner only
    -- (computer #2789, the owner's pocket computer). Add friends' pocket
    -- computer IDs here later (os.getComputerID() on their end) -- this
    -- stays a list on purpose so that's a config change, not a code change.
    REMOTE_ALLOWLIST = {
        2789,
    },

    MENU_MUSIC_VOLUME = 0.5,
    MENU_MUSIC_NAME = nil,

    MUSIC_MENU_IDLE_TIMEOUT_SEC = 300,

    DEFAULT_VOLUME = 1.0,
    MAX_VOLUME = 3.0, -- CC:Tweaked speaker.playAudio volume ceiling

    -- CC:Tweaked hard-caps concurrent speaker playback at 8, network-wide.
    -- Single test speaker for now; leave this as-is until multi-speaker
    -- sync is actually specified.
    MAX_SPEAKERS = 8,
}
