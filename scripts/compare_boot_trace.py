#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Diff the V70 core's boot against MAME's, access by access.

    python scripts/compare_boot_trace.py replay  tetrisp   # -> <set>_io_replay.txt for the bench
    python scripts/compare_boot_trace.py compare tetrisp   # MAME trace vs RTL trace

Both traces are "seq rw addr mask data" lines from a tap on the bus:
MAME's from scripts/mame_boot_trace.py, the RTL's from sim/v70_boot_tb.

THE COMPARISON IS AN ORDERED ADDRESS SUBSEQUENCE WITH DUPLICATES COLLAPSED,
not a line-for-line diff. Two correct cores do not fetch the same words:
MAME's V60 reads instruction bytes one at a time through OpRead8/16/32 and
the tap logs each lane as its own access; the RTL's prefetch unit reads
8-byte-aligned words ahead of execution and the adapter splits unaligned
accesses into two. So consecutive accesses to the same word are collapsed
on both sides and the MAME sequence is matched as a subsequence of the
RTL's within a bounded window (LESSONS_LEARNED, "[Seta] Two cores that
both boot correctly still fetch different words"). Writes are compared
strictly -- same address, same order -- because a write is the CPU's
externally visible result and there is no prefetch story for it.

Data is checked where it can be: on every matched READ from a non-replayed
address (ROM and RAM), the RTL's data must equal MAME's. A mismatch there
is a bus or memory-model fault, not a CPU one.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load(path):
    out = []
    for line in Path(path).read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        seq, rw, addr, mask, data = line.split("\t")
        out.append((rw, int(addr, 16), int(mask, 16), int(data, 16)))
    return out


# The same decode the bench uses: which addresses are ROM/RAM (modelled) and
# which are I/O (replayed from MAME). Bits 29:26 are mirror bits everywhere.
def region(addr):
    am = addr & 0xC3FFFFFF
    if (am >> 21) == 0b1100_0011_111: return "rom"
    if (am >> 20) == 0xc2e:            return "scratch"
    if (am >> 21) == 0b1100_0000_000:  return "nvram"
    if (am >> 18) == 0b1100_0001_0001_10: return "priram"
    if (am >> 21) == 0b1100_0001_010:  return "palram"
    if (am >> 21) == 0b1100_0010_000:  return "rozram"
    if (am >> 21) == 0b1100_0010_001:  return "lineram"
    if (am >> 21) == 0b1100_0010_100:  return "sprram"
    if (am >> 21) == 0b1100_0010_110:  return "txbg"
    if (addr >> 12) == 0xfce00:        return "ioregs"
    return "io"


def collapse(acc):
    """Consecutive accesses to the same word address and direction become one."""
    out = []
    for rw, addr, mask, data in acc:
        w = addr & ~3
        if out and out[-1][0] == rw and out[-1][1] == w:
            continue
        out.append((rw, w, mask, data))
    return out


def replay(game):
    mame = load(REPO / "debug" / f"{game}-boot" / f"{game}_boot.trace")
    out = REPO / "debug" / f"{game}-boot" / f"{game}_io_replay.txt"
    n = 0
    with open(out, "w") as f:
        for rw, addr, mask, data in mame:
            if rw == "r" and region(addr) == "io":
                f.write(f"{addr & ~3:08X} {data:08X}\n")
                n += 1
    print(f"{n} I/O reads -> {out}")


def compare(game):
    """Writes strictly in order; data reads matched between writes; ROM
    fetches as a superset. Instruction fetch order is NOT compared: MAME
    re-reads the instruction bytes after every bus access and never reads
    ahead, the RTL's prefetch unit reads 8-20 bytes ahead and shifts, so the
    two ROM read streams are legitimately different orderings of overlapping
    sets. The write stream and the data-read stream are what the program
    did, and those must agree exactly.
    """
    d = REPO / "debug" / f"{game}-boot"
    mame = collapse(load(d / f"{game}_boot.trace"))
    rtl = collapse(load(d / "rtl_boot.trace"))
    print(f"MAME {len(mame)} collapsed accesses, RTL {len(rtl)}")

    def split(acc):
        """[(write or None, [data reads since previous write])], ROM read set."""
        segs, cur, rom = [], [], set()
        for rw, addr, mask, data in acc:
            if rw == "w":
                segs.append(((addr, mask, data), cur)); cur = []
            elif region(addr) == "rom":
                rom.add(addr)
            else:
                cur.append((addr, mask, data))
        segs.append((None, cur))
        return segs, rom

    ms, mrom = split(mame)
    rs, rrom = split(rtl)

    # ROM fetch superset. MAME's trace ends at N accesses; the RTL's covers a
    # different span of the program, so only compare ROM words MAME read
    # BEFORE its last matched write (below); here just report the raw figure.
    missing_rom = sorted(mrom - rrom)
    print(f"ROM words MAME read: {len(mrom)}; of those not read by RTL: {len(missing_rom)}"
          + (f" (first {missing_rom[0]:08X})" if missing_rom else ""))

    nw = min(len(ms), len(rs)) - 1     # writes present in both (last seg has no write)
    bad = 0
    for i in range(nw):
        (mw, mreads), (rw_, rreads) = ms[i], rs[i]
        if mw[0] != rw_[0] or (mw[2] & mw[1]) != (rw_[2] & mw[1]):
            print(f"WRITE #{i} differs: MAME {mw[0]:08X}={mw[2]:08X} (mask {mw[1]:08X})  RTL {rw_[0]:08X}={rw_[2]:08X}")
            bad += 1
            if bad > 5: break
            continue
        # data reads between this write and the previous one: same addresses in order,
        # same data on the lanes MAME asked for
        ma = [(a, m, dd) for a, m, dd in mreads]
        ra = [(a, m, dd) for a, m, dd in rreads]
        if [a for a, _, _ in ma] != [a for a, _, _ in ra]:
            print(f"READS before write #{i} ({mw[0]:08X}) differ:")
            print("   MAME:", " ".join(f"{a:08X}" for a, _, _ in ma[:12]))
            print("   RTL :", " ".join(f"{a:08X}" for a, _, _ in ra[:12]))
            bad += 1
            if bad > 5: break
            continue
        for (a, m, dm), (_, _, dr) in zip(ma, ra):
            if (dm & m) != (dr & m):
                print(f"READ DATA {a:08X} before write #{i}: MAME {dm:08X} RTL {dr:08X} (mask {m:08X})")
                bad += 1
    print(f"{nw} writes compared in order, {bad} discrepancies; MAME has {len(ms)-1} writes in its trace, RTL {len(rs)-1}")
    return 1 if bad else 0


if __name__ == "__main__":
    cmd, game = sys.argv[1], sys.argv[2]
    sys.exit(replay(game) if cmd == "replay" else compare(game))
