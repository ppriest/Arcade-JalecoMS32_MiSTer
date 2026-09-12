#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a bench's rendered layer against the software model's.

    python scripts/compare_sim_layer.py tetrisp-title tx simout/tetrisp-title/sim_tx.txt

The bench writes one hex u16 per line, row-major, 320x224, 0xFFFF where the
layer is transparent; the model wrote debug/<capture>/model_<layer>.u16 in
the same convention (render_model.py --layer <layer>). Exit status is the
number of differing pixels, capped at 255, so a runner can chain on it.
A diff image goes beside the model's: red where the bench is opaque and the
model is not, blue the reverse, yellow where both are opaque and disagree.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
W, H = 320, 224


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    cap, layer, simfile = sys.argv[1:]
    d = REPO / "debug" / cap
    model = np.fromfile(d / f"model_{layer}.u16", dtype="<u2").reshape(H, W)
    sim = np.array([int(t, 16) for t in Path(simfile).read_text().split()], dtype=np.uint16)
    if sim.size != W * H:
        sys.exit(f"{simfile}: {sim.size} values, expected {W*H}")
    sim = sim.reshape(H, W)
    mop, sop = model != 0xFFFF, sim != 0xFFFF
    diff = sim != model
    n = int(diff.sum())
    img = np.zeros((H, W, 3), np.uint8)
    img[diff & sop & ~mop] = (255, 0, 0)
    img[diff & mop & ~sop] = (0, 0, 255)
    img[diff & mop & sop] = (255, 255, 0)
    img[~diff & mop] = (40, 40, 40)
    Image.fromarray(img).save(d / f"diff_{layer}.png")
    print(f"{cap} {layer}: {W*H - n} of {W*H} pixels match the model "
          f"({100.0*(W*H-n)/(W*H):.2f}%); model opaque {int(mop.sum())}, sim opaque {int(sop.sum())}")
    if n:
        ys, xs = np.nonzero(diff)
        print("  first mismatches (x,y model->sim): " + " ".join(
            f"({x},{y} {model[y,x]:04x}->{sim[y,x]:04x})" for x, y in list(zip(xs, ys))[:6]))
        print(f"  mismatch rows span {ys.min()}..{ys.max()}, cols {xs.min()}..{xs.max()} -> {d / f'diff_{layer}.png'}")
    return min(n, 255)


if __name__ == "__main__":
    sys.exit(main())
