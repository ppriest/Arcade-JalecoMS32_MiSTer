// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Tile-layer bench: ms32_crtc driving ms32_tilemap (TX and BG) and
//  ms32_roz, fed from a MAME capture (debug/<CAP>/) and the decrypted tile
//  ROMs (roms/<GAME>/), rendering one frame of each layer and writing the
//  palette index of every active dot for scripts/compare_sim_layer.py.
//
//  Run from the repository root, normally through scripts/sim_layer_check.py:
//      scripts/run_sim.sh layers_tb +CAP=tetrisp-title +GAME=tetrisp +LAT=12 +OUT=simout/tetrisp-title
//
//  The ROM models answer a granule LAT clocks after the request; LAT is a
//  plusarg so the same bench runs at the latency the SDRAM backend measures
//  later. Nothing here knows a layer's format: the bench moves bytes from
//  files into memories and pixels from ports into files, and reports the
//  heaviest line the ROZ engine met.
`timescale 1ns/1ps

module tb_layers;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1;

string CAP, GAME, OUTDIR;
integer LAT;

// ------------------------------------------------------------- memories
reg [7:0]  txrom  [0:(1 << 19) - 1];
reg [7:0]  bgrom  [0:(1 << 22) - 1];
reg [7:0]  rozrom [0:(1 << 22) - 1];
integer    txrom_mask, bgrom_mask, rozrom_mask;
reg [15:0] txram  [0:8191];
reg [15:0] bgram  [0:8191];
reg [15:0] rozram [0:32767];
reg [15:0] lineram [0:2047];
reg [31:0] txscroll [0:5];
reg [31:0] bgscroll [0:5];
reg [31:0] rozctrl [0:23];
reg [31:0] bgmode_r;

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
wire [14:0] rz_va;
wire [10:0] rz_la;
reg  [15:0] tx_vd, bg_vd, rz_vd, rz_ld;
always @(posedge clk) begin
	tx_vd <= txram[tx_va]; bg_vd <= bgram[bg_va]; rz_vd <= rozram[rz_va]; rz_ld <= lineram[rz_la];
end

wire        tx_req, bg_req, rz_req, tx_valid, bg_valid, rz_valid;
wire [23:0] tx_addr, bg_addr, rz_addr;
wire [63:0] tx_data, bg_data, rz_data;
wire [7:0]  tx_pen, bg_pen, rz_pen;
wire [3:0]  tx_col, bg_col, rz_col;
wire        tx_op, bg_op, rz_op, tx_ovr, bg_ovr, rz_ovr, rz_done;
wire [15:0] rz_cyc, rz_miss;

ms32_tilemap #(.TILE_16(1'b0)) u_tx (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.scrollx(tx_sx), .scrolly(tx_sy), .bgmode(1'b0),
	.vram_addr(tx_va), .vram_data(tx_vd),
	.rom_req(tx_req), .rom_addr(tx_addr), .rom_valid(tx_valid), .rom_data(tx_data),
	.pen(tx_pen), .colour(tx_col), .opaque(tx_op), .fetch_overrun(tx_ovr), .overrun_ev()
);
ms32_tilemap #(.TILE_16(1'b1)) u_bg (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.scrollx(bg_sx), .scrolly(bg_sy), .bgmode(bgmode_r[0]),
	.vram_addr(bg_va), .vram_data(bg_vd),
	.rom_req(bg_req), .rom_addr(bg_addr), .rom_valid(bg_valid), .rom_data(bg_data),
	.pen(bg_pen), .colour(bg_col), .opaque(bg_op), .fetch_overrun(bg_ovr), .overrun_ev()
);
ms32_roz u_roz (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.startx({rozctrl[1][1:0], rozctrl[0][15:0]}), .starty({rozctrl[3][1:0], rozctrl[2][15:0]}),
	.incxx({rozctrl[5][0], rozctrl[4][15:0]}), .incxy({rozctrl[7][0], rozctrl[6][15:0]}),
	.incyy({rozctrl[9][0], rozctrl[8][15:0]}), .incyx({rozctrl[11][0], rozctrl[10][15:0]}),
	.offsx(rozctrl[12][15:0]), .offsy(rozctrl[13][15:0]),
	.offsx_hi(rozctrl[14][0]), .offsy_hi(rozctrl[15][0]), .super_mode(rozctrl[23][0]),
	.line_addr(rz_la), .line_data(rz_ld),
	.vram_addr(rz_va), .vram_data(rz_vd),
	.rom_req(rz_req), .rom_addr(rz_addr), .rom_valid(rz_valid), .rom_data(rz_data),
	.pen(rz_pen), .colour(rz_col), .opaque(rz_op), .fetch_overrun(rz_ovr), .overrun_ev(),
	.line_done(rz_done), .line_cycles(rz_cyc), .line_misses(rz_miss)
);

// ------------------------------------------------------------ ROM models
// LAT clocks from request to valid; byte i of the granule at data[8*i +: 8].
reg [63:0] tx_data_r, bg_data_r, rz_data_r;
reg        tx_valid_r, bg_valid_r, rz_valid_r;
integer    tx_cnt = 0, bg_cnt = 0, rz_cnt = 0;
reg [23:0] tx_la, bg_la, rz_la_r;
assign tx_data = tx_data_r; assign tx_valid = tx_valid_r;
assign bg_data = bg_data_r; assign bg_valid = bg_valid_r;
assign rz_data = rz_data_r; assign rz_valid = rz_valid_r;
integer i;
always @(posedge clk) begin
	tx_valid_r <= 0;
	if (tx_cnt == 0) begin
		if (tx_req) begin tx_la <= tx_addr; tx_cnt <= LAT; end
	end else if (tx_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) tx_data_r[8*i +: 8] <= txrom[(tx_la + i) & txrom_mask];
		tx_valid_r <= 1; tx_cnt <= 0;
	end else tx_cnt <= tx_cnt - 1;

	bg_valid_r <= 0;
	if (bg_cnt == 0) begin
		if (bg_req) begin bg_la <= bg_addr; bg_cnt <= LAT; end
	end else if (bg_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) bg_data_r[8*i +: 8] <= bgrom[(bg_la + i) & bgrom_mask];
		bg_valid_r <= 1; bg_cnt <= 0;
	end else bg_cnt <= bg_cnt - 1;

	rz_valid_r <= 0;
	if (rz_cnt == 0) begin
		if (rz_req) begin rz_la_r <= rz_addr; rz_cnt <= LAT; end
	end else if (rz_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) rz_data_r[8*i +: 8] <= rozrom[(rz_la_r + i) & rozrom_mask];
		rz_valid_r <= 1; rz_cnt <= 0;
	end else rz_cnt <= rz_cnt - 1;
end

// ------------------------------------------------------------- capture
reg [15:0] out_tx [0:320*224-1];
reg [15:0] out_bg [0:320*224-1];
reg [15:0] out_rz [0:320*224-1];
integer frame = 0;
integer rz_max_cyc = 0, rz_max_miss = 0, rz_sum_miss = 0, rz_lines = 0;
always @(posedge clk) if (vblank_ev) frame <= frame + 1;
always @(posedge clk) begin
	if (ce_pix && h_active && v_active && frame == 2 && hcnt < 320 && vcnt < 224) begin
		out_tx[vcnt * 320 + hcnt] <= tx_op ? 16'h6000 + {tx_col, tx_pen} : 16'hFFFF;
		out_bg[vcnt * 320 + hcnt] <= bg_op ? 16'h1000 + {bg_col, bg_pen} : 16'hFFFF;
		out_rz[vcnt * 320 + hcnt] <= rz_op ? 16'h2000 + {rz_col, rz_pen} : 16'hFFFF;
	end
	if (rz_done && frame == 2) begin
		if (rz_cyc  > rz_max_cyc)  rz_max_cyc  = rz_cyc;
		if (rz_miss > rz_max_miss) rz_max_miss = rz_miss;
		rz_sum_miss = rz_sum_miss + rz_miss;
		rz_lines = rz_lines + 1;
	end
end

// ------------------------------------------------------------- loading
reg [7:0] tmp [0:131071];
integer n, k, fd;

initial begin
	if (!$value$plusargs("CAP=%s", CAP))   CAP = "tetrisp-title";
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 12;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/", CAP};

	// ModelSim ASE takes no ref arguments to fixed arrays, so the loading
	// is spelled out. ROM sizes are powers of two; the model wraps with % len.
	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); if (!fd) begin $display("FATAL no txtiles_dec.bin"); $finish; end
	n = $fread(txrom, fd); $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); if (!fd) begin $display("FATAL no bgtiles_dec.bin"); $finish; end
	n = $fread(bgrom, fd); $fclose(fd); bgrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb"); if (!fd) begin $display("FATAL no roztiles.bin"); $finish; end
	n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;
	$display("ROMs: txtiles %0d, bgtiles %0d, roztiles %0d bytes", txrom_mask + 1, bgrom_mask + 1, rozrom_mask + 1);

	// RAM dumps are the CPU's dword view, low halfword meaningful; registers are dwords
	fd = $fopen({"debug/", CAP, "/", GAME, "_txram.bin"}, "rb"); if (!fd) begin $display("FATAL no txram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 8192; k = k + 1) txram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgram.bin"}, "rb"); if (!fd) begin $display("FATAL no bgram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 8192; k = k + 1) bgram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozram.bin"}, "rb"); if (!fd) begin $display("FATAL no rozram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) rozram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_lineram.bin"}, "rb"); if (!fd) begin $display("FATAL no lineram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 2048; k = k + 1) lineram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_txscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 6; k = k + 1) txscroll[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 6; k = k + 1) bgscroll[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozctrl.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 24; k = k + 1) rozctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgmode.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd);
	bgmode_r = {tmp[3], tmp[2], tmp[1], tmp[0]};
	#1;
	$display("%s: tx scroll %04x,%04x  bg scroll %04x,%04x  bgmode %0d  roz %s  LAT %0d",
	         CAP, tx_sx, tx_sy, bg_sx, bg_sy, bgmode_r[0], rozctrl[23][0] ? "super" : "simple", LAT);

	for (k = 0; k < 320*224; k = k + 1) begin out_tx[k] = 16'hEEEE; out_bg[k] = 16'hEEEE; out_rz[k] = 16'hEEEE; end

	repeat (20) @(posedge clk);
	reset = 0;
	wait (frame == 3);
	@(posedge clk);

	fd = $fopen({OUTDIR, "/sim_tx.txt"}, "w"); if (!fd) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x
", out_tx[k]);
	$fclose(fd);
	fd = $fopen({OUTDIR, "/sim_bg.txt"}, "w");
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x
", out_bg[k]);
	$fclose(fd);
	fd = $fopen({OUTDIR, "/sim_roz.txt"}, "w");
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x
", out_rz[k]);
	$fclose(fd);
	$display("frame written to %s; overrun tx=%0d bg=%0d roz=%0d", OUTDIR, tx_ovr, bg_ovr, rz_ovr);
	$display("roz lines %0d: max %0d clk/line, max %0d misses/line, mean %0d misses/line",
	         rz_lines, rz_max_cyc, rz_max_miss, rz_lines ? rz_sum_miss / rz_lines : 0);
	$finish;
end

endmodule
