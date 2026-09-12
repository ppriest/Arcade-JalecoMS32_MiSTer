# Jaleco MegaSystem 32 — MiSTer Core Roadmap

## Context

Goal: a DE10-nano MiSTer core for Jaleco's MegaSystem 32 arcade hardware, emulated by MAME's
`jaleco/ms32.cpp` / `ms32_v.cpp` / `ms32_sprite.cpp` / `jaleco_ms32_sysctrl.cpp` — a Quartus 17.0.2
Verilog/SystemVerilog project producing one `.rbf` and a `.mra` per supported game, reusing proven
open MiSTer components where they exist.

MS32 runs a **NEC V70** (`D70632GD-20`). **An open FPGA V60/V70 core exists, runs on hardware, and
carries an `IS_V70` parameter already** — see "The CPU" below. That is the most important fact about
this project's shape, and it was nearly missed: a first pass concluded no such core existed, on a web
search that returned nothing, when two MiSTer cores ship one. A negative search result is not
evidence of absence, and the place to look for an arcade CPU core is the other arcade cores that
need the same CPU.

The sound chip is a **YMF271** (OPX), for which no FPGA implementation was found; `ymfm` and MAME's
`ymf271.cpp` (1,358 lines) are behaviour references, not synthesizable. That claim carries the same
caveat as the one above, and checking it the same way is a Phase 0 task rather than an assumption.

So the order of size is: a sound chip, then the video hardware that Psikyo/Fuuki/Seta would have
called the whole job, then integrating and re-verifying a vendored CPU. Phase 0 is still a gate, but
it gates on **throughput and area**, not on whether a CPU can be written at all.

Cross-cutting technical findings from the previous three cores — Quartus-vs-ModelSim divergences,
SDRAM gotchas, testbench pitfalls, hardware bring-up technique — are in
**[`LESSONS_LEARNED.md`](LESSONS_LEARNED.md)**. Working practice built on top of them (staged
builds, the JTAG probe, OSD debug switches, the MAME capture pipeline) is in
**[`WORKFLOW.md`](WORKFLOW.md)**. The entries that already bind decisions in this document are
collected below under "Pitfalls that already bind decisions here".

## Progress

**Phase 0 complete on its own terms (2026-09-11/12).** All four exit criteria are met for
`tetrisp`; what remains open is in-design margin, which is Phase 2's to measure.

| criterion | result |
|---|---|
| 1. upstream suite unchanged | 30/30 ModelSim, 22/22 Verilator (the other 8 are enum-FSM pokes only ModelSim elaborates); the same after every edit to the core |
| 2. boots and matches MAME | `tetrisp` from the reset vector through init, video-RAM fill, NVRAM, inputs and DIPs: **all 404,416 writes of a 5M-access MAME trace match in address, data and order**, every ROM word MAME read was read, **28 of 32 interrupts entered at exactly MAME's PC and PSW**. The 4 not taken are the replay harness's limit — vblank is a time event and in a polling loop the iteration is not recoverable from the trace — not a core fault; the discrepancies the comparator reports all follow from those 4 |
| 3. CPI on real code | **20.1** through the 32-bit data adapter; **7.57 with the 8-byte instruction port served in one clock** (an icache hit). MAME's flat model is 8. So a 20 MHz V70 with an instruction cache is at parity; without one it is 0.4× |
| 4. timing at that clock | 25.54 MHz standalone with the FP group (path `fp_a -> f_z`), 45.45 MHz without, against a 20 MHz target. Met standalone; the in-design margin at 20 MHz, and whether the FP tail has to be pipelined to keep it, is Phase 2's first Quartus run |

The interrupt-replay mechanism (WORKFLOW §12) reached 28/32 in four refinements — trigger on the
last write before the entry, then on MAME's pushed PC, then its pushed PSW, then the number of data
reads since the write; each step was a class of case the previous one could not tell apart. It is
left there deliberately: the remaining four are inside the game's idle loop, where MAME's frame
timer alone decides the iteration, and the core has nothing left to prove on them.

- **CPI: 8.48 on the RAM-clear loops, 20.1 on real code** — both on `tetrisp` with single-cycle
  bench memory, both over 6M bus accesses. The first figure (5.97M instructions) came from a run
  that never left the power-on RAM test, whose tight loops live inside the core's retained fetch
  window; it was recorded here as the answer for an hour. The second (1.67M instructions, once
  interrupts were replayed and the game ran its initialisation) has the core in `S_FILL` for 73%
  of cycles: every taken branch refills a conservative 20-byte window at ~6 cycles a word through
  the 32-bit data adapter. That is Model 1's 15–18 corroborated, and the number the clock has to
  be sized against — at 20 MHz it is ~1 MIPS against the 2.5 a real V70 at MAME's flat 8 implies.
  The lever is in the core already: the 8-byte `FAST_IFETCH` instruction port (s32 serves it from
  a ROM icache at `clk_sys` latency). The bench's `+FASTIF=1` A/B measures what it is worth before
  any cache is designed.

- **CPU vendored**: meathax/s32's `s32_v60` at `3bce67e`, into `rtl/cpu/v60/` with
  `PROVENANCE.md`. The Sega Model 1 fork was evaluated first and not taken — 25/30 on the suite
  against 30/30, with the two real failures being fixes s32 made after the fork (details in
  PROVENANCE). The core's own thirty benches run under ModelSim here for the first time
  (`scripts/run_v60_tests.sh`): **30/30**, before and after this project's edits.
- **32-bit bus adapter** `rtl/cpu/ms32_v70_bus.sv`, the piece upstream's `IS_V70` never became:
  1..2 aligned 32-bit cycles with byte enables, upstream's four-phase CPU-side handshake kept.
  `sim/v70_bus_tb`: 36/36, every size at every alignment, read and write, value and cycle count.
- **Two edits to the vendored core**, each with its §5(a) notice: `if_addr` widened to 32 bits;
  the prefetch unit no longer issues a read of address 0 during `S_RESET` (found by the trace
  diff — the only discrepancy in the first 16,659 writes). Plus `always @*` → `always_comb` at
  five sites, for the ModelSim time-zero reason recorded in LESSONS_LEARNED.
- **Boot-trace diff against MAME** (`scripts/mame_boot_trace.py`, `compare_boot_trace.py`,
  `sim/v70_boot_tb`): `tetrisp` boots from the reset vector at `0xFFFFFFF0`, jumps to
  `0xFFE01000`, and through 200,000 MAME accesses **every one of 16,659 writes matches in
  address and data, in order**, and every ROM word MAME read was read. A 1.2M-access run is in
  progress; the game is still in its power-on RAM test at that point, so no I/O has been
  exercised yet. At 5M MAME accesses the game has initialised every video RAM, NVRAM, and read
  inputs and DIPs; the first divergence there was MAME taking its first vblank interrupt (delivered
  the instant a `RETI` set IE), which the bench now replays by position — see WORKFLOW §12.
- **Standalone timing and area** (`rtl/synth_check/v70`, Quartus 17.0.2, virtual pins, HIGH
  PERFORMANCE EFFORT): the imported core is **20,701 ALM at 25.1 MHz** with the FP group and
  **18,044 ALM at 45.45 MHz** without; the whole gap is the FP compare/normalise tail
  (`fp_a → f_z`, 39 ns), which s32 constrains away with a multicycle and Model 1 pipelined
  (its fork: 15,755 ALM, 47.21 MHz). 25.1 MHz clears a 20 MHz V70 only if CPI is near MAME's 8,
  which is what criterion 3 measures next; the FP-tail pipelining is the known lever if it is not.
- Found along the way, both recorded: a YMF271 exists in the Seibu SPI MiSTer core and its author
  has confirmed GPL-3 (Phase 3 becomes a port); and `+initreg=r+0` turned an un-evaluated
  `always @*` into a zero that halted the first boot attempt at the reset vector.

