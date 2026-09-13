#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare sim/ymf_tb's YMF271 output against MAME's recording of the same run.

    python scripts/compare_ymf_audio.py tetrisp

Reads debug/<set>-sound/<set>_sound.wav (mame_sound_trace.py --wav, 44.1 kHz
stereo) and simout/ymf-<set>/rtl_audio.raw (16-bit stereo, one frame per
sample tick). The RTL stream starts at reset and MAME's at machine start, so
the offset between them is searched for (+-50 ms) on the first loud second.
For each second both sides are loud it reports the waveform correlation,
the correlation of the magnitude spectra (the SeibuSPI core's hardware
measure) and the RMS ratio RTL/MAME. Exit status 1 if any loud second's
spectral correlation is below 0.99.
"""
import sys
import wave
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parent.parent
SR = 44100


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    game = sys.argv[1]
    w = wave.open(str(REPO / "debug" / f"{game}-sound" / f"{game}_sound.wav"))
    if w.getframerate() != SR or w.getnchannels() != 2:
        sys.exit("MAME wav must be 44100 Hz stereo")
    mame = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").reshape(-1, 2).astype(float)
    rtl = np.fromfile(REPO / "simout" / f"ymf-{game}" / "rtl_audio.raw", dtype="<i2").reshape(-1, 2).astype(float)
    n = min(len(mame), len(rtl))
    mono_m = mame[:n].mean(axis=1)
    mono_r = rtl[:n].mean(axis=1)

    loud = [s for s in range(n // SR) if np.sqrt((mono_m[s * SR:(s + 1) * SR] ** 2).mean()) > 100]
    if not loud:
        sys.exit("MAME is silent over the RTL run")
    s0 = loud[0]
    a = mono_m[s0 * SR:(s0 + 1) * SR]
    best, lag = -2.0, 0
    for k in range(-2205, 2206):
        lo = s0 * SR + k
        if lo < 0 or lo + SR > n:
            continue
        b = mono_r[lo:lo + SR]
        c = np.corrcoef(a, b)[0, 1] if b.std() > 0 else -2.0
        if c > best:
            best, lag = c, k
    print(f"{game}: {n / SR:.1f} s compared, RTL lags MAME by {lag} samples ({lag / SR * 1e3:+.2f} ms), "
          f"waveform correlation {best:.4f} on second {s0}")

    worst = 1.0
    for s in loud:
        lo = s * SR
        if lo + lag < 0 or lo + lag + SR > n:
            continue
        a = mono_m[lo:lo + SR]
        b = mono_r[lo + lag:lo + lag + SR]
        wc = np.corrcoef(a, b)[0, 1] if b.std() > 0 else 0.0
        fa = np.abs(np.fft.rfft(a * np.hanning(SR)))
        fb = np.abs(np.fft.rfft(b * np.hanning(SR)))
        sc = np.corrcoef(fa, fb)[0, 1] if fb.std() > 0 else 0.0
        ratio = np.sqrt((b ** 2).mean()) / np.sqrt((a ** 2).mean())
        worst = min(worst, sc)
        print(f"  second {s:3d}: waveform r {wc:7.4f}   spectrum r {sc:.4f}   RMS RTL/MAME {ratio:.3f}")
    print(f"worst spectral correlation {worst:.4f}")
    return 0 if worst >= 0.99 else 1


if __name__ == "__main__":
    sys.exit(main())
