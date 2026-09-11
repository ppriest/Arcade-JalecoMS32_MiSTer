#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture the first N main-CPU bus accesses of a game's boot from MAME.

    python scripts/mame_boot_trace.py tetrisp 20000
    -> debug/tetrisp-boot/tetrisp_boot.trace

The reference the V70 core's boot is diffed against (docs/ROADMAP.md,
Phase 0 exit criterion 2). Cut down from the Seta core's mame_capture.py
to the one mode this project needs first; the rest of that script (frame
dumps, register-write taps, DIP seeding) comes over when Phase 1 needs it.

Conventions carried from there, each for a reason recorded in
docs/LESSONS_LEARNED.md:

  * -nodebug and -nowindow are passed explicitly. mame.ini may say `debug 1`,
    and then every launch halts in the debugger while the autoboot script
    still loads and still prints, so it looks like it is working while the
    machine never advances a frame.
  * -rompath is this repo's gitignored roms/ FIRST, then whatever mame.ini
    already had -- -rompath REPLACES the ini value rather than adding to it.
  * The output directory is deleted and recreated, so a capture is never a
    mixture of two runs.
  * The Lua side counts tap hits beside logged lines; an error inside a tap
    is swallowed by MAME and would otherwise read as "no accesses happened".

MAME_DIR / MAME_EXE come from the environment (mister.env has them), and
default to the install the sibling cores use.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

MAME_DIR = Path(os.environ.get("MAME_DIR", r"C:\Emulation\Emulators\MAME"))
MAME_EXE = MAME_DIR / os.environ.get("MAME_EXE", "arcade64.exe")


def rompath(repo):
    paths = [str(repo / "roms")]
    ini = MAME_DIR / "mame.ini"
    if ini.exists():
        for line in ini.read_text(errors="replace").splitlines():
            if line.strip().startswith("rompath"):
                for part in line.split(None, 1)[1].split(";"):
                    part = part.strip()
                    if part:
                        q = Path(part)
                        paths.append(str(q if q.is_absolute() else MAME_DIR / q))
                break
    seen, out = set(), []
    for q in paths:
        if q not in seen:
            seen.add(q)
            out.append(q)
    return ";".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("n", type=int, help="accesses to log")
    ap.add_argument("--seconds", type=int, default=30,
                    help="MAME -seconds_to_run backstop (default 30)")
    a = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    out = repo / "debug" / f"{a.game}-boot"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    if not MAME_EXE.exists():
        sys.exit(f"MAME not found at {MAME_EXE}; set MAME_DIR / MAME_EXE")

    env = dict(os.environ)
    env.update(MS32_OUT=out.as_posix(), MS32_TAG=a.game, MS32_TRACE_N=str(a.n))
    cmd = [str(MAME_EXE), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-rompath", rompath(repo),
           "-seconds_to_run", str(a.seconds),
           "-autoboot_delay", "0",
           "-autoboot_script", (repo / "scripts" / "mame" / "boottrace.lua").as_posix()]
    print(" ".join(cmd))
    r = subprocess.run(cmd, cwd=MAME_DIR, env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout[-2000:])
    sys.stderr.write(r.stderr[-2000:])

    trace = out / f"{a.game}_boot.trace"
    if not trace.exists():
        sys.exit("no trace written -- see MAME output above")
    tail = trace.read_text().splitlines()[-3:]
    print("\n".join(tail))
    print(f"-> {trace}")
    return 0 if r.returncode == 0 else r.returncode


if __name__ == "__main__":
    sys.exit(main())