**Phase 1 started (2026-09-12): the software model is pixel-exact on its first frame.**
`scripts/mame_capture.py` dumps every video RAM and register block through the CPU's address space
at a chosen frame beside MAME's own screenshot; `scripts/render_model.py` renders that state the way
`ms32_v.cpp` does — TX/BG tilemaps, ROZ (simple and per-line modes), the zoomed sprite engine, and
the priority-RAM mixer case by case — and compares. `tetrisp` frame 1200 (title): **71,680 of 71,680
pixels match.** The tile ROM decryption is verified byte for byte against MAME's post-init regions.
One finding on the way, recorded in LESSONS_LEARNED: sprite order is decided by the draw loop *and*
the priority-masked pixel op — first drawn wins, so MAME's tail-to-head walk puts the highest index
on top. The model is the reference the RTL engines will be checked against, per the Seta pattern.

Since then the model has been run on seven frames across three sets, all 71,680 of 71,680 pixels:
`tetrisp` 1200/2400/4800/7200 (animated sprites, once the sprite RAM was captured at the driver's
vblank copy), `p47aces` 1800 (ROZ simple mode), `gametngk` 3000 and 6000 (ROZ per-line mode,
primask 0xfe shadows, non-square and >1 zooms, ROT270). What each frame covers, and what none does
yet, is tabled in `docs/phase1_video.md`.

## Game scope

Twenty-one sets in `ms32.cpp`, all `MACHINE_IMPERFECT_GRAPHICS`, plus `f1superb` which is also
`MACHINE_NOT_WORKING`. Per-set ROM totals, summed from each `ROM_START`'s `ROM_REGION` declarations:

| set | total | maincpu | sprite | roztiles | bgtiles | txtiles | audiocpu | ymf |
|---|---|---|---|---|---|---|---|---|
| tetrisp | 14.75M | 2M | 4M | 2M | 2M | 0.5M | 0.25M | 4M |
| hayaosi2 | 18.75M | 2M | 9M | 2M | 1M | 0.5M | 0.25M | 4M |
| tp2m32 | 20.75M | 2M | 8M | 2M | 4M | 0.5M | 0.25M | 4M |
| wpksocv2 | 22.75M | 2M | 12M | 2M | 2M | 0.5M | 0.25M | 4M |
| gratia, gratiaa | 24.75M | 2M | 12M | 4M | 2M | 0.5M | 0.25M | 4M |
| suchie2, suchie2o | 25.75M | 2M | 16M | 2M | 1M | 0.5M | 0.25M | 4M |
| hayaosi3, hayaosi3a | 26.75M | 2M | 16M | 2M | 2M | 0.5M | 0.25M | 4M |
| bbbxing, akissa | 27.75M | 2M | 17M/16M | 2M/4M | 2M/1M | 0.5M | 0.25M | 4M |
| kirarast, kirarasta, akiss, bnstars, p47aces, p47acesa | 28.75M | 2M | 16M/14M | 4M | 2M/4M | 0.5M | 0.25M | 4M |
| desertwr, gametngk | 30.75M | 2M | 16M | 4M | 4M | 0.5M | 0.25M | 4M |
| **f1superb** | **56.75M** | 2M | 32M | 8M | 2M | 0.5M + gfx5 8M | 0.25M | 4M |

That table is the first scope decision and it is arithmetic, not preference:

- **In scope: everything up to 30.75 MB.** A 32 MB MiSTer SDRAM module holds the ROM for the
  largest of them with roughly 1.25 MB to spare — see "Memory plan" for what else has to fit and
  what has to move to DDR3.
- **Out of scope: `f1superb`.** 56.75 MB does not fit a 32 MB module, and it is the one set MAME
  itself does not run (road always rendered straight, an undumped maths coprocessor doing
  perspective, `MACHINE_NODEVICE_LAN`). Two independent reasons; it is not a close call.
- **Mahjong sets (`suchie2`, `akiss`, `kirarast`, `bnstars`) are in scope but late.** They need the
  `m_mahjong_input_select` keyboard-matrix path (`0xfd1c0000`) and a mahjong controller mapping in
  the `.mra`, which is separable work.
- **`bnstars1`, the dual-screen Vs. Janshi Brand New Stars, is a different driver** (`bnstars.cpp`)
  and out of scope. `bnstars` — the single-screen MS32 version — is in.

First-target set is **`tetrisp`**: the smallest ROM set (14.75 MB), no mahjong inputs, no ROT270.
`ms32_v.cpp`'s own first line is that this video hardware is "Similar to the Non-MS32 Version of
Tetris Plus 2", so `tetrisp2.cpp` is a second independent description of the same chips to read
against where MS32's own driver is unsure.

## Hardware reality (from the driver, not assumption)

One motherboard (`MB-93140A`) plus a per-game cartridge. Unlike Psikyo there is no board-variant
split to design around: `ms32(machine_config&)` is the only configuration, and the only per-game
machine difference is `ms32_invert_lines` (`tp2m32`, `wpksocv2`), which swaps which of the two
vertical interrupts is vblank and which is the 30 Hz field interrupt.

### Clocks

| part | rate | source |
|---|---|---|
| V70 main CPU | 20 MHz | `XTAL(40'000'000) / 2` |
| Z80 sound CPU | 8 MHz | 8000000 in the driver; the comment offers 40/5 or 48/6 |
| YMF271 | 16.9344 MHz | its own XTAL |
| dot clock | 6 MHz or 8 MHz | `XTAL(48'000'000)` / 8 or / 6, selected by sysctrl `control_w` bit 0 |

Default CRTC setup is `384 × 263` total, `320 × 224` visible, giving 6 000 000 / (384 × 263) =
**59.4106 Hz**. Every one of those numbers is *programmable*: `jaleco_ms32_sysctrl_device::amap`
exposes hblank/hdisplay/hbp/hfp and vblank/vdisplay/vbp/vfp as 12-bit writes, each stored as
`0x1000 - (data & 0xfff)`, and any write re-derives the screen parameters. The core's video timing
therefore has to come from CRTC registers, not from constants — this is a raster generator with a
register file, not a fixed 320×224 MiSTer arcade timing block.

### Interrupts

16 vectored levels. `irq_raise(level, state)` sets or clears a bit in `m_irqreq`;
`irq_callback()` returns the highest set bit, i.e. **highest level wins and the line stays asserted
while any bit is set**. Sources:

- vblank (at `current_scanline == vert_display`) and a 30 Hz "field" interrupt (at scanline 0 on odd
  frames). Which vector each uses is **per game**: `ms32_invert_lines` swaps them, and the driver
  comment records that `tp2m32`/`wpksocv2` want vblank as vector 9 and field as 10 while `p47aces`
  wants the opposite, with `bnstars` locking up if the wrong one runs at 60 Hz.
- a programmable timer (`timer_interval_w`, `control_w` bit 3 enables). MAME's period is
  `500 µs × interval` and is **explicitly a guess** — "TODO: unknown actual timings".
- sound-latch acknowledge: reading `sound_result_r` at `0xfd000000` clears level 1.

Acks go through `irq_ack_w`, `timer_ack_w`, `field_ack_w`, `vblank_ack_w` in the sysctrl.

### Memory map (the `0xc0000000` aliases; hardware also sees them at `0xfc000000`)

