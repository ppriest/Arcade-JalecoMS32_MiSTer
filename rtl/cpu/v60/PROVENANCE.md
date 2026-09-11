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

## Local modifications

None. The two files are byte-identical to upstream (`md5 b349f9d245681e95d33cb8c867d16a81` for
`s32_v60.sv` at import).
