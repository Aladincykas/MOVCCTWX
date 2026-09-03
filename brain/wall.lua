-- wall.lua -- treats a grid of monitor peripherals as one big display.
--
-- Exposes just the subset of the monitor API videoplayer.lua actually
-- calls on a video surface (getSize, setBackgroundColor, setTextColor,
-- setCursorPos, blit, clear, setPaletteColor) so videoplayer.lua doesn't
-- need to know it's talking to 12 monitors instead of 1. Every monitor in
-- the grid is assumed identical size -- mixed sizes aren't supported, since
-- a torn frame across differently-sized tiles isn't fixable at this layer.
--
-- Row-major grid: config.WALL_MONITOR_NAMES[1] is top-left, entry
-- WALL_COLUMNS is top-right, the next entry starts row 2, and so on --
-- must match the physical arrangement of the monitors in-world.

local M = {}

function M.open(config)
    local cols, rows = config.WALL_COLUMNS, config.WALL_ROWS
    local names = config.WALL_MONITOR_NAMES
    if #names ~= cols * rows then
        error(("WALL_MONITOR_NAMES has %d entries, expected %d (%dx%d)")
            :format(#names, cols * rows, cols, rows))
    end

    -- grid[row][col] = wrapped peripheral
    local grid = {}
    local tileW, tileH
    for r = 1, rows do
        grid[r] = {}
        for c = 1, cols do
            local idx = (r - 1) * cols + c
            local name = names[idx]
            local mon = peripheral.wrap(name)
            if not mon then
                error(("Wall monitor '%s' (row %d, col %d) not found. Check WALL_MONITOR_NAMES in config.lua.")
                    :format(name, r, c))
            end
            mon.setTextScale(config.WALL_TEXT_SCALE)
            local w, h = mon.getSize()
            if tileW == nil then
                tileW, tileH = w, h
            elseif w ~= tileW or h ~= tileH then
                error(("Wall monitor '%s' is %dx%d, expected %dx%d like the others -- every monitor in the grid must be the same size.")
                    :format(name, w, h, tileW, tileH))
            end
            mon.setBackgroundColor(colors.black)
            mon.setTextColor(colors.white)
            grid[r][c] = mon
        end
    end

    local totalW, totalH = tileW * cols, tileH * rows

    local wall = { tileW = tileW, tileH = tileH, cols = cols, rows = rows }

    function wall.getSize()
        return totalW, totalH
    end

    -- Music visuals and video want DIFFERENT text scales on the same
    -- physical wall, so the scale is switchable at runtime rather than
    -- fixed once at open().
    --
    -- 0.5 (the most characters CC allows) makes the wall 648x240 -- great
    -- for the music visualizer, which only redraws a couple of times a
    -- second anyway. Video at that size is a different story: ~58x the
    -- old single monitor's data per frame, at 25fps, which means both an
    -- unreasonable render load and .32vid chunks too big for GitHub to
    -- accept unless the segments are cut so short that playback stalls to
    -- reload every few seconds. Video therefore runs the wall at 1.0
    -- (324x120) instead. See config.lua's WALL_TEXT_SCALE_MUSIC/VIDEO.
    function wall.setScale(scale)
        tileW, tileH = nil, nil
        for r = 1, rows do
            for c = 1, cols do
                local mon = grid[r][c]
                mon.setTextScale(scale)
                local w, h = mon.getSize()
                if tileW == nil then tileW, tileH = w, h end
            end
        end
        totalW, totalH = tileW * cols, tileH * rows
        wall.tileW, wall.tileH = tileW, tileH
        return totalW, totalH
    end

    -- Applies fn(mon) to every monitor in the grid.
    local function forEach(fn)
        for r = 1, rows do
            for c = 1, cols do
                fn(grid[r][c])
            end
        end
    end

    function wall.setBackgroundColor(color)
        forEach(function(mon) mon.setBackgroundColor(color) end)
    end

    function wall.setTextColor(color)
        forEach(function(mon) mon.setTextColor(color) end)
    end

    -- Palette slots are shared color definitions, not per-pixel state --
    -- every monitor in the grid must agree on what color N means, or tile
    -- boundaries show visibly different colors for the same palette index.
    --
    -- Forwards the arguments it was ACTUALLY given rather than four named
    -- ones. CC accepts two call shapes -- setPaletteColor(index, 0xRRGGBB)
    -- and setPaletteColor(index, r, g, b) -- and naming the parameters
    -- turned the first into a four-argument call with nil g/b, which CC
    -- rejects with "bad argument #3 (number expected, got nil)". That fired
    -- at the end of every video chunk, where resetPalette() uses the packed
    -- form.
    function wall.setPaletteColor(...)
        local args = table.pack(...)
        forEach(function(mon) mon.setPaletteColor(table.unpack(args, 1, args.n)) end)
    end

    -- What each individual TILE last had written to each of its own lines.
    -- Keyed [monitorRow][monitorCol][lineWithinThatMonitor].
    --
    -- Callers already skip full wall rows that are unchanged, but a full row
    -- spans all four column monitors, so a change anywhere in it previously
    -- re-blitted all four. On a wall showing one moving subject that is
    -- mostly waste: the outer monitors are usually holding identical content
    -- frame to frame.
    --
    -- This matters far more than it looks. Every tile write is TWO peripheral
    -- calls (setCursorPos + blit), so a full 120-row wall costs 960 calls per
    -- frame -- ~19,200 a second at 20fps, which CC cannot move. Measured
    -- in-game: 96% of frames were being dropped because drawing one frame
    -- took longer than twenty-five frames' worth of time.
    local tileCache = {}
    local function resetTileCache()
        tileCache = {}
        for r = 1, rows do
            tileCache[r] = {}
            for c = 1, cols do tileCache[r][c] = {} end
        end
    end
    resetTileCache()

    function wall.clear()
        forEach(function(mon) mon.clear() end)
        -- The cache describes what is physically on each tile; wiping the
        -- monitors makes every entry a lie, and stale entries would suppress
        -- the redraw that is meant to put the content back.
        resetTileCache()
    end

    -- Only used by videoplayer.lua's cursor-based text writes (loading
    -- messages) -- routes to whichever single tile that (x,y) falls in and
    -- remembers it for the next write()/blit() call on this wall object.
    local cursorRow, cursorCol, cursorLocalX, cursorLocalY
    function wall.setCursorPos(x, y)
        cursorCol = math.min(cols, math.floor((x - 1) / tileW) + 1)
        cursorRow = math.min(rows, math.floor((y - 1) / tileH) + 1)
        cursorLocalX = x - (cursorCol - 1) * tileW
        cursorLocalY = y - (cursorRow - 1) * tileH
        grid[cursorRow][cursorCol].setCursorPos(cursorLocalX, cursorLocalY)
    end

    function wall.write(text)
        grid[cursorRow][cursorCol].write(text)
    end

    -- Matches the real monitor.blit(text, fg, bg) signature -- writes at
    -- whatever position the last setCursorPos() call left us at, same as a
    -- real monitor. Splits that one logical row across every column in the
    -- cursor's row, each tile only ever seeing its own slice in its own
    -- local x coordinates.
    function wall.blit(text, fg, bg)
        local r, localY = cursorRow, cursorLocalY
        local rowTiles = tileCache[r]
        for c = 1, cols do
            local startX = (c - 1) * tileW + 1
            local endX = startX + tileW - 1
            local t = text:sub(startX, endX)
            local f = fg:sub(startX, endX)
            local b = bg:sub(startX, endX)
            -- Comparing the concatenation is a few string ops; skipping the
            -- write saves two peripheral calls, which cost vastly more.
            local key = t .. f .. b
            local cache = rowTiles[c]
            if cache[localY] ~= key then
                grid[r][c].setCursorPos(1, localY)
                grid[r][c].blit(t, f, b)
                cache[localY] = key
            end
        end
    end

    return wall
end

return M
