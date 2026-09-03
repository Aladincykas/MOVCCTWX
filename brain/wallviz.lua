-- wallviz.lua -- decorative full-wall visual styles for music playback
-- (see musicplayer.lua). CC has no real audio-analysis API, so every
-- style here is animation driven by elapsed time/random walk, not an
-- actual spectrum -- same honest limitation the original bar equalizer
-- already had.
--
-- Style selection is deterministic per song (a plain string hash of the
-- song name), NOT random-per-play -- the same song always gets the same
-- style every time it plays, and different songs usually get different
-- ones. That reads as "this song has its own visual identity", not the
-- wall just flickering between random looks on repeat plays of the same
-- track.
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

-- ==== Style 1: bars -- vertical equalizer bars, smoothed random walk per
-- column, color banded bottom (green) to top (red). The original style. ====
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

-- ==== Style 2: wave -- a few scrolling sine waves at different
-- frequencies/phases/colors, like a simple oscilloscope. ====
local function newWaveStyle()
    local phase
    local LINES = { { freq = 3, offset = 0, band = 0.2 }, { freq = 5, offset = 2, band = 0.6 }, { freq = 2, offset = 4, band = 0.9 } }
    return {
        init = function() phase = math.random() * 10 end,
        step = function(cols, rows, paused)
            if not paused then phase = phase + 0.25 end
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

-- ==== Style 3: pulse -- concentric rings expanding outward from the
-- wall's center, old-school "ambience"/radar-sweep style. ====
local function newPulseStyle()
    local radius
    return {
        init = function() radius = 0 end,
        step = function(cols, rows, paused)
            if not paused then radius = radius + 0.4 end
        end,
        draw = function(wall, cols, rows)
            local cx, cy = cols / 2, rows / 2
            local maxR = math.sqrt(cx * cx + cy * cy)
            local r0 = radius % maxR
            blitFrame(wall, cols, rows, function(r, c)
                -- Monitors read roughly 2 chars wide per 1 tall -- squash
                -- the y delta so rings look circular instead of oval.
                local dx, dy = c - cx, (r - cy) * 2
                local dist = math.sqrt(dx * dx + dy * dy)
                if math.abs(dist - r0) < 2.5 then return bandColor(dist / maxR) end
            end)
        end,
    }
end

local STYLES = { newBarsStyle, newWaveStyle, newPulseStyle }

-- Plain string hash (sum of byte values) -- doesn't need to be
-- cryptographic, just stable across runs and reasonably spread out across
-- STYLES for a typical library of song names.
local function pickStyleIndex(songName)
    local sum = 0
    for i = 1, #songName do sum = sum + songName:byte(i) end
    return (sum % #STYLES) + 1
end

-- Returns a fresh style instance -- {init(cols,rows), step(cols,rows,
-- paused), draw(wall,cols,rows)} -- picked deterministically for this
-- song name.
function M.forSong(songName)
    return STYLES[pickStyleIndex(songName)]()
end

return M
