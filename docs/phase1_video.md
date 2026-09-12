# Phase 1 — the video engines

Design for the MS32 video path, derived from `ms32_v.cpp`/`ms32_sprite.cpp`/
`jaleco_ms32_sysctrl.cpp` and from the software model in `scripts/render_model.py`, which is
pixel-exact against MAME on the captured frames it has been run on (see the Progress section of
`ROADMAP.md` for the current list). The model is the reference the RTL is checked against: every
engine below is verified by preloading a capture's dumps, rendering one frame, and diffing against
`model_*.png` — the same test the model passed against `reference.png`.

Numbers not derived from the driver or a capture are marked as estimates.

## What the hardware does per frame

At the CRTC values every captured game programs (`hblank 64, hdisplay 320, vblank 39, vdisplay 224`
at 6 MHz): 384 × 263 dots, 59.41 Hz, **6,144 `clk_sys` cycles per line at 96 MHz** and 1,615,872 per
frame. The CRTC is programmable, so all of that is register-derived in the RTL (see "CRTC").

Per pixel the chip resolves, in this order: three tilemap pens (BG, ROZ, TX) with their opaque
flags → one "tile" pen plus a 3-bit tile-priority word (BG=1, ROZ=2, TX=4, ORed where opaque) →
a sprite pen with a 4-bit priority nibble from the sprite frame buffer → the priority-RAM lookup
(`primask`) → MAME's case table → a 15-bit palette index (or a half-brightness "shadow") → 24-bit
RGB through the palette and the global brightness. Everything above the palette lookup is 16-bit
integer work with no multiplies except the ROZ address stepper.

## Memory plan for the engines (from ROADMAP's RAM budget)

| RAM | size | who reads it, and how fast |
|---|---|---|
| Palette | 128 KB | mixer: one lookup per pixel (the resolved index), so a single read port at pixel rate plus the CPU port. MAME's "two lookups" are the same table indexed twice; the resolve happens *before* the lookup here |
| TX VRAM 16 KB, BG VRAM 16 KB | one tile entry per 8 (TX) or 16 (BG) pixels per line |
| ROZ VRAM 64 KB | up to one entry per pixel (a rotated line crosses tiles arbitrarily) |
| ROZ line RAM 4 KB | 8 u16 per scanline, read once per line |
| Sprite RAM 64 KB + its vblank copy 64 KB | the copy is walked once per frame by the sprite engine |
| Priority RAM 8 KB | 11 probes per resolve, but they collapse: 3 are per-frame constants and 8 depend only on the 4-bit sprite priority — a 16-entry table rebuilt when priority RAM is written |
| Tile ROMs (SDRAM) | TX 8 bytes per tile row, BG/ROZ 16 bytes per tile row, all contiguous |
| Sprite ROM (SDRAM) | 8 bytes per 8-pixel run, contiguous within a tile row |

The sprite frame buffer is **off-chip** (ROADMAP: 320×224×16 bits ×2 does not fit beside 74.6% of
the device already spoken for). Everything else is M10K.

## CRTC

A register file (the sysctrl `amap`: control, hblank, hdisplay, hbp, hfp, vblank, vdisplay, vbp,
vfp, each `0x1000 - (data & 0xfff)`) driving a raster counter. Dot clock 6 or 8 MHz from
`control` bit 0 (96/16 or 96/12). Outputs: `hpos`, `vpos`, `hblank`, `vblank`, `hsync`, `vsync`,
`ce_pix`, plus the two interrupt events the sysctrl raises — vblank at `vpos == vdisplay`, the
30 Hz field interrupt at `vpos == 0` on odd frames — and the programmable timer. Which level each
event drives is the `.mra` mod byte's `invert_lines` bit.

Defaults at reset are MAME's (`384×263`, 320×224 visible), because `bnstars1` never programs the
CRTC and the sysctrl comments say the first vblank has to happen regardless.

## Tilemap line engines (TX, BG)

The Psikyo `tilemap_line_engine` shape, one instance per layer: during hblank, walk the tiles the
coming line touches (21 tiles of 16 px for BG, 41 of 8 px for TX, one extra for the scroll
remainder), fetch each tile row from SDRAM (one burst per tile: 8 or 16 bytes), and write pens into
a ring of line buffers; the display side consumes at `ce_pix`. Scroll is `scroll[0] + scroll[2] +
const` (const 0x18 TX, 0x10 BG) and `scroll[3] + scroll[5]`, mod the map size; BG's map is 64×64 or
256×16 by `bgmode` bit 0, which changes only the index arithmetic.

