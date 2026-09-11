# rtl/cpu/v60 — provenance

## What this is

`s32_v60.sv` and `s32_v60_bus.sv`: the NEC V60/V70 CPU core written for the Sega System 32 MiSTer
core, **vendored verbatim** from

    https://github.com/meathax/s32
    commit 3bce67e004608c73cbc257a51f05ccf3db67bbf0  (2026-08-28)
    rtl/cpu/v60/s32_v60.sv, rtl/cpu/v60/s32_v60_bus.sv

Licence: upstream's README says "Original core source is licensed under GNU GPLv3" and its
`LICENSE` is the GPLv3 text. Copyright remains with the upstream author. This repository is
GPL-3.0-or-later for that reason — see `../../../THIRD-PARTY.md`.

The upstream files carry no per-file copyright or SPDX line; the header is the design note that
begins "NEC V60 (uPD70616) / V70 (uPD70632) CPU core for the Sega System 32 MiSTer core". It is
left exactly as found. **Any modification made here must be recorded at the top of the modified
file with what changed and the date** (GPLv3 §5(a)), appended to the upstream header rather than
replacing it, and listed under "Local modifications" below.

Its verification suite came with it, unchanged, into `sim/v60/` (upstream `verif/v60/`) and
`sim/v60/cosim/` (upstream `verif/cosim/`); `scripts/run_v60_tests.sh` drives it under ModelSim.

## Why this copy and not the Model 1 fork

The Sega Model 1 MiSTer core (alphanu1/sega-model1-mister, `rtl/cpu/v60/`) carries a fork of this
core taken at s32 commit `7905361` (its `deps.lock`, 2026-08-14) with the fetch unit split out into
`v60_ifetch.sv`, the FP tail pipelined, explicit width casts, and `dbg_*` ports. It was the first
candidate here, because of its Fmax work. Both were run through the same suite under ModelSim on
2026-09-11:

| core | result |
|---|---|
| s32 `3bce67e` (this copy) | **30 / 30 pass** |
| Model 1 `a7abcbf` | 25 / 30 — 3 benches use a `fast_ifetch` port the fork predates; `tb_v60_xch` fails all three memory-to-memory cases and `tb_v60_flags` fails 2 of 24, both fixed upstream after the fork (`75ae80f` "Implement V60 memory-to-memory XCH", `f63c8bc`) |

s32's history was rewritten after Model 1 pinned it — `7905361` is not an ancestor of `3bce67e`
and the repository has 147 commits total — so the fork cannot be rebased or diffed against
upstream mechanically. The maintained line with the correctness fixes and the throughput work
(`SEQ_DISPATCH`, `EXEC_RETIRE`) is this one. Model 1's Fmax changes are a known, documented set
that can be re-applied here if Phase 0's timing measurement needs them.

## What upstream does that this project must know

- **Clocking.** s32 runs the core on its 48.317 MHz `clk_sys` with the microsequencer enabled
  every other edge (`s32_v60_exec_cadence`, 24.16 MHz) and the bus unit on a 16.108 MHz enable, and
  its SDC grants **`set_multicycle_path -setup 2` on every register-to-register path inside
  `s32_v60`**, plus `-setup 3` from `fp_a[*]`. That constraint is only valid because the enable
  guarantees at least one idle edge between updates. Any use here with `ce` = 1 must close
  single-cycle, and the LESSONS_LEARNED rule about multicycles on posedge-to-negedge paths applies:
  the only `negedge` in these files is a simulation-only assertion block in `s32_v60_bus.sv`
  under `` `ifndef SYNTHESIS ``, so the core is single-edge.
- **`IS_V70` is half-wired.** It sets PIR (`0x7000`) and nothing else; `s32_v60_bus` declares the
  parameter and never branches on it, and issues 16-bit cycles on `m_addr[23:1]`. The instruction
  port is `if_addr[23:0]` (`assign if_addr = pf_addr[23:0]`). MS32 needs a 32-bit data bus and
  32-bit addresses: the adapter is replaced (new file, this project's), and the `if_addr` widening
  is a modification to `s32_v60.sv` that must be noticed per §5(a).
- **`fast_ifetch`** is a runtime input selecting the dedicated 8-byte instruction port when the
  compile-time `FAST_IFETCH` capability is on; s32 serves it from a 32-line ROM icache in
  `s32_core.sv` at `clk_sys` latency. The unit benches tie it off.
- **Two build-time defines** disable throughput features for A/B tests: `V60_NO_SEQ_DISPATCH`,
  `V60_NO_EXEC_RETIRE`. `S32_V60_NO_FP` compiles the FP group out (reserved-instruction
  exception instead; `tb_v60_no_fp` checks it).

## Measured standalone (Quartus 17.0.2, 5CSEBA6U23I7, `rtl/synth_check/v70` settings, virtual pins)

| core | ALM | Fmax (slow 100C) | worst path |
|---|---|---|---|
| s32 `3bce67e`, as imported | 20,701 | **25.1 MHz** | `fp_a[5] -> f_z`, 39.2 ns: the FP compare/normalise tail |
| s32 `3bce67e`, `S32_V60_NO_FP` | 18,044 | **45.45 MHz** | `ea_ofs -> r[..]`, the EA-to-register write |
| Model 1 `a7abcbf` fork | 15,755 | 47.21 MHz | `ea_ofs -> r[24]`, 20.6 ns |

So the FP group costs 2,657 ALM and 20 MHz of Fmax, which is what s32's own SDC papers over with
`set_multicycle_path -setup 3 -from fp_a[*]`, and what Model 1 removed by pipelining the tail.
Model 1's fork is also ~5,000 ALM smaller with FP present; its `MOVD` read-port and `ea_index`
changes are the likely reason, and are candidates to re-apply here (with its notices) once the
CPI measurement says what clock this core actually needs.

## Local modifications

Both files started byte-identical to upstream (`md5 b349f9d245681e95d33cb8c867d16a81` for
`s32_v60.sv` at import). Changes since, each with a §5(a) notice at the top of the file and an
`[MS32]` mark at the site:

| date | file | change | why |
|---|---|---|---|
| 2026-09-12 | `s32_v60.sv` | `if_addr` widened to `[31:0]` | V70 is a 32-bit machine; MS32 ROM is at `0xFFE00000` |
| 2026-09-12 | `s32_v60.sv` | PFU does not issue while `st == S_RESET` | it issued a read of address 0 from the pre-reset `fb_base`/`pc` before the reset-vector fetch; the bytes were discarded but the bus cycle happened. Found by the `tetrisp` boot-trace diff (`scripts/compare_boot_trace.py`), where it was the only discrepancy in 1,173 writes |

`s32_v60_bus.sv` is unmodified and unused here: `rtl/cpu/ms32_v70_bus.sv` (this project's own
file) is the 32-bit adapter.
