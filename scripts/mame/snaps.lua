-- Snapshots at a list of frames in one run: MS32_FRAMES "f1,f2,...", written
-- by MAME into -snapshot_directory as 0000.png, 0001.png, ... in frame order,
-- and the frame list into MS32_OUT/frames.txt so the numbering can be read back.
local OUT = os.getenv("MS32_OUT") or "."
local list = {}
for tok in string.gmatch(os.getenv("MS32_FRAMES") or "", "([^,]+)") do list[#list + 1] = tonumber(tok) end
local mach = manager.machine
local scr = mach.screens[":screen"]
local f = assert(io.open(OUT .. "/frames.txt", "w"))
local i = 1
_G.__snaps = emu.add_machine_frame_notifier(function()
    if i > #list then f:close(); mach:exit(); return end
    if scr:frame_number() >= list[i] then
        f:write(string.format("%d\n", scr:frame_number())); f:flush()
        mach.video:snapshot()
        i = i + 1
    end
end)
