-- MAME's side of rtl/cpu/ms32_cpu_sys.sv's FPU0 read log (JTAG window region
-- 10) for f1superb: the first 512 V70 reads of FPU0 from chain 0 on (a chain
-- starts at a V70 write of 0x338 to FPU0's PC, 0xFD1024C0), and the hash and
-- count of every V70 write to FPU0 before chain 0:
--   h' = rotl1(h) ^ data ^ (dword index << 3), dword index = (address - 0xFD100000) >> 2
--
--   MS32_OUT=<file> ms32 f1superb -autoboot_script scripts/mame/fpureads.lua ...
-- Output: "pre <count> <hash>", then "<n> <index> <data>" per read, hex.

local prog = manager.machine.devices[":maincpu"].spaces["program"]
local out = io.open(os.getenv("MS32_OUT") or "fpureads.txt", "w")
local BASE = 0xfd100000
local chains, hpre, npre, n = 0, 0, 0, 0

wtap = prog:install_write_tap(BASE, BASE + 0x5fff, "fpu0w", function(o, d, m)
	local x = ((o - BASE) >> 2) & 0x1fff
	if o == BASE + 0x24c0 and (d & 0x3ff) == 0x338 then
		if chains == 0 then out:write(string.format("pre %d %04x\n", npre, hpre)) end
		chains = chains + 1
	elseif chains == 0 then
		hpre = ((((hpre << 1) | (hpre >> 15)) & 0xffff) ~ (d & 0xffff) ~ ((x << 3) & 0xffff))
		npre = npre + 1
	end
end)
rtap = prog:install_read_tap(BASE, BASE + 0x5fff, "fpu0r", function(o, d, m)
	if chains >= 1 and n < 512 then
		out:write(string.format("%d %03x %04x\n", n, ((o - BASE) >> 2) & 0x1fff, d & 0xffff))
		n = n + 1
	end
end)

emu.register_frame_done(function()
	if n >= 512 then out:close(); manager.machine:exit() end
end)
