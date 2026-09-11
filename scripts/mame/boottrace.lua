-- Log the first N main-CPU bus accesses of a boot, as ground truth for the
-- RTL's own boot trace to be diffed against.
--
-- Driven by scripts/mame_boot_trace.py. Parameters arrive as environment
-- variables:
--
--   MS32_OUT      directory to write into (must already exist)
--   MS32_TAG      prefix for the output filename (normally the set name)
--   MS32_TRACE_N  how many accesses to log before stopping
--
-- Ported from the Seta core's scripts/mame/boottrace.lua. What changed for a
-- V70: the tap covers the full 32-bit address space and logs 32 bits of data,
-- because the V70 is a 32-bit machine whose ROM sits at 0xFFE00000 and whose
-- RAMs are mirrored across 0xC0000000-0xFFFFFFFF (ms32.cpp's map). The
-- Seta version masked to 24 bits and 16 bits, which would have silently
-- folded every MS32 address onto the wrong one.
--
-- WHY A READ TAP RATHER THAN THE DEBUGGER'S `trace`
-- -------------------------------------------------
-- MAME's `trace` emits one line per INSTRUCTION START. The RTL testbench sees
-- every bus ACCESS -- operand reads, stack pushes, table lookups. A read tap
-- on the program space records the accesses directly, so there is nothing to
-- reconstruct. It needs no debugger, which this MAME install would otherwise
-- open as a window.
--
-- What it does NOT capture: the distinction between an opcode fetch and a
-- data read (the Lua tap gives no function code), nor the WIDTH of each CPU
-- access -- the tap sees the address space's native unit, and `mask` says
-- which lanes the CPU asked for. Both are logged; the RTL bench should match
-- the ordered ADDRESS sequence and use mask/data as a check, not as the key.
--
-- Also note what the V70 core does that the tap will and will not see:
-- s32_v60's prefetch unit fetches 8-byte lines ahead of execution, so the RTL
-- will read ROM addresses MAME never touches. That is why the comparison is a
-- subsequence match with duplicates collapsed (LESSONS_LEARNED, "[Seta] Two
-- cores that both boot correctly still fetch different words").

local OUT = os.getenv("MS32_OUT") or "."
local TAG = os.getenv("MS32_TAG") or "trace"
local N   = tonumber(os.getenv("MS32_TRACE_N") or "512")

local mach = manager.machine
local cpu  = mach.devices[":maincpu"]
local prog = cpu.spaces["program"]

local f = assert(io.open(string.format("%s/%s_boot.trace", OUT, TAG), "w"))
f:write("# main-CPU bus accesses from reset, in order.\n")
f:write("# seq\trw\taddr\tmask\tdata\n")

local n, done = 0, false
local hits, logged, first_err = 0, 0, nil

local function stop()
    if done then return end
    done = true
    f:write(string.format("# %d accesses seen, %d logged\n", hits, logged))
    if first_err then f:write("# FIRST ERROR: " .. first_err .. "\n") end
    f:close()
    print(string.format("TRACE  %d accesses logged to %s/%s_boot.trace",
                        logged, OUT, TAG))
    mach:exit()
end

-- Every callback is wrapped and counted. An error inside a tap is SWALLOWED by
-- MAME -- on the Seta core that produced 459 tap hits and an empty log with
-- no diagnostic anywhere (docs/LESSONS_LEARNED.md). A hits count beside a
-- logged count is what makes that visible instead of silent.
local function record(rw)
    return function(offset, data, mask)
        hits = hits + 1
        if not done then
            local ok, err = pcall(function()
                n = n + 1
                f:write(string.format("%d\t%s\t%08X\t%08X\t%08X\n", n, rw,
                                      offset & 0xFFFFFFFF, mask & 0xFFFFFFFF,
                                      data & 0xFFFFFFFF))
                logged = logged + 1
            end)
            if not ok and not first_err then first_err = tostring(err) end
            if n >= N then stop() end
        end
        return data
    end
end

-- Keep the subscriptions alive: a collected tap silently stops firing.
_G.__ms32_trace_taps = {
    prog:install_read_tap(0x00000000, 0xffffffff, "rd", record("r")),
    prog:install_write_tap(0x00000000, 0xffffffff, "wr", record("w")),
}

-- A backstop, so a game that somehow makes fewer than N accesses still writes
-- its file rather than leaving an empty one behind when MAME's own
-- -seconds_to_run kills the run.
_G.__ms32_trace_notifier = emu.add_machine_frame_notifier(function()
    if mach.screens[":screen"]:frame_number() >= 600 then stop() end
end)
