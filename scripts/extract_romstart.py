#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read every set's ROM_START and GAME() line straight from ms32.cpp.

    python scripts/extract_romstart.py            # summary of every set
    python scripts/extract_romstart.py --selftest # agree with build_rom_image's hand tables

Point MAME_SRC at the driver (default E:/mame/src/mame/jaleco/ms32.cpp).

After Arcade-Seta_MiSTer/scripts/extract_romstart.py, for the same reason:
the driver is the authority, and hand transcription across twenty sets is
the interleave mistake LESSONS_LEARNED warns about in slower motion. ms32.cpp
uses three load forms, and only these are accepted; anything else in a
ROM_REGION this project loads is an error, not a silent omission.

    ROM_LOAD32_BYTE(file, offset, length)   one byte lane every four bytes
    ROM_LOAD32_WORD(file, offset, length)   one word every four bytes
    ROM_LOAD(file, offset, length)          contiguous
"""
import os
import re
import sys

SRC = os.getenv("MAME_SRC", "E:/mame/src/mame/jaleco/ms32.cpp")

REGIONS = ("maincpu", "sprite", "roztiles", "bgtiles", "txtiles", "audiocpu", "ymf")
KIND = {"ROM_LOAD32_BYTE": "B", "ROM_LOAD32_WORD": "W", "ROM_LOAD": "L"}


def _num(s):
    s = s.strip()
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def load():
    if not os.path.exists(SRC):
        sys.exit(f"driver not found at {SRC} (set MAME_SRC)")
    return open(SRC, encoding="utf8", errors="replace").read()


def roms(text):
    """{set: [(region, size, [(file, offset, kind, length)])]} in driver order."""
    out = {}
    for m in re.finditer(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", text, re.S):
        regions, cur = [], None
        for raw in m.group(2).split("\n"):
            line = raw.split("//")[0].strip()
            if not line:
                continue
            r = re.match(r'ROM_REGION(?:32_LE)?\(\s*(\w+)\s*,\s*"(\w+)"', line)
            if r:
                cur = (r.group(2), _num(r.group(1)), [])
                regions.append(cur)
                continue
            r = re.match(r'(ROM_LOAD32_BYTE|ROM_LOAD32_WORD|ROM_LOAD)\(\s*"([^"]+)"\s*,\s*(\w+)\s*,\s*(\w+)', line)
            if r:
                if cur is None:
                    sys.exit(f"{m.group(1)}: a load before any ROM_REGION: {line}")
                cur[2].append((r.group(2), _num(r.group(3)), KIND[r.group(1)], _num(r.group(4))))
                continue
            if cur is not None and cur[0] in REGIONS and line.startswith("ROM_"):
                sys.exit(f"{m.group(1)}/{cur[0]}: unhandled {line}")
        out[m.group(1)] = regions
    return out


def crcs(text):
    """{set: {file: crc32}} from the CRC(...) on every ROM_LOAD in a region this project loads.
    The .mra carries them so MiSTer can find a file by CRC: a merged parent zip keeps a clone's
    files in a subdirectory, or under the parent's name when the data is the same."""
    out = {}
    for m in re.finditer(r"ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END", text, re.S):
        d, cur = {}, None
        for raw in m.group(2).split("\n"):
            line = raw.split("//")[0].strip()
            r = re.match(r'ROM_REGION(?:32_LE)?\(\s*\w+\s*,\s*"(\w+)"', line)
            if r:
                cur = r.group(1)
                continue
            r = re.match(r'ROM_LOAD\w*\(\s*"([^"]+)".*CRC\(([0-9a-fA-F]{8})\)', line)
            if r and cur in REGIONS:
                d[r.group(1)] = int(r.group(2), 16)
        out[m.group(1)] = d
    return out


def games(text):
    """{set: dict(parent, machine, init, rot, maker, name, year)} from GAME() lines."""
    out = {}
    for m in re.finditer(r'^GAME\(\s*(\d+),\s*(\w+),\s*(\w+),\s*(\w+),\s*(\w+),\s*\w+,\s*(\w+),\s*(ROT\d+),\s*"([^"]*)",\s*"([^"]*)"',
                         text, re.M):
        year, s, parent, machine, inputs, init, rot, maker, name = m.groups()
        out[s] = dict(year=year, parent=parent, machine=machine, inputs=inputs, init=init,
                      rot=rot, maker=maker, name=name)
    return out


def sets_table(text=None):
    """build_rom_image.SETS's shape for every set: {set: [(region, size, [(file, offset, kind)])]}."""
    text = text or load()
    out = {}
    for s, regs in roms(text).items():
        out[s] = [(name, size, [(f, o, k) for f, o, k, _ in parts]) for name, size, parts in regs if name in REGIONS]
    return out


def main():
    text = load()
    g = games(text)
    if "--selftest" in sys.argv:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import build_rom_image
        got = sets_table(text)
        bad = 0
        for s, hand in build_rom_image.HAND_SETS.items():
            a = {r: (sz, sorted(p)) for r, sz, p in hand}
            b = {r: (sz, sorted(p)) for r, sz, p in got[s]}
            if a != b:
                bad += 1
                print(f"FAIL {s}: hand table and driver differ")
                for r in sorted(set(a) | set(b)):
                    if a.get(r) != b.get(r):
                        print(f"   {r}: hand {a.get(r)}\n   {' ' * len(r)}  drv  {b.get(r)}")
        print("PASS" if not bad else f"FAIL: {bad} set(s)", f"-- {len(build_rom_image.HAND_SETS)} hand-typed sets checked")
        return 1 if bad else 0
    for s, regs in roms(text).items():
        info = g.get(s, {})
        sizes = " ".join(f"{n}={sz:#x}" for n, sz, _ in regs if n in REGIONS)
        print(f"{s:10s} {info.get('parent', '?'):9s} {info.get('rot', '?'):6s} {info.get('init', '?'):16s} {sizes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
