#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read the ISSP debug probes over JTAG, under the machine-wide JTAG lock.

    python scripts/read_issp.py          # read
    python scripts/read_issp.py clear    # clear the counters, then read

Refuses to start while Quartus or ModelSim is running, and holds the marker
that makes builds and simulations refuse to start meanwhile (scripts/hwlock.py:
a JTAG session concurrent with either has bugchecked this PC). Needs the
MS32_stp revision (DEBUG_ISSP) on the board and the USB-Blaster connected.
"""
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from hwlock import jtag_session  # noqa: E402

QUARTUS_STP = Path(r"C:\intelFPGA_lite\17.0\quartus\bin64\quartus_stp.exe")


def main():
    if not QUARTUS_STP.exists():
        sys.exit(f"{QUARTUS_STP} not found")
    args = ["clear"] if len(sys.argv) > 1 and sys.argv[1] == "clear" else []
    with jtag_session("read_issp"):
        r = subprocess.run([str(QUARTUS_STP), "-t", str(REPO / "scripts" / "read_issp.tcl")] + args,
                           cwd=REPO, capture_output=True, text=True, timeout=180)
    for line in r.stdout.splitlines():
        if line.startswith(("Info", "Warning")) or not line.strip():
            continue
        print(line)
    if r.returncode:
        print(r.stderr.strip()[-800:])
    return r.returncode


if __name__ == "__main__":
    sys.exit(main())
