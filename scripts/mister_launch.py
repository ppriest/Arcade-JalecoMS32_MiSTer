#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Launch an .mra on the MiSTer through MiSTer Remote's API.

    python scripts/mister_launch.py "/media/fat/_Arcade/_Jaleco MegaSystem 32/_dev/Capture tetrisp-title.mra"

Bounces through menu.rbf first: launching an .mra while a core is already
running does not reprogram the FPGA or resend the ROMs (the Psikyo core's
LESSONS_LEARNED, "MiSTer caches the loaded ROM"), and a screenshot of a
stale core looks exactly like evidence. --no-bounce skips that when the
point is to poke a live core. Connection settings come from mister.env.
"""
import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from deploy import load_env  # noqa: E402


def post(host, path, body):
    req = urllib.request.Request(f"http://{host}:8182/api{path}", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mra", help="remote absolute path of the .mra")
    ap.add_argument("--no-bounce", action="store_true")
    ap.add_argument("--settle", type=float, default=6.0, help="seconds to wait after the launch")
    a = ap.parse_args()
    host = load_env(REPO / "mister.env")["MISTER_HOST"]
    if not a.no_bounce:
        post(host, "/launch", {"path": "/media/fat/menu.rbf"})
        time.sleep(3)
    post(host, "/launch", {"path": a.mra})
    time.sleep(a.settle)
    print(f"launched {a.mra}")


if __name__ == "__main__":
    main()
