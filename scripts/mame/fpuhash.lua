-- Per-chain hashes of the V70's traffic to f1superb's FPU0, the same as
-- rtl/cpu/ms32_cpu_sys.sv computes on the board (JTAG window region 10), to
-- find the first chain where the board parts from MAME.
--
--   MS32_OUT=<file> ms32 f1superb -autoboot_script scripts/mame/fpuhash.lua ...
--
-- A chain starts at a V70 write of 0x338 to FPU0's PC (0xFD1024C0). Per chain,
-- in access order, writes and reads apart:
--   h' = rotl1(h) ^ data ^ (dword index << 3), dword index = (address - 0xFD100000) >> 2
-- with data the low 16 bits written, or the 16 bits read back. The start write
-- opens the new chain's writes hash. Output: "<chain> <writes hash> <reads hash>",
-- hex, for the first 512 chains.

local prog = manager.machine.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("MS32_OUT") or "fpuhash.txt", "w")
local BASE = 0xfd100000
local hw, hr, chains = 0, 0, 0

local function mix(h, d, o)
	local x = ((o - BASE) >> 2) & 0x1fff
	h = ((h << 1) | (h >> 15)) & 0xffff
	return h ~ (d & 0xffff) ~ ((x << 3) & 0xffff)
end

wtap = prog:install_write_tap(BASE, BASE + 0x5fff, "fpu0w", function(o, d, m)
	if o == BASE + 0x24c0 and (d & 0x3ff) == 0x338 then
		if chains >= 1 and chains <= 512 then out:write(string.format("%d %04x %04x\n", chains - 1, hw, hr)) end
		chains = chains + 1
		hw, hr = 0, 0
	end
	hw = mix(hw, d, o)
end)
rtap = prog:install_read_tap(BASE, BASE + 0x5fff, "fpu0r", function(o, d, m)
	hr = mix(hr, d, o)
end)

emu.register_frame_done(function()
	if chains > 512 then out:close(); manager.machine:exit() end
end)
