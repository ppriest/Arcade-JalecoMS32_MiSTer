#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the .mra files: every set in build_rom_image.SETS, laid out to ms32_sdram_top's map.

    python scripts/build_mra.py            -> releases/<Description>.mra
    python scripts/build_mra.py --with-capture tetrisp-title
        -> releases/_dev/<Description> + capture tetrisp-title.mra: the ROMs plus the
           capture blob as rom index 2, so the board renders that frame from the real ROMs

The map is ms32_sdram_top.sv's (this file repeats its bases and sizes and
checks them against that file). Each region is filled by REPEATING its ROM
data to the region size, so tile numbers past the ROM wrap the way MAME's
`% elements` does; the CPU regions are exact. Interleaves follow ms32.cpp: ROM_LOAD32_BYTE x4 for the
program (map 0001/0010/0100/1000), ROM_LOAD32_WORD x2 for sprites
(0021/2100). Rom index 1 is the mod byte: [1:0] the decryption key, bit 2
ms32_invert_lines, bit 3 ROT270, bit 4 the 25-bit sprite mask (a sprite ROM over 16 MB),
bit 5 mahjong inputs (the set's INPUT_PORTS include ms32_mahjong), bit 7 holds the V70 (capture playback). The DIP switches are
extracted from ms32.cpp's INPUT_PORTS by scripts/extract_dips.py (Seta's parser).
"""
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
from build_rom_image import SETS, SET_KEY, PARENT, INVERT_LINES, ROT270, GAMES, CRCS  # noqa: E402
import extract_dips  # noqa: E402
import extract_romstart  # noqa: E402

# (set, region) -> bytes the ROM_LOADs actually fill; ROM_REGION can declare more (akiss's roztiles
# is a 4 MB region holding one 2 MB ROM), and MAME's region is zero past the data
_ROMS = extract_romstart.roms(extract_romstart.load())
DATA_END = {(s, r): max(o + n * {"L": 1, "B": 4, "W": 2}[k] - (o & 3 if k != "L" else 0) for _, o, k, n in parts)
            for s, regs in _ROMS.items() for r, _, parts in regs if parts}

KEY_INDEX = {"ss91022_10": 0, "ss92046_01": 1, "ss92047_01": 2, "ss92048_01": 3}
RBF = "Arcade-JalecoMS32"
# The .mra name is MAME's description with " / " as " - " (a file name cannot hold a
# slash); gametngk's is shortened to the name its first .mra shipped under.
NAMES = {s: g["name"].replace(" / ", " - ") for s, g in GAMES.items()}
NAMES["gametngk"] = "The Game Paradise - Master of Shooting! (ver 1.0)"
# the INPUT_PORTS block each set uses, from its GAME() line
INPUTS = {s: g["inputs"] for s, g in GAMES.items()}
# region order in the SDRAM map, with the sizes ms32_sdram_top.sv reserves
MAP = [("maincpu", 0x000_0000, 0x200000), ("txtiles", 0x020_0000, 0x080000), ("bgtiles", 0x028_0000, 0x400000),
       ("roztiles", 0x068_0000, 0x400000), ("sprite", 0x0A8_0000, 0x1100000), ("audiocpu", 0x1B8_0000, 0x040000),
       ("ymf", 0x1BC_0000, 0x400000)]


def check_map():
    src = (REPO / "rtl/memory/ms32_sdram_top.sv").read_text(encoding="utf-8")
    for name, base, _ in MAP:
        m = re.search(rf"BASE_{name.upper()}\s*=\s*26'h([0-9A-Fa-f_]+)", src)
        assert m and int(m.group(1).replace("_", ""), 16) == base, (name, base)


def region_xml(region, size, parts, crc):
    """<part>/<interleave> elements for one region as the download stream expects it.
    Every part carries its CRC from ROM_START: MiSTer finds a file by it when the name is not
    at the zip's top level -- a merged parent zip keeps a clone's files under <clone>/, and
    drops the ones equal to the parent's (tp2m32 in tetrisp2.zip)."""
    kinds = {k for _, _, k in parts}
    def c(fn):
        return f' crc="{crc[fn]:08x}"' if fn in crc else ""
    if kinds == {"L"}:
        parts_sorted = sorted(parts, key=lambda p: p[1])
        rom_len = sum(1 for _ in parts_sorted)   # not the length; repeat count derived below
        one = "".join(f'      <part name="{fn}"{c(fn)}/>\n' for fn, off, _ in parts_sorted)
        return one
    if kinds == {"B"}:
        by_off = sorted(parts, key=lambda p: p[1])
        maps = {0: "0001", 1: "0010", 2: "0100", 3: "1000"}
        return '      <interleave output="32">\n' + "".join(
            f'        <part name="{fn}"{c(fn)} map="{maps[off & 3]}"/>\n' for fn, off, _ in by_off) + "      </interleave>\n"
    if kinds == {"W"}:
        # pairs at offsets (4k, 4k+2): each pair one interleave group
        groups = {}
        for fn, off, _ in parts:
            groups.setdefault(off & ~3, []).append((off & 3, fn))
        out = ""
        for base in sorted(groups):
            g = dict(groups[base])
            out += '      <interleave output="32">\n'
            out += f'        <part name="{g[0]}"{c(g[0])} map="0021"/>\n'
            out += f'        <part name="{g[2]}"{c(g[2])} map="2100"/>\n'
            out += "      </interleave>\n"
        return out
    raise ValueError(f"{region}: mixed part kinds {kinds}")


