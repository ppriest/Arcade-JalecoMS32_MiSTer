# rtl/sound/ymf271 — provenance

## What this is

The Yamaha YMF271 (OPX) from the Seibu SPI MiSTer core, taken from

    https://github.com/zakk4223/Arcade-SeibuSPI_MiSTer
    commit fd25dd4057547d654c876bc0349698d1c88619e2
    rtl/ymf271.sv, rtl/ymf271_synth.sv, rtl/ymf271_tables.vh

It is a port of MAME's OPX rewrite (`ymf271.cpp`, MAME `03761e46766`): the register file, timers
and IRQ in `ymf271.sv`; the 48-slot FM/PCM engine, one serial pass per 44.1 kHz sample, in
`ymf271_synth.sv`; generated fixed-point tables in `ymf271_tables.vh`.

## Licence

The upstream repository has no LICENSE file and these files carry no licence header. The author
confirmed to the project owner that the files are GPL-3, and the project owner has authorised
their use here on that basis (recorded in `docs/ROADMAP.md`, "Open items"). GPL-3 into this
GPL-3.0-or-later project is direct. Copyright remains with the upstream author. When the upstream
LICENSE lands, record its commit here.

`ymf271_ss.sv`'s `ssbus_if` interface is Martin Donlon's (Arcade-IGSPGM_MiSTer, GPL v2 or later),
copied unchanged from the same SeibuSPI commit's `rtl/savestates.sv`.

## Files

| file | from | status |
|---|---|---|
| `ymf271.sv` | `rtl/ymf271.sv` | modified, §5(a) notice at the top |
| `ymf271_synth.sv` | `rtl/ymf271_synth.sv` | modified, §5(a) notice at the top |
| `ymf271_tables.vh` | `rtl/ymf271_tables.vh` | unchanged |
| `ymf271_ss.sv` | `ssbus_if` from `rtl/savestates.sv`; `system_consts` reduced to the four `SSIDX_YMF_*` values of `rtl/system_consts.sv` | this project's file around the unchanged interface |
| `ymf271_ms32.vh` | stands in for `rtl/spi_defs.vh` | this project's file |

md5 at import: `ymf271.sv` 5e44c76b52332fa7081886d5997b0fe5, `ymf271_synth.sv`
81612ef8de9cd0692de8169ea86d03dd, `ymf271_tables.vh` b1369dff4cee619b939d4490aab1cf5d.

## Local modifications

| date | file | change | why |
|---|---|---|---|
| 2026-09-13 | `ymf271.sv` | `CLK_HZ_X3` is a module parameter | the sample tick divides the clock enable's rate (48 MHz here), not SPI's 57.27 MHz |
| 2026-09-13 | `ymf271_synth.sv` | `spi_defs.vh` include replaced by `ymf271_ms32.vh` | SPI's header is its whole SDRAM map; the engine uses one name from it |
| 2026-09-13 | `ymf271_synth.sv` | the sample fetch address takes bit 21 when `pcm_25mb` is set | MS32's sample ROM is 4 MB; upstream's fetch stopped at bit 20 while its wave-memory read path already honoured `pcm_25mb` |
| 2026-09-13 | both | a clock enable `ce` on every clocked block (in the parameter RAM lanes, on each statement) | the engine missed MS32's 96 MHz by 5.9 ns; `ms32_sound` enables it every other clock and `MS32.sdc` gives its internal paths two. Gating the lanes' block as a whole stopped Quartus inferring them as RAM (15k registers, no fit) |

## How it is used here

`rtl/sound/ms32_sound.sv` instantiates `ymf271` with `ce` high every other clock, `stereo` and `pcm_25mb` high, `ymf_16384`
low, `pause` low, and every `ssbus_if` with its select off. The sample ROM is the `ymf` region of
`ms32_sdram_top` (0x1BC_0000, 4 MB), reached through a toggle-to-level adapter on port 2's
arbiter. `sim/ymf_tb` replays MAME's YMF271 writes into the chip under Verilator and
`scripts/compare_ymf_audio.py` compares its output with MAME's `-wavwrite`. The reference must be a
MAME with the OPX rewrite (`03761e46766`, August 2026): against MAME 0.286's older core the same
run correlates at about 0.6 per second.
