-- subtitles.lua -- subtitle track rendering for the monitor wall.
--
-- Subtitles are NOT burned into the video. They ship as their own small file
-- next to the .32vid chunks and are drawn here, in ComputerCraft's own font,
-- over the top of each frame.
--
-- Burning them in was tried first and measured: at the wall's real output
-- resolution (648x360 pixels) text has to be about a third of the frame tall
-- before it survives sanjuuni's downscale and its dither to 16 colours, and
-- even then the strokes come out soft and speckled. Drawing them here instead
-- costs two text rows out of 120, stays perfectly crisp whatever the scene
-- behind it looks like, can be switched off while the video plays, and adds
-- roughly 50KB to an entire film instead of inflating every single chunk.
--
-- The catch is that the wall is 324 characters wide, so one line of ordinary
-- monitor text would be about a sixth the height a cinema subtitle should be.
-- Hence the block font below: glyphs are drawn out of coloured background
-- cells, so a line can be made as large as it needs to be.

local M = {}

-- 3x5 block font, uppercase only.
--
-- Three columns is the narrowest a legible alphabet fits into, and it matters
-- here because width is what limits how much text fits on a line. Lowercase
-- is not attempted at this size -- descenders and x-height need at least 5x7
-- -- so everything is upper-cased before it is drawn, which is what cinema
-- subtitles have always done anyway.
local GLYPHS = {
    ["A"] = { "###", "# #", "###", "# #", "# #" },
    ["B"] = { "## ", "# #", "## ", "# #", "## " },
    ["C"] = { "###", "#  ", "#  ", "#  ", "###" },
    ["D"] = { "## ", "# #", "# #", "# #", "## " },
    ["E"] = { "###", "#  ", "## ", "#  ", "###" },
    ["F"] = { "###", "#  ", "## ", "#  ", "#  " },
    ["G"] = { "###", "#  ", "# #", "# #", "###" },
    ["H"] = { "# #", "# #", "###", "# #", "# #" },
    ["I"] = { "###", " # ", " # ", " # ", "###" },
    ["J"] = { "  #", "  #", "  #", "# #", "###" },
    ["K"] = { "# #", "# #", "## ", "# #", "# #" },
    ["L"] = { "#  ", "#  ", "#  ", "#  ", "###" },
    ["M"] = { "# #", "###", "###", "# #", "# #" },
    ["N"] = { "## ", "# #", "# #", "# #", "# #" },
    ["O"] = { "###", "# #", "# #", "# #", "###" },
    ["P"] = { "###", "# #", "###", "#  ", "#  " },
    ["Q"] = { "###", "# #", "# #", "###", "  #" },
    ["R"] = { "###", "# #", "###", "## ", "# #" },
    ["S"] = { "###", "#  ", "###", "  #", "###" },
    ["T"] = { "###", " # ", " # ", " # ", " # " },
    ["U"] = { "# #", "# #", "# #", "# #", "###" },
    ["V"] = { "# #", "# #", "# #", "# #", " # " },
    ["W"] = { "# #", "# #", "###", "###", "# #" },
    ["X"] = { "# #", "# #", " # ", "# #", "# #" },
    ["Y"] = { "# #", "# #", " # ", " # ", " # " },
    ["Z"] = { "###", "  #", " # ", "#  ", "###" },
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
    ["."] = { "   ", "   ", "   ", "   ", " # " },
    [","] = { "   ", "   ", "   ", " # ", "#  " },
    ["!"] = { " # ", " # ", " # ", "   ", " # " },
    ["?"] = { "###", "  #", " ##", "   ", " # " },
    ["'"] = { " # ", " # ", "   ", "   ", "   " },
    ['"'] = { "# #", "# #", "   ", "   ", "   " },
    ["-"] = { "   ", "   ", "###", "   ", "   " },
    ["_"] = { "   ", "   ", "   ", "   ", "###" },
    [":"] = { "   ", " # ", "   ", " # ", "   " },
    [";"] = { "   ", " # ", "   ", " # ", "#  " },
    ["("] = { " ##", " # ", " # ", " # ", " ##" },
    [")"] = { "## ", " # ", " # ", " # ", "## " },
    ["["] = { " ##", " # ", " # ", " # ", " ##" },
    ["]"] = { "## ", " # ", " # ", " # ", "## " },
    ["/"] = { "  #", "  #", " # ", "#  ", "#  " },
    ["\\"] = { "#  ", "#  ", " # ", "  #", "  #" },
    ["&"] = { "## ", "## ", "###", "# #", "###" },
    ["%"] = { "# #", "  #", " # ", "#  ", "# #" },
    ["+"] = { "   ", " # ", "###", " # ", "   " },
    ["="] = { "   ", "###", "   ", "###", "   " },
    ["*"] = { "# #", " # ", "# #", "   ", "   " },
    ["<"] = { "  #", " # ", "#  ", " # ", "  #" },
    [">"] = { "#  ", " # ", "  #", " # ", "#  " },
    ["#"] = { "# #", "###", "# #", "###", "# #" },
    ["$"] = { "###", "## ", "###", " ##", "###" },
    ["@"] = { "###", "# #", "###", "#  ", "###" },
    [" "] = { "   ", "   ", "   ", "   ", "   " },
}

