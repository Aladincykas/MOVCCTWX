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

-- ==== Style 3: plasma -- classic "flowing color blob" effect: four sine
-- waves at different frequencies/axes/speeds, summed and normalized to
-- pick a color band per cell. The frequencies are deliberately
-- incommensurate (10, 10, 10, 20 combined with DIFFERENT time multipliers
-- -- 1x, 1.3x, 0.7x, 1.6x) so the combined pattern doesn't repeat on any
-- short, obviously-noticeable cycle the way a single expanding ring did --
-- it keeps drifting/warping instead of looping. This is the standard
-- cheap-plasma technique (any old demoscene/screensaver plasma effect
-- uses this same trick), not anything CC-specific. ====
local function newPlasmaStyle()
    local t
    return {
        init = function() t = math.random() * 20 end,
        step = function(cols, rows, paused)
            if not paused then t = t + 0.12 end
        end,
        draw = function(wall, cols, rows)
            blitFrame(wall, cols, rows, function(r, c)
                local x, y = c / cols, r / rows
                local v = math.sin(x * 10 + t)
                    + math.sin(y * 10 - t * 1.3)
                    + math.sin((x + y) * 10 + t * 0.7)
                    + math.sin(math.sqrt((x - 0.5) ^ 2 + (y - 0.5) ^ 2) * 20 - t * 1.6)
                return bandColor(math.max(0, math.min(1, (v + 4) / 8)))
            end)
        end,
    }
end

-- ==== Style 4: starfield -- particles streaking outward from the wall's
-- center at random angles/speeds, each looping back to a fresh random
-- angle once it exits -- genuinely randomized motion (not a fixed
-- geometric shape animating), so it never traces the same path twice.
-- Star positions are written into a sparse lookup table BEFORE blitting
-- (not by checking every star against every cell -- that's O(cells *
-- stars) per frame, too slow for a big wall), so this stays the same
-- O(cells) cost per frame as every other style. ====
local function newStarfieldStyle()
    local NUM_STARS = 50
    local stars, cx, cy
    local function respawn(s)
        s.angle = math.random() * 2 * math.pi
        s.dist = 0
        s.speed = 0.4 + math.random() * 1.2
        s.band = math.random()
    end
    return {
        init = function(cols, rows)
            cx, cy = cols / 2, rows / 2
            stars = {}
            for i = 1, NUM_STARS do
                stars[i] = {}
                respawn(stars[i])
                stars[i].dist = math.random() * math.max(cx, cy) -- pre-scattered, not all starting at center
            end
        end,
        step = function(cols, rows, paused)
            if paused then return end
            local maxDist = math.sqrt(cx * cx + cy * cy)
            for _, s in ipairs(stars) do
                s.dist = s.dist + s.speed
                if s.dist > maxDist then respawn(s) end
            end
        end,
        draw = function(wall, cols, rows)
            local grid = {}
            for _, s in ipairs(stars) do
                -- Monitors read roughly 2 chars wide per 1 tall -- squash
                -- the vertical component so streaks radiate evenly instead
                -- of stretching top/bottom.
                local sx = math.floor(cx + math.cos(s.angle) * s.dist + 0.5)
                local sy = math.floor(cy + math.sin(s.angle) * s.dist * 0.5 + 0.5)
                if sx >= 1 and sx <= cols and sy >= 1 and sy <= rows then
                    grid[sy] = grid[sy] or {}
                    grid[sy][sx] = bandColor(s.band)
                end
            end
            blitFrame(wall, cols, rows, function(r, c)
                return grid[r] and grid[r][c]
            end)
        end,
    }
end

local STYLES = { newBarsStyle, newWaveStyle, newPlasmaStyle, newStarfieldStyle }

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
