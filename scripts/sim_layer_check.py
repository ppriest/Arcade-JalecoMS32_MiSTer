#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Render a capture's layers (TX, BG, ROZ, sprites) in RTL and diff them against the model.

    python scripts/sim_layer_check.py tetrisp-title            # tx, bg and roz
    python scripts/sim_layer_check.py gametngk-f3000 --lat 30  # slower ROM

One command per capture: makes sure the model's u16 dumps exist (running
render_model.py for each layer if not), runs sim/layers_tb through
scripts/run_sim.sh with the capture and game as plusargs, then
compare_sim_layer.py per layer. Exit status is the number of layers that
differ. Run from the repository root; run_sim.sh insists on it too.
"""
import argparse
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
# Windows paths, tried in this order, never a bare "bash": a Windows Python
# resolves that through System32 first, i.e. to WSL's bash, which is a
# different operating system (LESSONS_LEARNED, "bash on a Windows dev box
# may be WSL's"). The first symptom was run_sim.sh reporting ModelSim absent.
# which bench renders which layer
BENCHES = {"layers_tb": ["tx", "bg", "roz"], "sprite_tb": ["sprites"], "video_tb": ["rgb"]}
BASHES = [r"C:\Program Files\Git\usr\bin\bash.exe", r"E:\msys64\usr\bin\bash.exe"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--game", default=None)
    ap.add_argument("--lat", type=int, default=12, help="ROM model latency in clocks")
    ap.add_argument("--ddr-busy", type=int, default=6, help="video_tb: DDRAM busy clocks per transaction")
    ap.add_argument("--ddr-lat", type=int, default=20, help="video_tb: DDRAM read latency in clocks")
    ap.add_argument("--sdram", action="store_true", help="video_tb: the real SDRAM stack against the chip model instead of the latency ROM models")
    ap.add_argument("--layers", default="tx,bg,roz,sprites,rgb",
                    help="rgb is the whole path (sim/video_tb) against reference.png")
    a = ap.parse_args()
    game = a.game or a.capture.split("-")[0]
    layers = a.layers.split(",")
    d = REPO / "debug" / a.capture
    out = REPO / "simout" / a.capture
    out.mkdir(parents=True, exist_ok=True)

    for layer in layers:
        if layer != "rgb" and not (d / f"model_{layer}.u16").exists():
            subprocess.run([sys.executable, "scripts/render_model.py", a.capture, "--game", game,
                            "--layer", layer], cwd=REPO, check=True)

    bash = next((b for b in BASHES if Path(b).exists()), None)
    if bash is None:
        sys.exit("no Git Bash or MSYS2 bash found; edit BASHES")
    for bench, bench_layers in BENCHES.items():
        if not set(bench_layers) & set(layers):
            continue
        cmd = [bash, "scripts/run_sim.sh", bench, f"+CAP={a.capture}", f"+GAME={game}",
               f"+LAT={a.lat}", f"+DDR_BUSY={a.ddr_busy}", f"+DDR_LAT={a.ddr_lat}", f"+SDRAM={1 if a.sdram else 0}", f"+OUT=simout/{a.capture}"]
        r = subprocess.run(cmd, cwd=REPO, text=True, capture_output=True)
        log = out / f"{bench}.log"
        log.write_text(r.stdout + r.stderr, encoding="utf-8")
        for line in r.stdout.splitlines():
            if any(t in line for t in ("FATAL", "Error", "frame written", "ROMs:", "scroll", "overrun", "roz lines", "sprites:", "brightness")):
                print("  " + line.strip())
        if r.returncode:
            print(f"{bench} failed, see {log}")
            return 99

    bad = 0
    for layer in layers:
        if layer == "rgb":
            cmd = [sys.executable, "scripts/compare_sim_rgb.py", a.capture, str(out / "sim_rgb.txt")]
        else:
            cmd = [sys.executable, "scripts/compare_sim_layer.py", a.capture, layer, str(out / f"sim_{layer}.txt")]
        bad += 1 if subprocess.run(cmd, cwd=REPO).returncode else 0
    return bad


if __name__ == "__main__":
    sys.exit(main())
