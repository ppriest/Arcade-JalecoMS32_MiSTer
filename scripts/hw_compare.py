#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare a board screenshot of a capture against the model rendered the same way.

    python scripts/hw_compare.py tetrisp-title debug/hw/tetrisp-title-stubrom.png --stub-rom

--stub-rom renders the model with MS32.sv's ROM stub in place of the tile
and sprite ROMs (pen = addr[7:0] ^ addr[15:8] ^ addr[23:16]), which is what
the board shows until the SDRAM backend exists. The screenshot is the
framework's scaled output, so it is sampled back at each source pixel's
centre; a pixel counts as matching when every channel is within --tol.
Writes hw_model.png, hw_sampled.png and hw_diff.png beside the capture.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import render_model as rm  # noqa: E402

W, H = 320, 224


def stub(n):
    # MS32.sv's ROM_STUB replicates one byte across the 8-byte granule, from
    # the granule address (low three bits zero)
    i = np.arange(n, dtype=np.int64) & ~7
    return ((i & 0xFF) ^ ((i >> 8) & 0xFF) ^ ((i >> 16) & 0xFF)).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("screenshot")
    ap.add_argument("--stub-rom", action="store_true")
    ap.add_argument("--tol", type=int, default=8)
    ap.add_argument("--layer-colours", action="store_true", help="the palette build_capture_blob.py --layer-colours used")
    a = ap.parse_args()
    game = a.capture.split("-")[0]
    c = rm.Capture(a.capture, game)
    if a.stub_rom:
        c.txtiles = stub(1 << 24)
        c.bgtiles = stub(1 << 24)
        c.roztiles = stub(1 << 24)
        c.sprite = stub(1 << 24)
    if a.layer_colours:
        sys.path.insert(0, str(REPO / "scripts"))
        from build_capture_blob import layer_palette
        c.palram = layer_palette().astype(np.uint16)
    model = rm.mix(c)
    shot = np.array(Image.open(a.screenshot).convert("RGB"))
    sh, sw = shot.shape[:2]
    xs = ((np.arange(W) + 0.5) * sw / W).astype(int)
    ys = ((np.arange(H) + 0.5) * sh / H).astype(int)
    sampled = shot[ys][:, xs]
    d = np.abs(sampled.astype(int) - model.astype(int)).max(axis=2)
    ok = d <= a.tol
    exact = (d == 0)
    Image.fromarray(model).save(c.d / "hw_model.png")
    Image.fromarray(sampled).save(c.d / "hw_sampled.png")
    diff = np.where(ok[:, :, None], (model // 4).astype(np.uint8), np.array([255, 0, 0], np.uint8))
    Image.fromarray(diff).save(c.d / "hw_diff.png")
    print(f"{a.capture} vs {Path(a.screenshot).name} ({sw}x{sh}): {int(ok.sum())} of {W*H} pixels within {a.tol} "
          f"({100.0*ok.sum()/(W*H):.2f}%), {int(exact.sum())} exact -> {c.d / 'hw_diff.png'}")
    if not ok.all():
        yy, xx = np.nonzero(~ok)
        print(f"  mismatch rows {yy.min()}..{yy.max()}, cols {xx.min()}..{xx.max()}; per-row worst count "
              f"{np.bincount(yy, minlength=H).max()} at row {np.bincount(yy, minlength=H).argmax()}")


if __name__ == "__main__":
    main()
