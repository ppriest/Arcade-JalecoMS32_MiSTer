#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Capture a reference frame from MAME: video state plus the screenshot.

    python scripts/mame_capture.py tetrisp --frame 1200 --name title
    python scripts/mame_capture.py tetrisp --frame 3000 --name play --wlog
    -> debug/<name>/<set>_<region>.bin, reference.png, <set>_info.txt

Every region the video hardware renders from is dumped through the CPU's
program space at the chosen frame, and the screenshot MAME rendered from that
same state is saved beside them. Phase 1's benches preload the dumps, render
one frame, and compare against reference.png.

Region map: transcribed from ms32_map in jaleco/ms32.cpp (the 0xFC/0xFD/0xFE
aliases MAME's own comments name, which the CPU actually uses). Each is the
region's full physical size; the file is the CPU's dword view of it, little-
endian, umask32 applied by MAME's handlers (so a 16-bit region reads as
0x0000hhhh per dword).

Ported from the Seta core's scripts/mame_capture.py. Conventions kept, each
for a reason recorded in docs/LESSONS_LEARNED.md: -nodebug and -nowindow are
explicit; -rompath is this repo's roms/ first then mame.ini's entries; the
output directory starts clean so a capture is never a mixture of runs; the
Lua runs through run.lua so a syntax or runtime error becomes a printed line;
snapshots are searched for recursively and renamed to reference.png.
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mame_boot_trace import MAME_DIR, MAME_EXE, rompath  # noqa: E402

# name: (address, length). Sizes are the physical RAMs from ms32_map; the
# register blocks are the .ram().share() windows (readable) -- the sysctrl
# and brightness registers are write-only in MAME and reach a capture only
# through --wlog.
REGIONS = {
    "palram":  (0xFD400000, 0x40000),   # 0x8000 colours, two u16 each
    "priram":  (0xFD180000, 0x08000),   # 8-bit, 0x2000 bytes
    "rozram":  (0xFE000000, 0x20000),   # 128x128 tiles, two u16 each
    "lineram": (0xFE200000, 0x02000),   # 8 u16 per line
    "sprram":  (0xFE800000, 0x20000),   # 4096 sprites, 8 u16 each
    "txram":   (0xFEC00000, 0x08000),   # 64x64 tiles
    "bgram":   (0xFEC08000, 0x08000),   # 64x64 (or 256x16) tiles
    "sprctrl": (0xFCE00200, 0x00080),
    "rozctrl": (0xFCE00600, 0x00060),
    "txscroll": (0xFCE00A00, 0x00018),
    "bgscroll": (0xFCE00A20, 0x00018),
    "bgmode":  (0xFCE00A7C, 0x00004),
}
# --wlog taps: the write-only registers, so their last values are recoverable
WRITE_TAPS = [
    (0xFCE00000, 0xFCE0005F),   # sysctrl (CRTC, irq acks, timer)
    (0xFCE00280, 0xFCE0028F),   # brightness
    (0xFCE00200, 0xFCE0027F),   # sprite ctrl
    (0xFCE00600, 0xFCE0065F),   # roz ctrl
    (0xFCE00A00, 0xFCE00A7F),   # scroll, bgmode
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--frame", type=int, default=600)
    ap.add_argument("--name", help="capture directory name under debug/ (default <game>-f<frame>)")
    ap.add_argument("--wlog", action="store_true", help="log register writes with frame and scanline")
    a = ap.parse_args()

    repo = Path(__file__).resolve().parent.parent
    out = repo / "debug" / (a.name or f"{a.game}-f{a.frame}")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    if not MAME_EXE.exists():
        sys.exit(f"MAME not found at {MAME_EXE}; set MAME_DIR / MAME_EXE")

    env = dict(os.environ)
    env.update(
        MS32_OUT=out.as_posix(),
        MS32_FRAME=str(a.frame),
        MS32_TAG=a.game,
        MS32_REGIONS=",".join(f"{n}:{addr:x}:{ln:x}" for n, (addr, ln) in REGIONS.items()),
        MS32_TAPS=",".join(f"{lo:x}:{hi:x}" for lo, hi in WRITE_TAPS) if a.wlog else "",
        MS32_SCRIPT=(repo / "scripts" / "mame" / "capture.lua").as_posix(),
    )
    cmd = [str(MAME_EXE), a.game, "-skip_gameinfo", "-nodebug", "-nothrottle",
           "-sound", "none", "-video", "none", "-nowindow",
           "-autoboot_delay", "0",
           "-autoboot_script", (repo / "scripts" / "mame" / "run.lua").as_posix(),
           "-snapshot_directory", out.as_posix(),
           "-snapview", "native",
           "-rompath", rompath(repo),
           "-seconds_to_run", str(max(30, a.frame // 60 + 20))]
    print(" ".join(cmd))
    r = subprocess.run(cmd, cwd=str(MAME_DIR), env=env, capture_output=True, text=True)
    for line in (r.stdout or "").splitlines():
        if line.startswith(("CAPTURE", "LUAFAIL")):
            print("  " + line)

    err = out / "lua_error.txt"
    if err.exists():
        sys.exit("Lua failed: " + err.read_text().strip())
    got = [p.name for p in out.iterdir()]
    if not any(n.endswith(".bin") for n in got):
        print("--- MAME stdout ---\n" + (r.stdout or "").strip()[-2000:])
        print("--- MAME stderr ---\n" + (r.stderr or "").strip()[-2000:])
        sys.exit(f"no dumps written to {out}")

    snaps = sorted(out.rglob("[0-9][0-9][0-9][0-9].png"))
    if len(snaps) == 1:
        shutil.copyfile(snaps[0], out / "reference.png")
    elif len(snaps) > 1:
        sys.exit(f"{len(snaps)} snapshots in {out} -- cannot tell which frame the dumps belong to")
    else:
        print("  WARNING: no snapshot was written")

    print(f"\n{out}:")
    for n in sorted(p.name for p in out.iterdir()):
        print(f"  {n:28s} {(out / n).stat().st_size:>9,} bytes")


if __name__ == "__main__":
    main()