Budget (BG, the heavier): 21 bursts of 16 bytes per 6,144-cycle line — trivial. The engine's
correctness risk is the one LESSONS_LEARNED names for Psikyo: the display side must step at
`ce_pix`, and the SDRAM request must deassert combinationally on `valid`.

VRAM entry: `u16[2*ti]` = tile number, `u16[2*ti+1] & 0xf` = colour; pen index = base + colour×256 +
pen, base 0x6000 (TX) / 0x1000 (BG); pen 0 transparent. Confirmed by the model on every capture.

## ROZ engine

Per line: an affine stepper. Simple mode: `cx = (startx+offsx)<<16 + x*(incxx<<8) + y*(incyx<<8)`,
`cy` likewise with `incxy/incyy`; super mode (`roz_ctrl[0x5c]` bit 0): per-line `start2x/start2y/
incxx/incxy` from line RAM added to the frame registers, no y terms. Source pixel = `>> 16`, wrapped
to 2048 (128 tiles × 16). Sign extension: positions 18-bit, increments 17-bit. `offsx/offsy` gain
0x400 when `roz_ctrl[0x38]`/`[0x3c]` bit 0 is set (the model needed exactly this on tetrisp's title,
where the ROZ layer is scrolled by 1024 into an empty part of the map — which is also why it drew
nothing there).

The stepper is two 32-bit adds per pixel. The cost is the fetch: a rotated line crosses tile
boundaries at every pixel in the worst case, so the ROZ engine cannot burst a tile row and reuse it
the way the tilemaps do. Design: a small direct-mapped **tile-row cache** in M10K (estimate: 64
entries × 16 bytes = 1 KB) fed by 16-byte SDRAM bursts; a 1:1-scale line hits every entry 16 times
and a heavily zoomed-out line misses often. Worst case is bounded by the SDRAM port's bandwidth,
~6-7 cycles per burst at 96 MHz against 6,144 per line = ~900 bursts per line, i.e. the engine
survives up to ~2.8 tile crossings per pixel before it cannot keep up, and beyond that it must
drop pixels rather than stall the display. Measure on captures before sizing anything further —
`ROADMAP`'s "Estimate the worst case from the hardware" rule; the model can count tile crossings
per line from a capture's ROZ registers for free.

Wrapping is always on, as MAME has it; the driver's own note that this is wrong for four games goes
in `MAME_DIVERGENCE.md` when it is implemented.

## Sprite engine

Renders the whole list once per frame into the off-chip frame buffer, from the **vblank copy** of
sprite RAM (a real copy, per the LESSONS entry; the capture tooling learned the same thing).

Per sprite (8 u16, all from `extract_parameters`): disable = `~attr & 4`; flips `attr & 3`; priority
`attr & 0xf0`; page `color & 0xfff` (4096 pages of 256×256 in the sprite ROM); `tx/ty` from
`code`; colour `color >> 12`; size `(size & 0xff)+1` × `((size >> 8)+1)`; position 10-bit signed X,
9-bit signed Y; zoom `incx/incy` 8.8 (0x100 = 1:1, larger shrinks). The draw is MAME's
`draw_sprite_zoom_core`: for each destination row, `drawy = (ty*256 + srcy) >> 8`, `srcy += incy`;
for each destination pixel `drawx = (tx*256 + srcx) >> 8`, `srcx += incx`; flips mirror the source
coordinate within `srcend`. Left/top clip advances the source by `(clip - dest) * inc`.

**Which sprite is on top**: the list is walked tail→head when `sprite_ctrl[0x10/4]` bit 15 is clear
and head→tail otherwise, and **the first sprite drawn at a pixel wins** (MAME's priority-masked pixel
op). In RTL that is a write-if-empty into the frame buffer, which needs the buffer cleared per frame
and a read-before-write per pixel — or, cheaper, walk the list in the *opposite* order with plain
overwrite, which is the same result. The second is what the RTL does; the walk order is then
`head→tail` for bit 15 clear. Overflow (not finishing the list in a frame) then drops the sprites
the chip would have drawn *first*, i.e. the ones that would have been on top — the wrong ones.
The engine therefore records `dbg_sprites_completed` per frame from the first build, and the RTL
walks the list in the chip's own order with write-if-empty if the measurement ever shows overflow.

