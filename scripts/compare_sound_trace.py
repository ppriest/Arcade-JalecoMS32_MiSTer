#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare sim/sound_tb's Z80 trace against MAME's.

    python scripts/compare_sound_trace.py tetrisp

Reads debug/<set>-sound/<set>_sound.trace (scripts/mame_sound_trace.py) and
simout/sound-<set>/rtl_sound.trace, up to the end of the RTL run. Writes
(zw) are compared in order, address and data, and the time of each matched
pair gives the drift. Timers A and B expiring within a fraction of a
millisecond can be acknowledged in either order, so the writes outside the
YMF271's utility bank (0x3F0C/0x3F0D) are also compared on their own, and
the whole set as a multiset. Reads (zr) are compared as a collapsed sequence
of (address, data), without the repeat counts: a poll loop's count depends on
the poll's timing. Exit status: 1 when the non-utility writes differ or the
write multisets differ.
"""
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def load(path, t_end=None):
    zw, zr = [], []
    for line in Path(path).read_text().splitlines():
        if not line or line[0] == "#":
            continue
        f = line.split("\t")
        t = float(f[0])
        if t_end is not None and t > t_end:
            break
        if f[1] == "zw":
            zw.append((t, int(f[2], 16), int(f[3], 16)))
        elif f[1] == "zr":
            key = (int(f[2], 16), int(f[3], 16))
            if not zr or zr[-1][1:] != key:
                zr.append((t,) + key)
    return zw, zr


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    game = sys.argv[1]
    rtl_path = REPO / "simout" / f"sound-{game}" / "rtl_sound.trace"
    rzw, rzr = load(rtl_path)
    t_end = max([x[0] for x in rzw + rzr] or [0.0])
    mzw, mzr = load(REPO / "debug" / f"{game}-sound" / f"{game}_sound.trace", t_end)
    print(f"{game}: RTL to {t_end:.3f} s: {len(rzw)} writes, {len(rzr)} read runs; "
          f"MAME to then: {len(mzw)} writes, {len(mzr)} read runs")

    from collections import Counter
    util = (0x3F0C, 0x3F0D)
    mn = [w[1:] for w in mzw if w[1] not in util]
    rn = [w[1:] for w in rzw if w[1] not in util]
    same_other = mn == rn
    same_set = Counter(w[1:] for w in mzw) == Counter(w[1:] for w in rzw)
    swapped = sum(1 for m, r in zip(mzw, rzw) if m[1:] != r[1:])
    print(f"writes outside 0x3F0C/D: {len(mn)} MAME, {len(rn)} RTL, "
          f"{'identical in order' if same_other else 'DIFFER'}; all writes as a multiset: "
          f"{'equal' if same_set else 'DIFFER'}; positions differing in order: {swapped}")
    if len(mzw) == len(rzw):
        print(f"time RTL-MAME, position by position: max |dt| "
              f"{max(abs(m[0] - r[0]) for m, r in zip(mzw, rzw)) * 1e3:.3f} ms")

    bad = 0
    drift = []
    for i, (m, r) in enumerate(zip(mzw, rzw)):
        if m[1:] != r[1:]:
            bad = 1
            print(f"WRITE #{i} differs: MAME {m[0]:.6f} {m[1]:04X}={m[2]:02X}  RTL {r[0]:.6f} {r[1]:04X}={r[2]:02X}")
            for j in range(max(0, i - 4), min(i + 4, len(mzw), len(rzw))):
                print(f"   #{j}: MAME {mzw[j][0]:.6f} {mzw[j][1]:04X}={mzw[j][2]:02X}   RTL {rzw[j][0]:.6f} {rzw[j][1]:04X}={rzw[j][2]:02X}")
            break
        drift.append(r[0] - m[0])
    n = len(drift)
    if n:
        print(f"writes: {n} matched in order; RTL-MAME time min {min(drift) * 1e3:+.3f} ms, "
              f"max {max(drift) * 1e3:+.3f} ms, last {drift[-1] * 1e3:+.3f} ms")
    if not bad and len(rzw) != len(mzw):
        print(f"write counts differ past the matched prefix: MAME {len(mzw)}, RTL {len(rzw)} "
              f"(the last few can fall either side of the run's end)")

    for i, (m, r) in enumerate(zip(mzr, rzr)):
        if m[1:] != r[1:]:
            print(f"READ run #{i} differs: MAME {m[0]:.6f} {m[1]:04X}->{m[2]:02X}  RTL {r[0]:.6f} {r[1]:04X}->{r[2]:02X}")
            break
    else:
        print(f"reads: {min(len(mzr), len(rzr))} runs match in order")
    return 0 if same_other and same_set else 1


if __name__ == "__main__":
    sys.exit(main())
