local OUT = os.getenv("MS32_OUT")
local mach = manager.machine
local cpu = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]
local scr = mach.screens[":screen"]
local f = assert(io.open(OUT .. "/dsw_reads.log", "w"))
_G.__t = prog:install_read_tap(0xFCC00000, 0xFCC0001F, "dsw", function(offset, data, mask)
    local fr = scr:frame_number()
    if fr >= 4550 and fr <= 4700 then
        f:write(string.format("%d\t%08X\t%08X\t%08X\t%08X\n", fr, offset, mask, data, cpu.state["PC"].value))
    end
    if fr > 4700 then f:close(); mach:exit() end
    return data
end)
