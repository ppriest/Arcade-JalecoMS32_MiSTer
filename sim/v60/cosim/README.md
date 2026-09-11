# V60 co-simulation harness (DESIGN.md §11.2)

Infrastructure for instruction-level equivalence checking of `s32_v60`
against MAME's v60 core:

1. `mame_v60_trace.patch` — instruments MAME's execute loop to stream a
   24-byte architectural record per instruction (PC, PSW, changed register,
   memory write).
2. RTL side — the bench dumps the same record stream from `s32_v60`'s
   debug port (`dbg_pc` + register-write snoop).
3. `compare.py` — lock-step comparator; exits non-zero on the first
   architectural divergence window.

Running the corpus requires a MAME build (patched) and the game ROM sets to
generate per-game traces (boot + attract + scripted play). Neither ships in
this repository; this directory makes the bring-up-phase workflow
turn-key once both are available:

```
mame segas32 ga2 -bench 90            # patched build, V60_COSIM=1
vvp tb_v60_cosim +rom=ga2_maincpu.bin # RTL replay of same bus image
verif/cosim/compare.py v60_trace.bin rtl_trace.bin
```
