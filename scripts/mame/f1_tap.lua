-- SPDX-License-Identifier: GPL-3.0-or-later
--
-- F-1 Super Battle: what the V70 touches in the road plane and the two FPUs.
-- Sizes the RAMs the core has to provide and shows the access pattern
-- (ROADMAP, "F-1 Super Battle", stage 2). Needs a MAME with PR 16135.
--
--     MS32_OUT=<dir> MS32_FRAMES=<n> ms32.exe f1superb -autoboot_script this
--
-- Writes <MS32_OUT>/f1_regions.txt: per region, the writes and reads counted,
-- the offsets touched (low and high, and how many distinct 256-byte blocks),
-- and for the FPU host windows a split between program RAM, data RAM and the
-- register file. Also f1_first.txt, the first 200 accesses of each region
-- with frame, address and value, as a shape to check RTL against.
local OUT    = os.getenv("MS32_OUT") or "."
local FRAMES = tonumber(os.getenv("MS32_FRAMES") or "1800")
local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr  = mach.screens[":screen"]

-- name, first address, last address, and the address the offsets count from
local REGIONS = {
    { "road_vram",  0xFDC00000, 0xFDC1FFFF },
    { "road_line",  0xFDE00000, 0xFDE1FFFF },
    { "road_ctrl",  0xFCE00800, 0xFCE0085F },
    { "fpu0",       0xFD100000, 0xFD105FFF },
    { "fpu1",       0xFD140000, 0xFD145FFF },
    { "priram",     0xC1180000, 0xC1187FFF },
}

local stat, first, taps = {}, {}, {}
local nfirst = 0
local ffirst = assert(io.open(OUT .. "/f1_first.txt", "w"))
ffirst:write("frame\tregion\tdir\toffset\tmask\tdata\tpc\n")

for _, r in ipairs(REGIONS) do
    stat[r[1]] = { w = 0, rd = 0, lo = nil, hi = nil, blocks = {}, nblocks = 0, n_first = 0 }
end

local function note(name, base, dir, offset, mask, data)
    local s = stat[name]
    local off = offset - base
    if dir == "w" then s.w = s.w + 1 else s.rd = s.rd + 1 end
    if not s.lo or off < s.lo then s.lo = off end
    if not s.hi or off > s.hi then s.hi = off end
    local b = off >> 8
    if not s.blocks[b] then s.blocks[b] = true; s.nblocks = s.nblocks + 1 end
    if s.n_first < 200 then
        s.n_first = s.n_first + 1
        ffirst:write(string.format("%d\t%s\t%s\t%06X\t%08X\t%08X\t%08X\n",
            scr:frame_number(), name, dir, off, mask, data, cpu.state["PC"].value))
    end
end

for _, r in ipairs(REGIONS) do
    local name, lo, hi = r[1], r[2], r[3]
    taps[#taps + 1] = prog:install_write_tap(lo, hi, name .. "w", function(offset, data, mask)
        note(name, lo, "w", offset, mask, data)
        return data
    end)
    taps[#taps + 1] = prog:install_read_tap(lo, hi, name .. "r", function(offset, data, mask)
        note(name, lo, "r", offset, mask, data)
        return data
    end)
end

-- the summary is rewritten every 300 frames, so a run cut short still leaves one
local function dump()
    local f = assert(io.open(OUT .. "/f1_regions.txt", "w"))
    f:write(string.format("f1superb, %d frames\n\n", scr:frame_number()))
    f:write("region      writes      reads   lowest   highest  256-byte blocks\n")
    for _, r in ipairs(REGIONS) do
        local s = stat[r[1]]
        f:write(string.format("%-10s %9d %10d   %06X    %06X  %8d\n",
            r[1], s.w, s.rd, s.lo or 0, s.hi or 0, s.nblocks))
    end
    f:write("\nFPU host window: 0x0000-0x3FFF program RAM (32-bit words), " ..
            "0x4000-0x5FFF data RAM (16-bit), registers above (jalfpu.cpp host_map)\n")
    f:close()
end

emu.add_machine_frame_notifier(function()
    local fr = scr:frame_number()
    if fr % 300 == 0 then dump() end
    if fr < FRAMES then return end
    ffirst:close()
    dump()
    mach:exit()
end)
