-- Bootstrap that makes Lua failures VISIBLE to the calling script.
--
-- MAME reports a broken autoboot script with a modal dialog. Headless, that is
-- close to invisible: the process sits on the dialog until something kills it,
-- the capture directory looks untouched, and the only symptom is "it quietly
-- did nothing". Two separate faults on the Seta core hid that way -- a syntax
-- error from a stray newline inside a string literal, and a runtime error
-- after an edit deleted a function that was still being called.
--
-- This wrapper catches both classes and writes them to a file the Python
-- runner reads back, so a Lua fault becomes a printed error instead of a hunt:
--
--   syntax errors    loadfile() returns nil plus a message, BEFORE any of the
--                    target script runs. pcall cannot catch these, because
--                    there is nothing to call yet -- it has to be loadfile.
--   runtime errors   pcall around the call, and again around each frame
--                    notifier, since an error inside a notifier is reported by
--                    MAME but does not reach the loader.
--
-- Point -autoboot_script at THIS file and pass the real script in MS32_SCRIPT.
-- Ported from the Seta core's scripts/mame/run.lua.

local OUT    = os.getenv("MS32_OUT")    or "."
local SCRIPT = os.getenv("MS32_SCRIPT")

local function record(kind, msg)
    local f = io.open(OUT .. "/lua_error.txt", "w")
    if f then
        f:write(kind .. ": " .. tostring(msg) .. "\n")
        f:close()
    end
    print("LUAFAIL " .. kind .. ": " .. tostring(msg))
end

if not SCRIPT then
    record("config", "MS32_SCRIPT is not set")
    manager.machine:exit()
    return
end

local chunk, lerr = loadfile(SCRIPT)
if not chunk then
    record("syntax", lerr)
    manager.machine:exit()
    return
end

local ok, rerr = pcall(chunk)
if not ok then
    record("runtime", rerr)
    manager.machine:exit()
end
