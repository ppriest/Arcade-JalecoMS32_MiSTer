// SPDX-License-Identifier: GPL-3.0-or-later
//
//  F-1 Super Battle's video path against MAME's own screenshot: ms32_crtc
//  driving the two ms32_lineplane engines and the two ms32_tilemap engines,
//  mixed by ms32_mixer (F1) through the capture's priority and palette RAMs.
//
//  The sprite engine is not here -- it is the same one the other twenty-one
//  sets use and is checked by capload_tb -- so the sprite word per dot comes
//  from the model, which renders it exactly (scripts/render_model.py
//  write_sprite_words). Everything else is the core's own RTL.
//
//      python scripts/render_model.py f1superb-road2 --layer all
//      python scripts/run_verilator.py f1mix_tb +CAP=f1superb-road2 +LAT=12
//      python scripts/compare_sim_rgb.py f1superb-road2 simout/f1-mix/sim_rgb.txt
`timescale 1ns/1ps

module tb_f1mix;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1;

string  CAP, GAME, OUTDIR;
integer LAT;

// ------------------------------------------------------------- memories
reg [7:0]  gfx5rom [0:(1 << 23) - 1];
reg [7:0]  rozrom  [0:(1 << 23) - 1];
reg [7:0]  txrom   [0:(1 << 19) - 1];
reg [7:0]  bgrom   [0:(1 << 22) - 1];
integer    gfx5_mask, rozrom_mask, txrom_mask, bgrom_mask;
reg [15:0] roadvram [0:32767];
reg [15:0] roadline [0:32767];
reg [15:0] rozram   [0:32767];
reg [15:0] lineram  [0:2047];
reg [15:0] txram    [0:8191];
reg [15:0] bgram    [0:8191];
reg [31:0] roadctrl [0:23];
reg [31:0] rozctrl  [0:23];
reg [31:0] txscroll [0:5];
reg [31:0] bgscroll [0:5];
reg [31:0] bgmode_r;
reg [7:0]  priram  [0:8191];
reg [15:0] pal0 [0:32767];
reg [15:0] pal1 [0:32767];
reg [15:0] sprword [0:320*224-1];      // from the model
reg [15:0] rozlcol [0:223];            // from the model, for comparison only
reg [15:0] rdlcol  [0:223];

// ---------------------------------------------------------------- CRTC
wire        ce_pix;
wire [11:0] hcnt, vcnt, vcnt_next, vcnt_next2, hdisplay, vdisplay;
wire        h_active, v_active, line_start, vblank_ev;
ms32_crtc u_crtc (
	.clk(clk), .reset(reset),
	.reg_we(1'b0), .reg_off(4'd0), .reg_data(16'd0),
	.ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
	.h_active(h_active), .v_active(v_active), .hblank(), .vblank(), .hsync(), .vsync(),
	.line_start(line_start), .frame_odd(), .vblank_ev(vblank_ev), .field_ev(),
	.flip(), .timer_enable(), .hdisplay_o(hdisplay), .vdisplay_o(vdisplay)
);
wire fetch_active = (vcnt_next2 < vdisplay);

// ------------------------------------------------------------- engines
wire [15:0] tx_sx = txscroll[0][15:0] + txscroll[2][15:0] + 16'h18;
wire [15:0] tx_sy = txscroll[3][15:0] + txscroll[5][15:0];
wire [15:0] bg_sx = bgscroll[0][15:0] + bgscroll[2][15:0] + 16'h10;
wire [15:0] bg_sy = bgscroll[3][15:0] + bgscroll[5][15:0];

wire [12:0] tx_va, bg_va;
wire [10:0] rd_va, rd_la, rz_va, rz_la;
reg  [15:0] tx_vd, bg_vd, rd_vd, rd_ld, rz_vd, rz_ld;
always @(posedge clk) begin
	tx_vd <= txram[tx_va];    bg_vd <= bgram[bg_va];
	rd_vd <= roadvram[rd_va]; rd_ld <= roadline[{4'd0, rd_la}];
	rz_vd <= rozram[rz_va];   rz_ld <= lineram[rz_la];
end

wire        tx_req, bg_req, rd_req, rz_req, tx_valid, bg_valid, rd_valid, rz_valid;
wire [23:0] tx_addr, bg_addr, rd_addr, rz_addr;
wire [63:0] tx_data, bg_data, rd_data, rz_data;
wire [7:0]  tx_pen, bg_pen, rd_pen, rz_pen;
wire [3:0]  tx_col, bg_col, rd_col, rz_col;
wire        tx_op, bg_op, rd_op, rz_op;
wire [15:0] rd_lcol, rz_lcol;

ms32_tilemap #(.TILE_16(1'b0)) u_tx (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.scrollx(tx_sx), .scrolly(tx_sy), .bgmode(1'b0),
	.vram_addr(tx_va), .vram_data(tx_vd),
	.rom_req(tx_req), .rom_addr(tx_addr), .rom_valid(tx_valid), .rom_data(tx_data),
	.pen(tx_pen), .colour(tx_col), .opaque(tx_op), .fetch_overrun(), .overrun_ev()
);
ms32_tilemap #(.TILE_16(1'b1)) u_bg (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.scrollx(bg_sx), .scrolly(bg_sy), .bgmode(bgmode_r[0]),
	.vram_addr(bg_va), .vram_data(bg_vd),
	.rom_req(bg_req), .rom_addr(bg_addr), .rom_valid(bg_valid), .rom_data(bg_data),
	.pen(bg_pen), .colour(bg_col), .opaque(bg_op), .fetch_overrun(), .overrun_ev()
);
ms32_lineplane #(.WRAP(1'b1)) u_road (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.startx({roadctrl[1][1:0], roadctrl[0][15:0]}), .starty({roadctrl[3][1:0], roadctrl[2][15:0]}),
	.offsx(roadctrl[12][15:0]), .offsy(roadctrl[13][15:0]),
	.offsx_hi(roadctrl[14][0]), .offsy_hi(roadctrl[15][0]),
	.line_addr(rd_la), .line_data(rd_ld), .vram_addr(rd_va), .vram_data(rd_vd),
	.rom_req(rd_req), .rom_addr(rd_addr), .rom_valid(rd_valid), .rom_data(rd_data),
	.pen(rd_pen), .colour(rd_col), .opaque(rd_op), .line_colour(rd_lcol),
	.fetch_overrun(), .overrun_ev(), .line_done(), .line_cycles(), .line_misses()
);
ms32_lineplane #(.WRAP(1'b0)) u_rozf1 (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.startx({rozctrl[1][1:0], rozctrl[0][15:0]}), .starty({rozctrl[3][1:0], rozctrl[2][15:0]}),
	.offsx(rozctrl[12][15:0]), .offsy(rozctrl[13][15:0]),
	.offsx_hi(rozctrl[14][0]), .offsy_hi(rozctrl[15][0]),
	.line_addr(rz_la), .line_data(rz_ld), .vram_addr(rz_va), .vram_data(rz_vd),
	.rom_req(rz_req), .rom_addr(rz_addr), .rom_valid(rz_valid), .rom_data(rz_data),
	.pen(rz_pen), .colour(rz_col), .opaque(rz_op), .line_colour(rz_lcol),
	.fetch_overrun(), .overrun_ev(), .line_done(), .line_cycles(), .line_misses()
);

// ------------------------------------------------------------ ROM models
`define ROMMODEL(NAME, ROM, MASK) \
	reg [63:0] NAME``_data_r; reg NAME``_valid_r; integer NAME``_cnt = 0; reg [23:0] NAME``_lad; \
	assign NAME``_data = NAME``_data_r; assign NAME``_valid = NAME``_valid_r; \
	always @(posedge clk) begin \
		NAME``_valid_r <= 0; \
		if (NAME``_cnt == 0) begin if (NAME``_req) begin NAME``_lad <= NAME``_addr; NAME``_cnt <= LAT; end end \
		else if (NAME``_cnt == 1) begin \
			for (i = 0; i < 8; i = i + 1) NAME``_data_r[8*i +: 8] <= ROM[(NAME``_lad + i) & MASK]; \
			NAME``_valid_r <= 1; NAME``_cnt <= 0; \
		end else NAME``_cnt <= NAME``_cnt - 1; \
	end
