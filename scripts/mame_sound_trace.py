#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture both sides of the sound interface from MAME, timestamped.

    python scripts/mame_sound_trace.py tetrisp --frames 1200
    -> debug/<set>-sound/<set>_sound.trace

The V70's latch writes, result reads and sysctrl sound reset/ack, and every
Z80 access to 0x3F00-0x3FFF (YMF271, latch, bank). The command lines drive
sim/sound_tb; the Z80 lines are what the RTL's own accesses are compared
against. Format in scripts/mame/soundtrace.lua.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mame_boot_trace import MAME_DIR, MAME_EXE, rompath  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frames", type=int, default=1200)
    a = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    out = repo / "debug" / f"{a.game}-sound"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    env = dict(os.environ)
    env.update(MS32_OUT=out.as_posix(), MS32_TAG=a.game, MS32_FRAMES=str(a.frames),
               MS32_SCRIPT=(repo / "scripts" / "mame" / "soundtrace.lua").as_posix())
    cmd = [str(MAME_EXE), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-rompath", rompath(repo),
           "-seconds_to_run", str(a.frames // 50 + 30),
           "-autoboot_delay", "0",
           "-autoboot_script", (repo / "scripts" / "mame" / "run.lua").as_posix()]
    print(" ".join(cmd))
    r = subprocess.run(cmd, cwd=MAME_DIR, env=env, capture_output=True, text=True)
    sys.stdout.write(r.stdout[-2000:])
    sys.stderr.write(r.stderr[-2000:])
    trace = out / f"{a.game}_sound.trace"
    if not trace.exists():
        sys.exit("no trace written -- see MAME output above")
    print(f"-> {trace}")
    return 0 if r.returncode == 0 else r.returncode


if __name__ == "__main__":
    sys.exit(main())
