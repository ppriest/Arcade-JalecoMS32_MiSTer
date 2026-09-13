-- Log the sound interface from both sides, timestamped, as the reference the
-- Z80 subsystem is checked against.
--
-- Driven by scripts/mame_sound_trace.py. Environment:
--
--   MS32_OUT      directory to write into (must already exist)
--   MS32_TAG      prefix for the output filename (normally the set name)
--   MS32_FRAMES   frames to run before stopping
--
-- One line per event, time in seconds of emulated time:
--
--   t  cmd   dd        V70 wrote the sound latch (0xFC800000)
--   t  res   dd        V70 read the result (0xFD000000), as the V70 saw it
--   t  srst  dd        V70 wrote sysctrl sound reset (0xFCE00038)
--   t  sack  dd        V70 wrote sysctrl sound ack (0xFCE0004C)
--   t  zw    aaaa dd   Z80 write, 0x3F00-0x3FFF (YMF271, to_main, bank, ...)
--   t  zr    aaaa dd   Z80 read,  0x3F00-0x3F1F, as the Z80 saw it
--
-- Writes to 0x3F70 are not logged: the Z80 writes it every few instructions
-- and MAME leaves it unconnected. Consecutive identical zr lines (a status poll) are collapsed into one line
-- with a repeat count, or the file is mostly polls.

local OUT    = os.getenv("MS32_OUT") or "."
local TAG    = os.getenv("MS32_TAG") or "sound"
local FRAMES = tonumber(os.getenv("MS32_FRAMES") or "1200")

local mach = manager.machine
local main = mach.devices[":maincpu"].spaces["program"]
local z80  = mach.devices[":audiocpu"].spaces["program"]

local f = assert(io.open(string.format("%s/%s_sound.trace", OUT, TAG), "w"))
f:write("# t\tkind\t[addr]\tdata\n")

local hits, first_err, done = 0, nil, false
local last_zr, zr_rep, zr_t = nil, 0, 0

local function now() return mach.time:as_double() end

local function flush_zr()
    if last_zr then
        f:write(string.format("%.9f\tzr\t%s\tx%d\n", zr_t, last_zr, zr_rep))
        last_zr = nil
    end
end

local function guard(fn)
    return function(offset, data, mask)
        hits = hits + 1
        if not done then
            local ok, err = pcall(fn, offset, data, mask)
            if not ok and not first_err then first_err = tostring(err) end
        end
        return data
    end
end

local function main_w(kind)
    return guard(function(offset, data, mask)
        flush_zr()
        f:write(string.format("%.9f\t%s\t%02X\n", now(), kind, data & 0xFF))
    end)
end

_G.__ms32_sound_taps = {
    main:install_write_tap(0xfc800000, 0xfc800003, "cmd", main_w("cmd")),
    main:install_write_tap(0xfce00038, 0xfce0003b, "srst", main_w("srst")),
    main:install_write_tap(0xfce0004c, 0xfce0004f, "sack", main_w("sack")),
    main:install_read_tap(0xfd000000, 0xfd000003, "res", main_w("res")),
    z80:install_write_tap(0x3f00, 0x3fff, "zw", guard(function(offset, data)
        if offset == 0x3f70 then return end   -- written every few instructions; unconnected in MAME
        flush_zr()
        f:write(string.format("%.9f\tzw\t%04X\t%02X\n", now(), offset, data))
    end)),
    z80:install_read_tap(0x3f00, 0x3f1f, "zr", guard(function(offset, data)
        local key = string.format("%04X\t%02X", offset, data)
        if key == last_zr then
            zr_rep = zr_rep + 1
        else
            flush_zr()
            last_zr, zr_rep, zr_t = key, 1, now()
        end
    end)),
}

_G.__ms32_sound_notifier = emu.add_machine_frame_notifier(function()
    if done then return end
    if mach.screens[":screen"]:frame_number() >= FRAMES then
        done = true
        flush_zr()
        f:write(string.format("# %d tap hits\n", hits))
        if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
        f:close()
        print(string.format("SOUNDTRACE %d hits to %s/%s_sound.trace", hits, OUT, TAG))
        mach:exit()
    end
end)
