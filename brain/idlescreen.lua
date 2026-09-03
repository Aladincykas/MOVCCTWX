-- idlescreen.lua -- what the monitor wall shows when nothing is playing.
--
-- Twelve monitors sitting black is a waste of the most visible thing in the
-- build, so the wall becomes a clock whenever the brain is back at its menu.
--
-- Deliberately uses NO http. On a community server the HTTP whitelist may
-- only allow GitHub, which rules out weather/news/anything API-driven -- but
-- both clocks CC offers are local and always available:
--   os.date()  -- the server machine's real-world time
--   os.time()  -- Minecraft world time, 0-24 as a fraction of the game day
-- so this keeps working whatever the whitelist says.

local M = {}

-- 3x5 block font. Wide enough to read across a room once scaled up, small
-- enough that a whole glyph row is one string concat rather than per-cell
-- work. Only the characters a clock needs.
local GLYPHS = {
    ["0"] = { "###", "# #", "# #", "# #", "###" },
    ["1"] = { " # ", "## ", " # ", " # ", "###" },
    ["2"] = { "###", "  #", "###", "#  ", "###" },
    ["3"] = { "###", "  #", "###", "  #", "###" },
    ["4"] = { "# #", "# #", "###", "  #", "  #" },
    ["5"] = { "###", "#  ", "###", "  #", "###" },
    ["6"] = { "###", "#  ", "###", "# #", "###" },
    ["7"] = { "###", "  #", "  #", "  #", "  #" },
    ["8"] = { "###", "# #", "###", "# #", "###" },
    ["9"] = { "###", "# #", "###", "  #", "###" },
    [":"] = { "   ", " # ", "   ", " # ", "   " },
    [" "] = { "   ", "   ", "   ", "   ", "   " },
}

local GLYPH_W, GLYPH_H = 3, 5

-- Largest whole-number scale at which `text` still fits the wall, leaving a
-- margin. Whole numbers only: a fractional scale would make some columns of
-- a digit wider than others, which is very visible on a stroke this thick.
local function fitScale(text, wallW, wallH, maxRows)
    local cols = #text * (GLYPH_W + 1) - 1
    local byW = math.floor((wallW - 4) / cols)
    local byH = math.floor(maxRows / GLYPH_H)
    return math.max(1, math.min(byW, byH))
end

-- Renders `text` into rows[] as blit background strings, centred on x.
-- Written into an existing row table rather than blitted directly so the
-- whole frame goes out in one pass per row -- the wall splits every row
-- across four monitors, so half-rows would double the peripheral calls.
local function stamp(rows, text, scale, originX, originY, colorHex, wallW)
    local glyphCols = #text * (GLYPH_W + 1) - 1
    local pixelW = glyphCols * scale
    local x0 = originX or math.floor((wallW - pixelW) / 2)

    for i = 1, #text do
        local glyph = GLYPHS[text:sub(i, i)] or GLYPHS[" "]
        local gx = x0 + (i - 1) * (GLYPH_W + 1) * scale
        for gy = 1, GLYPH_H do
            local line = glyph[gy]
            for sy = 1, scale do
                local row = rows[originY + (gy - 1) * scale + sy]
                if row then
                    for cx = 1, GLYPH_W do
                        if line:sub(cx, cx) == "#" then
                            local px = gx + (cx - 1) * scale
                            for sx = 1, scale do
                                local at = px + sx
                                if at >= 1 and at <= wallW then row[at] = colorHex end
                            end
                        end
                    end
                end
            end
        end
    end
end

-- Minecraft's day is 24000 ticks and os.time() reports it as 0-24, so this
-- is just a format change, not a conversion.
local function minecraftClock()
    local t = os.time()
    local hours = math.floor(t)
    local minutes = math.floor((t - hours) * 60)
    return ("%02d:%02d"):format(hours % 24, minutes)
end

-- Draws one frame. Split out so the caller can decide the pacing.
function M.draw(wall)
    local wallW, wallH = wall.getSize()
    local BG = colors.toBlit(colors.black)

    local rows = {}
    for y = 1, wallH do
        local row = {}
        for x = 1, wallW do row[x] = BG end
        rows[y] = row
    end

    local realText = os.date("%H:%M")
    local mcText = minecraftClock()

    -- The real clock takes most of the height; the Minecraft one sits under
    -- it at a third the size, so the two are never mistaken for each other.
    local bigScale = fitScale(realText, wallW, wallH, math.floor(wallH * 0.55))
    local smallScale = math.max(1, math.floor(bigScale / 3))

    local bigH = GLYPH_H * bigScale
    local smallH = GLYPH_H * smallScale
    local gap = math.max(1, math.floor(bigScale / 2))
    local totalH = bigH + gap + smallH
    local top = math.max(1, math.floor((wallH - totalH) / 2) + 1)

    stamp(rows, realText, bigScale, nil, top, colors.toBlit(colors.white), wallW)
    stamp(rows, mcText, smallScale, nil, top + bigH + gap, colors.toBlit(colors.gray), wallW)

    local blankText = (" "):rep(wallW)
    local blankFg = BG:rep(wallW)
    for y = 1, wallH do
        wall.setCursorPos(1, y)
        wall.blit(blankText, blankFg, table.concat(rows[y]))
    end
end

-- Redraws until `shouldStop()` returns true.
--
-- Once a second is plenty for a clock, and it costs almost nothing: wall.blit
-- skips any tile whose content is unchanged, so a frame where only one digit
-- moved rewrites only the tiles that digit touches, not all twelve monitors.
function M.run(wall, shouldStop)
    while not shouldStop() do
        -- Checked immediately before AND after drawing. A frame takes real
        -- time to build, so playback can begin part-way through one -- and a
        -- clock frame landing after that point would both appear over the
        -- video and poison the wall's tile cache, so the video's next frame
        -- would diff against clock pixels and skip redrawing them.
        --
        -- Set by whoever owns the wall (see videoplayer/musicplayer), so this
        -- does not depend on the menu's own bookkeeping being timely.
        if _G.MOVCCTWX_WALL_BUSY then return end
        M.draw(wall)
        if _G.MOVCCTWX_WALL_BUSY or shouldStop() then return end
        os.sleep(1)
    end
end

return M
