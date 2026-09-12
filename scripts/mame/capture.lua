-- Capture a reference frame from a running MS32 game: every piece of video
-- state the RTL renders from, plus the screenshot MAME produced from it.
--
-- Driven by scripts/mame_capture.py -- see that file for usage and for the
-- region map. Parameters arrive as environment variables because MAME gives
-- an autoboot script no argument vector of its own:
--
--   MS32_OUT      directory to write into (must already exist)
--   MS32_FRAME    frame number to capture at
--   MS32_TAG      prefix for the output filenames (normally the set name)
--   MS32_REGIONS  "name:hexaddr:hexlen,name:hexaddr:hexlen,..."
--   MS32_TAPS     "hexlo:hexhi,..." ranges to log writes to, or empty
--
-- THIS FILE HOLDS NO GAME KNOWLEDGE: the addresses live in the Python side,
-- transcribed from ms32_map, where they can be reviewed together. A wrong
-- address here dumps zeros in silence.
--
-- Everything is read through the CPU program space, so what lands in the file
-- is what the CPU would read -- device handlers, umask32 and all -- rather
-- than a guess at where MAME keeps it internally. MS32's RAMs are 8- and
-- 16-bit devices behind a 32-bit bus (one meaningful byte or halfword per
-- dword), so the dump is one read_u32 per dword, written little-endian: the
-- file is the CPU's view of the region, byte for byte.
--
-- Ported from the Seta core's scripts/mame/capture.lua; the DIP mechanism is
-- not carried yet (see that file for why it is hard).

local OUT     = os.getenv("MS32_OUT")   or "."
local FRAME   = tonumber(os.getenv("MS32_FRAME") or "600")
local TAG     = os.getenv("MS32_TAG")   or "capture"
local REGIONS = os.getenv("MS32_REGIONS") or ""
local TAPS    = os.getenv("MS32_TAPS")  or ""

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

