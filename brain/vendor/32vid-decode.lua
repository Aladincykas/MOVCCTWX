-- 32vid-decode.lua
-- Module form of MCJack123's 32vid-player-MINI.lua (from the sanjuuni
-- project, https://github.com/MCJack123/sanjuuni, MIT licensed).
--
-- NOTE ON WHICH PLAYER THIS IS: sanjuuni's 0.5 release ships several player
-- scripts (32vid-player.lua, 32vid-player-mini.lua, ...). This project
-- originally vendored 32vid-player.lua (the OLDER per-stream Huffman-coded
-- format), which does not match what sanjuuni.exe 0.5 actually produces by
-- default -- confirmed in-game ("No video stream found") and then by
-- directly parsing an uploaded chunk's header with Node: the single stream
-- present has type 12 (Vid32Chunk::Type::Combined, confirmed against
-- sanjuuni's own C++ source, src/sanjuuni.hpp), not type 0 (Video). Passing
-- -S/--separate-streams does NOT change this -- verified by converting a
-- fresh test clip and re-parsing the header, still type 12. 32vid-player-
-- mini.lua is the one that explicitly requires ctype == 0x0C (Combined)
-- and uses a completely different per-frame ANS/tANS-style entropy coder
-- (init/read below) instead of the older Huffman-tree approach -- this is
-- the actually-correct decoder for what this sanjuuni build outputs, and
-- is ported here as faithfully as possible. Do not "clean up" the ANS
-- table-construction math by hand.
--
-- The storage and the hot loops HAVE since been optimised (lookup tables,
-- parallel arrays, inlined bit reads, reused row buffers), and that change was
-- verified the only way a decoder change can be: every frame of three real
-- DXR S1E1 chunks decoded in CraftOS-PC by both versions and compared byte for
-- byte -- rows, colours and palette. Any further change to this file needs the
-- same check before it ships.
--
-- STREAMING, NOT BATCH: this was previously rewritten to collect every
-- decoded video frame and audio chunk into video[]/audio[] arrays and
-- return them all at once after reading the whole chunk file. That was a
-- real mistake -- the ORIGINAL 32vid-player-mini.lua never does this, it
-- renders each video frame and plays each audio chunk immediately as it's
-- decoded, in one single streaming pass, holding at most one frame/chunk in
-- memory at a time. A real chunk is ~90s * ~10fps = ~900 video frame
-- records, each holding several ~2.7KB blit strings, plus ~90 one-second
-- audio chunks decoded as raw PCM tables (which have far more overhead per
-- element than packed bytes) -- collecting ALL of that into two big Lua
-- tables before playback even starts is a genuinely large amount of memory
-- pressure on a real CC:Tweaked computer, and is a very plausible
-- contributor to the monitor corruption/freeze symptoms that persisted even
-- after fps-capping and row-diffing the render side. This version goes back
-- to the reference design: M.decode() takes `handlers` and invokes them
-- inline per-record as it reads through the file, never accumulating more
-- than the current frame/chunk. See videoplayer.lua for how playback pacing
-- and audio dispatch now live inside those handler callbacks instead of a
-- separate post-decode phase.

local bit32_band, bit32_lshift, bit32_rshift, math_frexp = bit32.band, bit32.lshift, bit32.rshift, math.frexp
local function log2(n) local _, r = math_frexp(n) return r - 1 end
local dfpwm = require("cc.audio.dfpwm")

local blitColors = { [0] = "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f" }

-- Lookup tables for the per-symbol and per-cell hot paths.
--
-- A 324x120 frame is about 116,000 ANS symbols and 38,880 cells, and every one
-- of them used to pay for work whose answer never changes: `2 ^ n - 1` to build
-- a bit mask (a floating-point power, per symbol), and `string.char(128 + v)`
-- to build a drawing character that can only ever be one of 32 values. Both
-- are now looked up. Measured in CraftOS-PC on a real DXR S1E1 chunk, with the
-- decoded output checked byte-for-byte against the unoptimised version.
local MASK, POW2 = {}, {}
for n = 0, 32 do
    POW2[n] = 2 ^ n
    MASK[n] = 2 ^ n - 1
end
-- Out-of-range values fall through to string.char itself, so anything that
-- would have errored before still errors in exactly the same way.
local CHAR = setmetatable({}, { __index = function(_, v) return string.char(128 + v) end })
for v = 0, 127 do CHAR[v] = string.char(128 + v) end
local concat = table.concat

local M = {}

-- Streams an already-open 32vid file handle (opened "rb") through
-- `handlers`, a table of:
--   handlers.onHeader(width, height, fps)       -- called once, up front
--   handlers.onVideoFrame(frame, frameIndex)     -- frame = {palette=..., [1..height]={text,fg,bg}}
--   handlers.onAudioChunk(chunk)                 -- chunk = PCM sample table (fire-and-forget, matches reference player)
--   handlers.shouldStop() -> bool                -- checked before each record; decode aborts early if true
-- Only supports the single-stream, Combined (type 0x0C), ANS-compressed
-- format sanjuuni.exe 0.5 actually produces with -3 -d (with or without -S)
-- -- see the header comment above. Closes `file` when done (including on
-- early stop or error).
function M.decode(file, handlers)
    handlers = handlers or {}
    if file.read(4) ~= "32VD" then file.close() error("Not a 32vid file") end
    local width, height, fps, nstreams, flags = ("<HHBBH"):unpack(file.read(8))
    if nstreams ~= 1 then
        file.close()
        error("This 32vid file uses separate streams, which this decoder doesn't support -- only the default Combined/ANS format is handled.")
    end
    if bit32_band(flags, 1) == 0 then
        file.close()
        error("This 32vid file isn't ANS-compressed, which this decoder doesn't support.")
    end
    local _, nframes, ctype = ("<IIB"):unpack(file.read(9))
    if ctype ~= 0x0C then
        file.close()
        error(("This 32vid file's stream type (%d) isn't Combined (12), which this decoder doesn't support."):format(ctype))
    end

    if handlers.onHeader then handlers.onHeader(width, height, fps) end

    -- ==== ANS (tANS-style) entropy decoder, ported verbatim ====
    local function readDict(size)
        local retval = {}
        for i = 0, size - 1, 2 do
            local b = file.read()
            retval[i] = bit32_rshift(b, 4)
            retval[i + 1] = bit32_band(b, 15)
        end
        return retval
    end

    local init, read
    -- The decoding table is held as three parallel arrays (symbol, bit count,
    -- next-state base) instead of one small table per state. A table of 2^R
    -- entries was rebuilt for every init, which is twice per frame -- thousands
    -- of short-lived tables a frame for the garbage collector, on the same
    -- thread that draws. The construction math below is unchanged; only where
    -- its results are kept.
    --
    -- The bitstream state (partial/bits) lives here too, rather than inside a
    -- per-init readbits closure, so read() can pull bits inline instead of
    -- making a function call for every one of the ~116,000 symbols a frame.
    local decS, decN, decX, constantSymbol
    local X, isColor
    local partial, bits = 0, 0
    function init(c)
        isColor = c
        local R = file.read()
        local L = 2 ^ R
        local Ls = readDict(c and 24 or 32)
        if R == 0 then
            constantSymbol = file.read()
            X = nil
            return
        end
        local a = 0
        for i = 0, #Ls do Ls[i] = Ls[i] == 0 and 0 or 2 ^ (Ls[i] - 1) a = a + Ls[i] end
        assert(a == L, a)
        local x, step, next_, symbol = 0, 0.625 * L + 3, {}, {}
        for i = 0, #Ls do
            next_[i] = Ls[i]
            for _ = 1, Ls[i] do
                while symbol[x] do x = (x + 1) % L end
                x, symbol[x] = (x + step) % L, i
            end
        end
        local tS, tN, tX = {}, {}, {}
        for x2 = 0, L - 1 do
            local s = symbol[x2]
            local n = R - log2(next_[s])
            -- Same simultaneous update as before: both the next-state base and
            -- the increment use the value of next_[s] from BEFORE this entry.
            tS[x2], tN[x2], tX[x2], next_[s] = s, n, bit32_lshift(next_[s], n) - L, 1 + next_[s]
        end
        decS, decN, decX = tS, tN, tX

        -- A fresh bitstream for this init, then the initial state: what
        -- readbits(R) used to do. R is never 0 here.
        partial, bits = 0, 0
        while bits < R do bits, partial = bits + 8, bit32_lshift(partial, 8) + file.read() end
        X = bit32_band(bit32_rshift(partial, bits - R), MASK[R])
        bits = bits - R
    end
    function read(nsym)
        local retval = {}
        if X == nil then
            local v = constantSymbol
            for i = 1, nsym do retval[i] = v end
            return retval
        end
        -- Everything the loop touches, as locals: upvalue and global lookups
        -- cost more than locals, and this loop runs ~116,000 times a frame.
        local S, N, XT, mask, pow2 = decS, decN, decX, MASK, POW2
        local band, rshift, lshift, readByte = bit32_band, bit32_rshift, bit32_lshift, file.read
        local color = isColor
        local x, p, b = X, partial, bits
        local i, last = 1, 0
        while i <= nsym do
            local s = S[x]
            if color and s >= 16 then
                local l = pow2[s - 15]
                for n = 0, l - 1 do retval[i + n] = last end
                i = i + l
            else
                retval[i], last, i = s, s, i + 1
            end
            -- readbits(N[x]), inlined.
            local n = N[x]
            local v = 0
            if n ~= 0 then
                while b < n do b, p = b + 8, lshift(p, 8) + readByte() end
                v = band(rshift(p, b - n), mask[n])
                b = b - n
            end
            x = XT[x] + v
        end
        X, partial, bits = x, p, b
        return retval
    end

    -- ==== Main per-frame loop -- streams straight to handlers, nothing
    -- retained past the current record ====
    local vframe = 0

    for i = 1, nframes do
        if handlers.shouldStop and handlers.shouldStop() then break end

        local size, ftype = ("<IB"):unpack(file.read(5))

        if ftype == 0 then
            -- video frame: size is informational only, NOT used to bound
            -- the read -- the ANS init/read calls consume exactly as many
            -- bytes as they need, same as the original player.
            init(false)
            local screen = read(width * height)
            init(true)
            local bg = read(width * height)
            local fg = read(width * height)

            local frame = { palette = {} }
            -- The three row buffers are reused for every row: each row writes
            -- all `width` entries before it is joined, so nothing from the
            -- previous row can leak into the next.
            local text, fgs, bgs = {}, {}, {}
            local idx = 0
            for y = 1, height do
                for x = 1, width do
                    idx = idx + 1
                    text[x] = CHAR[screen[idx]]
                    fgs[x] = blitColors[fg[idx]]
                    bgs[x] = blitColors[bg[idx]]
                end
                frame[y] = { concat(text, "", 1, width), concat(fgs, "", 1, width), concat(bgs, "", 1, width) }
            end
            for n = 1, 16 do
                frame.palette[n] = { file.read() / 255, file.read() / 255, file.read() / 255 }
            end

            vframe = vframe + 1
            if handlers.onVideoFrame then handlers.onVideoFrame(frame, vframe) end
        elseif ftype == 1 then
            local data = file.read(size)
            local chunk
            if bit32_band(flags, 12) == 0 then
                chunk = { data:byte(1, -1) }
                for j = 1, #chunk do chunk[j] = chunk[j] - 128 end
            else
                chunk = dfpwm.decode(data)
            end
            -- This decoder itself never waits on anything here -- it just
            -- hands the decoded chunk to the handler and moves straight on
            -- to the next record, so decode throughput is never gated by
            -- speaker state. What the handler DOES with the chunk (dispatch
            -- immediately, queue it, wait for acks, ...) is entirely up to
            -- the caller -- see videoplayer.lua's onAudioChunk for why it
            -- queues rather than dispatching inline (a genuine
            -- fire-and-forget dispatch broke multi-speaker sync badly when
            -- tried, confirmed in-game).
            if handlers.onAudioChunk then handlers.onAudioChunk(chunk) end
        elseif ftype == 8 then
            -- Subtitle record: nothing in this project's UI renders
            -- subtitles, so just consume the bytes and move on rather than
            -- building tables no one reads.
            file.read(size)
        else
            file.close()
            error(("Unknown/unsupported frame type %d (multi-monitor output isn't supported here)"):format(ftype))
        end
    end

    file.close()
    if vframe == 0 then error("No video stream found in 32vid chunk") end
end

return M