def esc(s):
    return escape(str(s), {'"': "&quot;"})


def uses_mahjong(game):
    """True when the set's INPUT_PORTS reach ms32_mahjong through PORT_INCLUDEs."""
    blocks = extract_dips.load()
    seen, todo = set(), [INPUTS[game]]
    while todo:
        name = todo.pop()
        if name == "ms32_mahjong":
            return True
        if name in seen or name not in blocks:
            continue
        seen.add(name)
        todo += re.findall(r"PORT_INCLUDE\(\s*(\w+)\s*\)", blocks[name])
    return False


def switches_xml(game):
    """<switches> for the DSW word at 0xFCC00010: MS32.sv takes index 254 as four
    bytes, low first, so bit b of the word is dip bit b. A bit no switch covers
    reads 1 (every DIP line is pulled up, all ports IP_ACTIVE_LOW)."""
    blocks = extract_dips.load()
    missing = set()
    ports = extract_dips.parse_ports(blocks[INPUTS[game]], blocks, missing)
    if missing:
        sys.exit(f"{game}: DEF_STR missing from extract_dips: {sorted(missing)}")
    default = 0xFFFFFFFF
    dips = []
    for name, mask, dflt, settings in sorted(ports["DSW"], key=lambda d: (d[1] & -d[1])):   # OSD in bit order
        default = (default & ~mask) | (dflt & mask)
        if settings is None:
            continue
        pos = [b for b in range(32) if mask & (1 << b)]
        ids = []
        for idx in range(1 << len(pos)):
            value = sum(1 << bp for j, bp in enumerate(pos) if idx & (1 << j))
            ids.append(settings.get(value, "-"))
        if any("," in i for i in ids):
            sys.exit(f"{game}: dip {name!r} has a comma in a label")
        dips.append(f'    <dip name="{esc(name)}" bits="{",".join(map(str, pos))}" ids="{esc(",".join(ids))}"/>')
    dflt_bytes = ",".join(f"{(default >> (8 * i)) & 0xFF:02X}" for i in range(4))
    return [f'  <switches default="{dflt_bytes}" base="0">'] + dips + ["  </switches>"]


