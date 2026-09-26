// SPDX-License-Identifier: GPL-3.0-or-later
//
//  F-1 Super Battle's two line planes (ms32_lineplane), driven by ms32_crtc
//  from a MAME capture, against the pixel-exact model:
//
//      python scripts/render_model.py f1superb-road2 --layer road
//      python scripts/render_model.py f1superb-road2 --layer rozf1
//      python scripts/run_verilator.py lineplane_tb +CAP=f1superb-road2 +LAT=12
//      python scripts/compare_sim_layer.py f1superb-road2 road  simout/f1-lineplane/sim_road.u16
//      python scripts/compare_sim_layer.py f1superb-road2 rozf1 simout/f1-lineplane/sim_rozf1.u16
//
//  The road plane draws gfx5 and wraps; the ROZ plane draws roztiles through
//  the same f1layout and clips instead. Both write one palette index per
//  displayed dot, 0xFFFF where transparent, as scripts/compare_sim_layer.py
//  expects. The ROM models answer a granule LAT clocks after the request.
`timescale 1ns/1ps

module tb_lineplane;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1;

string  CAP, GAME, OUTDIR;
integer LAT;

// ------------------------------------------------------------- memories
reg [7:0]  gfx5rom [0:(1 << 23) - 1];
reg [7:0]  rozrom  [0:(1 << 23) - 1];
integer    gfx5_mask, rozrom_mask;
reg [15:0] roadvram [0:32767];
reg [15:0] roadline [0:32767];
reg [15:0] rozram   [0:32767];
reg [15:0] lineram  [0:2047];
reg [31:0] roadctrl [0:23];
reg [31:0] rozctrl  [0:23];

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
wire [10:0] rd_va, rd_la, rz_va, rz_la;
reg  [15:0] rd_vd, rd_ld, rz_vd, rz_ld;
always @(posedge clk) begin
	rd_vd <= roadvram[rd_va]; rd_ld <= roadline[{4'd0, rd_la}];
	rz_vd <= rozram[rz_va];   rz_ld <= lineram[rz_la];
end

wire        rd_req, rz_req, rd_valid, rz_valid;
wire [23:0] rd_addr, rz_addr;
wire [63:0] rd_data, rz_data;
wire [7:0]  rd_pen, rz_pen;
wire [3:0]  rd_col, rz_col;
wire        rd_op, rz_op, rd_ovr, rz_ovr, rd_done, rz_done;
wire [15:0] rd_cyc, rd_miss, rz_cyc, rz_miss, rd_lcol, rz_lcol;

ms32_lineplane #(.WRAP(1'b1)) u_road (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.startx({roadctrl[1][1:0], roadctrl[0][15:0]}), .starty({roadctrl[3][1:0], roadctrl[2][15:0]}),
	.offsx(roadctrl[12][15:0]), .offsy(roadctrl[13][15:0]),
	.offsx_hi(roadctrl[14][0]), .offsy_hi(roadctrl[15][0]),
	.line_addr(rd_la), .line_data(rd_ld),
	.vram_addr(rd_va), .vram_data(rd_vd),
	.rom_req(rd_req), .rom_addr(rd_addr), .rom_valid(rd_valid), .rom_data(rd_data),
	.pen(rd_pen), .colour(rd_col), .opaque(rd_op), .line_colour(rd_lcol),
	.fetch_overrun(rd_ovr), .overrun_ev(), .line_done(rd_done), .line_cycles(rd_cyc), .line_misses(rd_miss)
);

ms32_lineplane #(.WRAP(1'b0)) u_rozf1 (
	.clk(clk), .reset(reset),
	.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
	.startx({rozctrl[1][1:0], rozctrl[0][15:0]}), .starty({rozctrl[3][1:0], rozctrl[2][15:0]}),
	.offsx(rozctrl[12][15:0]), .offsy(rozctrl[13][15:0]),
	.offsx_hi(rozctrl[14][0]), .offsy_hi(rozctrl[15][0]),
	.line_addr(rz_la), .line_data(rz_ld),
	.vram_addr(rz_va), .vram_data(rz_vd),
	.rom_req(rz_req), .rom_addr(rz_addr), .rom_valid(rz_valid), .rom_data(rz_data),
	.pen(rz_pen), .colour(rz_col), .opaque(rz_op), .line_colour(rz_lcol),
	.fetch_overrun(rz_ovr), .overrun_ev(), .line_done(rz_done), .line_cycles(rz_cyc), .line_misses(rz_miss)
);

// ------------------------------------------------------------ ROM models
reg [63:0] rd_data_r, rz_data_r;
reg        rd_valid_r, rz_valid_r;
integer    rd_cnt = 0, rz_cnt = 0;
reg [23:0] rd_la_r, rz_la_r;
assign rd_data = rd_data_r; assign rd_valid = rd_valid_r;
assign rz_data = rz_data_r; assign rz_valid = rz_valid_r;
integer i;
always @(posedge clk) begin
	rd_valid_r <= 0;
	if (rd_cnt == 0) begin
		if (rd_req) begin rd_la_r <= rd_addr; rd_cnt <= LAT; end
	end else if (rd_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) rd_data_r[8*i +: 8] <= gfx5rom[(rd_la_r + i) & gfx5_mask];
		rd_valid_r <= 1; rd_cnt <= 0;
	end else rd_cnt <= rd_cnt - 1;

	rz_valid_r <= 0;
	if (rz_cnt == 0) begin
		if (rz_req) begin rz_la_r <= rz_addr; rz_cnt <= LAT; end
	end else if (rz_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) rz_data_r[8*i +: 8] <= rozrom[(rz_la_r + i) & rozrom_mask];
		rz_valid_r <= 1; rz_cnt <= 0;
	end else rz_cnt <= rz_cnt - 1;
end

// ------------------------------------------------------------- capture
reg [15:0] out_rd [0:320*224-1];
reg [15:0] out_rz [0:320*224-1];
integer frame = 0;
integer rd_max_cyc = 0, rd_max_miss = 0, rz_max_cyc = 0, rz_max_miss = 0;
integer rd_tot_miss = 0, rz_tot_miss = 0, rd_lines = 0, rz_lines = 0;
always @(posedge clk) if (vblank_ev) frame <= frame + 1;
always @(posedge clk) begin
	if (ce_pix && h_active && v_active && frame == 2 && hcnt < 320 && vcnt < 224) begin
		// the model's palette indices: gfx5 at bank 0x50, roztiles at 0x2000
		out_rd[vcnt * 320 + hcnt] <= rd_op ? 16'h5000 + {rd_col, rd_pen} : 16'hFFFF;
		out_rz[vcnt * 320 + hcnt] <= rz_op ? 16'h2000 + {rz_col, rz_pen} : 16'hFFFF;
	end
	if (frame == 2) begin
		if (rd_done) begin
			if (rd_cyc  > rd_max_cyc)  rd_max_cyc  = rd_cyc;
			if (rd_miss > rd_max_miss) rd_max_miss = rd_miss;
			rd_tot_miss = rd_tot_miss + rd_miss; rd_lines = rd_lines + 1;
		end
		if (rz_done) begin
			if (rz_cyc  > rz_max_cyc)  rz_max_cyc  = rz_cyc;
			if (rz_miss > rz_max_miss) rz_max_miss = rz_miss;
			rz_tot_miss = rz_tot_miss + rz_miss; rz_lines = rz_lines + 1;
		end
	end
end

// +TRACE=<line>: the road plane's writes for one display line, to see the
// generator and fetcher in step
integer TRACE = -1;
always @(posedge clk) if (frame == 2 && TRACE >= 0 && vcnt_next2 == TRACE[11:0]) begin
	if (u_road.q_push)
		$display("  push x=%0d gran=%05x byte=%0d col=%x clear=%b", u_road.q_x[u_road.q_wr], u_road.q_gran[u_road.q_wr], u_road.q_byte[u_road.q_wr], u_road.q_col[u_road.q_wr], u_road.q_clear[u_road.q_wr]);
	if (u_road.wr_en)
		$display("  write x=%0d pen=%02x col=%x  (level %0d, head x=%0d)", u_road.wr_x, u_road.wr_pen, u_road.wr_col, u_road.q_level, u_road.q_x[u_road.q_rd]);
end

// ------------------------------------------------------------- loading
reg [7:0] tmp [0:262143];
integer n, k, fd;

initial begin
	if (!$value$plusargs("CAP=%s", CAP))    CAP = "f1superb-road2";
	if (!$value$plusargs("GAME=%s", GAME))  GAME = "f1superb";
	if (!$value$plusargs("LAT=%d", LAT))    LAT = 12;
	void'($value$plusargs("TRACE=%d", TRACE));
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = "simout/f1-lineplane";

	fd = $fopen({"roms/", GAME, "/gfx5.bin"}, "rb"); if (!fd) begin $display("FATAL no gfx5.bin"); $finish; end
	n = $fread(gfx5rom, fd); $fclose(fd); gfx5_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb"); if (!fd) begin $display("FATAL no roztiles.bin"); $finish; end
	n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;

	// the RAM dumps are the CPU's dword view, low halfword meaningful
	fd = $fopen({"debug/", CAP, "/", GAME, "_roadvram.bin"}, "rb"); if (!fd) begin $display("FATAL no roadvram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) roadvram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_roadline.bin"}, "rb"); if (!fd) begin $display("FATAL no roadline"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) roadline[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozram.bin"}, "rb"); if (!fd) begin $display("FATAL no rozram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) rozram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_lineram.bin"}, "rb"); if (!fd) begin $display("FATAL no lineram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 2048; k = k + 1) lineram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_roadctrl.bin"}, "rb"); if (!fd) begin $display("FATAL no roadctrl"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 24; k = k + 1) roadctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozctrl.bin"}, "rb"); if (!fd) begin $display("FATAL no rozctrl"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 24; k = k + 1) rozctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	#1;
	$display("%s: gfx5 %0d bytes, roztiles %0d bytes, LAT %0d", CAP, gfx5_mask + 1, rozrom_mask + 1, LAT);

	repeat (4) @(posedge clk);
	reset = 0;
	wait (frame == 3);
	@(posedge clk);

	// one hex index a line, as scripts/compare_sim_layer.py reads them
	fd = $fopen({OUTDIR, "/sim_road.u16"}, "w");
	if (!fd) begin $display("FATAL: cannot write %s/sim_road.u16 (does the directory exist?)", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x\n", out_rd[k]);
	$fclose(fd);
	fd = $fopen({OUTDIR, "/sim_rozf1.u16"}, "w");
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x\n", out_rz[k]);
	$fclose(fd);

	$display("road : heaviest line %0d clocks, %0d misses, overrun %0d, %0d fetches over %0d lines", rd_max_cyc, rd_max_miss, rd_ovr, rd_tot_miss, rd_lines);
	$display("rozf1: heaviest line %0d clocks, %0d misses, overrun %0d, %0d fetches over %0d lines", rz_max_cyc, rz_max_miss, rz_ovr, rz_tot_miss, rz_lines);
	$display("wrote %s/sim_road.u16 and sim_rozf1.u16", OUTDIR);
	$finish;
end

endmodule
