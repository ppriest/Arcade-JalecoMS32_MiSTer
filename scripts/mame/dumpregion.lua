-- Dump MAME memory regions AFTER the driver's init has run -- for MS32 that is
-- after decrypt_ms32_tx/bg -- so a transcription of the decryption can be
-- checked byte for byte against MAME's own result rather than judged by eye.
--   MS32_OUT      directory
--   MS32_TAG      filename prefix
--   MS32_MREGIONS "txtiles,bgtiles"  (region tags without the leading colon)
local OUT = os.getenv("MS32_OUT") or "."
local TAG = os.getenv("MS32_TAG") or "dump"
local mach = manager.machine
for name in string.gmatch(os.getenv("MS32_MREGIONS") or "", "([^,]+)") do
    local r = mach.memory.regions[":" .. name]
    if not r then print("LUAFAIL no region " .. name); mach:exit(); return end
    local f = assert(io.open(string.format("%s/%s_%s_mame.bin", OUT, TAG, name), "wb"))
    local buf = {}
    for i = 0, r.size - 1 do
        buf[#buf + 1] = string.char(r:read_u8(i))
        if #buf >= 65536 then f:write(table.concat(buf)); buf = {} end
    end
    f:write(table.concat(buf)); f:close()
    print(string.format("REGION   %-10s %d bytes -> %s", name, r.size, f))
end
mach:exit()
