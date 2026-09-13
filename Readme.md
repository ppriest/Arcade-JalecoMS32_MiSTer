# Jaleco MegaSystem 32 core for MiSTer

MiSTer FPGA core for Jaleco's MegaSystem 32 arcade hardware — MAME's `jaleco/ms32.cpp` — built with
Quartus Prime 17.0.2 Lite for the DE10-nano.

## Contents

- [Games](#games)
  - [Supported](#supported)
  - [Out of scope for now](#out-of-scope-for-now)
- [Hardware](#hardware)
- [History](#history)
- [Installation](#installation)
- [Status](#status)
  - [Todo](#todo)
  - [Resource usage](#resource-usage)
- [AI Attestation](#ai-attestation)
- [Verification](#verification)
- [Acknowledgements](#acknowledgements)
- [Layout](#layout)
- [License](#license)

## Games

The goal is the MegaSystem 32 sets in MAME's `ms32.cpp` that fit a 32 MB SDRAM module
(`docs/ROADMAP.md`, "Game scope"). Tetris Plus is playable, without sound.

### Supported

| Name | Year | Manufacturer | Key | Notes |
|-|-|-|-|-|
| Tetris Plus (ver 1.0) | 1995 | Jaleco / BPS | SS92046-01 | Playable, silent |
| P-47 Aces (ver 1.1) | 1995 | Jaleco | SS92048-01 | Attract mode runs on the board |
| The Game Paradise - Master of Shooting! (ver 1.0) | 1995 | Jaleco | SS91022-10 | ROT270. Attract mode runs on the board |
| Hayaoshi Quiz Grand Champion Taikai | 1994 | Jaleco | SS92046-01 | Attract mode runs on the board |
| Tetris Plus 2 (ver 1.0, MegaSystem 32 Version) | 1997 | Jaleco | SS91022-10 | Swapped vblank/field interrupts. Attract mode runs on the board |
| Hayaoshi Quiz Nettou Namahousou (ver 1.5) | 1994 | Jaleco | SS92046-01 | |
| Best Bout Boxing (ver 1.3) | 1994 | Jaleco | SS92046-01 | 17 MB of sprites: mod byte selects a 25-bit sprite mask |
| Desert War - Wangan Sensou (ver 1.0) | 1995 | Jaleco | SS91022-10 | ROT270 |
| Gratia - Second Earth (ver 1.0) | 1996 | Jaleco | SS92047-01 | |
| World PK Soccer V2 (ver 1.1) | 1996 | Jaleco | SS92046-01 | Swapped vblank/field interrupts |
| Idol Janshi Suchie-Pai II (ver 1.1) | 1994 | Jaleco | SS92048-01 | Mahjong keys from a keyboard. Attract mode and service menu run on the board |
| Mahjong Angel Kiss (ver 1.0) | 1995 | Jaleco | SS92047-01 | Mahjong keys from a keyboard |
| Ryuusei Janshi Kirara Star (ver 1.0) | 1996 | Jaleco | SS92047-01 | Mahjong keys from a keyboard |
| Vs. Janshi Brandnew Stars (Ver 1.1, MegaSystem 32 Version) | 1997 | Jaleco | SS92046-01 | Mahjong keys from a keyboard |

"Key" is the cartridge's decryption chip, which selects the tile ROM key. Clones have `.mra` files in
`releases/_alternatives/`. Every `<part>` carries its CRC, so a clone loads from its own zip or from
a merged parent zip. The streams of all twenty sets were checked byte for byte against images built
from `ROM_START`.

### Out of scope for now

| MAME description | Why |
|-|-|
| F-1 Super Battle | 56.75 MB of ROM, does not fit 32 MB; MAME does not run it either |
| Vs. Janshi Brandnew Stars (dual screen) | Different driver (`bnstars.cpp`) |

## Hardware

| Chip | Function | Status |
|-|-|-|
| NEC V70 | Main CPU, 20 MHz | Vendored `s32_v60` with a 32-bit bus adapter; runs `tetrisp` on the board |
| System controller | CRTC, interrupts, timer | Written |
| Tilemaps, ROZ, sprites, mixer | Video | Written, pixel-exact against MAME on seven captures |
| Cartridge decryption chip | Tile ROM encryption | Decrypted in the download path |
| Z80 | Sound CPU, 8 MHz | T80, with its RAM, banks and latches; its writes match MAME's over 12 s of `tetrisp` |
| YMF271 | FM + PCM sound | Timers and status only (the driver polls them); no synthesis yet, so no audio |

## History

No release yet.

## Installation

* Take the latest `*.rbf` and put it in `_Arcade/cores`
* Take the `*.mra` files from `releases/` and `releases/_alternatives/` and put them in `_Arcade`
* Put the MAME ROMs in `games/mame`

Development `.mra` files (capture playback) are in `releases/_dev/`.

The mahjong sets take a PS/2 or USB keyboard with MAME's default keys: A-N for the tiles, Left Ctrl
Kan, Left Alt Pon, Space Chi, Left Shift Reach, Z Ron, 1 Start (joystick Start works too). Coins
stay on the joystick.

## Status

The video path renders MAME captures pixel-exact on the board from the real ROMs. In simulation
the whole board (V70, memory map, interrupts, video) runs `tetrisp` from reset to its title screen,
pixel-exact against MAME at frame 1200. On the board `tetrisp` is playable, P-47 Aces and The Game
Paradise and Tetris Plus 2 run their attract modes; the sound CPU runs but there is no audio yet. Every in-scope set has a generated `.mra`,
with DIP menus from MAME's input ports; HDMI rotation and Flip 180 are in the OSD. ROMs load through
DDR3 (`address="0x30000000"`), and NVRAM is saved to `config/nvram` when the OSD opens. The games'
own Flip Screen DIP does nothing: MAME's flips the tilemaps and not the sprites.

### Todo

- [x] Z80
- [ ] YMF271 synthesis (the Seibu SPI core's, once its licence is committed)
- [ ] The games' Flip Screen DIP (sysctrl control bit 1)
- [x] Mahjong inputs

### Resource usage

`MS32_stp` at commit `91f3146`, on the DE10-nano's Cyclone V 5CSEBA6, speed grade 7:

| resource | used | available |
| --- | --- | --- |
| Logic (ALMs) | 32,111 (77%) | 41,910 |
| Block memory bits | 4,139,457 (73%) | 5,662,720 |
| RAM blocks | 519 (94%) | 553 |
| DSP blocks | 49 (44%) | 112 |
| PLLs | 3 | 6 |

Block count, not bits, is the limit: an M10K holds 1024 words of up to 10 bits, so a 32,768-word
RAM costs 32 blocks per 10 bits of width. The per-RAM figures are estimated from commit `db73165`'s
Analysis & Synthesis RAM Summary as the fewest M10K configurations (8192×1 … 256×40) that hold
each RAM; they sum to 521 against that build's fitter count of 517.

| RAM | words × width | M10K |
|---|---|---|
| Work RAM | 32,768 × 32 | 128 |
| Palette, RG words | 32,768 × 16 | 64 |
| Palette, B words | 32,768 × 16 | 64 |
| ROZ VRAM | 32,768 × 16 | 64 |
| Object RAM (the vblank copy is in DDR3) | 32,768 × 16 | 64 |
| Framework scaler (`ascal`) | various | 42 |
| TX VRAM | 8,192 × 16 | 16 |
| BG VRAM | 8,192 × 16 | 16 |
| NVRAM | 8,192 × 8 | 8 |
| Program ROM cache | 1,024 × 72 | 8 |
| Priority RAM | 8,192 × 8 | 8 |
| Register readback | 1,024 × 32 | 4 |
| ROZ line RAM | 2,048 × 16 | 4 |
| Framework OSD (HDMI, VGA), shadow mask, VGA scaler output | various | 13 |
| Line buffers, ROZ cache, object copy staging and window | various | 18 |
| **Total** | | **521** |

## AI Attestation

This core is being developed with heavy use of a frontier coding assistant.

## Verification

Not PCB-validated. MAME is the accuracy reference, with its own acknowledged uncertainties noted
where they matter.

* Hardware facts come from the MAME driver and are verified against it.
  * The tile ROM decryption is checked byte for byte against MAME's decrypted regions
  * The CPU is diffed against a MAME bus trace of `tetrisp`'s boot, access by access
  * The video path is diffed against MAME's own screenshots of captured frames, in simulation and
    on the board
  * The whole board is diffed against MAME's frame 1200 of `tetrisp`, and its video RAMs against
    MAME's at frame 1200 of `tp2m32`
  * The sound CPU's bus is diffed against a timestamped MAME trace of `tetrisp`
  * The `.mra` files are generated from `ROM_START`

## Acknowledgements

- **Sorgelig** and the **MiSTer-devel team** for
  - the [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) framework this project
    is seeded from
  - the SDRAM controller (`sdram.sv`, vendored via
    [Arcade-Jackal_MiSTer](https://github.com/MiSTer-devel/Arcade-Jackal_MiSTer), with burst-4
    reads added)
- **meathax** for the V60/V70 CPU core from the Sega System 32 core,
  [meathax/s32](https://github.com/meathax/s32), and its verification suite.
- The **MAMEdev team** — in particular **David Haywood**, **Paul Priest** and **Luca Elia** — for
  [MAME](https://github.com/mamedev/mame)'s `jaleco/ms32.cpp`, `ms32_v.cpp`, `ms32_sprite.cpp`,
  `jaleco_ms32_sysctrl.cpp` and `jalcrpt.cpp`, and **Farfetch'd** and **R. Belmont** for its V60
  core, which is the behavioural contract of the CPU core here.

## Layout

Standard [Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) structure:

| path | contents |
| - | - |
| `sys` | MiSTer framework, vendored from the template |
| `rtl` | core source |
| `releases` | `.mra` files, and the current `.rbf` |
| `docs` | design notes and hard-won debugging lessons |
| `sim` | ModelSim and Verilator testbenches |
| `scripts` | build, capture and verification tooling |
| `debug` | reference captures from MAME used as ground truth (gitignored) |
| `roms` | your own MAME sets (gitignored, never committed) |

## License

GPL v3 or later (see `LICENSE` and `THIRD-PARTY.md`). The vendored V60/V70 core is GPL-3, and the
MiSTer framework in `sys/` is GPL-2-or-later, whose or-later clause makes the combination lawful.
The SDR SDRAM controller is Sorgelig's, GPL-3.0-or-later.

Game ROMs contain copyrighted material and are not included. Obtaining them is your
responsibility.
