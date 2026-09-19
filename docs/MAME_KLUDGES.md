# MAME's kludges, guesses and open questions, and what the core does

MAME is this core's behaviour reference, but `ms32.cpp`, `ms32_v.cpp`, `ms32_sprite.cpp` and
`jaleco_ms32_sysctrl.cpp` contain places where MAME says it is guessing, patching around something
it does not understand, or has not implemented the hardware. Following those blindly copies the
guess. This file lists each one that touches an in-scope set, what MAME does, and what the core
does. Hardware measurements, where they exist, are in [`HARDWARE_NOTES.md`](HARDWARE_NOTES.md)
(Charles MacDonald's notes). Line numbers are MAME `783e8a2efc2`.

**Core column:** *copies* MAME; *differs* (and why); *n/a* (not in the core's scope).

## CPU and timing

| MAME | Where | Core |
|---|---|---|
| `sound_command_w` spins the V70 for 40 us after a latch write, "to give the Z80 time to respond" | ms32.cpp 502-508 | copies: the bus holds 800 `clk_cpu` clocks (`SND_SPIN`). Without it the games' command pairs arrived 8 us apart and the Z80 lost the first byte (no sound, `4be9bdf`). What the real board does instead is unknown |
| `sound_result_r` clears IRQ level 1: "tp2m32 never pings the sound ack, so irq ack is most likely done here" | ms32.cpp 510-515 | copies |
| `sound_ack_w` sets `to_main` to `0xFF`: "used by f1superb, is it the reason for sound dying?" | ms32.cpp 1655-1660 | copies |
| Sound CPU reset is a zero-length pulse | ms32.cpp 1607-1611 | differs slightly: 1,024 clocks, so the T80 sees it. MacDonald measured about one second (HARDWARE_NOTES.md) |
| Programmable timer period `500 us x interval`: "unknown actual timings" | jaleco_ms32_sysctrl.cpp 150-166 | copies (`ms32_sysctrl`, 10,000 clocks per 500 us) |
| vblank and field IRQ levels swapped per set by an init-time setter: "both irqs are somehow configurable (a pin?)" | jaleco_ms32_sysctrl.cpp 171-187 | copies, as mod byte bit 2; the acknowledges keep their levels (`1bcdafc`) |
| 30 Hz field IRQ at line 0 of odd frames: "unknown mechanics where this happens, is it even tied to scanline?" | jaleco_ms32_sysctrl.cpp 183-186 | copies |
| Watchdog not implemented | jaleco_ms32_sysctrl.cpp 104 | copies (ignored) |
| "TODO: confirm irq priority" (highest set level wins) | ms32.cpp 1568 | copies |
| V70 PIR `0x00007000`; LSB "reserved to NEC, so I don't know what it contains" | v60.cpp 105-110 | differs: `0x00007007`, MacDonald's measurement |
| `MOV.D` register pair `m_reg[n + 1]`, which for R31 reads the PC slot | op12.hxx 797 | differs: R31:R31, MacDonald's measurement |

## Video

| MAME | Where | Core |
|---|---|---|
| Mixer and priority: "spaghetti code", "complete guesswork and missing many spots", "actually understand this (per-scanline priority and alpha-blend over every layer?)" | ms32_v.cpp 376, 423-425 | copies MAME's decision tree exactly (`ms32_mixer`); it is the only reference and the captures match it |
| Unhandled priority mask `0xc0`: MAME draws `machine().rand()` pixels and pops a message | ms32_v.cpp 522-526 | differs: not reproduced (no random pixels) |
| `hayaosi3` final round priority `0xcc`: "may have some blending, hard to say without ref video" | ms32_v.cpp 527-538 | copies |
| Global brightness: "I'm not sure how the brightness should be applied"; "The second brightness control might apply to shadows"; "fix p47aces brightness"; the header's "cut by 50% at most" | ms32_v.cpp 107, 124-160; ms32.cpp 99-103 | copies the current `(0x100 - reg)/0x100` scaling (three multipliers in `ms32_mixer`); the header's 50% note is older than that code |
| Power-on defaults "tp2m32 doesn't set the brightness registers so we need sensible defaults": brightness `0xFFFF`, sprite control `0x10` = `0x8000` | ms32_v.cpp 82-84 | copies (from this commit; the core reset both to 0 before, which walks the sprite list the other way until a game writes it) |
| Shadow sprites guessed from one priority bit; "the second global brightness register" unexplained | ms32.cpp 105-110 | copies (shadow = halve) |
| Background colour: pen 0 "correct for gametngk, but wrong for f1superb" | ms32.cpp 128-129, ms32_v.cpp 366-368 | copies (pen 0; f1superb is out of scope) |
| ROZ wrapping: "always ON, breaking places where it gets very small ... (p47aces, kirarast, bbbxing, gametngk need it OFF), gratia and desertwr need it ON"; registers `0x40/0x44/0x50/0x54` "unknown meaning", their values listed per game | ms32.cpp 131-133, ms32_v.cpp 214-230 | copies: wrap always on, the four registers ignored. The per-game table in ms32_v.cpp is the lead for a real fix |
| ROZ0, the second rotate plane at `0xfe400000`: not implemented | ms32.cpp 645-646 | copies (not implemented); whether any in-scope game writes it is unchecked |
| Flip screen: MAME flips the four tilemaps, "TODO: sprite device" | ms32_v.cpp 698-705 | differs: the games' Flip Screen DIP does nothing yet; Flip 180 in the OSD rotates the whole picture. Decision pending (ROADMAP) |
| "sprite control 0x10 also uses bits 0-11 for sprite start address?" | ms32_v.cpp 175 | copies (only bit 15, list direction, is used) |
| Sprites with zoom 0 in either axis are not drawn | ms32_v.cpp 198 | copies. It avoids an endless loop in MAME's loop; the chip's behaviour is unknown |
| Zoomed source pixels past the 256x256 page are skipped, not wrapped | ms32_sprite.cpp draw_sprite_zoom_core | copies |
| "hack for tetrisp2?" clamps the source size when zoom is absent | ms32_sprite.cpp 144 | n/a: only the no-zoom `tetrisp2.cpp` sprite chip takes that path |
| suchie2: "on attract gals background display is cut off on the right side" | ms32_sprite.cpp 8 | not checked |
| "horizontal position of tx and bg tilemaps is off by 1 pixel in some games"; "bbbxing: some sprite/roz/bg alignment issues"; "missing clipping window effect in gametngk intro"; gratia level-name and sky notes | ms32.cpp 112-126, 135 | not checked; the core renders what MAME renders |
| "there are sprite lag issues - sprites should be framebuffered" | ms32.cpp 135 | superseded in MAME (vblank copy of object RAM) and in the core (`ms32_objram`) |
| CRTC sync porches (`hbp`, `hfp`, `vbp`, `vfp`) only logged, never used | jaleco_ms32_sysctrl.cpp | differs: the core generates sync from them (`ms32_crtc` header) |
| nndmseal writes a 0x1000 vblank "possibly for screen disable?" | jaleco_ms32_sysctrl.cpp 205 | n/a |

## Sound

| MAME | Where | Core |
|---|---|---|
| YMF271 Busy flag never set; PFM and alternate PCM loop not implemented; waveforms 1-6 "unverified on HW recordings and based on guesswork"; negative-block key code clamps "assumed" | ymf271.cpp header | copies: the SeibuSPI port is a port of this rewrite |
| Timer A register split (0x10 high, 0x11 low) "behaves like other Yamaha chips", the manual says the opposite | ymf271.cpp write_util | copies |
| `3F20` second latch, `3F40` YMF271 pins, `3F70` "unknown ? connected to GS91022-04 pin 55": all no-ops | ms32.cpp 1622-1627 | copies |

## Inputs and DIPs

| MAME | Where | Core |
|---|---|---|
| "DIP switches/inputs in t2m32 and f1superb"; hayaosi3 "dips are somehow different than hayaosi2"; wpksocv2 "still missing the correct input for begin the left right movement"; "inputs in akiss, bnstars" | ms32.cpp 91, 1324, 1406, 2729 | copies MAME's ports into the `.mra` DIP menus and inputs. The World PK Soccer V2 TODO may be the kick/ball fault reported on the board (README Status); not checked |
