#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build and run a Verilator bench: sim/<bench>/files.f lists its sources.

    python scripts/run_verilator.py capload_tb +CAP=tetrisp-title +GAME=tetrisp
    python scripts/run_verilator.py capload_tb --rebuild +OLD=1

Verilator, g++ and make come from msys64 (E:/msys64/mingw64, E:/msys64/usr).
The model is built under simout/verilator/<bench> and run from the repository
root, so the bench's relative paths (roms/, debug/, simout/) resolve as they
do under scripts/run_sim.sh. The top module is the file.f's last entry's
module, named tb_<bench without _tb>. Plusargs pass through unchanged.
A rebuild happens when any listed source is newer than the executable.
"""
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MSYS = Path(os.environ.get("MSYS64", r"E:\msys64"))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    bench = sys.argv[1]
    rest = sys.argv[2:]
    rebuild = "--rebuild" in rest
    plusargs = [a for a in rest if a != "--rebuild"]
    srcs = [ln.strip() for ln in (REPO / "sim" / bench / "files.f").read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")]
    top = "tb_" + bench.removesuffix("_tb")
    obj = REPO / "simout" / "verilator" / bench     # not build/: that is the Quartus worktree
    exe = obj / f"V{top}.exe"

    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(MSYS / "mingw64" / "bin"), str(MSYS / "usr" / "bin"), env["PATH"]])
    env["VERILATOR_ROOT"] = str(MSYS / "mingw64" / "share" / "verilator")

    # "+incdir+dir" lines are options, not sources
    newest = max((REPO / s).stat().st_mtime for s in srcs if not s.startswith("+"))
    if rebuild or not exe.exists() or exe.stat().st_mtime < newest:
        obj.mkdir(parents=True, exist_ok=True)
        cmd = [str(MSYS / "mingw64" / "bin" / "verilator_bin.exe"),"--binary", "--timing", "-j", "4",   # -j caps the g++ fan-out (run_v60_verilator.sh)
               "-Wno-fatal", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND", "-Wno-UNUSEDSIGNAL", "-Wno-PINCONNECTEMPTY",
               "--top-module", top, "--Mdir", str(obj), "-o", f"V{top}.exe"] + srcs
        print("verilator:", bench, flush=True)
        r = subprocess.run(cmd, cwd=REPO, env=env)
        if r.returncode:
            return r.returncode
    (REPO / "simout").mkdir(exist_ok=True)
    for a in plusargs:
        if a.startswith("+OUT="):
            (REPO / a[5:]).mkdir(parents=True, exist_ok=True)
    return subprocess.run([str(exe)] + plusargs, cwd=REPO, env=env).returncode


if __name__ == "__main__":
    sys.exit(main())