integer i;
`ROMMODEL(tx, txrom, txrom_mask)
`ROMMODEL(bg, bgrom, bgrom_mask)
`ROMMODEL(rd, gfx5rom, gfx5_mask)
`ROMMODEL(rz, rozrom, rozrom_mask)

// -------------------------------------------------------------- the mixer
wire [12:0] pri_addr;
wire [14:0] pal_addr;
reg  [7:0]  pri_data;
reg  [15:0] pal_w0, pal_w1;
always @(posedge clk) begin
	pri_data <= priram[pri_addr];
	pal_w0   <= pal0[pal_addr];
	pal_w1   <= pal1[pal_addr];
end

// the sprite word for the dot being mixed, from the model
wire [15:0] spr_w = (v_active && h_active && vcnt < 224 && hcnt < 320)
                  ? sprword[vcnt * 320 + hcnt] : 16'd0;

wire [7:0] vr, vg, vb;
ms32_mixer #(.F1(1'b1)) u_mix (
	.clk(clk), .reset(reset),
	.tx_pen(tx_pen),   .tx_col(tx_col),   .tx_op(tx_op),
	.bg_pen(bg_pen),   .bg_col(bg_col),   .bg_op(bg_op),
	.roz_pen(rz_pen),  .roz_col(rz_col),  .roz_op(rz_op),
	.road_pen(rd_pen), .road_col(rd_col), .road_op(rd_op),
	.roz_line(rz_lcol), .road_line(rd_lcol), .spr(spr_w),
	.pri_addr(pri_addr), .pri_data(pri_data),
	.pal_addr(pal_addr), .pal_w0(pal_w0), .pal_w1(pal_w1),
	.brt0(16'd0), .brt1(16'd0), .brt2(16'd0), .brt3(16'd0),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0), .dis_road(1'b0),
	.r(vr), .g(vg), .b(vb)
);