Pixel format in the frame buffer: 16 bits, `pri<<12 | colour<<8 | pen`, pen 0 = empty. 320×224
of them, double-buffered, in DDR3 (ROADMAP "Memory plan"), with a two-line scanline prefetch into
M10K on the display side (the LESSONS entry "A double buffer puts the renderer TWO lines ahead").

Budget: the frame is 1.6M cycles; the title screen has 20 sprites, the tetrisp gameplay frames
~194, and the tetrisp intro's HOW TO PLAY frame drew 194 sprites at up to 96×64 — a few tens of
thousands of pixels. The engine's throughput target is one pixel per cycle at 1:1 (8 pixels per
8-byte SDRAM word), which leaves an order of magnitude for overdraw and zoom-in; per-frame counters
say whether that holds on the heaviest capture, not this paragraph.

## Mixer

Exactly MAME's `screen_update`, as the model has it and as the roadmap's design decision requires:

1. Layer order from three priority-RAM probes: `priram[0x2b00/2] == 0x34` → TX up else ROZ up;
   `priram[0x2e00/2] == 0x34` → TX up else BG up; `priram[0x3a00/2] == 0x09` → TX = 3;
   `& 0x30 == 0` → BG up else ROZ up. Evaluated once per frame (the RAM is 8-bit and CPU-written).
2. Tile resolve: for `prin` 0..3, the layer with that rank overwrites where opaque and ORs its bit
   (BG 1, ROZ 2, TX 4) into `tpri`. Three pens and three opaque flags in, one pen and 3 bits out.
3. `primask` from the sprite pixel's 4-bit priority: eight probes `priram[(pri | 0x0a00 | k)/2] & 0x38`
   for `k` in `1500,1400,1100,1000,0500,0400,0100,0000` → an 8-bit mask. Only 16 possible sprite
   priorities, so this is a 16×8 table rebuilt on priority-RAM writes.
4. The case table, per (`primask`, `tpri`, sprite opaque): `0x00` sprite if opaque; `0xf0` sprite
   if opaque and `tpri ≤ 3`; `0xfc` … `tpri ≤ 1`; `0xfe` … `tpri == 0`, and `tpri` 1..3 is the tile
   at half brightness (gametngk's shadows); `0xf8` sprite if opaque and `tpri == 2`; `0xcc` sprite
   if opaque and `tpri & 2 == 0`; anything else black (MAME draws noise for `0xc0` and pops a
   message). Every one of these is a captured game's case in the driver's own comments.
5. Palette: index → `RRRRRRRR GGGGGGGG` / `........ BBBBBBBB`, then brightness
   `× (0x100 - reg)/0x100` unless bit 14 of the index is set. The half-brightness shadow is a shift
   after the lookup.

The mixer is one pipeline stage per pixel with no feedback, so it runs at `ce_pix` with the palette
read in the middle of it. The OSD debug page gets a render-disable per layer and for sprites, in
the all-zero-is-normal sense.

## Verification, engine by engine

Each engine gets a bench that preloads the relevant dumps from a capture directory (`debug/<name>/`),
renders one frame with the real SDRAM transport in the fetch path, and diffs against the model's
layer image (`model_tx.png`, `model_bg.png`, `model_roz.png`, `model_sprites.png`) — then the mixer
bench diffs the composed frame against `model_all.png`, which is `reference.png` on every frame the
model has passed. The captures on hand and what each exercises:

| capture | exercises | model |
|---|---|---|
| `tetrisp-title` | TX, BG, 20 unzoomed overlapping sprites, primask 0xfc, layer order BG/ROZ/TX | 100% |
| `tetrisp-f2400` | the same state a second later | 100% |
| `tetrisp-f4800`, `f7200v` | ~194 sprites, animated, the sprite-RAM copy timing, 2:1 zoom | 100% |
| `p47aces-f1800` | ROZ simple mode over most of the screen, 41 sprites | 100% |
| `gametngk-f3000` | ROT270, ROZ super (per-line) mode, primask 0xfe shadows, non-square zoom (0x25,0x35) | 100% |
| `gametngk-f6000` | ROT270, 33 sprites at zooms 0x111/0x180/0x199, 0xfe shadows over TX | 100% |

Not yet exercised by any capture: BG in 256×16 mode, a brightness register other than zero (every
frame so far has `0x100 - 0` = full), primask cases 0x00/0xf8/0xcc, and the driver's own flip bit.
A capture of a ROT270 set needs the snapshot turned back 180° (LESSONS_LEARNED, "[MS32] MAME's
native snapshot of a ROT270 set"); `render_model.py` does that from the orientation in `_info.txt`.
