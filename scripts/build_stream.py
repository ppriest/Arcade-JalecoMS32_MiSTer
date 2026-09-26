#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the ROM image a .mra streams, as one file.

    python scripts/build_stream.py tetrisp     -> simout/tetrisp_stream.bin
    python scripts/build_stream.py f1superb

The image is what the HPS writes into DDR3 for a fast load: each region of
build_mra.py's map in order, its ROM data padded to the declared region size
and repeated to fill the space ms32_sdram_top.sv reserves, with a partial
repeat expressed as zeros exactly as the .mra expresses it. sim/romload_tb
replays this file through ms32_rom_loader and compares SDRAM against the
per-region .bin files, so the two have to be built from the same source:
run scripts/build_rom_image.py <set> first.

Rebuild it whenever the map changes. A stale image reads as a loader fault:
the copy runs past the end of the file and the regions after the truncation
all differ.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from build_mra import map_for  # noqa: E402
from build_rom_image import SETS  # noqa: E402


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in SETS:
        sys.exit(f"usage: build_stream.py <set>   ({', '.join(sorted(SETS))})")
    game = sys.argv[1]
    src = REPO / "roms" / game
    out = REPO / "simout" / f"{game}_stream.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    sizes = {r: s for r, s, _ in SETS[game]}

    pos = 0
    with out.open("wb") as f:
        for region, base, rsize in map_for(game):
            assert pos == base, (region, hex(pos), hex(base))
            p = src / f"{region}.bin"
            if not p.exists():
                sys.exit(f"{p} not found -- run scripts/build_rom_image.py {game}")
            data = p.read_bytes()
            size = sizes[region]
            if len(data) < size:            # the .mra pads a short region with zeros
                data += bytes(size - len(data))
            reps, rem = divmod(rsize, size)
            for _ in range(reps):
                f.write(data)
            if rem:
                f.write(bytes(rem))
            print(f"  {region:9s} {size:#09x} x{reps} at {base:#09x}" + (f" + {rem:#x} zeros" if rem else ""))
            pos = base + rsize
    print(f"{out}: {pos:#x} bytes ({pos / 2**20:.2f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
