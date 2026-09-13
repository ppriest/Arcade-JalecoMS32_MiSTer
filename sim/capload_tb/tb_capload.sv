// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Capture load the way the board does it: debug/<CAP>/capture.bin streamed
//  byte by byte on ioctl index 2 through ms32_capture_loader, with the core
//  reset held for the whole download as MiSTer holds RESET and ioctl_wait
//  honoured. The loader's writes cross into ms32_core's CPU domain (20 MHz
//  here, as on the board) and go through the CPU address decode with the
//  V70 held; ms32_core runs from the loader's sys_reset, as in MS32.sv. The
//  frame after the load is written for scripts/compare_sim_rgb.py.
//
//  sim/video_tb loads the same state through the video block's ports with
//  reset low, so it cannot see a write dropped by reset; this bench can.
//  +OLD=1 drives ms32_core from the composite reset instead (the wiring
//  before the fix) and must fail -- the negative control.
//
//      python scripts/run_verilator.py capload_tb +CAP=tetrisp-title +GAME=tetrisp
`timescale 1ns/1ps

module tb_capload;

reg clk = 0;
always #5.208 clk = ~clk;       // clk_sys, 96 MHz
reg clk_cpu = 0;
always #25 clk_cpu = ~clk_cpu;  // clk_cpu, 20 MHz
reg base_reset = 1;

string CAP, GAME, OUTDIR;
integer LAT, OLD, ROT, NVTEST;
reg  [12:0] nv_addr = 13'd0;
wire  [7:0] nv_rdata;

// ------------------------------------------------------------- ioctl side
reg         ioctl_download = 0, ioctl_wr = 0;
reg  [15:0] ioctl_index = 0;
reg  [26:0] ioctl_addr = 0;
reg   [7:0] ioctl_dout = 0;
wire        ioctl_wait;
wire        reset = base_reset | ioctl_download;     // MS32.sv's composite reset, as far as it matters here

wire        sys_reset, ld_req, ld_ack;
wire [31:0] ld_addr, ld_data;
wire [3:0]  ld_be;
ms32_capture_loader u_capload (
	.clk(clk), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait),
	.sys_reset(sys_reset),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack)
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

// the core's DDRAM side (c_*) and the port the model sees (DDRAM_*), with
// ms32_ddram_mux and screen_rotate_two between them as in MS32.sv
wire        c_busy, c_rd, c_we, c_dout_ready;
wire [7:0]  c_burstcnt, c_be;
wire [28:0] c_addr;
wire [63:0] c_din, c_dout;
wire        DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY;
wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN, DDRAM_DOUT;

wire        ce_pix, hblank, vblank, hsync, vsync, vblank_ev;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

// the V70 stays in reset: capture playback
ms32_core u_core (
	.clk_sys(clk), .clk_cpu(clk_cpu), .sys_reset(OLD != 0 ? reset : sys_reset), .cpu_run(1'b0), .invert_lines(1'b0),
	.inputs(32'hFFFF_FFFF), .dsw(32'hFFFF_FFFF), .mahjong(1'b0), .mj_keys({30{1'b1}}),
	.nv_addr(nv_addr), .nv_rdata(nv_rdata), .nv_written(),
	.snd_reset(), .snd_cmd_we(), .snd_cmd_data(), .snd_tomain_we(1'b0), .snd_tomain_data(8'h00),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack),
	.prg_req(), .prg_addr(), .prg_valid(1'b0), .prg_data(64'd0),
	.tx_req(tx_req),   .tx_addr(tx_addr),  .tx_valid(tx_valid),  .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),  .bg_valid(bg_valid),  .bg_data(bg_data),
	.roz_req(rz_req),  .roz_addr(rz_addr), .roz_valid(rz_valid), .roz_data(rz_data),
	.spr_req(sp_req),  .spr_addr(sp_addr), .spr_valid(sp_valid), .spr_data(sp_data),
	.DDRAM_BUSY(c_busy), .DDRAM_BURSTCNT(c_burstcnt), .DDRAM_ADDR(c_addr), .DDRAM_DOUT(c_dout),
	.DDRAM_DOUT_READY(c_dout_ready), .DDRAM_RD(c_rd), .DDRAM_DIN(c_din), .DDRAM_BE(c_be), .DDRAM_WE(c_we),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(vblank_ev),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.dbg_roz_fill(), .dbg_roz_hit(), .dbg_roz_pen_nz(), .dbg_pc()
);

// ------------------------------------------------------------ rotation (+ROT=1 cw, 2 ccw)
wire        r_we, r_rd;
wire [7:0]  r_burstcnt, r_be;
wire [28:0] r_addr;
wire [63:0] r_din;
wire        fifo_overflow;
screen_rotate_two u_rot (
	.CLK_VIDEO(clk), .CE_PIXEL(ce_pix),
	.VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hsync), .VGA_VS(vsync), .VGA_DE(~(hblank | vblank)),
	.rotate_ccw(ROT == 2), .no_rotate(ROT == 0), .flip(1'b0), .two_screen(1'b0), .video_rotated(),
	.FB_EN(), .FB_FORMAT(), .FB_WIDTH(), .FB_HEIGHT(), .FB_BASE(), .FB_STRIDE(), .FB_VBL(vsync), .FB_LL(1'b0),
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(r_burstcnt), .DDRAM_ADDR(r_addr), .DDRAM_DIN(r_din),
	.DDRAM_BE(r_be), .DDRAM_WE(r_we), .DDRAM_RD(r_rd)
);
ms32_ddram_mux u_mux (
	.clk(clk), .reset(1'b0),
	.c_busy(c_busy), .c_burstcnt(c_burstcnt), .c_addr(c_addr), .c_dout(c_dout), .c_dout_ready(c_dout_ready),
	.c_rd(c_rd), .c_din(c_din), .c_be(c_be), .c_we(c_we),
	.r_addr(r_addr), .r_din(r_din), .r_be(r_be), .r_we(r_we),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.fifo_overflow(fifo_overflow)
);
// the rotator's three buffers, 512 KB each, byte-addressed; everything outside
// the core's 0x3xxxxxxx window lands here instead of in the model's words
reg [7:0] rot_mem [0:3*(1 << 19) - 1];
integer rot_writes = 0;
wire is_rot = (DDRAM_ADDR[28:25] != 4'b0011);

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
localparam [27:0] FB_BASE = 28'h2000000;
localparam integer DDR_BUSY = 6, DDR_LAT = 20;
reg [63:0] ddr [0:262143];   // 18-bit word index: frame buffer 0x00000-0x0FFFF, object copy 0x20000-0x21FFF (DDRAM_ADDR's low 18 bits)
reg        ddr_busy = 0;
integer    ddr_busy_cnt = 0, ddr_rd_cnt = 0, ddr_rd_left = 0, ddr_wr_left = 0, j;
reg [17:0] ddr_rd_word, ddr_wr_word;
reg        ddr_ready = 0;
reg [63:0] ddr_dout;
assign DDRAM_BUSY = ddr_busy;
assign DDRAM_DOUT_READY = ddr_ready;
assign DDRAM_DOUT = ddr_dout;
wire [17:0] ddr_word = DDRAM_ADDR[17:0];
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
		if (DDRAM_WE && is_rot) begin
			for (j = 0; j < 8; j = j + 1) if (DDRAM_BE[j] && DDRAM_ADDR[21:20] < 2'd3 && DDRAM_ADDR[19:16] == 4'd0)
				rot_mem[{DDRAM_ADDR[21:20], DDRAM_ADDR[15:0], 3'b000} + j] <= DDRAM_DIN[8*j +: 8];
			rot_writes = rot_writes + 1;
		end else if (DDRAM_WE) begin
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
	if (ce_pix && !hblank && !vblank && frame == 3 && u_core.u_video.hcnt < 320 && u_core.u_video.vcnt < 224)
		out[u_core.u_video.vcnt * 320 + u_core.u_video.hcnt] <= {r, g, b};
end

// ------------------------------------------------------------- stimulus
reg [7:0] blob [0:(1 << 20) - 1];
integer n, k, fd, blob_len;

// hps_io's pacing: one ioctl_wr pulse, then the next only once ioctl_wait is
// low: the loader holds it while a word crosses into the CPU domain.
task send(input integer addr, input [7:0] d);
	begin
		ioctl_addr <= addr[26:0]; ioctl_dout <= d; ioctl_wr <= 1;
		@(posedge clk);
		ioctl_wr <= 0;
		@(posedge clk);
		while (ioctl_wait) @(posedge clk);
	end
endtask

initial begin
	if (!$value$plusargs("CAP=%s", CAP))   CAP = "tetrisp-title";
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 12;
	if (!$value$plusargs("OLD=%d", OLD))   OLD = 0;
	if (!$value$plusargs("ROT=%d", ROT))   ROT = 0;
	if (!$value$plusargs("NVTEST=%d", NVTEST)) NVTEST = 0;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/", CAP};

	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); if (fd == 0) begin $display("FATAL no txtiles_dec.bin"); $finish; end
	n = $fread(txrom, fd); $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); n = $fread(bgrom, fd); $fclose(fd); bgrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb");    n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/sprite.bin"}, "rb");      n = $fread(sprrom, fd); $fclose(fd); sprrom_mask = n - 1;
	if ((n & (n - 1)) != 0) sprrom_mask = (1 << $clog2(n)) - 1;
	fd = $fopen({"debug/", CAP, "/capture.bin"}, "rb"); if (fd == 0) begin $display("FATAL no capture.bin"); $finish; end
	blob_len = $fread(blob, fd); $fclose(fd);
	for (k = 0; k < 262144; k = k + 1) ddr[k] = 64'd0;
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

	// +NVTEST=1: the .mra's <nvram> download (index 4) through the loader, then
	// the HPS's read-back through nv_addr/nv_rdata, byte for byte
	if (NVTEST != 0) begin : nvtest
		integer bad;
		repeat (20) @(posedge clk);
		ioctl_index <= 16'd4; ioctl_download <= 1;
		repeat (8) @(posedge clk);
		for (k = 0; k < 8192; k = k + 1) send(k, 8'((k * 7 + 3) ^ (k >> 8)));
		repeat (8) @(posedge clk);
		ioctl_download <= 0;
		repeat (20) @(posedge clk);
		bad = 0;
		for (k = 0; k < 8192; k = k + 1) begin
			nv_addr <= k[12:0];
			@(posedge clk); @(posedge clk);
			if (nv_rdata !== 8'((k * 7 + 3) ^ (k >> 8))) begin
				if (bad < 5) $display("NVRAM %04x: read %02x, wrote %02x", k, nv_rdata, 8'((k * 7 + 3) ^ (k >> 8)));
				bad = bad + 1;
			end
		end
		$display("NVRAM: %0d of 8192 bytes read back differently", bad);
	end
	frame = 0;

	wait (frame == 4);
	@(posedge clk);
	fd = $fopen({OUTDIR, "/sim_rgb.txt"}, "w"); if (fd == 0) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%06x\n", out[k]);
	$fclose(fd);
	$display("frame written to %s; overrun tx=%0d bg=%0d roz=%0d spr=%0d fb=%0d bad_primask=%0d", OUTDIR, tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm);
	if (ROT != 0) begin
		fd = $fopen({OUTDIR, "/rot_mem.bin"}, "wb");
		for (k = 0; k < 3*(1 << 19); k = k + 1) $fwrite(fd, "%c", rot_mem[k]);
		$fclose(fd);
		$display("rotator: %0d writes, fifo_overflow=%0d, buffers written to %s/rot_mem.bin", rot_writes, fifo_overflow, OUTDIR);
	end
	$finish;
end

endmodule
