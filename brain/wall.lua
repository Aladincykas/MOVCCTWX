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
    function wall.setPaletteColor(colorNum, r, g, b)
        forEach(function(mon) mon.setPaletteColor(colorNum, r, g, b) end)
    end

    function wall.clear()
        forEach(function(mon) mon.clear() end)
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
        for c = 1, cols do
            local startX = (c - 1) * tileW + 1
            local slice = function(s) return s:sub(startX, startX + tileW - 1) end
            grid[r][c].setCursorPos(1, localY)
            grid[r][c].blit(slice(text), slice(fg), slice(bg))
        end
    end

    return wall
end

return M
