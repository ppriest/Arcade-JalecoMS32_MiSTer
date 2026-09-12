#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Take a screenshot of whatever the MiSTer is showing and pull it back.

    python scripts/mister_screenshot.py --out debug/hw/tetrisp-title.png

Writes "screenshot" to /dev/MiSTer_cmd on the device, which saves the core's
output at its NATIVE resolution (320x224 here; the MiSTer binary's own
strings: "saving screenshot at native res"), then watches
/media/fat/screenshots for the new file. --scaled asks for the framework's
scaled output instead ("screenshot scaled"), which is what MiSTer Remote's
API produces and is useless for pixel comparison. The trigger is re-sent
until a file appears, since the Psikyo core found about one in two
dropped. Connection settings come from mister.env (see deploy.py).
"""
import argparse
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from deploy import load_env, Mister  # noqa: E402

REMOTE_SHOTS = "/media/fat/screenshots"


def listing(m):
    out = m.run(f"find {REMOTE_SHOTS} -type f -name '*.png' 2>/dev/null; true")
    return set(l.strip() for l in out.splitlines() if l.strip())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--attempts", type=int, default=4)
    ap.add_argument("--poll", type=int, default=15, help="seconds to wait per trigger")
    ap.add_argument("--scaled", action="store_true", help="the framework's scaled output, not the native frame")
    a = ap.parse_args()
    env = load_env(REPO / "mister.env")
    m = Mister(env, False)
    before = listing(m)
    newest = None
    for attempt in range(1, a.attempts + 1):
        m.run(f"echo 'screenshot{' scaled' if a.scaled else ''}' > /dev/MiSTer_cmd")
        deadline = time.time() + a.poll
        while time.time() < deadline:
            new = listing(m) - before
            if new:
                newest = sorted(new)[-1]
                break
            time.sleep(1)
        if newest:
            break
        print(f"no new screenshot after trigger {attempt}/{a.attempts}; retriggering")
    if not newest:
        sys.exit("no screenshot appeared")
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    import subprocess
    p = subprocess.run([m.pscp, "-batch", "-pw", m.pw, f"{m.user}@{m.host}:{newest}", str(out)],
                       capture_output=True, text=True, timeout=120)
    if p.returncode:
        sys.exit(f"copy failed: {p.stderr.strip()}")
    print(f"{newest} -> {out}")


if __name__ == "__main__":
    main()