local GLYPH_W, GLYPH_H = 3, 5
-- One blank column between glyphs, scaled with them.
local ADVANCE = GLYPH_W + 1

-- ---------------------------------------------------------------- parsing

-- The cue file is one cue per line, tab separated:
--     startMs <TAB> endMs <TAB> line1 [<TAB> line2 ...]
--
-- Deliberately not SRT. SRT needs multi-line state, blank-line record
-- separation and timecode parsing, all of which is fiddly in Lua and has to
-- run on the brain before playback can start. This format is one gmatch per
-- line, and the conversion costs nothing because addmedia does it once at
-- upload time -- where it also strips accents the block font cannot draw.
function M.parse(text)
    local cues = {}
    for line in text:gmatch("[^\r\n]+") do
        local fields = {}
        for field in line:gmatch("[^\t]*") do fields[#fields + 1] = field end
        local startMs = tonumber(fields[1])
        local endMs = tonumber(fields[2])
        if startMs and endMs then
            local lines = {}
            for i = 3, #fields do
                if fields[i] ~= "" then lines[#lines + 1] = fields[i] end
            end
            if #lines > 0 then
                cues[#cues + 1] = {
                    startSec = startMs / 1000,
                    endSec = endMs / 1000,
                    lines = lines,
                }
            end
        end
    end
    return cues
end

-- A cursor over the cue list.
--
-- Playback is linear, so the cue for the next frame is almost always the one
-- being shown or the one right after it. Keeping a pointer makes the common
-- case a couple of comparisons instead of a search through several thousand
-- cues, sixty times a second. It still copes with time jumping backwards --
-- which pausing and resuming can do by a fraction of a second -- by starting
-- over from the beginning rather than assuming forward motion.
function M.newCursor(cues)
    local cursor = { cues = cues, i = 1 }

    function cursor:at(timeSec)
        if #self.cues == 0 then return nil end
        if timeSec < (self.cues[self.i] and self.cues[self.i].startSec or 0) then
            self.i = 1
        end
        while self.i <= #self.cues and self.cues[self.i].endSec < timeSec do
            self.i = self.i + 1
        end
        local cue = self.cues[self.i]
        if cue and timeSec >= cue.startSec and timeSec <= cue.endSec then return cue end
        return nil
    end

    return cursor
end

-- ---------------------------------------------------------------- layout

-- Splits a line that is too wide to fit, breaking at spaces.
local function wrap(text, maxChars)
    if #text <= maxChars then return { text } end
    local out = {}
    local current = ""
    local function flush()
        if current ~= "" then out[#out + 1] = current current = "" end
    end
    for word in text:gmatch("%S+") do
        -- A single word longer than a whole line can never be placed by
        -- breaking at spaces, so it gets cut. Ordinary dialogue never contains
        -- one, but a URL or a long run of hyphens would otherwise be clipped
        -- mid-glyph at the edge of the box.
        while #word > maxChars do
            flush()
            out[#out + 1] = word:sub(1, maxChars)
            word = word:sub(maxChars + 1)
        end
        if current == "" then
            current = word
        elseif #current + 1 + #word <= maxChars then
            current = current .. " " .. word
        else
            flush()
            current = word
        end
    end
    flush()
    return out
end

-- Most lines a subtitle may occupy. Two is the convention; four is already
-- covering a third of the wall, and anything past that is better truncated
-- than allowed to push the box off the top of the screen.
local MAX_LINES = 4

-- How large to draw, given the wall. One glyph row is GLYPH_H*scale text rows,
-- so on the 120-row wall scale 1 puts a two-line subtitle at about 9% of the
-- height -- close to what a cinema subtitle occupies. Scale 2 would be 18%,
-- which is too much of the picture to cover.
function M.scaleFor(wallW, wallH)
    return math.max(1, math.floor(math.min(wallW / 320, wallH / 110)))
end

-- Builds the drawable form of a cue: a list of rows, each a run of cells to
-- paint, positioned as a centred box near the bottom of the wall.
--
-- Returns { top = y, left = x, width = n, rows = { [offset] = { bool... } } }
-- where a true cell is text and a false cell is box background. Nothing here
-- knows about colours -- the caller picks those from the frame's own palette.
function M.layout(cue, wallW, wallH, scale, marginBottom)
    scale = scale or 1
    marginBottom = marginBottom or (2 * scale)

    local glyphW = GLYPH_W * scale
    local glyphH = GLYPH_H * scale
    local advance = ADVANCE * scale
    local padX = 2 * scale
    local padY = scale
    local lineGap = scale

    -- Leave room for the padding on both sides, and never let a line run the
    -- full width of the wall -- text spanning all twelve monitors is harder
    -- to read than the same text spanning the middle six.
    local maxChars = math.max(8, math.floor((wallW * 0.66 - 2 * padX + scale) / advance))

    local lines = {}
    for _, raw in ipairs(cue.lines) do
        for _, piece in ipairs(wrap(raw:upper(), maxChars)) do
            lines[#lines + 1] = piece
        end
    end
    if #lines == 0 then return nil end

    -- Truncated rather than dropped. Returning nothing for an over-long cue
    -- would silently blank a subtitle that is merely too wordy, which is the
    -- worst of both outcomes -- showing most of it is strictly better.
    local roomForLines = math.floor((wallH - marginBottom - 2 * padY + lineGap) / (glyphH + lineGap))
    local allowed = math.max(1, math.min(MAX_LINES, roomForLines))
    while #lines > allowed do table.remove(lines) end

    local widest = 0
    for _, line in ipairs(lines) do
        local w = #line * advance - scale
        if w > widest then widest = w end
    end

    local boxW = math.min(wallW, widest + 2 * padX)
    local boxH = #lines * glyphH + (#lines - 1) * lineGap + 2 * padY
    local left = math.max(1, math.floor((wallW - boxW) / 2) + 1)
    local top = wallH - marginBottom - boxH + 1
    if top < 1 then return nil end

    -- Painted as a grid of booleans first, so a glyph that would spill past
    -- the edge is simply clipped instead of shifting the whole line.
    local rows = {}
    for y = 1, boxH do
        local row = {}
        for x = 1, boxW do row[x] = false end
        rows[y] = row
    end

    for lineIndex, line in ipairs(lines) do
        local lineW = #line * advance - scale
        local originX = math.floor((boxW - lineW) / 2) + 1
        local originY = padY + (lineIndex - 1) * (glyphH + lineGap) + 1
        for i = 1, #line do
            local glyph = GLYPHS[line:sub(i, i)] or GLYPHS[" "]
            local gx = originX + (i - 1) * advance
            for gy = 1, GLYPH_H do
                local pattern = glyph[gy]
                for cx = 1, GLYPH_W do
                    if pattern:sub(cx, cx) == "#" then
                        for sy = 1, scale do
                            local row = rows[originY + (gy - 1) * scale + sy - 1]
                            if row then
                                for sx = 1, scale do
                                    local at = gx + (cx - 1) * scale + sx - 1
                                    if at >= 1 and at <= boxW then row[at] = true end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return { top = top, left = left, width = boxW, height = boxH, rows = rows }
end

-- Turns a layout into the per-row patches drawFrame splices into the video's
-- own rows: { [y] = { x = , text = , fg = , bg = } }.
--
-- textHex and boxHex are single blit characters, chosen by the caller from
-- the palette the current frame is actually using.
function M.patches(layout, textHex, boxHex)
    if not layout then return nil end
    local patches = {}
    local blank = (" "):rep(layout.width)
    for offset = 1, layout.height do
        local row = layout.rows[offset]
        local bg = {}
        for x = 1, layout.width do
            bg[x] = row[x] and textHex or boxHex
        end
        patches[layout.top + offset - 1] = {
            x = layout.left,
            -- Space characters everywhere, so only the background colour
            -- shows. That means one blit paints both the glyph and its box,
            -- and the monitor never has to render a text glyph at all.
            text = blank,
            fg = boxHex:rep(layout.width),
            bg = table.concat(bg),
        }
    end
    return patches
end

-- Picks the lightest and darkest entries of the frame's own palette.
--
-- The wall encodes with all 16 palette slots free -- reserving white and
-- black for overlays was tried and it scattered bright speckle through dark
-- scenes, because the dither reached for colours the image did not contain.
-- So there is no guaranteed white to draw with. Taking the extremes of
-- whatever the frame is already using gives the most contrast available
-- without costing the picture anything, and it adapts scene by scene.
function M.contrastPair(palette)
    local lightestIndex, darkestIndex = 1, 1
    local lightest, darkest = -1, 2
    for i = 1, 16 do
        local c = palette[i]
        if c then
            local luma = 0.299 * (c[1] or 0) + 0.587 * (c[2] or 0) + 0.114 * (c[3] or 0)
            if luma > lightest then lightest = luma lightestIndex = i end
            if luma < darkest then darkest = luma darkestIndex = i end
        end
    end
    local hex = "0123456789abcdef"
    return hex:sub(lightestIndex, lightestIndex), hex:sub(darkestIndex, darkestIndex)
end

return M
