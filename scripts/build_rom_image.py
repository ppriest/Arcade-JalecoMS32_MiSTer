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
    "p47aces": [
        ("maincpu", 0x200000, [
            ("p-47_aces_3-31_rom_26_ver1.1.26", 0x000003, "B"),
            ("p-47_aces_3-31_rom_27_ver1.1.27", 0x000002, "B"),
            ("p-47_aces_3-31_rom_28_ver1.1.28", 0x000001, "B"),
            ("p-47_aces_3-31_rom_29_ver1.1.29", 0x000000, "B"),
        ]),
        ("sprite", 0xe00000, [
            ("mr94020-02.1",  0x000002, "W"), ("mr94020-01.13", 0x000000, "W"),
            ("mr94020-04.2",  0x400002, "W"), ("mr94020-03.14", 0x400000, "W"),
            ("mr94020-06.3",  0x800002, "W"), ("mr94020-05.15", 0x800000, "W"),
            ("mr94020-08.4",  0xc00002, "W"), ("mr94020-07.16", 0xc00000, "W"),
        ]),
        ("roztiles", 0x400000, [("mr94020-11.11", 0, "L"), ("mr94020-12.12", 0x200000, "L")]),
        ("bgtiles",  0x400000, [("mr94020-10.10", 0, "L"), ("mr94020-09.9", 0x200000, "L")]),
        ("txtiles",  0x080000, [("p-47_ver1.0-30.30", 0, "L")]),
        ("audiocpu", 0x040000, [("p-47_ver1.0-21.21", 0, "L")]),
        ("ymf",      0x400000, [("mr92042-01.22", 0, "L"), ("mr94020-13.23", 0x200000, "L")]),
    ],
    "gametngk": [
        ("maincpu", 0x200000, [
            ("mb94166_ver1.0-26.26", 0x000003, "B"),
            ("mb94166_ver1.0-27.27", 0x000002, "B"),
            ("mb94166_ver1.0-28.28", 0x000001, "B"),
            ("mb94166_ver1.0-29.29", 0x000000, "B"),
        ]),
        ("sprite", 0x1000000, [
            ("mr94041-01.13", 0x0000000, "W"), ("mr94041-02.1",  0x0000002, "W"),
            ("mr94041-03.14", 0x0400000, "W"), ("mr94041-04.2",  0x0400002, "W"),
            ("mr94041-05.15", 0x0800000, "W"), ("mr94041-06.3",  0x0800002, "W"),
            ("mr94041-07.16", 0x0c00000, "W"), ("mr94041-08.4",  0x0c00002, "W"),
        ]),
        ("roztiles", 0x400000, [("mr94041-11.11", 0, "L"), ("mr94041-12.12", 0x200000, "L")]),
        ("bgtiles",  0x400000, [("mr94041-09.10", 0, "L"), ("mr94041-10.9", 0x200000, "L")]),
        ("txtiles",  0x080000, [("mb94166_ver1.0-30.30", 0, "L")]),
        ("audiocpu", 0x040000, [("mb94166_ver1.0-21.21", 0, "L")]),
        ("ymf",      0x400000, [("mr94041-13.22", 0, "L"), ("mr94041-14.23", 0x200000, "L")]),
    ],
}


# jalcrpt.cpp, transcribed: dest[i] = src[L(i ^ addr_xor)] ^ (i & 0xff) ^ data_xor,
# L a cascade of conditional XORs (GF(2)-linear; verified invertible in
# docs/ROADMAP.md "ROM encryption"). Per-set keys from ms32.cpp's init_ss9xxxx.
TX_TAPS = [(18,0x40000),(17,0x60000),(7,0x70000),(3,0x78000),(14,0x7c000),(13,0x7e000),
           (0,0x7f000),(11,0x7f800),(10,0x7fc00),(9,0x00200),(8,0x00300),(16,0x00380),
           (6,0x003c0),(12,0x003e0),(4,0x003f0),(15,0x003f8),(2,0x003fc),(1,0x003fe),(5,0x003ff)]
BG_TAPS = [(19,0x80000),(8,0xc0000),(17,0xe0000),(2,0xf0000),(15,0xf8000),(14,0xfc000),
           (13,0xfe000),(12,0xff000),(1,0xff800),(10,0xffc00),(9,0x00200),(3,0x00300),
           (7,0x00380),(6,0x003c0),(5,0x003e0),(4,0x003f0),(18,0x003f8),(16,0x003fc),
           (11,0x003fe),(0,0x003ff)]
# set -> (tx addr_xor, tx data_xor, bg addr_xor, bg data_xor); init_* in ms32.cpp
KEYS = {
    "ss91022_10": (0x00000, 0x35, 0x00000, 0xa3),
    "ss92046_01": (0x00020, 0x7e, 0x00001, 0x9b),
    "ss92047_01": (0x24000, 0x18, 0x24000, 0x55),
    "ss92048_01": (0x20400, 0xd6, 0x20400, 0xd4),
}
SET_KEY = {"tetrisp": "ss92046_01", "bbbxing": "ss92046_01", "hayaosi2": "ss92046_01",
           "hayaosi3": "ss92046_01", "bnstars": "ss92046_01", "wpksocv2": "ss92046_01",
           "desertwr": "ss91022_10", "gametngk": "ss91022_10", "tp2m32": "ss91022_10",
           "gratiaa": "ss91022_10", "kirarasta": "ss91022_10",
           "gratia": "ss92047_01", "kirarast": "ss92047_01", "akiss": "ss92047_01",
           "p47aces": "ss92048_01", "suchie2": "ss92048_01", "akissa": "ss92048_01"}


def decrypt(src, taps, addr_xor, data_xor, top_mask):
    """MAME's decrypt_ms32_tx/bg. top_mask: bg keeps address bits above the
    scrambled 20 (j = i & ~0xfffff); tx scrambles all 19 of its bits."""
    n = len(src)
    out = bytearray(n)
    for i in range(n):
        ii = i ^ addr_xor
        j = i & top_mask
        for bit, c in taps:
            if (ii >> bit) & 1:
                j ^= c
        out[i] = src[j] ^ (i & 0xff) ^ data_xor
    return bytes(out)


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
            img[off:off + 2 * len(data):4] = data[0::2]
            img[off + 1:off + 2 * len(data):4] = data[1::2]
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
            if region in ("txtiles", "bgtiles") and game in SET_KEY:
                txa, txd, bga, bgd = KEYS[SET_KEY[game]]
                if region == "txtiles":
                    dec = decrypt(img, TX_TAPS, txa ^ 0x1005d, txd, 0)
                else:
                    dec = decrypt(img, BG_TAPS, bga ^ 0xc1c5b, bgd, ~0xfffff)
                (out / f"{region}_dec.bin").write_bytes(dec)
                print(f"{region:9s} decrypted ({SET_KEY[game]}) -> {out / region}_dec.bin")


if __name__ == "__main__":
    main()
