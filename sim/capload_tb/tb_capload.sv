// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Capture load the way the board does it: debug/<CAP>/capture.bin streamed
//  byte by byte on ioctl index 2 through ms32_capture_loader, with the core
//  reset held for the whole download as MiSTer holds RESET. ms32_video is
//  driven from the loader's video_reset, as MS32.sv drives it; the frame
//  after the load is written for scripts/compare_sim_rgb.py.
//
//  sim/video_tb loads the same state through the video block's ports with
//  reset low, so it cannot see a write dropped by reset; this bench can.
//  +OLD=1 drives the video block from the composite reset instead (the
//  wiring before the fix) and must fail -- the negative control.
//
//      python scripts/run_verilator.py capload_tb +CAP=tetrisp-title +GAME=tetrisp
`timescale 1ns/1ps

module tb_capload;

reg clk = 0;
always #5 clk = ~clk;
reg base_reset = 1;

string CAP, GAME, OUTDIR;
integer LAT, OLD;

// ------------------------------------------------------------- ioctl side
reg         ioctl_download = 0, ioctl_wr = 0;
reg  [15:0] ioctl_index = 0;
reg  [26:0] ioctl_addr = 0;
reg   [7:0] ioctl_dout = 0;
wire        reset = base_reset | ioctl_download;     // MS32.sv's composite reset, as far as it matters here

wire        video_reset, ld_tx, ld_bg, ld_roz, ld_line, ld_obj, ld_pal, ld_pri, ld_vreg;
wire [17:0] ld_rel;
wire [15:0] ld_data;
ms32_capture_loader u_capload (
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.video_reset(video_reset),
	.ld_tx(ld_tx), .ld_bg(ld_bg), .ld_roz(ld_roz), .ld_line(ld_line), .ld_obj(ld_obj),
	.ld_pal(ld_pal), .ld_pri(ld_pri), .ld_vreg(ld_vreg), .ld_rel(ld_rel), .ld_data(ld_data)
);

// ------------------------------------------------------------- ROMs
reg [7:0]  txrom  [0:(1 << 19) - 1];
reg [7:0]  bgrom  [0:(1 << 22) - 1];
reg [7:0]  rozrom [0:(1 << 22) - 1];
reg [7:0]  sprrom [0:(1 << 24) - 1];
integer    txrom_mask, bgrom_mask, rozrom_mask, sprrom_mask;

wire        tx_req, bg_req, rz_req, sp_req;
wire [23:0] tx_addr, bg_addr, rz_addr;
wire [27:0] sp_addr;
reg         tx_valid = 0, bg_valid = 0, rz_valid = 0, sp_valid = 0;
reg  [63:0] tx_data, bg_data, rz_data, sp_data;

wire        DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY;
wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN, DDRAM_DOUT;

wire        ce_pix, hblank, vblank, hsync, vsync, vblank_ev;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

ms32_video u_video (
	.clk(clk), .reset(OLD != 0 ? reset : video_reset),
	.vreg_we(ld_vreg), .vreg_off({ld_rel[9:0], 2'b00}), .vreg_data(ld_data),
	.txram_we(ld_tx),     .txram_addr(ld_rel[12:0]),   .txram_wdata(ld_data),
	.bgram_we(ld_bg),     .bgram_addr(ld_rel[12:0]),   .bgram_wdata(ld_data),
	.rozram_we(ld_roz),   .rozram_addr(ld_rel[14:0]),  .rozram_wdata(ld_data),
	.lineram_we(ld_line), .lineram_addr(ld_rel[10:0]), .lineram_wdata(ld_data),
	.objram_we(ld_obj),   .objram_addr(ld_rel[14:0]),  .objram_wdata(ld_data),
	.palram_we(ld_pal),   .palram_addr(ld_rel[15:0]),  .palram_wdata(ld_data),
	.priram_we(ld_pri),   .priram_addr(ld_rel[12:0]),  .priram_wdata(ld_data[7:0]),
	.tx_rom_req(tx_req),  .tx_rom_addr(tx_addr),  .tx_rom_valid(tx_valid), .tx_rom_data(tx_data),
	.bg_rom_req(bg_req),  .bg_rom_addr(bg_addr),  .bg_rom_valid(bg_valid), .bg_rom_data(bg_data),
	.roz_rom_req(rz_req), .roz_rom_addr(rz_addr), .roz_rom_valid(rz_valid), .roz_rom_data(rz_data),
	.spr_rom_req(sp_req), .spr_rom_addr(sp_addr), .spr_rom_valid(sp_valid), .spr_rom_data(sp_data),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(vblank_ev), .field_ev(), .timer_enable(),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.spr_frame_cycles(), .spr_drawn(),
	.dbg_roz_fill(), .dbg_roz_hit(), .dbg_roz_pen_nz()
);

// ------------------------------------------------------------ ROM models
// LAT clocks from req to valid, one request at a time per port (sim/video_tb's model).
integer tx_cnt = 0, bg_cnt = 0, rz_cnt = 0, sp_cnt = 0, i;
reg [27:0] tx_la, bg_la, rz_la, sp_la;
always @(posedge clk) begin
	tx_valid <= 0;
	if (tx_cnt == 0) begin if (tx_req) begin tx_la <= {4'd0, tx_addr}; tx_cnt <= LAT; end end
	else if (tx_cnt == 1) begin for (i = 0; i < 8; i = i + 1) tx_data[8*i +: 8] <= txrom[(tx_la + i) & txrom_mask]; tx_valid <= 1; tx_cnt <= 0; end
	else tx_cnt <= tx_cnt - 1;
	bg_valid <= 0;
	if (bg_cnt == 0) begin if (bg_req) begin bg_la <= {4'd0, bg_addr}; bg_cnt <= LAT; end end
	else if (bg_cnt == 1) begin for (i = 0; i < 8; i = i + 1) bg_data[8*i +: 8] <= bgrom[(bg_la + i) & bgrom_mask]; bg_valid <= 1; bg_cnt <= 0; end
	else bg_cnt <= bg_cnt - 1;
	rz_valid <= 0;
	if (rz_cnt == 0) begin if (rz_req) begin rz_la <= {4'd0, rz_addr}; rz_cnt <= LAT; end end
	else if (rz_cnt == 1) begin for (i = 0; i < 8; i = i + 1) rz_data[8*i +: 8] <= rozrom[(rz_la + i) & rozrom_mask]; rz_valid <= 1; rz_cnt <= 0; end
	else rz_cnt <= rz_cnt - 1;
	sp_valid <= 0;
	if (sp_cnt == 0) begin if (sp_req) begin sp_la <= sp_addr; sp_cnt <= LAT; end end
	else if (sp_cnt == 1) begin for (i = 0; i < 8; i = i + 1) sp_data[8*i +: 8] <= sprrom[(sp_la + i) & sprrom_mask]; sp_valid <= 1; sp_cnt <= 0; end
	else sp_cnt <= sp_cnt - 1;
end

// ------------------------------------------------------------ DDRAM model
// sim/video_tb's model with a busy time of 6 and a read latency of 20.
localparam [27:0] FB_BASE = 28'h1000000;
localparam integer DDR_BUSY = 6, DDR_LAT = 20;
reg [63:0] ddr [0:65535];
reg        ddr_busy = 0;
integer    ddr_busy_cnt = 0, ddr_rd_cnt = 0, ddr_rd_left = 0, ddr_wr_left = 0, j;
reg [15:0] ddr_rd_word, ddr_wr_word;
reg        ddr_ready = 0;
reg [63:0] ddr_dout;
assign DDRAM_BUSY = ddr_busy;
assign DDRAM_DOUT_READY = ddr_ready;
assign DDRAM_DOUT = ddr_dout;
wire [15:0] ddr_word = DDRAM_ADDR[15:0] - FB_BASE[18:3];
always @(posedge clk) begin
	ddr_ready <= 0;
	if (ddr_busy_cnt > 0) begin ddr_busy_cnt <= ddr_busy_cnt - 1; if (ddr_busy_cnt == 1) ddr_busy <= 0; end
	if (ddr_rd_cnt > 0) begin
		ddr_rd_cnt <= ddr_rd_cnt - 1;
		if (ddr_rd_cnt == 1) begin
			ddr_dout <= ddr[ddr_rd_word]; ddr_ready <= 1;
			if (ddr_rd_left > 1) begin ddr_rd_left <= ddr_rd_left - 1; ddr_rd_word <= ddr_rd_word + 1; ddr_rd_cnt <= 1; end
			else begin ddr_rd_left <= 0; ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end
	end
	if (!ddr_busy) begin
		if (DDRAM_WE) begin
			if (ddr_wr_left == 0) begin ddr_wr_word = ddr_word; ddr_wr_left = {24'd0, DDRAM_BURSTCNT}; end
			for (j = 0; j < 8; j = j + 1) if (DDRAM_BE[j]) ddr[ddr_wr_word][8*j +: 8] <= DDRAM_DIN[8*j +: 8];
			ddr_wr_word = ddr_wr_word + 1;
			ddr_wr_left = ddr_wr_left - 1;
			if (ddr_wr_left == 0) begin ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end else if (DDRAM_RD && ddr_rd_left == 0) begin
			ddr_rd_word <= ddr_word; ddr_rd_left <= {24'd0, DDRAM_BURSTCNT}; ddr_rd_cnt <= DDR_LAT;
			ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY;
		end
	end
end

// ------------------------------------------------------------- frame capture
reg [23:0] out [0:320*224-1];
integer frame = -1;      // counts from the end of the load
always @(posedge clk) if (vblank_ev && frame >= 0) frame <= frame + 1;
always @(posedge clk) begin
	if (ce_pix && !hblank && !vblank && frame == 3 && u_video.hcnt < 320 && u_video.vcnt < 224)
		out[u_video.vcnt * 320 + u_video.hcnt] <= {r, g, b};
end

// ------------------------------------------------------------- stimulus
reg [7:0] blob [0:(1 << 20) - 1];
integer n, k, fd, blob_len;

// hps_io's pacing: one ioctl_wr pulse, then a few idle clocks. The capture
// loader applies no back-pressure.
task send(input integer addr, input [7:0] d);
	begin
		ioctl_addr <= addr[26:0]; ioctl_dout <= d; ioctl_wr <= 1;
		@(posedge clk);
		ioctl_wr <= 0;
		repeat (3) @(posedge clk);
	end
endtask

initial begin
	if (!$value$plusargs("CAP=%s", CAP))   CAP = "tetrisp-title";
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 12;
	if (!$value$plusargs("OLD=%d", OLD))   OLD = 0;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/", CAP};

	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); if (fd == 0) begin $display("FATAL no txtiles_dec.bin"); $finish; end
	n = $fread(txrom, fd); $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); n = $fread(bgrom, fd); $fclose(fd); bgrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb");    n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/sprite.bin"}, "rb");      n = $fread(sprrom, fd); $fclose(fd); sprrom_mask = n - 1;
	if ((n & (n - 1)) != 0) sprrom_mask = (1 << $clog2(n)) - 1;
	fd = $fopen({"debug/", CAP, "/capture.bin"}, "rb"); if (fd == 0) begin $display("FATAL no capture.bin"); $finish; end
	blob_len = $fread(blob, fd); $fclose(fd);
	for (k = 0; k < 65536; k = k + 1) ddr[k] = 64'd0;
	for (k = 0; k < 320*224; k = k + 1) out[k] = 24'h000000;
	$display("%s: capture blob %0d bytes, LAT %0d, %s", CAP, blob_len, LAT, OLD != 0 ? "OLD wiring (video in the composite reset)" : "video_reset");

	repeat (20) @(posedge clk);
	base_reset = 0;
	repeat (20) @(posedge clk);

	// MiSTer sequence: the download asserts reset for its whole length
	ioctl_index <= 16'd2; ioctl_download <= 1;
	repeat (8) @(posedge clk);
	for (k = 0; k < blob_len; k = k + 1) send(k, blob[k]);
	repeat (8) @(posedge clk);
	ioctl_download <= 0;
	frame = 0;

	wait (frame == 4);
	@(posedge clk);
	fd = $fopen({OUTDIR, "/sim_rgb.txt"}, "w"); if (fd == 0) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%06x\n", out[k]);
	$fclose(fd);
	$display("frame written to %s; overrun tx=%0d bg=%0d roz=%0d spr=%0d fb=%0d bad_primask=%0d", OUTDIR, tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm);
	$finish;
end

endmodule
