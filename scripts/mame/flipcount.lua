-- Count, per frame, how many DRAWN sprites carry flipx and flipy, exactly as
-- ms32_sprite.cpp's extract_parameters reads them. The core's own probe counts
-- the same thing on hardware, so the two are directly comparable.
--
--   MS32_FLIP_OUT=<file>  where to write "<frame> <drawn> <flipx> <flipy> <both>"
local out = os.getenv("MS32_FLIP_OUT") or "flipcount.txt"
local fh = io.open(out, "w")
local mac = manager.machine
local cpu = mac.devices[":maincpu"]
local mem = cpu.spaces["program"]
local frame = 0

emu.register_frame_done(function()
    frame = frame + 1
    if frame % 30 ~= 0 then return end
    local drawn, fx, fy, both = 0, 0, 0, 0
    -- object RAM at 0xfe800000, one u16 per 32-bit slot, 8 words a sprite
    for s = 0, 0x20000 - 8, 8 do
        local base = 0xfe800000 + s * 4
        local attr = mem:read_u32(base) & 0xffff
        if (attr & 4) ~= 0 then
            local incx = mem:read_u32(base + 6 * 4) & 0xffff
            local incy = mem:read_u32(base + 7 * 4) & 0xffff
            if incx ~= 0 and incy ~= 0 then
                drawn = drawn + 1
                if (attr & 1) ~= 0 then fx = fx + 1 end
                if (attr & 2) ~= 0 then fy = fy + 1 end
                if (attr & 3) == 3 then both = both + 1 end
            end
        end
    end
    fh:write(string.format("%d %d %d %d %d\n", frame, drawn, fx, fy, both))
    fh:flush()
end)
