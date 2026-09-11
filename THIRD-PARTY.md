# Third-party code and licences

**This project is GPL-3.0-or-later.** `LICENSE` carries the GPLv3 text.

That is forced rather than preferred, and this file records why, what each dependency obliges, and
what it costs. The decision is also stated in [`docs/ROADMAP.md`](docs/ROADMAP.md) under "Design
decisions", because it constrains what can be vendored here for the life of the project.

## Why GPL-3, and why it is one-way

The V60/V70 CPU core this project vendors is GPL-3.0-only-or-later. A work containing it must be
GPL-3.0-or-later. That combination is lawful only because of the `sys/` framework's own licence
grant — see below — and the consequence is permanent in one direction:

> **Code can flow in from GPL-2-or-later MiSTer cores. It cannot flow back out to them.**

Anything written here is unavailable to a GPL-2-or-later core unless its author also offers it under
GPL-2-or-later separately. To relicense this repository back to GPL-2-or-later, the vendored V60
would have to be removed and replaced with an independently written core, or its authors would have
to agree to dual-license.

The sibling cores this project inherits its practice from — `Arcade-Psikyo_MiSTer`,
`Arcade-Fuuki_MiSTer`, `Arcade-Seta_MiSTer` — already carry the GPLv3 text (all three `LICENSE`
files are byte-identical to this one), so this is not a divergence from them.

## In use

### meathax/s32 and alphanu1/sega-model1-mister — GPL-3.0-or-later

<https://github.com/meathax/s32> — the NEC V60/V70 CPU core (`s32_v60.sv`, `s32_v60_bus.sv`) and its
verification suite (`verif/v60/`, `verif/cosim/`), written for the Sega System 32 MiSTer core.

<https://github.com/alphanu1/sega-model1-mister> — the Sega Model 1 MiSTer core, which imported that
CPU and modified it: the instruction fetch, realign network, loop cache and prefetch unit split out
into `v60_ifetch.sv`; the floating-point normalise/round/exponent tail folded into one pipelined
stage; `MOVD` routed through the register file's existing read ports; the group 6/7 scaled index
computed once. Its per-file headers record each change and the date, as GPLv3 §5(a) requires.

This project takes the core through the Model 1 lineage. **Copyright remains with those authors on
those files.** GPL-3 to GPL-3, so reuse is direct.

Obligations this project carries:

- Publish the source, which this repository does.
- **GPLv3 §5(a): every modified file must carry prominent notice that it was changed, and a date.**
  Both upstreams already do this at the top of each file. Our modifications — the 32-bit bus adapter,
  the widened instruction-fetch address, any V70 wiring — go into that same notice block, appended
  rather than replacing what is there. Do not strip an upstream notice; it is the licence's
  requirement on *them*, not a comment.
- Keep `rtl/cpu/v60/PROVENANCE.md` current with what was taken, from which commit, and what was
  changed here. That is this project's own convention rather than a licence term, and it is how the
  next person works out whether an upstream fix applies.

### MiSTer template and `sys/` — GPL-2.0-or-later

<https://github.com/MiSTer-devel/Template_MiSTer> — framework, `hps_io`, the scaler, `sys_top`.

The Template repository's own `LICENSE` carries the **GPLv2** text, but every source file header in
`sys/` reads "either version 2 of the License, or (at your option) any later version". **That
or-later clause is the only reason the combination in this repository is lawful**: it permits using
`sys/` under GPL-3.

Do not edit `sys/`. Framework updates overwrite it, and this project has no reason to diverge from
upstream there. Build-time behaviour is changed through `VERILOG_MACRO` settings in the `.qsf`, which
is a project decision rather than a modification of `sys/`.

### MAME — BSD-3-Clause

<https://github.com/mamedev/mame> — the behavioural oracle throughout. `jaleco/ms32.cpp`,
`ms32_v.cpp`, `ms32_sprite.cpp`, `jaleco_ms32_sysctrl.cpp`, `jalcrpt.cpp` for the board; `v60/` for
the CPU's contract; `sound/ymf271.cpp` for the sound chip.

BSD-3 permits derivation outright. The obligation is to retain the copyright notice and licence text
and not to use contributors' names as endorsement. Where a file here is a transcription of a MAME
file rather than an independent implementation of the hardware, say so in its header and name the
source file.

**A caution about reading MAME.** MAME is GPL-2.0 *as a whole*, and individual files carry their own
SPDX headers which are not all BSD-3. Check the header of any file before treating it as
BSD-licensed, and do not assume a driver's licence from its neighbours.

**And a distinction that matters.** The behaviour of the original Jaleco and NEC silicon is fact, not
MAME's expression, and reimplementing hardware behaviour is not derivative of the program that
documents it. That applies to *function*. It does not extend to *structure*: where MAME made a
decomposition choice that alternatives existed for, mirroring that choice is a different question
from reproducing what the chip does.

### ymfm — BSD-3-Clause

<https://github.com/aaronsgiles/ymfm> — the YMF271 behaviour reference for the from-scratch sound
chip. Same obligations as MAME's BSD-3 files. Not vendored; read, not copied.

## Not in this repository

- **ROMs.** `roms/` is gitignored and no ROM data is committed, in any subdirectory.
- **Third-party source that is only read, not copied** — MAME, `ymfm`. Point at an upstream commit
  rather than vendoring a snapshot.

## Release checklist

Before publishing an `.rbf`:

1. `LICENSE` is the GPLv3 text.
2. Every vendored file carries its upstream copyright, its SPDX identifier, and a §5(a) notice
   listing this project's changes with a date.
3. Every vendored directory has a `PROVENANCE.md` naming the upstream repository and commit.
4. This file lists every dependency actually present in the tree.
5. No ROM data anywhere in the commit.
