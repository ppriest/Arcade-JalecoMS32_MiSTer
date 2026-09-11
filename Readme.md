# Arcade-JalecoMS32_MiSTer

A MiSTer FPGA core for Jaleco's **MegaSystem 32** arcade hardware (1994-1997), targeting MAME's
`jaleco/ms32.cpp` driver set.

**Status: design only. No RTL exists yet.**

## Documents

| | |
|---|---|
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | What the hardware is, what has to be built, in what order, and why. Read this first. |
| [`docs/LESSONS_LEARNED.md`](docs/LESSONS_LEARNED.md) | Carried over from the Psikyo, Fuuki and Seta cores. Rules that cost those projects real time to find. Read the section headings before starting a subsystem, not after it misbehaves. |
| [`docs/WORKFLOW.md`](docs/WORKFLOW.md) | Build, deploy, instrumentation and MAME-capture practice. Not optional. |
| [`THIRD-PARTY.md`](THIRD-PARTY.md) | What is vendored, what each licence obliges, and the release checklist. |

## Why this one is different

MS32 runs a **NEC V70**. An open FPGA V60/V70 core exists — written for the Sega System 32 core
([meathax/s32](https://github.com/meathax/s32)) and carried into the Sega Model 1 core
([alphanu1/sega-model1-mister](https://github.com/alphanu1/sega-model1-mister)) — and it already has
an `IS_V70` parameter. Vendoring it makes this core **GPL-3.0-or-later** permanently — decision
taken, obligations in [`THIRD-PARTY.md`](THIRD-PARTY.md).

What is left from scratch is the **YMF271** sound chip, the video hardware, and a 32-bit bus adapter
for the CPU. Phase 0 gates on CPU throughput rather than on whether a CPU can be written: the Model 1
project measures its V60 at about 70% of the real board's work per frame, and MS32 has to know its
own number before building on top of it.

## Building

Quartus 17.0.2 for the bitstream; ModelSim ASE 10.5b and Verilator 5 (MSYS2's mingw64 package)
for simulation — the vendored CPU's suite runs under both (`scripts/run_v60_tests.sh`,
`scripts/run_v60_verilator.sh`), and the boot-trace diff is a Verilator job. Builds run out of a
git worktree, never in the tree:

```bash
python scripts/build_staged.py
```

That refuses a dirty tree, gates on negative setup slack on every clock, checks the design survived
to the fitted netlist, and records the commit and fitter seed in `build/BUILT_COMMIT`. JTAG and
Quartus are mutually exclusive on this machine and `scripts/hwlock.py` enforces it — running them
together has bugchecked the PC.

The upstream framework documentation is in
[MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer), from which `sys/`
and the project skeleton here are taken unmodified.

## Licence

**GPL-3.0-or-later.** Forced rather than chosen: the vendored V60/V70 CPU core is GPL-3, and `sys/`
is GPL-2-**or-later**, whose or-later clause is what makes the combination lawful. Code can flow in
from GPL-2-or-later MiSTer cores and cannot flow back out to them. See
[`THIRD-PARTY.md`](THIRD-PARTY.md).
