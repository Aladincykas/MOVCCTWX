-- identify-monitors.lua -- standalone, one-off utility. NOT part of
-- startup.lua and never run automatically -- run it by hand whenever you
-- need to (re-)map the physical wall to WALL_MONITOR_NAMES in config.lua.
--
-- What it does: writes each monitor's own peripheral name onto itself, as
-- big as that monitor can fit it in one line, so it's readable standing
-- back from the wall. Also prints a table on the computer's own screen
-- with every monitor's name and character size at scale 1.0 (the number
-- that actually matters -- config.WALL_TEXT_SCALE, and wall.lua's
-- requirement that every monitor in the grid be the same size).
--
-- Run in-game (on the brain computer), after install-brain.lua:
--   identify-monitors.lua
-- or straight from GitHub without installing anything first:
--   wget run https://raw.githubusercontent.com/Aladincykas/MOVCCTWX/main/brain/identify-monitors.lua

local names = peripheral.getNames()
local monitors = {}
for _, name in ipairs(names) do
    if peripheral.getType(name) == "monitor" then
        table.insert(monitors, name)
    end
end

if #monitors == 0 then
    error("No monitor peripherals found on the network. Check they're connected via modem.")
end

table.sort(monitors)

term.clear()
term.setCursorPos(1, 1)
print(("Found %d monitor(s). Labeling each one now...\n"):format(#monitors))

local firstSize = nil
local sizeMismatch = false

for i, name in ipairs(monitors) do
    local mon = peripheral.wrap(name)

    -- Report size at scale 1.0 -- what wall.lua/config.WALL_TEXT_SCALE
    -- actually uses, and the number that needs to MATCH across every
    -- monitor in the grid for the wall to work at all (wall.lua errors
    -- out otherwise).
    mon.setTextScale(1.0)
    local w1, h1 = mon.getSize()
    if not firstSize then
        firstSize = { w = w1, h = h1 }
    elseif w1 ~= firstSize.w or h1 ~= firstSize.h then
        sizeMismatch = true
    end

    -- Largest text scale (CC:Tweaked caps at 5, floors at 0.5) that still
    -- fits this monitor's own name on one line -- tried biggest-first,
    -- backing off until it actually fits, so "monitor_11" reads clearly
    -- from a distance instead of wrapping or getting cut off.
    local scale, w, h = 5, nil, nil
    while scale >= 0.5 do
        mon.setTextScale(scale)
        local mw, mh = mon.getSize()
        if mw >= #name then w, h = mw, mh break end
        scale = scale - 0.5
    end
    if not w then
        mon.setTextScale(0.5)
        w, h = mon.getSize()
        scale = 0.5
    end

    mon.setBackgroundColor(colors.black)
    mon.clear()
    mon.setTextColor(colors.lime)
    mon.setCursorPos(math.max(1, math.floor((w - #name) / 2) + 1), math.max(1, math.floor(h / 2) + 1))
    mon.write(name)

    print(("%2d. %-14s  scale 1.0: %dx%d   |   label shown at scale %.1f")
        :format(i, name, w1, h1, scale))
end

-- Every text scale CC:Tweaked actually allows (multiples of 0.5, 0.5-5.0)
-- and what each one gives you across the WHOLE 4x3 wall. This is the table
-- to read before re-encoding video: a video has to be encoded at exactly
-- the wall's character size for the chosen scale, and cell count is what
-- decides .32vid file size (that format stores every frame independently
-- at a flat ~1.3 bytes per cell -- measured, not assumed -- so bytes scale
-- linearly with cells x fps and nothing else).
--
-- Sizes are read back from the hardware rather than divided out of the
-- scale-1.0 figure, because CC floors the division and subtracts monitor
-- border pixels: the true size at 1.5 is NOT the scale-1.0 size / 1.5.
do
    local probe = peripheral.wrap(monitors[1])
    local cols, rows = 4, 3
    print("\n" .. "Wall size by text scale (" .. cols .. "x" .. rows .. " grid):")
    print("scale   per monitor    whole wall     cells")
    local scale = 0.5
    while scale <= 5.0 do
        probe.setTextScale(scale)
        local mw, mh = probe.getSize()
        local ww, wh = mw * cols, mh * rows
        print(("%.1f     %3dx%-3d        %4dx%-4d     %d")
            :format(scale, mw, mh, ww, wh, ww * wh))
        scale = scale + 0.5
    end
    -- Put it back where the rest of this script expects it, so the probe
    -- monitor keeps showing its label at the scale chosen for it above.
    probe.setTextScale(1.0)
end

print("\nEach monitor now shows its own peripheral name in big text --")
print("stand in front of the wall and read off the name on each one, in")
print("physical order (left-to-right, top-to-bottom, 4 across x 3 down).")
print("Send me that list of 12 names in that order -- that's exactly what")
print("goes into WALL_MONITOR_NAMES in config.lua.")

if sizeMismatch then
    print("\n/!\\ Not every monitor reported the same scale-1.0 size above --")
    print("wall.lua requires all 12 to match. Double check they're the same")
    print("physical monitor size (same number of blocks each).")
else
    print("\nAll monitors report the same size -- good, that's what wall.lua needs.")
end
