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
        # capture frame are the values in force. ms32_brightness_w: bank 0
        # from brt[0..1], bank 1 from brt[2..3], each
        #   r = 0x100 - (w0 >> 8 & 0xff), g = 0x100 - (w0 & 0xff), b = 0x100 - (w1 & 0xff)
        self.brt = [0, 0, 0, 0]
        wl = d / f"{game}_writes.log"
        if wl.exists():
            for line in wl.read_text().splitlines():
                if line.startswith("#"):
                    continue
                fr, ln, addr, mask, data, pc = line.split("	")
                a = int(addr, 16)
                if 0xFCE00280 <= a <= 0xFCE0028C and a % 4 == 0:
                    self.brt[(a - 0xFCE00280) // 4] = int(data, 16)
                # tilemaplayoutcontrol is write-only too, so a capture without
                # --wlog reads it as 0: F-1 Super Battle sets it, and its BG is
                # the 256x16 layout (the 64x64 one misses every pixel)
                if a == 0xFCE00A7C:
                    self.bgmode = int(data, 16)
        self.h, self.w = self.ref.shape[:2]
        roms = REPO / "roms" / game
        self.txtiles = np.fromfile(roms / "txtiles_dec.bin", dtype=np.uint8)
        self.bgtiles = np.fromfile(roms / "bgtiles_dec.bin", dtype=np.uint8)
        self.roztiles = np.fromfile(roms / "roztiles.bin", dtype=np.uint8)
        self.sprite = np.fromfile(roms / "sprite.bin", dtype=np.uint8)
        # F-1 Super Battle: the road plane's map, line registers and control
        # block, and its gfx5 textures (ROADMAP, "F-1 Super Battle")
        self.f1 = (d / f"{game}_roadvram.bin").exists()
        if self.f1:
            self.roadvram = load_u16(d / f"{game}_roadvram.bin")
            self.roadline = load_u16(d / f"{game}_roadline.bin")
            self.road_ctrl = load_u32(d / f"{game}_roadctrl.bin")
            self.gfx5 = np.fromfile(roms / "gfx5.bin", dtype=np.uint8)

    # ms32_v.cpp update_color(): word0 = RRRRRRRRGGGGGGGG, word1 low byte = B,
    # no brightness (MAME PR 16243 moved it to the mixer, see brightness()).
    def palette(self):
        n = 0x8000
        w0 = self.palram[0:2 * n:2].astype(np.int32)
        w1 = self.palram[1:2 * n:2].astype(np.int32)
        r = (w0 >> 8) & 0xFF
        g = w0 & 0xFF
        b = w1 & 0xFF
        return np.stack([r, g, b], axis=1).astype(np.uint8)

    def brightness(self, bank):
        """(r, g, b) multipliers of brightness bank 0 or 1, 0x100 = unchanged."""
        w0, w1 = self.brt[2 * bank], self.brt[2 * bank + 1]
        return np.array([0x100 - ((w0 >> 8) & 0xFF), 0x100 - (w0 & 0xFF), 0x100 - (w1 & 0xFF)], np.int64)


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
    cov = np.zeros((c.h, c.w), bool)   # apply_sprite_effects' box coverage
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
                cov[cury, xs[ok]] = True
            cury += 1; srcy += incy
    c.n_sprites_drawn = n_drawn
    c.spr_cov = cov
    spridat = (bmp & 0x0FFF).astype(np.int64)
    pri = ((bmp & 0xF000) >> 8).astype(np.int64)
    return spridat, (bmp & 0xFF) != 0, pri


def write_sprite_words(c):
    """The sprite bitmap as the mixer sees it: {priority nibble, colour, pen}
    per dot, 0 where nothing was drawn. sim/f1mix_tb drives the mixer with this,
    so the bench needs no sprite engine."""
    spr, op, pri = render_sprites(c)
    word = np.where(op, ((pri >> 4) << 12) | (spr & 0x0FFF), 0).astype("<u2")
    out = c.d / "model_sprite_words.u16"
    with out.open("w") as f:
        for v in word.reshape(-1):
            f.write(f"{int(v):04x}\n")
    return out


def write_line_colours(c):
    """The two line planes' per-line colour words, which the mixer's depth
    bits come from."""
    _, _, roz_line = render_roz_f1(c)
    _, _, road_line = render_road(c)
    out = c.d / "model_line_colours.txt"
    with out.open("w") as f:
        for y in range(c.h):
            f.write(f"{int(roz_line[y]):04x} {int(road_line[y]):04x}\n")
    return out


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


def render_lineplane(c, vram, lineram, ctrl, wrap, colour_base, colour_offset, tiles):
    """ms32_v.cpp draw_line_plane(), the renderer F-1 Super Battle uses for both
    the road plane and its ROZ layer. The map is 1 tile wide by 0x400 tall and a
    tile is 2048x1 (f1layout), so a row of the map is one 2048-pixel strip of
    texture: the ROZ accumulators pick the strip (py) and the pixel along it
    (px). Per screen line, lineram gives start and increments as in ROZ super
    mode, and vram[row*2] == 0 leaves the whole line transparent.

    Returns (palette index, opaque, line colour), the last being vram[row*2+1]
    per line -- bits 6-4 are the depth the priority RAM is indexed with."""
    reg = lambda o: int(ctrl[o // 4])
    startx = s18((reg(0x00) & 0xFFFF) | ((reg(0x04) & 3) << 16))
    starty = s18((reg(0x08) & 0xFFFF) | ((reg(0x0c) & 3) << 16))
    offsx = reg(0x30) + (reg(0x38) & 1) * 0x400
    offsy = reg(0x34) + (reg(0x3c) & 1) * 0x400

    ln = lineram.astype(np.int64)
    row8 = 8 * (np.arange(c.h) & 0xFF)
    st2x = np.array([s18((ln[i + 0] & 0xFFFF) | ((ln[i + 1] & 3) << 16)) for i in row8])[:, None]
    st2y = np.array([s18((ln[i + 2] & 0xFFFF) | ((ln[i + 3] & 3) << 16)) for i in row8])[:, None]
    lixx = np.array([s17((ln[i + 4] & 0xFFFF) | ((ln[i + 5] & 1) << 16)) for i in row8])[:, None]
    lixy = np.array([s17((ln[i + 6] & 0xFFFF) | ((ln[i + 7] & 1) << 16)) for i in row8])[:, None]

    xs = np.arange(c.w)[None, :].astype(np.int64)
    cx = ((st2x + startx + offsx) << 16) + xs * (lixx << 8)
    cy = ((st2y + starty + offsy) << 16) + xs * (lixy << 8)
    px = (cx >> 16) & 2047
    py = (cy >> 16) & 1023
    inside = np.ones_like(px, bool)
    if not wrap:            # draw_roz without wrap clips instead of repeating
        inside = (((cx >> 16) >= 0) & ((cx >> 16) < 2048)
                  & ((cy >> 16) >= 0) & ((cy >> 16) < 1024))

    # the per-line row decides whether the line is drawn at all, and its colour
    line_row = ((st2y[:, 0] + starty + offsy) & 0x3FF)
    line_on = vram[2 * line_row] != 0
    line_colour = np.where(line_on, vram[2 * line_row + 1], 0).astype(np.int64)

    tileno = vram[2 * py].astype(np.int64)
    colour = vram[2 * py + 1].astype(np.int64) & 0xF
    off = tileno * 2048 + px
    pen = tiles[off % len(tiles)].astype(np.int64)
    idx = colour_base + (colour + colour_offset) * 256 + pen
    opaque = (pen != 0) & inside & line_on[:, None]
    return idx, opaque, line_colour


def render_road(c):
    # gfx5: palette base 0x0000, the tile info adds 0x50 to the colour
    return render_lineplane(c, c.roadvram, c.roadline, c.road_ctrl, True, 0x0000, 0x50, c.gfx5)


def render_roz_f1(c):
    # roztiles through f1layout: palette base 0x2000, colour as it stands
    return render_lineplane(c, c.rozram, c.lineram, c.roz_ctrl, False, 0x2000, 0, c.roztiles)


def priram_bytes(c):
    return (np.fromfile(c.d / f"{c.game}_priram.bin", dtype="<u4") & 0xFF).astype(np.int64)


def pri_index(spr_op, pri, tx_op, roz_op, road_op, bg_op, depth):
    """The 13-bit priority-RAM index both mixers form per pixel:
    bit 12 sprite transparent, 11 text transparent, 10 always 1, 9 ROZ
    transparent, 8 road transparent, 7 BG transparent, 6-3 sprite priority
    nibble, 2-0 line depth."""
    return ((~spr_op & 1) << 12) | ((~tx_op & 1) << 11) | (1 << 10) | ((~roz_op & 1) << 9)         | ((~road_op & 1) << 8) | ((~bg_op & 1) << 7) | (pri << 3) | depth


def select_pen(code, layers):
    """code bits 5-3 pick the layer (0 sprite, 1 BG, 2 ROZ, 4 road, 6 text,
    else nothing), bit 6 the backdrop; a transparent pick is pen 0."""
    sel = (code >> 3) & 7
    pen = np.zeros(code.shape, np.int64)
    for k, (idx, op) in layers.items():
        pen = np.where((sel == k) & op, idx, pen)
    return np.where((code >> 6) & 1, 0, pen)


def scale(rgb, m, where):
    return np.where(where[:, :, None], rgb * m // 0x100, rgb)


def sprite_effects(c, rgb, pri8, spr_op, tx_op, roz_op, bg_op):
    """ms32_state::apply_sprite_effects() (PR 16243), run after either mixer:
    where a sprite's box covers a pixel but no sprite pen is opaque there, the
    lookup is redone as if a sprite were opaque, and a clear bit 2 glows a
    sprite pick (bank 1 first when bits 1-0 are 2) or halves anything else.
    The pass writes (1 + pri) << 8 with pri = attr & 0xf0, so its recovered
    priority ((cov >> 8) - 1) & 0xf is always 0: the index's sprite nibble is
    0 whatever the covering sprite's priority. Road bit forced transparent and
    depth 0, also as MAME, f1superb included."""
    m = c.spr_cov & ~spr_op
    code = pri8[pri_index(np.ones_like(spr_op), 0, tx_op, roz_op, np.zeros_like(spr_op), bg_op, 0)]
    fx = m & (((code >> 2) & 1) == 0)
    spr_pick = ((code >> 3) & 7) == 0
    g = fx & spr_pick
    rgb = scale(rgb, c.brightness(1), g & ((code & 3) == 2))
    rgb = np.where(g[:, :, None], (rgb + 255) >> 1, rgb)          # alpha_blend_r32(c, white, 128)
    rgb = np.where((fx & ~spr_pick)[:, :, None], rgb >> 1, rgb)
    c.n_effect_pixels = int(fx.sum())
    return rgb


def mix_f1(c):
    """ms32_f1superbattle_state::mix_layers(): every pixel is a 13-bit index
    into the priority RAM, whose byte says which layer shows and whether it is
    halved (bit 2 clear, every layer). No brightness: since PR 16243
    update_color() applies none and this mixer does not either. Then
    apply_sprite_effects()."""
    pal = c.palette()
    pri8 = priram_bytes(c)

    tx_idx, tx_op = render_tx(c)
    bg_idx, bg_op = render_bg(c)
    roz_idx, roz_op, roz_line = render_roz_f1(c)
    road_idx, road_op, road_line = render_road(c)
    spr, spr_op, spr_pri = render_sprites(c)

    road_depth = ((road_line >> 4) & 7)[:, None]
    roz_depth = ((roz_line >> 4) & 7)[:, None]
    depth = np.where(roz_op, roz_depth, road_depth)

    # render_sprites gives the attribute's priority nibble already shifted into
    # bits 7-4; the index takes the nibble itself, in bits 6-3
    pri = np.where(spr_op, spr_pri >> 4, 0)
    code = pri8[pri_index(spr_op, pri, tx_op, roz_op, road_op, bg_op, depth)]
    pen = select_pen(code, {0: (spr & 0x0FFF, spr_op), 1: (bg_idx, bg_op), 2: (roz_idx, roz_op),
                            4: (road_idx, road_op), 6: (tx_idx, tx_op)})

    rgb = pal[pen & 0x7FFF].astype(np.int64)
    rgb = np.where((((code >> 2) & 1) == 0)[:, :, None], rgb >> 1, rgb)
    rgb = sprite_effects(c, rgb, pri8, spr_op, tx_op, roz_op, bg_op)
    return rgb.astype(np.uint8)


def mix(c):
    """ms32_state::mix_layers() (PR 16243): the same per-pixel priority-RAM
    lookup as mix_f1, with the road transparent and depth 0. Then brightness
    by code bits 1-0: 3 is bank 0; 0 is bank 1 except for text; 2 is bank 1
    for a sprite pick. Bit 2 clear glows a sprite pick and halves the rest.
    Then apply_sprite_effects()."""
    pal = c.palette()
    pri8 = priram_bytes(c)
    tx_idx, tx_op = render_tx(c)
    bg_idx, bg_op = render_bg(c)
    roz_idx, roz_op = render_roz(c)
    spr, spr_op, spr_pri = render_sprites(c)

    pri = np.where(spr_op, spr_pri >> 4, 0)
    none = np.zeros_like(spr_op)
    code = pri8[pri_index(spr_op, pri, tx_op, roz_op, none, bg_op, 0)]
    layer = (code >> 3) & 7
    pen = select_pen(code, {0: (spr & 0x0FFF, spr_op), 1: (bg_idx, bg_op), 2: (roz_idx, roz_op),
                            6: (tx_idx, tx_op)})

    rgb = pal[pen & 0x7FFF].astype(np.int64)
    lo = code & 3
    rgb = scale(rgb, c.brightness(0), lo == 3)
    rgb = scale(rgb, c.brightness(1), ((lo == 0) & (layer != 6)) | ((lo == 2) & (layer == 0)))
    fx = ((code >> 2) & 1) == 0
    rgb = np.where((fx & (layer == 0))[:, :, None], (rgb + 255) >> 1, rgb)
    rgb = np.where((fx & (layer != 0))[:, :, None], rgb >> 1, rgb)
    rgb = sprite_effects(c, rgb, pri8, spr_op, tx_op, roz_op, bg_op)
    return rgb.astype(np.uint8)


def render_mixed_layer(c):
    rgb = mix(c)
    return rgb, np.ones((c.h, c.w), bool)


def render_road_layer(c):
    idx, op, _ = render_road(c)
    return idx, op


def render_rozf1_layer(c):
    idx, op, _ = render_roz_f1(c)
    return idx, op


LAYERS = {"tx": render_tx, "bg": render_bg, "roz": render_roz, "sprites": render_sprites_layer,
          "road": render_road_layer, "rozf1": render_rozf1_layer}


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
        if c.f1:
            print("  " + str(write_sprite_words(c)))
            print("  " + str(write_line_colours(c)))
        rgb = mix_f1(c) if c.f1 else mix(c)
        opaque = np.ones((c.h, c.w), bool)
        print(f"  pixels changed by the sprite-effects pass: {c.n_effect_pixels}")
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
