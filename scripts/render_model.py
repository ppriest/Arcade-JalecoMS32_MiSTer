#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""A software model of the MS32 video hardware, rendered from a capture.

    python scripts/render_model.py tetrisp-title            # all layers it knows
    python scripts/render_model.py tetrisp-title --layer tx # one layer, and compare

Reads the region dumps scripts/mame_capture.py wrote (the CPU's dword view of
each RAM), the decrypted tile ROMs from build_rom_image.py, and renders the
way ms32_v.cpp does -- transcribed, register expression by register
expression, with the operators (LESSONS_LEARNED: "Copy a driver's register
expression including its operators"). The output is compared against the
capture's reference.png, MAME's own render of the same state.

This is the Seta pattern: the Python model is checked pixel-exact against
MAME first, then the RTL is checked against the model. A layer that is right
here is a layer whose data format, addressing and palette path are
understood; the RTL then has one unknown fewer.

Layers in the order ms32_v.cpp composes them are added as they are built.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent


def load_u16(path):
    """A 16-bit region as MAME's m_xxx[] u16 array: the CPU dump holds one
    u16 per dword (umask32 0x0000ffff), so u16 k is dword k's low half."""
    d = np.fromfile(path, dtype="<u4")
    return (d & 0xFFFF).astype(np.uint16)


def load_u32(path):
    return np.fromfile(path, dtype="<u4")


class Capture:
    def __init__(self, name, game):
        d = REPO / "debug" / name
        self.d, self.game = d, game
        self.palram = load_u16(d / f"{game}_palram.bin")      # 0x10000 u16
        self.txram = load_u16(d / f"{game}_txram.bin")        # 0x2000 u16
        self.bgram = load_u16(d / f"{game}_bgram.bin")
        self.rozram = load_u16(d / f"{game}_rozram.bin")
        self.lineram = load_u16(d / f"{game}_lineram.bin")
        # the vblank-start copy is what MAME rendered from (see capture.lua);
        # older captures only have the end-of-frame dump
        vbl = d / f"{game}_sprram_vbl.bin"
        self.sprram = load_u16(vbl if vbl.exists() else d / f"{game}_sprram.bin")
        self.sprram_source = "vblank-start copy" if vbl.exists() else "end-of-frame (may be one frame ahead)"
        self.tx_scroll = load_u32(d / f"{game}_txscroll.bin")
        self.bg_scroll = load_u32(d / f"{game}_bgscroll.bin")
        self.roz_ctrl = load_u32(d / f"{game}_rozctrl.bin")
        self.spr_ctrl = load_u32(d / f"{game}_sprctrl.bin")
        self.bgmode = int(load_u32(d / f"{game}_bgmode.bin")[0])
        self.ref = np.array(Image.open(d / "reference.png").convert("RGB"))
        # MAME's native-view snapshot of a ROT270 set (desertwr, gametngk)
        # comes out landscape, 320x224, and rotated 180 degrees from the
        # bitmap the driver drew -- measured, not derived: gametngk frames
        # 3000 and 6000 match the model to the pixel under rot180 and
        # nothing else (as-is 60%/0.3%, flipx 68%/6%, flipy 62%/0.6%). The
        # driver's own flip bit (sysctrl control_w bit 1) is clear in both
        # write logs, so this is the snapshot's orientation, not the game's.
        # The model works in the driver's frame, so the reference is turned
        # back. Only orientation 0 and 270 occur in this core's game list.
        self.orientation = 0
        info = d / f"{game}_info.txt"
        if info.exists():
            for line in info.read_text().splitlines():
                if line.startswith("orientation"):
                    self.orientation = int(line.split()[1])
        if self.orientation == 270:
            self.ref = self.ref[::-1, ::-1]
        elif self.orientation != 0:
            raise SystemExit(f"orientation {self.orientation}: snapshot transform not measured")
        # Brightness registers are write-only, so the capture cannot dump
        # them; --wlog records every write, and the last ones before the
        # capture frame are the values in force. ms32_brightness_w:
        #   brt_r = 0x100 - (brt[0] >> 8 & 0xff), brt_g = 0x100 - (brt[0] & 0xff),
        #   brt_b = 0x100 - (brt[1] & 0xff);  brt[2..3] (bank 1) unused by MAME
        self.brt = [0, 0]
        wl = d / f"{game}_writes.log"
        if wl.exists():
            for line in wl.read_text().splitlines():
                if line.startswith("#"):
                    continue
                fr, ln, addr, mask, data, pc = line.split("	")
                a = int(addr, 16)
                if a in (0xFCE00280, 0xFCE00284):
                    self.brt[(a - 0xFCE00280) // 4] = int(data, 16)
        self.h, self.w = self.ref.shape[:2]
        roms = REPO / "roms" / game
        self.txtiles = np.fromfile(roms / "txtiles_dec.bin", dtype=np.uint8)
        self.bgtiles = np.fromfile(roms / "bgtiles_dec.bin", dtype=np.uint8)
        self.roztiles = np.fromfile(roms / "roztiles.bin", dtype=np.uint8)
        self.sprite = np.fromfile(roms / "sprite.bin", dtype=np.uint8)

    # ms32_v.cpp update_color(): word0 = RRRRRRRRGGGGGGGG, word1 low byte = B.
    # Brightness is applied only to colours with bit 14 CLEAR; the capture's
    # brightness registers are write-only, so the model takes them as args.
    def palette(self, brt_r=None, brt_g=None, brt_b=None):
        if brt_r is None: brt_r = 0x100 - ((self.brt[0] >> 8) & 0xFF)
        if brt_g is None: brt_g = 0x100 - (self.brt[0] & 0xFF)
        if brt_b is None: brt_b = 0x100 - (self.brt[1] & 0xFF)
        n = 0x8000
        w0 = self.palram[0:2 * n:2].astype(np.int32)
        w1 = self.palram[1:2 * n:2].astype(np.int32)
        r = (w0 >> 8) & 0xFF
        g = w0 & 0xFF
        b = w1 & 0xFF
        dim = (np.arange(n) & 0x4000) == 0
        r = np.where(dim, r * brt_r // 0x100, r)
        g = np.where(dim, g * brt_g // 0x100, g)
        b = np.where(dim, b * brt_b // 0x100, b)
        return np.stack([r, g, b], axis=1).astype(np.uint8)


def draw_tilemap(vram, tiles, tw, cols, rows, scrollx, scrolly, w, h, color_base):
    """One MAME tilemap, TILEMAP_SCAN_ROWS, tw x tw 8bpp raw tiles, pen 0
    transparent. Returns (pen index into the palette, opaque mask), both
    screen-sized. VRAM entry: u16[2*ti] = tile number, u16[2*ti+1] & 0xf =
    colour; the gfx decode gives each colour 256 pens."""
    mapw, maph = cols * tw, rows * tw
    ys = (np.arange(h)[:, None] + scrolly) % maph
    xs = (np.arange(w)[None, :] + scrollx) % mapw
    ti = (ys // tw) * cols + (xs // tw)
    tileno = vram[2 * ti].astype(np.int64)
    colour = vram[2 * ti + 1].astype(np.int64) & 0xF
    off = tileno * (tw * tw) + (ys % tw) * tw + (xs % tw)
    pen = tiles[off % len(tiles)].astype(np.int64)
    idx = color_base + colour * 256 + pen
    return idx, pen != 0


def render_tx(c):
    # screen_update(): scrollx = tx_scroll[0x00/4] + tx_scroll[0x08/4] + 0x18,
    #                  scrolly = tx_scroll[0x0c/4] + tx_scroll[0x14/4]
    sx = (int(c.tx_scroll[0]) + int(c.tx_scroll[2]) + 0x18) & 0xFFFF
    sy = (int(c.tx_scroll[3]) + int(c.tx_scroll[5])) & 0xFFFF
    return draw_tilemap(c.txram, c.txtiles, 8, 64, 64, sx, sy, c.w, c.h, 0x6000)


def render_bg(c):
    sx = (int(c.bg_scroll[0]) + int(c.bg_scroll[2]) + 0x10) & 0xFFFF
    sy = (int(c.bg_scroll[3]) + int(c.bg_scroll[5])) & 0xFFFF
    if c.bgmode & 1:
        return draw_tilemap(c.bgram, c.bgtiles, 16, 256, 16, sx, sy, c.w, c.h, 0x1000)
    return draw_tilemap(c.bgram, c.bgtiles, 16, 64, 64, sx, sy, c.w, c.h, 0x1000)


# Sprite page layout (ms32_sprite.cpp's EXTENDED_XOFFS/YOFFS tables, read
# off as a formula): a page is 65,536 bytes holding a 32x32 grid of 8x8x8
# tiles, row-major, so pixel (x,y) of page p is at
#     p*65536 + ((y>>3)*32 + (x>>3))*64 + (y&7)*8 + (x&7)
def page_pixels(sprite_rom, page):
    """The 256x256 pixel array MAME's gfx decode would hand draw_sprite_zoom_core."""
    base = (page * 65536) % len(sprite_rom)
    blk = sprite_rom[base:base + 65536]
    if len(blk) < 65536:
        blk = np.concatenate([blk, np.zeros(65536 - len(blk), np.uint8)])
    # (ty, tx, y, x) -> (ty*8+y, tx*8+x)
    return blk.reshape(32, 32, 8, 8).transpose(0, 2, 1, 3).reshape(256, 256)


def render_sprites(c):
    """draw_sprites() + prio_zoom_transpen_raw: a u16 bitmap of
    colour<<8 | pri<<8 | pen per pixel, pen 0 transparent. Returns
    (palette index, opaque, pri) screen-sized.

    WHICH SPRITE IS ON TOP takes both halves of MAME's mechanism. The loop
    walks the list tail->0 when sprite_ctrl[0x10/4] bit 15 is clear (the
    "reverse" case) and 0->tail otherwise -- and the pixel op is the
    priority-masked one, which ORs 1<<31 into pmask and stamps the priority
    buffer 31 after the first opaque draw, so LATER sprites never overwrite
    an already-drawn pixel: the FIRST sprite drawn at a pixel wins. Reverse
    iteration therefore puts the HIGHEST index on top. The loop alone reads
    as the opposite, and the tetrisp title logo, where adjacent letters
    overlap, was 182 pixels wrong until the second half was read."""
    ram = c.sprram
    tail = len(ram) - 8
    reverse = (int(c.spr_ctrl[0x10 // 4]) & 0x8000) == 0
    order = range(tail, -1, -8) if reverse else range(0, tail, 8)
    bmp = np.zeros((c.h, c.w), np.uint16)
    pages = {}
    n_drawn = 0
    for s in order:
        attr = int(ram[s])
        pri = attr & 0x00F0
        disable = (~attr & 0x0004) != 0
        flipx = attr & 1
        flipy = attr & 2
        code = int(ram[s + 1]); color = int(ram[s + 2])
        tx, ty = code & 0xFF, (code >> 8) & 0xFF
        code = color & 0x0FFF
        color = (color >> 12) & 0xF
        size = int(ram[s + 3])
        srcw, srch = (size & 0xFF) + 1, ((size >> 8) & 0xFF) + 1
        sx = (int(ram[s + 5]) & 0x3FF) - (int(ram[s + 5]) & 0x400)
        sy = (int(ram[s + 4]) & 0x1FF) - (int(ram[s + 4]) & 0x200)
        incx, incy = int(ram[s + 6]) & 0xFFFF, int(ram[s + 7]) & 0xFFFF
        if disable or not incx or not incy:
            continue
        if code not in pages:
            pages[code] = page_pixels(c.sprite, code)
        src = pages[code]
        n_drawn += 1
        # draw_sprite_zoom_core, transcribed
        srcstartx, srcstarty = tx << 8, ty << 8
        srcendx, srcendy = srcw << 8, srch << 8
        destx, desty = sx, sy
        srcx = 0
        if destx < 0:
            srcx = (0 - destx) * incx; destx = 0
        if srcx >= srcendx:
            continue
        srcy = 0
        if desty < 0:
            srcy = (0 - desty) * incy; desty = 0
        if srcy >= srcendy:
            continue
        base = (color << 8) | (pri << 8)
        cury = desty
        while cury < c.h and srcy < srcendy:
            drawy = (srcstarty + ((srcendy - srcy - 1) if flipy else srcy)) >> 8
            if drawy < 256:
                row = src[drawy]
                # vectorised inner loop: every dest x in range at once
                nx = min(c.w - destx, (srcendx - srcx + incx - 1) // incx)
                cursrcx = srcx + incx * np.arange(nx)
                cursrcx = cursrcx[cursrcx < srcendx]
                drawx = (srcstartx + ((srcendx - cursrcx - 1) if flipx else cursrcx)) >> 8
                ok = drawx < 256
                pens = np.zeros(len(drawx), np.uint16)
                pens[ok] = row[drawx[ok]]
                xs = destx + np.arange(len(drawx))
                hit = (pens != 0) & (bmp[cury, xs] == 0)   # first drawn wins
                bmp[cury, xs[hit]] = base + pens[hit]
            cury += 1; srcy += incy
    c.n_sprites_drawn = n_drawn
    spridat = (bmp & 0x0FFF).astype(np.int64)
    pri = ((bmp & 0xF000) >> 8).astype(np.int64)
    return spridat, (bmp & 0xFF) != 0, pri


def render_sprites_layer(c):
    idx, opaque, _ = render_sprites(c)
    print(f"  sprites drawn: {c.n_sprites_drawn}")
    return idx, opaque


def s18(v):  # 18-bit two's complement, as draw_roz sign-extends its positions
    return v - 0x40000 if v & 0x20000 else v


def s17(v):  # 17-bit, for the increments
    return v - 0x20000 if v & 0x10000 else v


def render_roz(c):
    """draw_roz(): 128x128 map of 16x16 tiles, colour base 0x2000, wrap always
    on (as MAME has it). "Simple" mode is one affine transform for the frame;
    "super" mode adds per-line start and x-increments from lineram. The
    driver passes start<<16 and inc<<8, so with the register's 8.8 increments
    everything is 16.16 fixed point and the source pixel is the value >> 16."""
    r = c.roz_ctrl
    reg = lambda o: int(r[o // 4])
    startx = s18((reg(0x00) & 0xFFFF) | ((reg(0x04) & 3) << 16))
    starty = s18((reg(0x08) & 0xFFFF) | ((reg(0x0c) & 3) << 16))
    incxx = s17((reg(0x10) & 0xFFFF) | ((reg(0x14) & 1) << 16))
    incxy = s17((reg(0x18) & 0xFFFF) | ((reg(0x1c) & 1) << 16))
    incyy = s17((reg(0x20) & 0xFFFF) | ((reg(0x24) & 1) << 16))
    incyx = s17((reg(0x28) & 0xFFFF) | ((reg(0x2c) & 1) << 16))
    offsx = reg(0x30) + (reg(0x38) & 1) * 0x400
    offsy = reg(0x34) + (reg(0x3c) & 1) * 0x400
    ys = np.arange(c.h)[:, None].astype(np.int64)
    xs = np.arange(c.w)[None, :].astype(np.int64)
    if reg(0x5c) & 1:
        # super mode: per scanline, lineram[8*(y&0xff)] holds start2x, start2y,
        # incxx, incxy (each as low u16 + high bits in the next u16 pair)
        ln = c.lineram.astype(np.int64)
        row = 8 * (np.arange(c.h) & 0xFF)
        st2x = np.array([s18((ln[i + 0] & 0xFFFF) | ((ln[i + 1] & 3) << 16)) for i in row])[:, None]
        st2y = np.array([s18((ln[i + 2] & 0xFFFF) | ((ln[i + 3] & 3) << 16)) for i in row])[:, None]
        lixx = np.array([s17((ln[i + 4] & 0xFFFF) | ((ln[i + 5] & 1) << 16)) for i in row])[:, None]
        lixy = np.array([s17((ln[i + 6] & 0xFFFF) | ((ln[i + 7] & 1) << 16)) for i in row])[:, None]
        # each line is its own one-row draw_roz: startx' = start2x+startx+offsx, no y terms
        cx = ((st2x + startx + offsx) << 16) + xs * (lixx << 8)
        cy = ((st2y + starty + offsy) << 16) + xs * (lixy << 8)
    else:
        cx = ((startx + offsx) << 16) + xs * (incxx << 8) + ys * (incyx << 8)
        cy = ((starty + offsy) << 16) + xs * (incxy << 8) + ys * (incyy << 8)
    px = (cx >> 16) & 2047
    py = (cy >> 16) & 2047
    ti = (py // 16) * 128 + (px // 16)
    tileno = c.rozram[2 * ti].astype(np.int64)
    colour = c.rozram[2 * ti + 1].astype(np.int64) & 0xF
    off = tileno * 256 + (py % 16) * 16 + (px % 16)
    pen = c.roztiles[off % len(c.roztiles)].astype(np.int64)
    return 0x2000 + colour * 256 + pen, pen != 0


def mix(c):
    """screen_update(): the three tilemaps in the order the priority RAM's
    three probes give, each ORing its bit into a per-pixel priority
    (BG 1, ROZ 2, TX 4); sprites over that per the eight-probe primask and
    MAME's per-case table. Transcribed case for case, comments and all."""
    pri8 = (np.fromfile(c.d / f"{c.game}_priram.bin", dtype="<u4") & 0xFF).astype(np.int64)
    asc = scr = rot = 0
    if (pri8[0x2b00 // 2] & 0xFF) == 0x34: asc += 1
    else: rot += 1
    if (pri8[0x2e00 // 2] & 0xFF) == 0x34: asc += 1
    else: scr += 1
    if pri8[0x3a00 // 2] == 0x09: asc = 3
    if (pri8[0x3a00 // 2] & 0x30) == 0: scr += 1
    else: rot += 1
    c.layer_order = {"bg": scr, "roz": rot, "tx": asc}

    tile = np.zeros((c.h, c.w), np.int64)
    tpri = np.zeros((c.h, c.w), np.int64)
    layers = {"bg": (render_bg, 1), "roz": (render_roz, 2), "tx": (render_tx, 4)}
    for prin in range(4):
        for name, (fn, bit) in layers.items():
            if c.layer_order[name] == prin:
                idx, op = fn(c)
                tile[op] = idx[op]
                tpri[op] |= bit
    spr, sop, spri = render_sprites(c)

    # primask per pixel from the sprite priority nibble
    probes = [0x1500, 0x1400, 0x1100, 0x1000, 0x0500, 0x0400, 0x0100, 0x0000]
    primask = np.zeros((c.h, c.w), np.int64)
    for bit, a in enumerate(probes):
        v = pri8[((spri | 0x0a00 | a) // 2)]
        primask |= ((v & 0x38) != 0).astype(np.int64) << bit

    pal = c.palette()
    tile_rgb = pal[tile].astype(np.int64)
    spr_rgb = pal[spr].astype(np.int64)
    out = tile_rgb.copy()
    sprite_over = np.zeros((c.h, c.w), bool)
    shadow = np.zeros((c.h, c.w), bool)
    for pm in np.unique(primask):
        m = primask == pm
        if pm == 0x00:
            sprite_over |= m & sop
        elif pm == 0xf0:
            sprite_over |= m & sop & (tpri <= 3)
        elif pm == 0xfc:
            sprite_over |= m & sop & (tpri <= 1)
        elif pm == 0xfe:
            sprite_over |= m & sop & (tpri == 0)
            shadow |= m & (tpri >= 1) & (tpri <= 3)
        elif pm == 0xf8:
            sprite_over |= m & sop & (tpri == 2)
        elif pm == 0xcc:
            sprite_over |= m & sop & ((tpri & 2) == 0)
        else:
            c.unhandled_primask = int(pm)   # 0xc0 draws noise in MAME; anything else black
            out[m] = 0
    out[sprite_over] = spr_rgb[sprite_over]
    out[shadow] = tile_rgb[shadow] // 2        # alpha_blend_r32(tile, black, 128)
    return out.astype(np.uint8)


def render_mixed_layer(c):
    rgb = mix(c)
    return rgb, np.ones((c.h, c.w), bool)


LAYERS = {"tx": render_tx, "bg": render_bg, "roz": render_roz, "sprites": render_sprites_layer}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--game", default=None, help="set name (default: prefix of the capture dir)")
    ap.add_argument("--layer", default="all", choices=sorted(LAYERS) + ["all"])
    a = ap.parse_args()
    game = a.game or a.capture.split("-")[0]
    c = Capture(a.capture, game)
    pal = c.palette()

    if a.layer == "all":
        rgb = mix(c)
        opaque = np.ones((c.h, c.w), bool)
        print(f"  layer order (bottom first): " + ", ".join(k for k, v in sorted(c.layer_order.items(), key=lambda kv: kv[1])))
    else:
        idx, opaque = LAYERS[a.layer](c)
        rgb = pal[idx]
        # The RTL benches compare against this, not the PNG: one little-endian
        # u16 palette index per pixel, row-major, 0xFFFF where the layer is
        # transparent. scripts/compare_sim_layer.py reads it back.
        np.where(opaque, idx, 0xFFFF).astype("<u2").tofile(c.d / f"model_{a.layer}.u16")
    out = c.d / f"model_{a.layer}.png"
    Image.fromarray(rgb).save(out)

    # Where the layer is opaque, does the reference show exactly this pixel?
    # That is only a full test for a layer nothing draws over; for the others
    # it is a lower bound, and the composed comparison comes with the mixer.
    same = np.all(rgb == c.ref, axis=2)
    n_op = int(opaque.sum())
    n_ok = int((same & opaque).sum())
    print(f"{a.layer}: {n_op} opaque pixels of {c.w*c.h}; {n_ok} match the reference "
          f"({100.0*n_ok/max(1,n_op):.2f}%) -> {out}")
    if n_op and n_ok < n_op:
        ys, xs = np.nonzero(opaque & ~same)
        print(f"  first mismatches: " + " ".join(f"({x},{y})" for x, y in list(zip(xs, ys))[:8]))
        print(f"  mismatch rows span {ys.min()}..{ys.max()}, cols {xs.min()}..{xs.max()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