| region | window | physical size | width |
|---|---|---|---|
| NVRAM (battery-backed) | `0xc0000000` | 0x2000 | 8 |
| Priority RAM | `0xc1180000` | 0x2000 | 8 |
| Palette RAM | `0xc1400000` | 0x20000 | 16 |
| ROZ1 VRAM | `0xc2000000` | 0x10000 | 16 |
| ROZ1 line RAM | `0xc2200000` | 0x1000 | 16 |
| Sprite (object) RAM | `0xc2800000` | 0x10000 | 16 |
| ASCII/text VRAM | `0xc2c00000` | 0x4000 | 16 |
| Background VRAM | `0xc2c08000` | 0x4000 | 16 |
| Scratch (work) RAM | `0xc2e00000` | 0x20000 | 32 |
| Program ROM | `0xc3e00000` | 0x200000 | 32 |

Every one of those has a large `.mirror()` and the 8- and 16-bit regions sit behind `umask32`, so a
32-bit read of an 8-bit region returns one meaningful byte. I/O lives at `0xfc800000` (sound command
write), `0xfcc00004` (inputs), `0xfcc00010` (DIPs), `0xfce00000`–`0xfce00a7f` (sysctrl, sprite ctrl,
brightness, ROZ ctrl, tx/bg scroll, bgmode), `0xfd000000` (sound result), `0xfd1c0000` (mahjong row
select).

**`ROZ0` is decoded in the comments and not implemented** — `0xfe400000` ROZ0 VRAM, `0xfe600000`
ROZ0 line RAM, `0xfce00400` ROZ0 control. The board has two ROZ planes; MAME models one. Follow
MAME (see "Design decisions").

### Video

Three tilemaps plus a sprite plane, all 8bpp with linear `_raw` gfx layouts — no bitplane
interleave anywhere, which removes the entire class of layout bugs that cost Seta a session:

| layer | tile | map | gfx region | palette base |
|---|---|---|---|---|
| ROZ1 | 16×16 | 128×128 | `roztiles` | 0x2000 |
| BG | 16×16 | 64×64, or 256×16 when `bgmode` bit 0 set | `bgtiles` | 0x1000 |
| TX (ASCII) | 8×8 | 64×64 | `txtiles` | 0x6000 |

VRAM entries are two `u16`: word 0 is the 16-bit tile number, word 1's low nibble is the colour.
Scroll is `scroll[0x00/4] + scroll[0x08/4]` plus a constant (+0x18 for TX, +0x10 for BG), so two
registers sum — copy that, do not pick one.

**ROZ** has two modes, selected by `roz_ctrl[0x5c/4]` bit 0. "Simple" uses one affine transform for
the frame (`startx/starty`, `incxx/incxy/incyx/incyy`, `offsx/offsy`, with sign extension at bit 17
for positions and bit 16 for increments). "Super" reads `lineram[8 * (y & 0xff)]` per scanline for
`start2x/start2y/incxx/incxy` and adds them to the frame registers — a per-line affine transform,
which is the shape a line-rate RTL engine wants anyway. Wrapping is hardcoded on in MAME and the
driver says that is wrong for `p47aces`, `kirarast`, `bbbxing`, `gametngk` and right for `gratia`,
`desertwr`; registers `0x40`/`0x44`/`0x50`/`0x54` are suspected to control it and are not decoded.

**Sprites.** Object RAM is 0x10000 bytes = 0x8000 `u16`, walked 8 `u16` at a time, so **4,096
sprite slots**, of which MAME walks 4,095 every frame (`sprite_tail = size - 8`). The list is copied to a shadow buffer on
vblank (`screen_vblank` → `std::copy_n`) — a copy, not a bank swap, and LESSONS_LEARNED has an entry
on why that distinction is not cosmetic. `sprite_ctrl[0x10/4]` bit 15 clear means **walk the list in
reverse**, which several games need. Per sprite: 4-bit priority, flipx/flipy, a disable bit,
`code` selecting one of 4096 256×256-pixel pages, `tx`/`ty` picking the starting 8×8 tile within the
page, `srcwidth`/`srcheight` in pixels (1..256), signed 10-bit X and 9-bit Y, and 16-bit `incx`/
`incy` zoom where 0x100 is 1:1.

Sprite graphics are 8bpp 8×8 tiles (64 bytes each) laid out as a 32×32 grid per 256×256-pixel
page, row-major, so a page is 65,536 bytes:

```
byte(page, x, y) = page*65536 + ((y>>3)*32 + (x>>3))*64 + (y&7)*8 + (x&7)
```

That is read off `sprite_xoffset`/`sprite_yoffset` in `ms32_sprite.cpp`, which state the layout as
256-entry `EXTENDED_XOFFS`/`EXTENDED_YOFFS` tables rather than as a stride — so **check it with the
"every bit of a tile exactly once" test** from LESSONS_LEARNED before writing address arithmetic
against it. A 16-pixel run is 16 contiguous bytes, which makes
sprite fetch burst-friendly, unlike Seta's `RGN_FRAC(1,2)` split.

**Palette** is 0x8000 entries, two `u16` each: word 0 is `RRRRRRRR GGGGGGGG`, word 1's low byte is
blue. A global brightness register (`ms32_brightness_w`) scales R, G and B by `0x100 - value`, and
is skipped for any colour with bit 14 set. There is a second brightness register, written only by
`gametngk`, `tetrisp`, `tp2m32` and `gratia`, whose function is unknown. The driver header records
that the first register's real behaviour is not understood either — that it cannot be right for it
to reach full black, because `kirarast`'s attract mode depends on it not doing so, and that
brightness "breaks other games in various places". Treat the whole brightness path as a known
divergence to be measured against captures, not as a modelled mechanism.

**Mixing is the least-known part of the hardware.** The driver's own first line is "hardware tests
are needed to establish how the mixing really works". The 0x2000-byte priority RAM is clearly a
lookup table; MAME probes eight fixed addresses of the form `spritepri | 0x0a00 | 0x1500` to build an
8-bit `primask`, derives three layer priorities from three more fixed probes
(`0x2b00`, `0x2e00`, `0x3a00`), and then runs a per-pixel if-else chain that the source itself labels
"spaghetti code", "complete guesswork and missing many spots". Whatever the real chip does, MAME's
output is the only reference available.

### Sound

Z80 at 8 MHz with two banked 16 KB windows, 16 KB of RAM, and the YMF271 at `0x3f00`-`0x3f0f`.
The V70 writes `0xfc800000` to load the latch and raise the Z80's NMI; it reads the return byte,
inverted, at `0xfd000000`, and that read also acknowledges interrupt level 1. MAME additionally
spins the V70 for 40 µs after a sound command — a synchronisation hack with no hardware counterpart,
and the kind of thing that turns into a real race in RTL.

YMF271: 48 slots in 12 groups of 4; each group can be one 4-op FM channel, two 2-op FM channels, one
3-op FM channel plus one PCM channel, or four PCM channels. Sample ROM is 4 MB
(`device_rom_interface<23>`). Both outputs 0 and 1 are routed; 2 and 3 are unused on this board.

### ROM encryption

`txtiles` and `bgtiles` are encrypted on every set, with four key pairs selected by the cartridge's
custom chip (`init_ss91022_10`, `init_ss92046_01`, `init_ss92047_01`, `init_ss92048_01`). The
transform in `jalcrpt.cpp` is `dest[i] = src[L(i ^ addr_xor)] ^ (i & 0xff) ^ data_xor`, where `L` is
a cascade of conditional XORs — i.e. a **GF(2)-linear map** on 19 address bits (tx) or 20 (bg).

I checked this rather than assuming it: both maps are linear (verified against 2,000 random pairs
each) and invertible (Gaussian elimination over GF(2) succeeds, and `L⁻¹(L(x)) == x` for the first
5,000 values of each). `L⁻¹` is itself a 19- or 20-term conditional-XOR cascade. **So decryption can
run inside the ioctl download path**: for each incoming source byte at stream offset `j`, write it to
`i = L⁻¹(j) ^ addr_xor` with data `src ^ (i & 0xff) ^ data_xor`. No offline ROM modification, no
`.mra` trickery, about forty lines of RTL and a table of four key pairs selected by the `.mra` mod
byte. Per LESSONS_LEARNED, that mod byte must be listed as `<rom index="1">` **before**
`<rom index="0">`, because it gates download-time logic.

