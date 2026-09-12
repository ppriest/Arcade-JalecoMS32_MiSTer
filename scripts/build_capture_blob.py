#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pack a MAME capture into the blob MS32.sv's capture loader expects.

    python scripts/build_capture_blob.py tetrisp-title            -> debug/tetrisp-title/capture.bin

Loaded on the board through the OSD ("Load capture", menu index 1), the
blob fills every video RAM and register from the capture, and the hardware
renders the frame the simulation benches and the model rendered -- the
same test, on silicon, with no CPU involved. Until the SDRAM backend
exists the tile and sprite ROM ports are stubbed, so the picture has the
right geometry and placeholder pens.

Layout (little-endian u16 words, in MS32.sv's W_* order): txram 0x2000,
bgram 0x2000, rozram 0x8000, lineram 0x800, objram 0x8000 (the vblank copy
when the capture has one), palram 0x10000, priram 0x2000 (u8 in the low
byte), then 0x400 register words where word k is the 16-bit register at
byte offset 4k of the 0xFCE00000 block: sysctrl/CRTC at 0x000, sprite
control at 0x200, brightness 0x280/0x284, ROZ control 0x600, TX scroll
0xA00, BG scroll 0xA20, bgmode 0xA7C. The CRTC and brightness words come
from the write log when the capture has one, else the driver defaults.
"""
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent

# raw CRTC values that give MAME's defaults through 0x1000 - (d & 0xfff)
CRTC_DEFAULTS = {0x00: 0x0000, 0x02: 0x1000 - 64, 0x04: 0x1000 - 320, 0x06: 0x1000 - 16, 0x08: 0x1000 - 46,
                 0x0A: 0x1000 - 39, 0x0C: 0x1000 - 224, 0x0E: 0x1000 - 16, 0x10: 0x1000 - 24}


def layer_palette():
    """word0 = RRGG, word1 = ..BB per entry; bit 14 of the index clear so brightness applies"""
    pal = np.zeros(0x10000, dtype="<u2")
    def fill(lo, hi, r, g, b):
        pal[2 * lo:2 * hi:2] = (r << 8) | g
        pal[2 * lo + 1:2 * hi:2] = b
    fill(0x0000, 0x1000, 0xFF, 0xFF, 0xFF)   # sprites
    fill(0x1000, 0x2000, 0xFF, 0x00, 0x00)   # BG
    fill(0x2000, 0x3000, 0x00, 0xFF, 0x00)   # ROZ
    fill(0x6000, 0x7000, 0x00, 0x00, 0xFF)   # TX
    pal[0] = 0; pal[1] = 0                   # entry 0: black
    return pal


def lo16(path, count):
    d = np.fromfile(path, dtype="<u4")
    out = np.zeros(count, dtype="<u2")
    n = min(count, d.size)
    out[:n] = d[:n] & 0xFFFF
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    cap = args[0]
    game = args[1] if len(args) > 1 else cap.split("-")[0]
    d = REPO / "debug" / cap
    # --layer-colours: every palette entry of a layer's range becomes one flat colour
    # (sprites white, BG red, ROZ green, TX blue, entry 0 black), so a board
    # screenshot shows which layer put each pixel there. Output capture_layers.bin.
    layer_colours = "--layer-colours" in sys.argv
    parts = [
        lo16(d / f"{game}_txram.bin", 0x2000),
        lo16(d / f"{game}_bgram.bin", 0x2000),
        lo16(d / f"{game}_rozram.bin", 0x8000),
        lo16(d / f"{game}_lineram.bin", 0x800),
        lo16(d / (f"{game}_sprram_vbl.bin" if (d / f"{game}_sprram_vbl.bin").exists() else f"{game}_sprram.bin"), 0x8000),
        layer_palette() if layer_colours else lo16(d / f"{game}_palram.bin", 0x10000),
        lo16(d / f"{game}_priram.bin", 0x2000) & 0xFF,
    ]
    regs = np.zeros(0x400, dtype="<u2")
    # sysctrl slot k (amap byte offset 2k) is the CPU's dword 4k, i.e. word k
    regs[:9] = [CRTC_DEFAULTS[2 * k] for k in range(9)]
    regs[0x200 // 4: 0x200 // 4 + 32] = lo16(d / f"{game}_sprctrl.bin", 32)
    regs[0x600 // 4: 0x600 // 4 + 24] = lo16(d / f"{game}_rozctrl.bin", 24)
    regs[0xA00 // 4: 0xA00 // 4 + 6] = lo16(d / f"{game}_txscroll.bin", 6)
    regs[0xA20 // 4: 0xA20 // 4 + 6] = lo16(d / f"{game}_bgscroll.bin", 6)
    regs[0xA7C // 4] = lo16(d / f"{game}_bgmode.bin", 1)[0]
    wl = d / f"{game}_writes.log"
    n_log = 0
    if wl.exists():
        for line in wl.read_text().splitlines():
            if line.startswith("#"):
                continue
            fr, ln, addr, mask, data, pc = line.split("\t")
            a = int(addr, 16)
            if 0xFCE00000 <= a < 0xFCE01000 and (a & 3) == 0:
                off = a - 0xFCE00000
                if off < 0x24 or off in (0x280, 0x284):
                    regs[off // 4] = int(data, 16) & 0xFFFF
                    n_log += 1
    parts.append(regs)
    blob = np.concatenate(parts)
    out = d / ("capture_layers.bin" if layer_colours else "capture.bin")
    blob.tofile(out)
    print(f"{out}: {blob.size} words ({blob.size * 2:,} bytes); {n_log} CRTC/brightness values from the write log"
          + ("" if wl.exists() else " (no write log: CRTC defaults)"))


if __name__ == "__main__":
    main()
