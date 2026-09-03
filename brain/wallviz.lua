-- wallviz.lua -- decorative full-wall visual styles for music playback
-- (see musicplayer.lua). CC has no real audio-analysis API, so every
-- style here is animation driven by elapsed time/random walk, not an
-- actual spectrum -- same honest limitation the original bar equalizer
-- already had.
--
-- musicplayer.lua ROTATES through styles roughly once a minute during a
-- song (see M.new/M.count/M.startIndexForSong below), starting from a
-- deterministic per-song index (a plain hash of the song name) so a given
-- song still always OPENS on the same style, but a long song doesn't just
-- sit on one look the whole time.
--
-- Every style draws as solid colored BACKGROUND blocks, not text glyphs
-- (see musicplayer.lua's comment on why -- a glyph has gaps and reads as
-- a faint texture from a distance; a colored cell is a solid rectangle).

local M = {}

local VIZ_ROW_COLORS = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green }
local function bandColor(t) -- t in [0,1], 0 = coolest/green end, 1 = hottest/red end
    local idx = math.max(1, math.min(#VIZ_ROW_COLORS, math.ceil(t * #VIZ_ROW_COLORS)))
    return VIZ_ROW_COLORS[idx]
end

local BG_HEX = colors.toBlit(colors.black)

-- Shared helper: blits one full-wall frame from a per-cell function
-- fn(row, col) -> colors.XXX or nil (nil = black/empty cell). Every style
-- below is just a different fn.
local function blitFrame(wall, cols, rows, fn)
    local blankText = (" "):rep(cols)
    for r = 1, rows do
        local bg = {}
        for c = 1, cols do
            local color = fn(r, c)
            bg[c] = color and colors.toBlit(color) or BG_HEX
        end
        wall.setCursorPos(1, r)
        wall.blit(blankText, blankText, table.concat(bg))
    end
end

-- ==== bars -- vertical equalizer bars, smoothed random walk per column,
-- color banded bottom (green) to top (red). The original style. ====
local function newBarsStyle()
    local heights
    return {
        init = function(cols, rows)
            heights = {}
            for c = 1, cols do heights[c] = math.random(0, rows) end
        end,
        step = function(cols, rows, paused)
            if paused then return end
            local maxStep = math.max(1, math.floor(rows * 0.2))
            for c = 1, cols do
                local h2 = (heights[c] or 0) + math.random(-maxStep, maxStep)
                heights[c] = math.max(0, math.min(rows, h2))
            end
        end,
        draw = function(wall, cols, rows)
            blitFrame(wall, cols, rows, function(r, c)
                if heights[c] >= (rows - r + 1) then return bandColor(r / rows) end
            end)
        end,
    }
end

-- ==== wave -- a few scrolling sine waves, like a simple oscilloscope.
-- Low frequencies on purpose (1-2 full cycles across the whole wall, not
-- 3-5) -- a few big sweeping arcs read as bold loops from a distance;
-- lots of small ripples read as thin scribbles. ====
local function newWaveStyle()
    local phase
    local LINES = { { freq = 1.5, offset = 0, band = 0.2 }, { freq = 2, offset = 2.5, band = 0.6 }, { freq = 1, offset = 5, band = 0.9 } }
    return {
        init = function() phase = math.random() * 10 end,
        step = function(cols, rows, paused)
            if not paused then phase = phase + 0.2 end
        end,
        draw = function(wall, cols, rows)
            local mid = rows / 2
            local amp = math.max(1, rows / 2 - 1)
            local ys = {}
            for li, line in ipairs(LINES) do
                ys[li] = {}
                for c = 1, cols do
                    ys[li][c] = math.floor(mid + amp * math.sin((c / cols) * math.pi * line.freq + phase + line.offset) + 0.5)
                end
            end
            blitFrame(wall, cols, rows, function(r, c)
                for li, line in ipairs(LINES) do
                    if ys[li][c] == r then return bandColor(line.band) end
                end
            end)
        end,
    }
end

-- ==== plasma -- classic "flowing color blob" effect: four sine waves at
-- different frequencies/axes/speeds, summed and normalized to pick a
-- color band per cell. freqs/speeds are deliberately incommensurate (no
-- shared small ratio between them) so the combined pattern doesn't repeat
-- on any short, obviously-noticeable cycle -- it keeps drifting/warping
-- instead of looping. Standard cheap-plasma technique (any old
-- demoscene/screensaver plasma effect uses this same trick), not anything
-- CC-specific. 3 variants below (different freqs/speeds) for visual
-- variety -- same formula, different "personality".
local function newPlasmaStyle(freqs, speeds)
    local t
    return {
        init = function() t = math.random() * 20 end,
        step = function(cols, rows, paused)
            if not paused then t = t + 0.12 end
        end,
        draw = function(wall, cols, rows)
            blitFrame(wall, cols, rows, function(r, c)
                local x, y = c / cols, r / rows
                local v = math.sin(x * freqs[1] + t * speeds[1])
                    + math.sin(y * freqs[2] - t * speeds[2])
                    + math.sin((x + y) * freqs[3] + t * speeds[3])
                    + math.sin(math.sqrt((x - 0.5) ^ 2 + (y - 0.5) ^ 2) * freqs[4] - t * speeds[4])
                return bandColor(math.max(0, math.min(1, (v + 4) / 8)))
            end)
        end,
    }
end

local function newPlasmaA() return newPlasmaStyle({ 10, 10, 10, 20 }, { 1, 1.3, 0.7, 1.6 }) end
local function newPlasmaB() return newPlasmaStyle({ 6, 6, 14, 10 }, { 0.8, 1.6, 0.5, 1.1 }) end -- busier/more turbulent
local function newPlasmaC() return newPlasmaStyle({ 4, 4, 4, 8 }, { 0.5, 0.9, 0.35, 0.7 }) end -- slower, bigger blobs

local STYLES = { newBarsStyle, newWaveStyle, newPlasmaA, newPlasmaB, newPlasmaC }

-- Plain string hash (sum of byte values) -- doesn't need to be
-- cryptographic, just stable across runs and reasonably spread out across
-- STYLES for a typical library of song names.
function M.startIndexForSong(songName)
    local sum = 0
    for i = 1, #songName do sum = sum + songName:byte(i) end
    return (sum % #STYLES) + 1
end

function M.count()
    return #STYLES
end

-- Returns a fresh style instance -- {init(cols,rows), step(cols,rows,
-- paused), draw(wall,cols,rows)} -- for style index `i` (wraps around, so
-- callers can just keep incrementing past M.count() to rotate).
function M.new(i)
    return STYLES[((i - 1) % #STYLES) + 1]()
end

return M