## The CPU

### There is a V60/V70 core, and it runs on hardware

`s32_v60` — an instruction-accurate microsequenced V60/V70 in SystemVerilog, written for the Sega
System 32 core ([meathax/s32](https://github.com/meathax/s32), GPL-3.0-or-later) and carried into
the Sega Model 1 core
([alphanu1/sega-model1-mister](https://github.com/alphanu1/sega-model1-mister), GPL-3.0-or-later,
which split the fetch unit out and reworked the FP tail). Both boot games on a DE10-nano with it.

Its own header states the contract: "Behavioral contract is MAME's v60 core (BSD-3-Clause,
Farfetch'd / R. Belmont): opcode dispatch per `optable.hxx`, addressing modes per `am1-3.hxx`,
exception entry per `v60.cpp`" — the same specification this project would have written against.
Scope, per that header: full integer ISA, string ops including the fill/stop variants, `TASI`, bit
ops, `PREPARE`/`DISPOSE`, `PUSH(M)`/`POP(M)`, `GETPSW`/`UPDPSW`, `TRAP`/`TRAPFL`/`BRK`/`BRKV`,
`CHLVL`, task save/load, `LDPR`/`STPR`, the decimal and bit-field groups, and single-precision FP
(`0x5C`/`0x5F`). Not implemented: the sub-opcodes MAME itself leaves `UNHANDLED`, and MMU/TLB
effects — absent exactly as they are in MAME.

`s32/verif/v60/` carries 37 testbenches and `s32/verif/cosim/` a differential harness against a
Python V60 reference plus a MAME tracing patch. That apparatus is the "diff the CPU against MAME"
test this roadmap would otherwise have had to build, and it arrives with the core.

**Correction to an earlier draft of this document:** MAME's V60 is *not* missing floating point. The
FP opcodes (`ADDFS`, `MULFS`, `DIVFS`, `CVTWS`, `CVTSW`, ...) dispatch through the `0x5C`/`0x5F`
escapes, which is why grepping `optable.hxx` alone does not show them. `opTRAPFL` `fatalerror`s on an
FP *trap*, not on FP arithmetic. What is true: 54 of the 256 primary opcodes are `opUNHANDLED`, no
TLB, and 295 distinct `op*` handler names across the primary and extended tables.

### What is actually missing for V70

`IS_V70` exists but is half-wired. Three gaps, all bounded:

1. **The bus adapter is 16-bit.** `s32_v60_bus` issues 1..3 aligned 16-bit cycles on `m_addr[23:1]`.
   Its header says "V70 (`IS_V70=1`) uses 1..2 aligned 32-bit cycles" and the parameter is declared,
   but no code branches on it — `v60.sv`'s own header admits "the parameter is unused". MS32 needs a
   new 32-bit adapter. The CPU-side port is already `c_addr[31:0]`, so this is one module rewritten,
   not the core.
2. **The fast instruction-fetch port is 24-bit.** `v60_ifetch.sv` does
   `assign if_addr = pf_addr[23:0]`. MS32's program ROM is at `0xFFE00000`, so this widens to 32.
   Checked: every other `24'` in `v60.sv` is `{24'b0, byte}` zero-extension, not address truncation.
3. **`IS_V70` otherwise only selects PIR** (`0x00007000` vs `0x00006000`) — which is exactly what
   distinguishes the two in MAME, where `v70_device` is `v60_device` with databits 16→32,
   addrbits 24→32 and that PIR. Nothing else in MAME's model differs, and MAME is the target.

MS32 also never touches the `IN`/`OUT` I/O space — `ms32_map` declares no `AS_IO` — which removes the
one thing Model 1 had to fix in the imported core.

### The real gate is throughput, not correctness

The Model 1 project measured its V60 honestly, and those numbers are why Phase 0 still exists:

> Our V60 executes ~1.28 MIPS (19.2 MHz at CPI ~15) against real silicon's ~2.0 (16 MHz at CPI ~8).

and on the shipped build:

> The V60 runs at 23.529 MHz and a mean CPI of ~17.9 against the ~12.5 real time needs, so the game
> gets about **70% of the real board's work done per frame** — which is the VR slowdown.

MS32's V70 is nominally 20 MHz at MAME's flat 8 CPI, i.e. 2.5 MIPS. At CPI 15 that wants a 37.5 MHz
CPU clock. Measured standalone Fmax after Model 1's FP-unpack pipelining is **38.19 MHz** (up from
35.38), and **45.98 MHz with the FP group removed** — so the target is at the edge of reach rather
than out of it, and whether MS32 needs the FP group at all is a measurable question (a MAME tap on
`0x5C`/`0x5F` dispatch across the game list answers it).

What makes it plausible is where the cycles go. Model 1 measured 30.49 CPI decomposed as ~20 waiting
on memory and ~10 executing, with the core "close to the reference already — ~6 CPI in isolation
against MAME's implied ~8", and separately measured its bus adapter costing ~9 CPU cycles of fixed
handshake per access *regardless of what memory is behind it*. **Most of the gap is the bus adapter,
and MS32 is writing a new one anyway** — 32-bit path, work RAM in single-cycle BRAM rather than
SDRAM, wide instruction port. That is the Phase 0 experiment.

### The cost

Model 1's per-entity figures, Quartus 17.0, same device:

| | |
|---|---|
| V60 in-core | **15,684 ALM** (14,687 monolith + 897 `v60_ifetch`) |
| V60 standalone | 20,129 ALM — the fitter cannot optimise across the boundary, so use the in-core figure |
| Whole Model 1 design | 36,979 / 41,910 ALM (88%), 504 / 553 M10K (91%), 53 DSP |

The CPU is **~37% of the device's ALMs** before MS32 writes a line of its own. Model 1 fits a
flat-shaded 3D rasterizer and a floating-point DSP alongside it; MS32's video is 2D and should be
cheaper than Model 1's `m1_raster3d` (6,977 ALM) plus `m1_tgp` (2,434 ALM) — but "should be" is not a
budget. M10K is the number to watch, because the RAM budget below already puts MS32's game RAM at
74.6% on its own and Model 1 shipped at 91% with its CPU in the same device.

## The YMF271

No FPGA implementation. The nearest starting point in-house is **Psikyo's from-scratch YMF278B
(OPL4) core** in `Arcade-Psikyo_MiSTer/rtl/sound/opl4/` — a comparable chip (FM plus a
wavetable/PCM engine reading a multi-megabyte sample ROM through the SDRAM arbiter) written against
`ymfm` as the behaviour reference, with its sample cache, envelope pipeline and SDRAM client
structure all directly relevant. `ymfm`'s `ymf271` model and MAME's `ymf271.cpp` are the spec.

This is Phase 3 work, and it is **a port, not a from-scratch block**: the YMF271 in the Seibu SPI
MiSTer core is GPL-3 by its author's confirmation (see "Open items"), pending the LICENSE file
landing upstream. Psikyo's OPL4 remains the in-house reference for the SDRAM sample-cache shape.

## The mixer

Not large, but the least determinable part of the hardware, and the one thing here that genuinely
has no prior implementation to borrow. See "Design decisions" for how it is being approached.

## On-chip RAM budget

This design is **BRAM-bound before a line of video RTL exists**, and the arithmetic has to be done
now rather than discovered in a fitter error. The DE10-nano's `5CSEBA6U23I7` has 553 M10K blocks =
5,662,720 block memory bits.

| RAM | bytes | bits | % of device |
|---|---|---|---|
| Palette | 131,072 | 1,048,576 | 18.5% |
| Scratch (work) RAM | 131,072 | 1,048,576 | 18.5% |
| ROZ1 VRAM | 65,536 | 524,288 | 9.3% |
| Sprite RAM | 65,536 | 524,288 | 9.3% |
| Sprite RAM shadow copy | 65,536 | 524,288 | 9.3% |
| TX VRAM | 16,384 | 131,072 | 2.3% |
| BG VRAM | 16,384 | 131,072 | 2.3% |
| Z80 RAM | 16,384 | 131,072 | 2.3% |
| Priority RAM | 8,192 | 65,536 | 1.2% |
| NVRAM | 8,192 | 65,536 | 1.2% |
| ROZ line RAM | 4,096 | 32,768 | 0.6% |
| **Total** | **528,384** | **4,227,072** | **74.6%** |

And that is *before* anything the core needs for itself. The single item that will not fit is the
one Psikyo used and this design would naturally reach for: **a sprite frame buffer.** 320 × 224 at
16 bits per pixel (12-bit palette index + 4-bit priority) is 1,146,880 bits, 20.3% of the device,
and double-buffered 40.5%. 74.6 + 40.5 = 115%. It does not fit, and no repacking makes it fit —
LESSONS_LEARNED's entry on being BRAM-bound at 40% logic says exactly this: at ~95% of block memory
bits a design cannot be repacked into fitting, only made smaller.

Sprites also cannot be rendered per-scanline the way Seta's were. Seta walks 512 foreground entries
per line; MS32 has **4,096**, and 4,096 × 263 lines is not a budget, it is a refusal.

So: **the sprite frame buffer lives off-chip**, with a double-buffered one-scanline prefetch in BRAM
so that the display side never waits on external latency. That is the single structural decision
this budget forces, and it should be designed in from the start rather than retrofitted.

Two further notes, both from LESSONS_LEARNED and both cheap now and expensive later:

- Every inferred RAM gets a **power-of-two depth**. 3,072 entries once stopped being an M10K
  silently and took a Seta build 55% over the LAB count with a fitter error that named nothing.
- Any true dual-port array is **one `always_ff` with both ports in it**. Two blocks writing one array
  builds it out of logic; an 8 KB register file done that way needed 122,886 combinational nodes
  against the device's 83,820.

## Memory plan

Target: a **32 MB** MiSTer SDRAM module, because that is what most people have. Largest in-scope ROM
set is 30.75 MB.

| what | where | why |
|---|---|---|
| `maincpu`, `sprite`, `roztiles`, `bgtiles`, `txtiles`, `audiocpu` | SDRAM | hard real-time fetch budgets; ≤26.75 MB for every in-scope set |
| `ymf` sample ROM (4 MB) | DDR3 | latency-tolerant behind a sample cache; frees the 4 MB that makes 30.75 fit in 32 |
| Sprite frame buffer (double) | DDR3 | 2.29 Mbit, cannot be BRAM; sequential reads behind a scanline prefetch |
| Everything in the RAM table above | BRAM | CPU-random-access or pixel-rate |

The SDRAM-over-DDRAM rule in LESSONS_LEARNED is about *hard real-time fetch budgets* — tilemap and
sprite graphics fetch with a per-scanline deadline. Neither of the two DDR3 consumers here has one:
the sample cache absorbs latency by prefetching ahead of the sample rate, and the frame buffer's
display side reads a whole scanline ahead. Both need that stated in their port comments, and both
need measuring rather than assuming — `tb_video_pipeline_ddram.sv` in the Psikyo tree is the shape
of the measurement.

Open question for Phase 1, to be settled by measurement not argument: whether the sprite frame
buffer is better placed in the SDRAM's spare ~1.25 MB than in DDR3. It is written by the sprite
engine at high rate while the same SDRAM is serving sprite graphics fetch, which argues for DDR3;
it is read at pixel rate, which argues for neither once a scanline prefetch exists.

## Component reuse map

| block | plan | source |
|---|---|---|
| **V70 CPU** | **Vendor `s32_v60` with `IS_V70=1`.** New 32-bit bus adapter and a 32-bit `if_addr` are ours; the core is not. **GPL-3.0-or-later — see Design decisions** | [meathax/s32](https://github.com/meathax/s32) via [alphanu1/sega-model1-mister](https://github.com/alphanu1/sega-model1-mister); `mame/src/devices/cpu/v60/` remains the behavioural spec |
| Z80 sound CPU | **T80** (Daniel Wallner), as used by Psikyo/Fuuki/Seta | vendored, with `PROVENANCE.md` |
| **YMF271** | **From scratch** — now the largest such block — starting from Psikyo's OPL4 core's structure. Search other cores first | `Arcade-Psikyo_MiSTer/rtl/sound/opl4/`, `ymfm`, MAME `ymf271.cpp` |
| SDRAM backend | Psikyo/Seta's `sdram.sv` + arbiter + download path, **including Seta's `dq_in` capture fix** | `Arcade-Seta_MiSTer/rtl/memory/` |
| DDRAM backend | Psikyo's `ddram_phy`/`ddram_arbiter`/`ddram_download` | `Arcade-Psikyo_MiSTer/rtl/memory/` |
| Tilemap engines | Custom, but the line-engine shape (prefetch ring, `ce_pix` display side, req/valid gfx fetch) is settled work | Psikyo `tilemap_line_engine.sv` as the pattern |
| ROZ engine | Custom. Per-line affine walk; "super" mode is the general case and "simple" is it with constant line registers | `ms32_v.cpp:draw_roz` |
| Zoom sprite engine | Custom, but Psikyo's display-list-walk → attribute → zoom → gfx fetch → pixel write pipeline is the pattern | Psikyo `sprite_render_engine.sv` et al |
| Mixer | Custom. See "Design decisions" | `ms32_v.cpp:screen_update` |
| CRTC | Custom — MS32's is programmable, so this is a register file driving a raster generator | `jaleco_ms32_sysctrl.cpp` |
| ROM decrypt | Custom, in the download path. `L⁻¹` cascade, four key pairs by mod byte | `jalcrpt.cpp` |
| NVRAM persistence | `hiscore.v`-style pause-and-borrow-a-BRAM-port, or the framework's save path | MiSTer-devel |
| Debug probe, tracer, counters, pause | Port from Seta with header comments intact | `Arcade-Seta_MiSTer/rtl/debug/` |
| CPU verification harness | **Reuse as-is**: 37 unit benches plus a differential harness against a Python V60 reference and a MAME tracing patch | `s32/verif/v60/`, `s32/verif/cosim/` |
| Top-level framework | **MiSTer-devel/Template_MiSTer** (already checked in) | this repo's `sys/` |

## Design decisions

**Clock plan: two domains, because the CPU cannot live in the fast one.** An earlier draft put
everything on one 96 MHz `clk_sys` with the V70 on a 5-in-24 clock enable. That is not available:
`s32_v60` measures 38.19 MHz standalone, and Model 1 runs it on a dedicated `clk_cpu` at 23.529 MHz
while its memory and video run at 80 MHz. So MS32 gets the same shape.

| domain | consumer | rate | derivation |
|---|---|---|---|
| `clk_sys` | dot clock (default) | 6 MHz | 96 / 16 |
| `clk_sys` | dot clock (alternate) | 8 MHz | 96 / 12 |
| `clk_sys` | Z80 | 8 MHz | 96 / 12 |
| `clk_cpu` | V70 | **20 MHz** (960 MHz VCO / 48), `ce = 1` | CPI 8.48 measured; 24 MHz (/40) held in reserve |
| own output | YMF271 | 16.9344 MHz | its own PLL output |

One VCO serves both: 960 MHz gives 96 (/10) and 20 (/48) exactly, and any `clk_cpu` the Phase 0
measurement asks for has to be checked for an exact divide before it is adopted.

**The CPU clock rate is an output of Phase 0, not an input to it — and the measurement is in.**
CPI on `tetrisp` boot code with ideal memory is 8.48 against MAME's flat 8, so at exactly 20 MHz
the core does ~94% of MAME's V70 work per frame. The plan is therefore **`clk_cpu` = 20 MHz
exact** (960 MHz VCO: /48; `clk_sys` 96 MHz is /10), the original rate, with two levers held in
reserve and both already measured: 24 MHz (/40) buys the 6% back and is a documented divergence
for `docs/MAME_DIVERGENCE.md`; pipelining the FP tail the way Model 1 did takes the core's
standalone Fmax from 25.1 to ~45 MHz and is the answer if the in-design margin at 20 MHz proves
thin. What the SDRAM-backed ROM does to the 8.48 is Phase 2's first measurement, and the s32
instruction cache (`FAST_IFETCH`) is the lever for that one.

**The CPU/system clock crossing is real design work and Model 1 has already solved it once.** Read
`m1_integrated.sv`'s domain notes before writing a synchroniser.

**This core is GPL-3.0-or-later. Decision taken; `LICENSE` carries the GPLv3 text.** `s32_v60` is
GPL-3.0-or-later, so anything containing it must be too. That combination is lawful only because
every file in `sys/` reads "either version 2 of the License, or (at your option) any later version"
— the or-later clause permits using `sys/` under GPL-3.

The consequence is permanent in one direction: **code can flow in from GPL-2-or-later MiSTer cores
and cannot flow back out to them.** Undoing it means replacing the CPU with an independently written
core. Psikyo, Fuuki and Seta already carry the same GPLv3 text, so this is not a divergence from the
sibling projects.

What it obliges, in full, is in [`THIRD-PARTY.md`](../THIRD-PARTY.md). The part that bites during
development: **GPLv3 §5(a) requires every modified file to carry prominent notice that it was
changed, and a date.** Both upstreams already do this at the top of each file. Our changes append to
that block; they never replace it, and the notice is not a comment to tidy away.

**Follow MAME, including where MAME is wrong, and write down every place that is.** There is no MS32
PCB here. MAME's output is the accuracy target, which means its acknowledged guesses are inherited
deliberately: the brightness model, always-on ROZ wrapping, the unimplemented ROZ0 plane, the
500 µs programmable-timer period, the priority-RAM probe addresses. Each of those goes in
`docs/MAME_DIVERGENCE.md` when it is implemented, with what MAME does, what the hardware is suspected
to do, and what would settle it. Seta's file of the same name is the model.

**Transcribe the mixer from MAME literally first, then look for the table.** The priority RAM is
0x2000 bytes and MAME reads eleven fixed addresses out of it. The temptation is to infer the real
lookup and implement that; the Psikyo lesson "read both halves of a mechanism before changing it"
says not to, and here we cannot read the other half at all. Build MAME's version, get pixel-exact
agreement with captured frames, and only then experiment — with the experiment on an OSD switch so
it is an A/B, not a rebuild.

**One `.rbf` for all games.** Per-game differences are: the `ms32_invert_lines` interrupt swap, the
four decryption key pairs, ROM region sizes, mahjong inputs, and screen rotation. All of those are
`.mra` mod-byte configuration, not compile-time.

**Two Quartus revisions, `MS32_stp` and `MS32`,** differing only by a `DEBUG_ISSP` macro,
as in Seta. See [`WORKFLOW.md`](WORKFLOW.md).

## Pitfalls that already bind decisions here

These are the entries from [`LESSONS_LEARNED.md`](LESSONS_LEARNED.md) that are not general advice for
this project but already constrain something written above. Read the entry, not the summary.

| Entry | What it binds here |
|---|---|
| *Suspect your own integration before any vendored module* | The CPU is now vendored, proven on two shipping cores. When MS32 misbehaves, the bus adapter and the memory map are ours and the core is not — rank hypotheses accordingly |
| *Treat a conspicuous omission in a vendored module as deliberate* | `IS_V70` is declared and unused in `s32_v60_bus`. That is an unfinished feature rather than a deliberate omission — but read both upstreams' notes before assuming which |
| *Re-run the regression on a clean stash before debugging your change* | The imported core arrives with 37 passing benches. Run them on arrival, before touching anything, so a porting failure is never mistaken for a V70 change |
| *A design can be BRAM-bound while logic sits at 40%* | The whole "On-chip RAM budget" section. 74.6% before any core RAM, and the sprite frame buffer moved off-chip because of it |
| *An inferred RAM must have a power-of-two depth* | Palette is 0x8000 entries and ROZ line RAM 0x800 — both already powers of two, but NVRAM, priority RAM and every cache must be checked |
| *A true dual-port RAM must be ONE always block* | Palette needs two simultaneous reads per pixel (Psikyo's compositor did); it must be written in the shape Quartus infers |
| *Driving a dual-port RAM's second read port can silently REPLICATE the array* | Same array. The mixer's two lookups and the CPU's port cannot be three independent addresses |
| *A region whose base is not aligned to its size must be indexed by subtraction* | BG VRAM is at `0xc2c08000` inside the same 0x8000-aligned decode as TX VRAM at `0xc2c00000`; the palette sub-banks (object 0x0000, bg 0x8000, roz1 0x10000, roz0 0x20000, ascii 0x30000) are offsets, not maskable windows |
| *The self-tests walk the whole SRAM chip, not the window the custom chip uses* | Every region above is declared with a large `.mirror()`. Model the mirrors, and back the full declared size, before concluding a boot failure is a transport bug |
| *An unbacked RAM region does not read as garbage, it reads as a failed power-on memory test* | NVRAM especially: it is battery-backed, and a game that fails its own NVRAM check runs a different program |
| *A mirrored work-RAM block reads as a CPU that executes an illegal instruction* | Scratch RAM is 0x20000 with a 0x3c0e0000 mirror. Get the mirror wrong and the stack aliases |
| *Never hold the memory path in the core reset* | The decryption unit sits in the download path, which runs entirely while MiSTer holds core `RESET` asserted |
| *List `<rom index="1">` before `<rom index="0">` when a mod byte gates download-time logic* | The decryption key selection is exactly that case |
| *Treat the map-digit rule as mechanical and check it* | `maincpu` is `ROM_LOAD32_BYTE` ×4, `sprite` is `ROM_LOAD32_WORD` pairs, tiles are plain `ROM_LOAD`. Three different interleaves in one `.mra` |
| *Prove the interleave against MAME's disassembly offline, before building* | Applies with more force than usual: there is no 68k idiom to recognise in a V70 reset vector, so the check must be mechanical |
| *A swap is not a copy* | `screen_vblank` does `std::copy_n` into the sprite shadow buffer. Do not ping-pong it |
| *A double buffer puts the renderer TWO lines ahead, not one* | The scanline prefetch in front of the off-chip sprite frame buffer |
| *Put a time budget just below the period, not at it* | The sprite engine's per-frame cutoff, and the prefetch's per-line one |
| *A back-to-front line buffer cannot drop the right sprites* | 4,096 slots and `sprite_ctrl[0x10/4]` bit 15 selecting reverse order. Overflow must drop the sprites the chip draws first, not last — carry the index, do not encode priority in write order |
| *Estimate the worst case from the hardware, not from the frames you happened to look at* | 4,096 is what the engine walks. Instrument the RTL for worst-line and worst-frame counts from the first build |
| *Copy a driver's register expression including its operators* | `disable = (~attr & 0x0004)`, `reverseorder = (ctrl & 0x8000) == 0x0000`, brightness `0x100 - value`, CRTC `0x1000 - (data & 0xfff)`. Four inverted senses before any video RTL exists |
| *Give a held interrupt line's acknowledge priority* | `irq_callback` returns the highest set bit and the line stays asserted while any bit is set. Acknowledge must win over a simultaneous raise |
| *DTACK/ready must be a held level, never a pulse, for any clock-enabled CPU* | The CPU sits in its own slower clock domain, so every ack crossing into it must be a level that survives the crossing, not a `clk_sys` pulse |
| *Derive the clock-enable ratio exactly rather than rounding* | 5/24 is exact. 96/5 = 19.2 MHz and 96/4 = 24 MHz are both meaningfully wrong |
| *Budget for the CPU core to be the Fmax-limiting block* | Phase 0's entire purpose |
| *A constraint proved in a side project is not in your design* | Phase 0 is a side project. Its SDC moves with its measurement, in the same commit |
| *A clean STA summary is a property of one placement, not of the design* | The seed is recorded in `BUILT_COMMIT`. When a build regresses games the diff cannot reach, rebuild the same commit at another seed first |
| *Open the STA summary before believing any hardware-vs-simulation divergence* | `build_staged.py` gates on it; do not route around the gate |
| *A bidirectional bus captured into four lane registers gets one I/O register and three lottery tickets* | Port Seta's fixed `sdram.sv`, the one that does `dq_in <= SDRAM_DQ` unconditionally, not an older copy |
| *A correct `.mra` DIP block still needs one line in CONF_STR* | Three 8-position DIP banks. `"DIP;"` goes in CONF_STR in the same commit as the first `.mra` |
| *Make the all-zero configuration the correct one* | Every OSD debug switch, from the first one |
| *Ask of every stimulus whether it is the shape the real system produces* | vblank is held for a whole blanking interval, and the V70's interrupt line stays asserted while any level is pending |
| *A liveness test needs a timescale* | MS32 boot length is unknown. Measure it with `mame_capture.py --boot-trace N` before asserting that anything should have happened by frame N |
| *Reduce by the driver's screen height, not the RTL's* | MAME's `time_until_pos()` wraps modulo the **driver's** declared height, which for MS32 is whatever the CRTC was last programmed to — itself variable. Derive the line period, do not assume 263 |

## Phased roadmap

**Phase 0 — V70 bring-up and throughput spike. The gate for the whole project.**
Vendor `s32_v60` into `rtl/cpu/v60/` with a `PROVENANCE.md` recording the meathax/s32 →
alphanu1/Model 1 → here chain and the upstream commit it was taken from. The licence side is already
settled — see [`THIRD-PARTY.md`](../THIRD-PARTY.md) — so what remains is keeping each file's §5(a)
notice correct as it is edited. Write the 32-bit bus adapter, widen
`if_addr`, and stand the result up in its own Quartus project (`rtl/synth_check/`, Seta's pattern)
holding the CPU, the bus and the SDRAM transport and nothing else. Exit criteria:

1. **The imported unit suite passes unchanged, before anything is modified** — `verif/v60/`'s 37
   benches and `verif/cosim/run_diff.sh`'s differential seeds. A vendored core that fails its own
   tests on arrival is a porting problem, and finding that out after MS32-specific edits is how a day
   gets lost. Then re-run it after the V70 changes, as the regression it now is.
2. **Boots `tetrisp`'s program ROM and matches MAME's bus trace**, diffed access by access as a
   subsequence with duplicates collapsed (Seta's method), every peripheral stubbed to whatever
   MAME's would return. This is what catches a V70-vs-V60 divergence that the V60's own tests cannot
   see, because none of them ran with 32-bit addresses or a 32-bit bus.
3. **Measured CPI on real game code**, against the 2.5 MIPS a 20 MHz V70 at MAME's 8 CPI implies.
   Report the split between execution and memory stall the way Model 1 did — the number that matters
   is not CPI but which half of it the new bus adapter can move.
4. **Fits and closes timing at the CPU clock (3) demands**, on real Cyclone V speed grade 7, with the
   constraint that proves it committed **in the same commit as the measurement**. Starting points:
   38.19 MHz standalone, 45.98 MHz with the FP group removed if a MAME tap shows no MS32 game
   dispatches `0x5C`/`0x5F`.

If (3) and (4) cannot together reach real-board throughput, that is a decision point rather than
necessarily a stop — Model 1 ships at ~70% and says so in its release notes. What is not acceptable
is discovering it in Phase 4.

**Phase 1 — Video, on a CPU that works.**
CRTC register file and raster generator; TX, BG and ROZ1 line engines; the zoom sprite engine with
its off-chip frame buffer and scanline prefetch; palette and brightness; the mixer transcribed from
MAME. Verified in simulation against MAME-captured VRAM/vreg/spriteram dumps at known frames before
any of it reaches hardware. Exit criteria: `tetrisp` renders frames pixel-identical to MAME's for a
captured set of scenes, silent.

**Phase 2 — Hardware bring-up and the first games.**
SDRAM backend with all clients, the decryption download path, `.mra` generation, inputs and DIPs,
NVRAM persistence, the ISSP probe and OSD debug page. The CPU's program ROM goes behind an
instruction cache from the start, not as a later optimisation: the 8.48 CPI was measured with
single-cycle memory, and s32 already has the shape to port — a direct-mapped cache of 64 eight-byte
lines (`s32_core.sv`, `S32_AREA_ROM_CACHE`) serving the core's `FAST_IFETCH` port at `clk_sys`
latency from one burst SDRAM client, with the data-side ROM reads sharing the same client. The
first Phase 2 measurement is the CPI with that in place against the SDRAM model, so that the
ideal-memory figure is not mistaken for the board's. Exit criteria: `tetrisp`, `hayaosi2` and
`tp2m32` boot and play on a DE10-nano, silent, with the `ms32_invert_lines` interrupt variant
exercised by `tp2m32`.

**Phase 3 — YMF271.**
From scratch, against `ymfm` and MAME as the spec, starting from the OPL4 core's structure. Sample
ROM in DDR3 behind a cache. Exit criteria: register-write traces captured from MAME reproduce
recognisably correct audio, verified by ear and by a decoded capture.

**Phase 4 — The rest of the game list, and accuracy.**
Mahjong inputs, ROT270 sets, per-game `.mra` files including every clone, the ROZ wrapping question,
the second brightness register, the priority-RAM experiments. `docs/MAME_DIVERGENCE.md` is the
deliverable that says what is still not right and what would settle it.

**Phase 5 — Savestates.** Not before Phase 4. Psikyo's `docs/savestates.md` is the feasibility study
and its conclusions mostly transfer. The CPU is no longer a self-dump-stub problem the way the 68020
was — a vendored SystemVerilog core with an explicit register file can expose state directly, which
is the T80 situation rather than the TG68K one — and a from-scratch YMF271 can be built with a state
port from the start if Phase 3 knows it is wanted.

## Verification strategy

- **MAME is a reference generator, driven from scripts, not a thing to eyeball.** Boot traces, VRAM
  and register dumps at known frames, palette dumps, register-write logs. All of WORKFLOW section 8
  applies, including its traps.
- **The CPU is verified by trace diff against MAME, not by "it boots".** For a CPU this size that
  distinction is the project.
- **Layouts are verified before ROMs are involved**: the sprite `gfx_layout` gets the "every bit of a
  tile exactly once" check.
- **The decryption is verified offline**: decrypt a real `txtiles` ROM with the RTL's own `L⁻¹`
  expressed in Python and compare byte-for-byte against MAME's `decrypt_ms32_tx` output.
- **`.mra` files are generated, not written**, re-read and compared byte-for-byte against an image
  built from `ROM_START`, and gated on an XML well-formedness check before every deploy.
- **Worst cases are measured in the RTL**, not modelled in Python. Sprite slots walked per frame,
  pixels written per line, fetch stalls — counters with no reset port, saturating, each paired with a
  total.

## Repository setup

Seeded from **MiSTer-devel/Template_MiSTer** (`sys/`, `rtl/`, `files.qip`, `Template.*` — the
`Template.*` files get renamed to `JalecoMS32.*` when the first RTL lands). Quartus **17.0.2**, which
is what the MiSTer developer reference names as the version the vast majority of cores use and what
the previous three cores were built with.

Conventions, all carried over and all described in [`WORKFLOW.md`](WORKFLOW.md):

- **The project is `MS32`, in two revisions** — `MS32_stp` (instrumented: `DEBUG_ISSP=1`, the OSD
  Debug page visible) and `MS32` (release, both compiled out) — one source, two `.qsf` files
  identical above their last block. The first staged build of `MS32_stp` (the template demo plus
  the Debug-page gating, 2026-09-12) ran every gate and produced an `.rbf` in 4.5 minutes.
- **Builds are staged, never in-tree.** `scripts/build_staged.py` snapshots HEAD into a git worktree
  at `build/` (gitignored) and runs Quartus there. A dirty tree is refused by default. It gates on
  negative slack on **every** clock, checks that required blocks survived to the fitted netlist,
  checks that required `VERILOG_MACRO`s are defined, and records commit, timestamp and fitter seed in
  `build/BUILT_COMMIT`.
- **Build and probe are mutually exclusive, enforced not remembered.** `scripts/hwlock.py` holds a
  machine-wide marker beside the user profile, shared with the Psikyo, Fuuki and Seta repositories on
  this PC. A JTAG tool refuses to start while Quartus or ModelSim is running; a build or a simulation
  refuses to start while a JTAG tool holds the marker. Concurrent JTAG and Quartus bugchecked this PC
  three times (`KERNEL_SECURITY_CHECK_FAILURE`, 0x139).
- **Two revisions from one source**: `MS32_stp` (ISSP probes + OSD Debug page) and
  `MS32` (both compiled out), differing only by `DEBUG_ISSP` in the `.qsf`.
- **Releases** are the `.rbf` plus the whole `.mra` set together under `releases/`, parents at the
  top level and clones in `releases/_alternatives/`. They are coupled: the SDRAM layout is encoded in
  both.
- **Branching**: `develop` carries granular commits, squashed onto `master` at milestones. ROMs live
  in `roms/` and are gitignored.
- `.gitattributes` pins `*.sh` and this project's `.tcl`/`.lua` to LF. With `core.autocrlf` on, a
  `git reset --hard` gives them CRLF and bash rejects `set -euo pipefail\r` on line 1.
- **Licence: GPL-3.0-or-later**, forced by the vendored CPU. Every dependency, what it obliges and
  the release checklist are in [`THIRD-PARTY.md`](../THIRD-PARTY.md). `sys/` is never edited.

## Open items

- **No MS32 PCB.** MAME's output is the accuracy target including its acknowledged guesses. Listed
  under "Design decisions"; tracked in `docs/MAME_DIVERGENCE.md` once there is something to track.
- **Whether the vendored CPU reaches real-board throughput.** Phase 0 answers it. Model 1 ships at
  ~70% of its board's per-frame work and says so; MS32 has to decide what it will accept, and the
  `.mra`/release notes have to say it.
- **Whether any MS32 game dispatches the FP group.** A MAME tap on `0x5C`/`0x5F` across the game list
  answers it, and a negative answer is worth 1,942 ALM and ~7 MHz of Fmax.
- ~~**The licence decision.**~~ **Taken: GPL-3.0-or-later**, `LICENSE` replaced, obligations in
  [`THIRD-PARTY.md`](../THIRD-PARTY.md). What stays open is the discipline, not the choice — each
  vendored file's §5(a) change notice has to be kept accurate as it is edited.
- **A YMF271 core exists, and it is unlicensed.** The board-enumeration check found the boards
  (`seibu/seibuspi.cpp`, `sony/zn.cpp` besides MS32) and then a web search said no Seibu SPI core
  exists — wrong for the second time in this document:
  [zakk4223/Arcade-SeibuSPI_MiSTer](https://github.com/zakk4223/Arcade-SeibuSPI_MiSTer) ships
  `rtl/ymf271.sv` + `rtl/ymf271_synth.sv` (2,377 lines plus tables), a port of MAME's OPX rewrite:
  12-voice interpolated PCM, 4-op/2×2-op/3-op FM with all 28 networks, LFO, timers, IRQ — its
  `STATUS.md` says verified in simulation against MAME register traces and matched on hardware by
  spectrum (r 0.9999 on `rdft2`), with PFM, PCM alternate loop and the Busy flag as known gaps. Its
  Z80 interface is the same sixteen-byte window MS32 uses at `0x3f00`. **The repository has no
  LICENSE file and those files carry no licence header** — only its third-party files (rmonic79's
  CRT modules, Sorgelig's `sdram.sv`, Martin Donlon's savestate RAM) are licensed. Unlicensed means
  all rights reserved: it could not be vendored without the author's grant. **Asked and answered
  the same day: zakk4223 confirmed the file is GPL-3 and will add a LICENSE to the repository**
  (relayed by the project owner, 2026-09-11). Vendor it once that LICENSE is committed upstream, so
  the provenance points at a licensed commit rather than a message. The port carries SPI-specific
  dependencies to strip (`system_consts`, the `ssbus_if` savestate interfaces, a 57.27 MHz `CLK_HZ`
  constant) and its ALM cost is not separated in that project's figures.
- **Sprite frame buffer placement** — DDR3 or SDRAM's remainder. Decide by measurement in Phase 1.
- **Whether the sprite engine can finish a frame.** 4096 slots, each up to 256×256 zoomed, against
  1,615,872 `clk_sys` cycles per frame at 96 MHz (263 lines x 6,144). Instrument from the first
  build rather than model it.
- **The programmable timer's real period.** MAME uses 500 µs × interval and says it does not know.
  `p47acesa` v1.0 is documented as mis-programming it, which makes it a poor calibration target and a
  good regression one.
- **ROZ wrapping**, the unmapped `roz_ctrl` `0x40`/`0x44`/`0x50`/`0x54`, and the second brightness
  register. All three are "MAME does not know either".
- **ROZ0.** The board has a second ROZ plane that MAME does not implement. Whether any in-scope game
  writes to `0xfe400000` is answerable with a MAME write tap over the full game list, and worth
  answering before deciding it does not matter.
- **32 MB versus 128 MB SDRAM.** The plan targets 32 MB. If the DDR3 sample-ROM or frame-buffer
  placement turns out not to work, the fallback is requiring a larger module, which narrows the
  audience; note it early rather than discovering it at release.
- **NVRAM persistence** across core loads is a real feature on this hardware (5.5 V battery), not a
  high-score nicety. Games will run their own NVRAM checks.

## Next steps

1. Rename `Template.*` to `JalecoMS32.*`, create the second revision, and get an empty core building
   through `scripts/build_staged.py` — so the build gate exists before there is anything to gate.
2. Port `scripts/` from Seta: `deploy.py`, `run_sim.sh`, `cfg.py`, `read_issp.tcl`,
   `sta_failing_paths.tcl`, `mame_capture.py` + `mame/*.lua`, `parse_mame_trace.py`, `boot_trace.py`,
   `build_mra.py`/`mra.py`/`validate_mra.py`, `memdump.py`. Header comments intact.
3. Capture `tetrisp` reference data from MAME: boot trace, program-ROM disassembly at known offsets,
   VRAM/vreg/spriteram/palette dumps at chosen frames.
4. Verify the decryption inverse against a real ROM offline, in Python, before any RTL.
5. Start Phase 0: vendor `s32_v60` (licence settled), run its own suite unchanged, then the 32-bit
   bus adapter, then the `tetrisp` trace diff, then the CPI measurement.