// ------------------------------------------------------------- capture
// the mixer answers six clocks after its inputs, well inside a dot
reg [23:0] out_rgb [0:320*224-1];
integer frame = 0;
integer line_mismatch = 0;
always @(posedge clk) if (vblank_ev) frame <= frame + 1;
always @(posedge clk) begin
	if (ce_pix && h_active && v_active && frame == 2 && hcnt < 320 && vcnt < 224)
		out_rgb[vcnt * 320 + hcnt] <= {vr, vg, vb};
	// the planes' line colours against the model's, which is what the mixer's
	// depth bits come from
	if (ce_pix && h_active && v_active && frame == 2 && hcnt == 12'd0 && vcnt < 224)
		if (rz_lcol !== rozlcol[vcnt] || rd_lcol !== rdlcol[vcnt]) begin
			if (line_mismatch < 4)
				$display("  line %0d colours: roz %04x (model %04x), road %04x (model %04x)",
				         vcnt, rz_lcol, rozlcol[vcnt], rd_lcol, rdlcol[vcnt]);
			line_mismatch = line_mismatch + 1;
		end
end

// ------------------------------------------------------------- loading
reg [7:0] tmp [0:262143];
integer n, k, fd, v0, v1;

initial begin
	if (!$value$plusargs("CAP=%s", CAP))    CAP = "f1superb-road2";
	if (!$value$plusargs("GAME=%s", GAME))  GAME = "f1superb";
	if (!$value$plusargs("LAT=%d", LAT))    LAT = 12;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = "simout/f1-mix";

	fd = $fopen({"roms/", GAME, "/gfx5.bin"}, "rb");        n = $fread(gfx5rom, fd); $fclose(fd); gfx5_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb");    n = $fread(rozrom, fd);  $fclose(fd); rozrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); n = $fread(txrom, fd);   $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); n = $fread(bgrom, fd);   $fclose(fd); bgrom_mask = n - 1;

	fd = $fopen({"debug/", CAP, "/", GAME, "_roadvram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) roadvram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_roadline.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) roadline[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) rozram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_lineram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 2048; k = k + 1) lineram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_txram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 8192; k = k + 1) txram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 8192; k = k + 1) bgram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_priram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 8192; k = k + 1) priram[k] = tmp[4*k];
	fd = $fopen({"debug/", CAP, "/", GAME, "_palram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) begin
		pal0[k] = {tmp[8*k+1], tmp[8*k]};
		pal1[k] = {tmp[8*k+5], tmp[8*k+4]};
	end
	fd = $fopen({"debug/", CAP, "/", GAME, "_roadctrl.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 24; k = k + 1) roadctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozctrl.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 24; k = k + 1) rozctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_txscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 6; k = k + 1) txscroll[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 6; k = k + 1) bgscroll[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgmode.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	bgmode_r = {tmp[3], tmp[2], tmp[1], tmp[0]};
	// bgmode is write-only, so the capture reads it as 0: +BGMODE says what the
	// write log holds (f1superb sets it, and its BG is the 256x16 layout)
	if ($value$plusargs("BGMODE=%d", n)) bgmode_r = n[31:0];

	// the model's sprite words and line colours
	fd = $fopen({"debug/", CAP, "/model_sprite_words.u16"}, "r");
	if (fd == 0) begin $display("FATAL: no model_sprite_words.u16 -- run render_model.py --layer all"); $finish; end
	for (k = 0; k < 320*224; k = k + 1) n = $fscanf(fd, "%h", sprword[k]);
	$fclose(fd);
	fd = $fopen({"debug/", CAP, "/model_line_colours.txt"}, "r");
	if (fd == 0) begin $display("FATAL: no model_line_colours.txt"); $finish; end
	for (k = 0; k < 224; k = k + 1) begin
		n = $fscanf(fd, "%h %h", v0, v1);
		rozlcol[k] = v0[15:0]; rdlcol[k] = v1[15:0];
	end
	$fclose(fd);
	#1;
	$display("%s: bgmode %0d, LAT %0d", CAP, bgmode_r[0], LAT);

	repeat (4) @(posedge clk);
	reset = 0;
	wait (frame == 3);
	@(posedge clk);

	fd = $fopen({OUTDIR, "/sim_rgb.txt"}, "w");
	if (fd == 0) begin $display("FATAL: cannot write %s/sim_rgb.txt", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%06x\n", out_rgb[k]);
	$fclose(fd);
	$display("line colour mismatches: %0d of 224", line_mismatch);
	$display("wrote %s/sim_rgb.txt", OUTDIR);
	$finish;
end

endmodule
