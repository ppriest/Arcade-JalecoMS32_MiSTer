#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Dump a video RAM region off a running board, under the machine-wide JTAG lock.

    python scripts/dump_ram.py <region> <count> <outfile>
    python scripts/dump_ram.py all <dir>        # every region this window reaches

Regions: 0 road map (1024), 1 road line RAM (2048), 2 road_ctrl (24),
3 priority RAM (8192), 4 ROZ map (32768), 5 ROZ line RAM (2048),
6 TX map (8192), 7 palette (32768).

The window takes over the RAMs' read ports while it is armed, so the picture
is garbage during a dump and the game should be paused first. Object RAM is
not here: it lives in SDRAM and needs its own tap.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hwlock import jtag_session  # noqa: E402

QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")
SIZES = {0: 1024, 1: 2048, 2: 24, 3: 8192, 4: 32768, 5: 2048, 6: 8192, 7: 32768}
NAMES = {0: "roadvram", 1: "roadline", 2: "roadctrl", 3: "priram",
         4: "rozram", 5: "lineram", 6: "txram", 7: "palram"}


def dump(region, count, out):
    r = subprocess.run([str(QUARTUS_STP), "-t", str(REPO / "scripts" / "dump_ram.tcl"),
                        str(region), str(count), str(out)],
                       cwd=REPO, capture_output=True, text=True, timeout=3600)
    for line in r.stdout.splitlines():
        if line.startswith(("wrote", "NO ")):
            print("  " + line)
    if r.returncode:
        print(r.stderr.strip()[-500:])
    return r.returncode


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "all":
        d = Path(sys.argv[2]); d.mkdir(parents=True, exist_ok=True)
        with jtag_session("dump_ram (all regions)"):
            for reg, n in SIZES.items():
                print(f"{NAMES[reg]}: {n} words")
                if dump(reg, n, d / f"{NAMES[reg]}.hex"):
                    return 1
        return 0
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    region, count, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    with jtag_session(f"dump_ram region {region}"):
        return dump(region, count, out)


if __name__ == "__main__":
    sys.exit(main())
