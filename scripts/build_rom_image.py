#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble a set's ROM regions from its zip, the way MAME's ROM_START does.

    python scripts/build_rom_image.py tetrisp            # all regions below
    python scripts/build_rom_image.py tetrisp maincpu    # one region

Writes roms/<set>/<region>.bin (gitignored) plus <region>.hex for
$readmemh -- one byte per line, so a bench's byte array reads it directly
and no byte-order assumption is baked into the fixture.

The layouts are transcribed from ms32.cpp's ROM_START blocks per game, not
derived: LESSONS_LEARNED, "Prove the interleave against MAME's disassembly
offline". For Phase 0 only maincpu is needed and only tetrisp is entered.
Every ROM_LOAD32_BYTE places one file at byte offset o, o+4, o+8, ... (the
MAME macro is ROM_SKIP(3)); ROM_LOAD32_WORD places 16-bit words at o, o+4,
... (ROM_SKIP(2)); plain ROM_LOAD is contiguous.

The zip is found on the same rompath mame_boot_trace.py uses, so a trace
and the image it is diffed against come from the same file.
"""
import os
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mame_boot_trace import rompath  # noqa: E402

# (region, size, [(file, offset, kind)]) ; kind: B = LOAD32_BYTE, W = LOAD32_WORD, L = LOAD
SETS = {
    "tetrisp": [
        ("maincpu", 0x200000, [
            ("mb93166_ver1.0-26.26", 0x000003, "B"),
            ("mb93166_ver1.0-27.27", 0x000002, "B"),
            ("mb93166_ver1.0-28.28", 0x000001, "B"),
            ("mb93166_ver1.0-29.29", 0x000000, "B"),
        ]),
        ("sprite", 0x400000, [
            ("mr95024-01.01", 0x000002, "W"),
            ("mr95024-02.13", 0x000000, "W"),
        ]),
        ("roztiles", 0x200000, [("mr95024-04.11", 0, "L")]),
        ("bgtiles",  0x200000, [("mr95024-03.10", 0, "L")]),
        ("txtiles",  0x080000, [("mb93166_ver1.0-30.30", 0, "L")]),
        ("audiocpu", 0x040000, [("mb93166_ver1.0-21.21", 0, "L")]),
        ("ymf",      0x400000, [("mr92042-01.22", 0, "L"), ("mr95024-05.23", 0x200000, "L")]),
    ],
}


def find_zip(name, repo):
    for d in rompath(repo).split(";"):
        p = Path(d) / f"{name}.zip"
        if p.exists():
            return p
    sys.exit(f"{name}.zip not on rompath")


def build(region, size, parts, zf):
    img = bytearray(size)
    for fn, off, kind in parts:
        data = zf.read(fn)
        if kind == "L":
            img[off:off + len(data)] = data
        elif kind == "B":
            img[off:off + 4 * len(data):4] = data
        elif kind == "W":
            for i in range(0, len(data), 2):
                img[off + 2 * i:off + 2 * i + 2] = data[i:i + 2]
        else:
            raise ValueError(kind)
    return img


def main():
    game = sys.argv[1]
    only = sys.argv[2] if len(sys.argv) > 2 else None
    repo = Path(__file__).resolve().parent.parent
    out = repo / "roms" / game
    out.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(find_zip(game, repo)) as zf:
        for region, size, parts in SETS[game]:
            if only and region != only:
                continue
            img = build(region, size, parts, zf)
            (out / f"{region}.bin").write_bytes(img)
            with open(out / f"{region}.hex", "w") as f:
                f.write("\n".join(f"{b:02x}" for b in img))
                f.write("\n")
            print(f"{region:9s} {size:#9x}  -> {out / region}.bin/.hex")


if __name__ == "__main__":
    main()