local function split(s, sep)
    local out = {}
    for tok in string.gmatch(s, "([^" .. sep .. "]+)") do out[#out + 1] = tok end
    return out
end

local function fail(msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write(msg .. "\n"); f:close() end
    print("LUAFAIL " .. msg)
    mach:exit()
end

local regions = {}
for _, spec in ipairs(split(REGIONS, ",")) do
    local f = split(spec, ":")
    if #f == 3 then
        regions[#regions + 1] = { tonumber(f[2], 16), tonumber(f[3], 16), f[1] }
    end
end
if #regions == 0 then
    fail("MS32_REGIONS was empty -- nothing to capture")
    return
end

local function dump(addr, len, name)
    local path = string.format("%s/%s_%s.bin", OUT, TAG, name)
    local f = assert(io.open(path, "wb"))
    local buf = {}
    for i = 0, len - 4, 4 do
        local w = prog:read_u32(addr + i)
        buf[#buf + 1] = string.char(w & 0xFF, (w >> 8) & 0xFF, (w >> 16) & 0xFF, (w >> 24) & 0xFF)
        if #buf >= 4096 then f:write(table.concat(buf)); buf = {} end
    end
    f:write(table.concat(buf))
    f:close()
    print(string.format("CAPTURE  %-12s %08X +%06X -> %s", name, addr, len, path))
end

-- THE CURRENT SCANLINE, derived rather than asked for: this MAME's Lua screen
-- binding has no vpos(). time_until_pos(y) exists, and from it
--     line_period  = smallest positive time_until_pos(1) - time_until_pos(0)
--     current line = (frame_period - time_until_pos(0)) / line_period
-- (LESSONS_LEARNED, "[Seta] An error inside a MAME write tap is SWALLOWED").
local frame_period = 1.0 / scr.refresh
local line_period
for _ = 1, 64 do
    local d = scr:time_until_pos(1) - scr:time_until_pos(0)
    if d > 0 and (line_period == nil or d < line_period) then line_period = d end
end
local function cur_line()
    if not line_period or line_period <= 0 then return -1 end
    return math.floor((frame_period - scr:time_until_pos(0)) / line_period + 0.5)
end

-- Optional write log: frame, scanline in force, address, data, PC. Every
-- callback wrapped and counted (hits beside logged), because an error inside
-- a tap is swallowed by MAME and would read as "no writes happened".
local wlog
local tap_hits, tap_logged, tap_err = 0, 0, nil
if TAPS ~= "" then
    wlog = assert(io.open(string.format("%s/%s_writes.log", OUT, TAG), "w"))
    wlog:write(string.format("# vtotal %d, derived from time_until_pos\n",
                             line_period and math.floor(frame_period / line_period + 0.5) or -1))
    wlog:write("# frame\tscanline\taddr\tmask\tdata\tpc\n")
    _G.__ms32_taps = {}   -- keep them alive; a collected tap stops firing
    for _, spec in ipairs(split(TAPS, ",")) do
        local f = split(spec, ":")
        local lo, hi = tonumber(f[1], 16), tonumber(f[2], 16)
        local tap = prog:install_write_tap(lo, hi, "ms32wr", function(offset, data, mask)
            tap_hits = tap_hits + 1
            local ok, err = pcall(function()
                wlog:write(string.format("%d\t%d\t%08X\t%08X\t%08X\t%08X\n",
                    scr:frame_number(), cur_line(), offset & 0xFFFFFFFF,
                    mask & 0xFFFFFFFF, data & 0xFFFFFFFF, cpu.state["PC"].value))
            end)
            if ok then tap_logged = tap_logged + 1
            elseif not tap_err then tap_err = tostring(err) end
            return data
        end)
        _G.__ms32_taps[#_G.__ms32_taps + 1] = tap
        print(string.format("CAPTURE  write tap %08X-%08X", lo, hi))
    end
end

local function nfail(msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then f:write("notifier: " .. tostring(msg) .. "\n"); f:close() end
    print("LUAFAIL notifier: " .. tostring(msg))
    mach:exit()
end

-- SPRITE RAM IS DOUBLE-BUFFERED BY THE DRIVER, AND THE CAPTURE HAS TO BE TOO.
--
-- ms32_v.cpp renders sprites from m_sprram_buffer, a copy of sprite RAM
-- taken in screen_vblank() at the START of vblank. The frame notifier fires
-- at the END of the frame, after the game's vblank handler has rewritten
-- sprite RAM for the next frame -- so a sprram dump taken there is one frame
-- AHEAD of what MAME drew. Static screens hide it (the title matched 100%);
-- animated ones showed it as ~1% of pixels, every one a sprite (tetrisp
-- frames 4800 and 7200; frame 7200 rendered with frame 7199's sprite RAM
-- matched to the pixel).
--
-- No yields are available to an autoboot script (emu.wait/wait_next_frame
-- fail outside a coroutine), so the copy moment is caught the other way
-- round: at the end of frame FRAME-1 a write tap goes onto sprite RAM, and
-- the FIRST write it sees -- the vblank handler's first sprite write after
-- the next vblank begins, i.e. after the driver's copy -- dumps the RAM as
-- it still is at that instant: "sprram_vbl". A game that writes nothing
-- that frame never fires it, and the end-of-frame dump is then identical.
local sprram_region
for _, r in ipairs(regions) do if r[3] == "sprram" then sprram_region = r end end
local vbl_dumped = false
local function arm_vbl_dump()
    if not sprram_region or _G.__ms32_vbl_tap then return end
    _G.__ms32_vbl_tap = prog:install_write_tap(sprram_region[1], sprram_region[1] + sprram_region[2] - 1,
        "ms32sprvbl", function(offset, data, mask)
            if not vbl_dumped then
                vbl_dumped = true
                local ok, err = pcall(dump, sprram_region[1], sprram_region[2], "sprram_vbl")
                if not ok then print("LUAFAIL vbl dump: " .. tostring(err)) end
                print(string.format("CAPTURE  sprram_vbl at the first sprite write of frame %d, line %d",
                                    scr:frame_number(), cur_line()))
            end
            return data
        end)
end

local done = false
local function frame_body()
    if done then return end
    local n = scr:frame_number()
    if n == FRAME - 1 then arm_vbl_dump() end
    if n < FRAME then return end
    done = true

    print(string.format("CAPTURE  frame %d, %s -> %s", n, TAG, OUT))
    for _, r in ipairs(regions) do dump(r[1], r[2], r[3]) end

    -- THE SNAPSHOT IS THE REFERENCE. video:snapshot() re-renders from the
    -- state that is live now -- the same state the dumps above read -- while
    -- scr:pixels() is the bitmap from the end of the previous visible area,
    -- one vblank earlier, before the game's handler rewrote sprite RAM.
    -- mame_capture.py passes -snapview native so no cabinet rotation is
    -- applied (desertwr and gametngk are ROT270).
    mach.video:snapshot()

    local f = assert(io.open(string.format("%s/%s_info.txt", OUT, TAG), "w"))
    f:write(string.format("system      %s\n", mach.system.name))
    f:write(string.format("description %s\n", mach.system.description))
    f:write(string.format("frame       %d\n", n))
    f:write(string.format("screen      %dx%d refresh %f\n", scr.width, scr.height, scr.refresh))
    f:write(string.format("orientation %s\n", tostring(scr:orientation())))
    f:write(string.format("vtotal      %d (derived)\n",
            line_period and math.floor(frame_period / line_period + 0.5) or -1))
    f:write(string.format("mame        %s\n", emu.app_version()))
    f:close()

    if wlog then
        wlog:write(string.format("# %d tap hits, %d logged\n", tap_hits, tap_logged))
        if tap_err then wlog:write("# FIRST ERROR: " .. tap_err .. "\n") end
        wlog:close()
    end
    mach:exit()
end

_G.__ms32_frame_notifier = emu.add_machine_frame_notifier(function()
    local ok, err = pcall(frame_body)
    if not ok then nfail(err) end
end)
