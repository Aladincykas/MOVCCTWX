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

    -- The 4x3 monitor wall. Fill in the real peripheral names once the
    -- monitors are placed and networked (see peripheral.getNames() -- run
    -- from the brain computer's own terminal to list them). Order matters:
    -- row-major, left-to-right then top-to-bottom, exactly matching how the
    -- monitors are physically arranged. Each entry is one 8x6-block monitor
    -- cluster; wall.lua reads their individual getSize() at runtime and
    -- assumes every monitor in the grid is the same size.
    WALL_COLUMNS = 4,
    WALL_ROWS = 3,
    WALL_MONITOR_NAMES = {
        "monitor_0", "monitor_1", "monitor_2", "monitor_3",
        "monitor_4", "monitor_5", "monitor_6", "monitor_7",
        "monitor_8", "monitor_9", "monitor_10", "monitor_11",
    },
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
