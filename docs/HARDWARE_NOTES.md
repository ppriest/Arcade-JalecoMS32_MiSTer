# Charles MacDonald's hardware notes, against this core

MAME's `src/mame/jaleco/ms32.cpp` opens with "Notes from Charles MacDonald": measurements from a
Desert War boardset (a stock MegaSystem 32 mainboard) covering the V70 memory map, the sound
latches, the sound CPU reset, the I/O ports, the RAMs' widths and mirroring, and two V70 details.
They are the only hardware measurements in the driver, so where they and MAME disagree they are
the better reference. This file takes each point, says what the core does, and gives the status.

**Status:** *matches*; *changed* (the core now follows the note; the commit that did it says so);
*differs* (not followed, with the reason). Line numbers are `ms32.cpp` at MAME `783e8a2efc2`.

## Sound latches (ms32.cpp 181-216)

| Note | Core | Status |
|---|---|---|
| A write to `FC800000` loads the Z80 latch and triggers NMI | `ms32_cpu_sys` mailboxes the byte to `ms32_sound`, which raises NMI on pending | matches |
| Reads of `FC800000` return `$FFFF` in D15-D0, D31-D16 open bus | `0x0000FFFF` | changed (was 0) |
| Writing D15-D8 of `FC800000` does nothing; writing D31-D16 resets the machine | the byte in D7-D0 is taken, the rest ignored; no reset | differs: no known game does it |
| `FD000000` reads D15-D8 = `$FF`, D7-D0 = the Z80's byte inverted, D31-D16 open bus | `{16'h0000, 8'hFF, ~to_main}` | changed (D15-D8 were 0, as in MAME) |
| Writes to `FD000000` halt the system | ignored | differs: no known game does it |
| Z80 `3F10` read returns the latch inverted; a write loads the V70's latch | as noted | matches |
| NMI is gated by a flip-flop that a read of `3F10`-`3F1F` clears | pending is cleared by a read of `3F10` only | differs: the drivers read `3F10`; MAME decodes `3F10` only too |

## Sound CPU reset (ms32.cpp 218-230)

| Note | Core | Status |
|---|---|---|
| Writing 1 to bit 0 of `FCE00038` triggers a timed /RESET pulse; the bit does not hold reset | a write with bit 0 set starts a pulse | matches |
| The pulse lasts approximately one second | 1,024 `clk_sys` clocks (10.7 us); MAME's is zero-length | **differs**: follows MAME, where every sound check so far was made (Z80 writes against MAME's traces, games by ear). A one-second pulse moves every Z80 boot handshake by a second against MAME; the note itself asks for the width to be measured |

## V70 memory map (ms32.cpp 232-286)

| Note | Core | Status |
|---|---|---|
| A 64 MB block mirrored through `C0000000`-`FFFFFFFF` | RAMs decode on `a & 0xC3FFFFFF` | matches for the RAMs and ROM |
| I/O mirrors: latch out every 4 bytes in `FC800000`-`FC9FFFFF`, I/O area 16 words mirrored in `FCC00000`-`FCDFFFFF`, video registers every 8K in `FCE00000`-`FCFFFFFF`, latch in through `FD000000`-`FD03FFFF` | I/O decodes the exact addresses MAME maps (MAME: "TODO: mirrors like above?") | differs: no known game uses a mirror |
| An unused address or a wrong-direction access halts the V70; the watchdog then resets | reads return 0 (MAME's unmapped value), writes are dropped | differs: a hang is not useful on MiSTer |
| `FC600000`-`FC7FFFFF` is unused and returns `$FFFFFFFF` | as noted | changed (was 0) |
| NVRAM 8K bytes in D7-D0, mirrored every 32K bytes | as noted | matches |
| Priority RAM 8K bytes in D7-D0, mirrored every 32K bytes | as noted | matches |
| Colour RAM: R and G in D15-D0 of even words, B in D7-D0 of odd words, 256K bytes mirrored | as noted (`u_pal0`, `u_pal1`) | matches |
| Rotate RAM 64K, mirrored every 128K bytes | 32,768 words, mirrored every 128K bytes | matches |
| Line RAM 4K, mirrored every 8K bytes | 2,048 words, every 8K bytes | matches |
| Object RAM mirrored every 256K bytes | every 128K bytes, as MAME maps it (`0x20000` with `mirror(0x3c1e0000)`) | differs: the games use the first 128K (4,096 x 8 words) |
| ASCII / scroll RAM mirrored every 128K bytes | every 64K bytes, as MAME (`mirror(0x3c1f0000)`) | differs: no known game reads the upper copy |
| Work RAM 128K, mirrored every 128K bytes | as noted | matches |
| Program ROM mirrored (512K on Desert War) | the 2 MB ROM at `FFE00000`, mirrored by the 64 MB rule | matches for the 2 MB sets |
| The undriven upper bits of the narrow RAMs read as bus garbage (`$FFFFF4xx` NVRAM, `$00FFFFxx` priority, `$FFFFxxxx` object, ...) | zero-extended, as MAME | differs: the values are floating-bus approximations, not logic |
| All video registers are write-only | the RAM-backed register ranges read back, as MAME's `.ram().share()` | differs: follows MAME |

## I/O ports (ms32.cpp 288-322)

| Note | Core | Status |
|---|---|---|
| `FCC00004`: 1P `4321 rldu` in D7-D0, 2P in D15-D8, coins D17-D16 (2P, 1P), test/service D19-D18, starts D21-D20, active low | `MS32.sv` `inputs` | matches |
| TILT resets the system while asserted and cannot be read | no tilt input | differs: MiSTer has no tilt switch |
| `FCC00010`: DIP SW2 in D7-D0, SW1 in D15-D8, SW3 in D23-D16, switch 1 in the high bit, active low | the `.mra` DIP bytes, from MAME's `PORT_DIPLOCATION`s | matches |

## System and video registers (ms32.cpp 324-356)

| Note | Core | Status |
|---|---|---|
| `FCE00000` D0: dot clock (1 = 24 kHz?, 0 = 15 kHz) | control bit 0 selects 8 MHz (1) or 6 MHz (0) dots, `ms32_crtc` | matches (the faster clock for 1) |
| `FCE00038` sound CPU reset | see above | matches, pulse width differs |
| `FCE00050` watchdog reset | ignored | differs: no watchdog |
| `FCE00Exx` coin meter and lockout | ignored | differs: no meters on MiSTer |
| `FCE00045` "IRQ acknowledge" | the acknowledges are at `0x3C`, `0x58`, `0x5C` (MAME's sysctrl) | `0x45` is not a word address; read as a typo |

## CPU (ms32.cpp 445-466)

| Note | Core | Status |
|---|---|---|
| uPD70632GD-20, 20 MHz | `clk_cpu` 20 MHz | matches |
| PIR reads `$00007007` | `0x00007007` | changed (was MAME's `0x7000`) |
| `MOV.D` from a register uses the pair rn:rn+1; for R31 the pair is R31:R31 | as noted | changed (R31 took the register after it). The qword decode itself was fixed for tp2m32 (`722e2c8`) |
| `MOV.D` with an immediate or quick-immediate source raises an Addressing Mode exception | not modelled | differs: not known to be used |
| Z80 is NMOS: `out (c), 0` outputs 0 | T80 in Mode 0 | not relevant: the MS32 sound board has no Z80 I/O ports |

## What is left open

- The reset pulse width. A board measurement settles it; until then MAME's timing is kept.
- The upper-bit read values and the I/O mirrors are not followed; if a game turns out to depend on
  one, this is the table to start from.