def main():
    check_map()
    caps = [a for a in sys.argv[2:]] if len(sys.argv) > 2 and sys.argv[1] == "--with-capture" else []

    for game, regions in SETS.items():
        cap = next((c for c in caps if c.split("-")[0] == game), None)
        if caps and not cap:
            continue
        by_name = {r: (size, parts) for r, size, parts in regions}
        # parents at the top of releases/, clones of an MS32 parent under
        # _alternatives/_<parent> (WORKFLOW §10); a parent in another driver
        # (tp2m32, bnstars) leaves the set a parent here
        parent = PARENT.get(game)
        if cap:
            out_dir = REPO / "releases" / "_dev"
        elif parent in SETS:
            out_dir = REPO / "releases" / "_alternatives" / f"_{NAMES[parent]}"
        else:
            out_dir = REPO / "releases"
        out_dir.mkdir(parents=True, exist_ok=True)
        xml = [f"<!-- Generated by scripts/build_mra.py from build_rom_image.SETS; the layout is",
               f"     {'DEVELOPMENT: the ROMs plus a capture blob on rom index 2. ' if cap else ''}",
               f"     rtl/memory/ms32_sdram_top.sv's map. Regions are filled by repeating the",
               f"     ROM data to the region size (MAME's tile-number wrap). -->",
               "<misterromdescription>",
               f"  <name>{esc(NAMES.get(game, game))}</name>",
               f"  <setname>{game}</setname>",
               f"  <year>{GAMES[game]['year']}</year>",
               f"  <manufacturer>{esc(GAMES[game]['maker'])}</manufacturer>",
               f"  <rbf>{RBF}</rbf>",
               "  <mameversion>0286</mameversion>"]
        xml += switches_xml(game)
        # The mod byte always goes first (docs/LESSONS_LEARNED.md): the HPS sends roms in file order.
        key = KEY_INDEX[SET_KEY[game]]
        spr_size = by_name["sprite"][0]
        mod = (key | (0x04 if game in INVERT_LINES else 0) | (0x08 if game in ROT270 else 0)
               | (0x10 if spr_size > 0x1000000 else 0) | (0x20 if uses_mahjong(game) else 0) | (0x80 if cap else 0))
        xml.append(f'  <rom index="1"><part>{mod:02X}</part></rom>   <!-- mod byte: key {SET_KEY[game]}'
                   f'{", vblank/field swapped" if game in INVERT_LINES else ""}{", ROT270" if game in ROT270 else ""}{", mahjong keys" if uses_mahjong(game) else ""}{", CPU held" if cap else ""} -->')
        zips = f"{game}.zip" + (f"|{PARENT[game]}.zip" if game in PARENT else "")
        # address: the HPS writes the image into DDR3 and ms32_rom_loader copies it to SDRAM
        # (MS32.sv, "FAST ROM LOAD"). Not for capture playback: the copy holds the video
        # path in reset, which would clear the capture's registers.
        addr = '' if cap else ' address="0x30000000"'
        xml.append(f'  <rom index="0" zip="{zips}" md5="none"{addr}>')
        pos = 0
        for region, base, rsize in MAP:
            if region not in by_name:
                sys.exit(f"{game}: no {region} region in SETS")
            size, parts = by_name[region]
            if pos != base:
                sys.exit(f"{game}: region {region} would start at {pos:#x}, map says {base:#x}")
            body = region_xml(region, size, parts, CRCS.get(game, {}))
            short = size - DATA_END[(game, region)]
            if short > 0:
                body += f'      <part repeat="{short:#x}">00</part>\n'
            reps, rem = divmod(rsize, size)
            note = (f", then {rem:#x} bytes of zeros (a partial repeat cannot be expressed; "
                    f"tiles past the ROM read as pen 0 here where MAME wraps)") if rem else ""
            xml.append(f"    <!-- {region}: {size:#x} bytes at {base:#x}, repeated {reps}x{note} -->")
            for _ in range(reps):
                xml.append(body.rstrip("\n"))
            if rem:
                xml.append(f'      <part repeat="{rem:#x}">00</part>')
            pos = base + rsize
        xml.append("  </rom>")
        if cap:
            blob = REPO / "debug" / cap / "capture.bin"
            data = blob.read_bytes()
            xml.append(f'  <rom index="2">   <!-- capture blob {cap}, {len(data)} bytes -->')
            xml.append("    <part>")
            xml.append("\n".join(data[i:i + 64].hex() for i in range(0, len(data), 64)))
            xml.append("    </part>")
            xml.append("  </rom>")
        if not cap:
            # NVRAM, 0x2000 bytes at 0xC0000000: downloaded after the ROM on index 4,
            # read back by the HPS when the core asks (MS32.sv, "NVRAM SAVE")
            xml.append('  <nvram index="4" size="8192"/>')
        xml.append("</misterromdescription>")
        text = "\n".join(xml)
        assert text.index('<rom index="1">') < text.index('<rom index="0"'), "mod byte must precede rom index 0"
        path = out_dir / (f"{NAMES.get(game, game)} + capture {cap}.mra" if cap else f"{NAMES.get(game, game)}.mra")
        path.write_text("\n".join(xml) + "\n", encoding="utf-8", newline="\n")
        print(f"{path.name}: {pos:#x} bytes streamed, key {key}")


if __name__ == "__main__":
    main()
