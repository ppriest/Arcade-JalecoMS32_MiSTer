#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare the video bench's RGB frame against the capture's reference.png.

    python scripts/compare_sim_rgb.py tetrisp-title simout/tetrisp-title/sim_rgb.txt

The bench writes one hex RRGGBB per line, row-major, 320x224. The
reference is MAME's own screenshot, turned back to the driver's frame the
way render_model.py does for ROT270 sets. Writes sim_rgb.png and
diff_rgb.png beside the model images. Exit status: differing pixels,
capped at 255.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from render_model import Capture  # noqa: E402

W, H = 320, 224


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    cap, simfile = sys.argv[1:3]
    c = Capture(cap, cap.split("-")[0])
    if len(sys.argv) == 4:   # compare against another image (a board screenshot) instead of reference.png
        c.ref = np.array(Image.open(sys.argv[3]).convert("RGB"))
    vals = [int(t, 16) for t in Path(simfile).read_text().split()]
    if len(vals) != W * H:
        sys.exit(f"{simfile}: {len(vals)} values, expected {W*H}")
    sim = np.array(vals, dtype=np.uint32).reshape(H, W)
    rgb = np.stack([(sim >> 16) & 0xFF, (sim >> 8) & 0xFF, sim & 0xFF], axis=2).astype(np.uint8)
    Image.fromarray(rgb).save(c.d / "sim_rgb.png")
    diff = np.any(rgb != c.ref, axis=2)
    n = int(diff.sum())
    img = np.where(diff[:, :, None], np.array([255, 0, 0], np.uint8), (c.ref // 4).astype(np.uint8))
    Image.fromarray(img).save(c.d / "diff_rgb.png")
    print(f"{cap} rgb: {W*H - n} of {W*H} pixels match the reference ({100.0*(W*H-n)/(W*H):.2f}%) -> {c.d / 'sim_rgb.png'}")
    if n:
        ys, xs = np.nonzero(diff)
        print("  first mismatches (x,y ref->sim): " + " ".join(
            f"({x},{y} {c.ref[y,x,0]:02x}{c.ref[y,x,1]:02x}{c.ref[y,x,2]:02x}->{sim[y,x]:06x})" for x, y in list(zip(xs, ys))[:6]))
        print(f"  mismatch rows span {ys.min()}..{ys.max()}, cols {xs.min()}..{xs.max()} -> {c.d / 'diff_rgb.png'}")
    return min(n, 255)


if __name__ == "__main__":
    sys.exit(main())
