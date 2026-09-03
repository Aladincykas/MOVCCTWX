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
    -- The wall switches text scale depending on what's on it, because
    -- music visuals and video have completely different needs.
    --
    -- MUSIC 0.5: CC's smallest text scale = the MOST characters. Each 8x6
    -- monitor goes from 81x40 characters to 162x80, so the wall is
    -- 648x240 -- 4x the detail. The visualizer only redraws a couple of
    -- times a second, so it can afford that, and it automatically slows
    -- its own redraw rate on a bigger wall (see musicplayer.lua's
    -- frameInterval).
    --
    -- VIDEO 1.0: 324x120. Video needs ~25fps, and at 0.5 that's ~58x the
    -- old single monitor's data per frame -- both far too much to render
    -- and far too big to upload (the segments would have to be so short
    -- that playback stalls to reload every few seconds). 1.0 keeps each
    -- individual monitor at roughly the per-monitor load the old
    -- single-monitor build already handled fine.
    --
    -- Videos must be ENCODED at the matching size (324x120) -- addmedia
    -- does that automatically when you pick "Didziulis ekranas".
    WALL_TEXT_SCALE_MUSIC = 0.5,
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
