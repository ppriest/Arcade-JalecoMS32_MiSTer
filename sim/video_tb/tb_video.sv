// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Full video path bench: ms32_video loaded with a MAME capture through its
//  CPU-side RAM and register ports, tile and sprite ROMs behind
//  latency-parameterised req/valid models, the sprite frame buffer behind
//  a DDRAM model with a busy time and a read latency, running until the
//  fourth frame and writing every active dot's RGB for
//  scripts/compare_sim_rgb.py against reference.png -- the Phase 1 exit
//  test in simulation.
//
//  Run from the repository root, normally through scripts/sim_layer_check.py:
//      scripts/run_sim.sh video_tb +CAP=tetrisp-title +GAME=tetrisp +LAT=12 +DDR_BUSY=6 +DDR_LAT=20 +OUT=simout/tetrisp-title
`timescale 1ns/1ps

module tb_video;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1;

string CAP, GAME, OUTDIR;
integer LAT, DDR_BUSY, DDR_LAT, STUB, SDRAM;

// ------------------------------------------------------------- ROMs
reg [7:0]  txrom  [0:(1 << 19) - 1];
reg [7:0]  bgrom  [0:(1 << 22) - 1];
reg [7:0]  rozrom [0:(1 << 22) - 1];
reg [7:0]  sprrom [0:(1 << 24) - 1];
integer    txrom_mask, bgrom_mask, rozrom_mask, sprrom_mask;

// ------------------------------------------------------------- DUT
wire        s_tx_valid, s_bg_valid, s_rz_valid, s_sp_valid;   // from the SDRAM stack (+SDRAM=1)
wire [63:0] s_tx_data, s_bg_data, s_rz_data, s_sp_data;
reg         vreg_we = 0;
reg  [11:0] vreg_off;
reg  [15:0] vreg_data;
reg         txram_we = 0, bgram_we = 0, rozram_we = 0, lineram_we = 0, objram_we = 0, palram_we = 0, priram_we = 0;
reg  [15:0] ram_addr;
reg  [15:0] ram_wdata;

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
wire [23:0] spr_cycles;
wire [12:0] spr_drawn;

ms32_video u_video (
	.clk(clk), .reset(reset),
	.vreg_we(vreg_we), .vreg_off(vreg_off), .vreg_data(vreg_data),
	.cpu_clk(clk), .cpu_wdata(ram_wdata),
	.txram_addr(ram_addr[12:0]),   .txram_wel(txram_we),     .txram_weh(txram_we),     .txram_rdata(),
	.bgram_addr(ram_addr[12:0]),   .bgram_wel(bgram_we),     .bgram_weh(bgram_we),     .bgram_rdata(),
	.rozram_addr(ram_addr[14:0]),  .rozram_wel(rozram_we),   .rozram_weh(rozram_we),   .rozram_rdata(),
	.lineram_addr(ram_addr[10:0]), .lineram_wel(lineram_we), .lineram_weh(lineram_we), .lineram_rdata(),
	.objram_addr(ram_addr[14:0]),  .objram_wel(objram_we),   .objram_weh(objram_we),   .objram_rdata(),
	.palram_addr(ram_addr[15:0]),  .palram_wel(palram_we),   .palram_weh(palram_we),   .palram_rdata(),
	.priram_addr(ram_addr[12:0]),  .priram_we(priram_we),                              .priram_rdata(),
	.tx_rom_req(tx_req),  .tx_rom_addr(tx_addr),  .tx_rom_valid(SDRAM ? s_tx_valid : tx_valid),  .tx_rom_data(SDRAM ? s_tx_data : tx_data),
	.bg_rom_req(bg_req),  .bg_rom_addr(bg_addr),  .bg_rom_valid(SDRAM ? s_bg_valid : bg_valid),  .bg_rom_data(SDRAM ? s_bg_data : bg_data),
	.roz_rom_req(rz_req), .roz_rom_addr(rz_addr), .roz_rom_valid(SDRAM ? s_rz_valid : rz_valid), .roz_rom_data(SDRAM ? s_rz_data : rz_data),
	.spr_rom_req(sp_req), .spr_rom_addr(sp_addr), .spr_rom_valid(SDRAM ? s_sp_valid : sp_valid), .spr_rom_data(SDRAM ? s_sp_data : sp_data),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(vblank_ev), .field_ev(), .timer_enable(),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.spr_frame_cycles(spr_cycles), .spr_drawn(spr_drawn)
);

// ------------------------------------------------------------ SDRAM stack
// +SDRAM=1 routes the four ROM ports through ms32_sdram_top and Seta's
// command-decoding chip model instead of the latency models below; the
// model's memory is preloaded with the (decrypted) images at
// ms32_sdram_top's bases, as a download would leave them.
wire [12:0] SDRAM_A;
wire [15:0] SDRAM_DQ;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
reg         sd_init = 1;
wire        sd_tx_req = SDRAM ? tx_req : 1'b0, sd_bg_req = SDRAM ? bg_req : 1'b0;
wire        sd_rz_req = SDRAM ? rz_req : 1'b0, sd_sp_req = SDRAM ? sp_req : 1'b0;
ms32_sdram_top u_sdram (
	.clk(clk), .reset(reset), .init(sd_init),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.ioctl_download(1'b0), .ioctl_index(16'd0), .ioctl_wr(1'b0), .ioctl_addr(27'd0), .ioctl_dout(8'd0), .ioctl_wait(), .key(2'd0),
	.tx_req(sd_tx_req),  .tx_addr(tx_addr),  .tx_valid(s_tx_valid),  .tx_data(s_tx_data),
	.bg_req(sd_bg_req),  .bg_addr(bg_addr),  .bg_valid(s_bg_valid),  .bg_data(s_bg_data),
	.roz_req(sd_rz_req), .roz_addr(rz_addr), .roz_valid(s_rz_valid), .roz_data(s_rz_data),
	.spr_req(sd_sp_req), .spr_addr(sp_addr), .spr_valid(s_sp_valid), .spr_data(s_sp_data),
	.if_req(1'b0), .if_addr(18'd0), .if_valid(), .if_data(),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(1'b0), .z80_addr(18'd0), .z80_valid(), .z80_data()
);
sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);
localparam int W_MAINCPU = 26'h000_0000 / 2, W_TX = 26'h020_0000 / 2, W_BG = 26'h028_0000 / 2, W_ROZ = 26'h068_0000 / 2, W_SPR = 26'h0A8_0000 / 2;

// ------------------------------------------------------------ ROM models
integer tx_cnt = 0, bg_cnt = 0, rz_cnt = 0, sp_cnt = 0, i;
reg [27:0] tx_la, bg_la, rz_la, sp_la;
always @(posedge clk) begin
	tx_valid <= 0;
	if (tx_cnt == 0) begin if (tx_req && !SDRAM) begin if (LAT == 0) begin for (i = 0; i < 8; i = i + 1) tx_data[8*i +: 8] <= txrom[(tx_addr + i) & txrom_mask]; tx_valid <= 1; end else begin tx_la <= tx_addr; tx_cnt <= LAT; end end end
	else if (tx_cnt == 1) begin for (i = 0; i < 8; i = i + 1) tx_data[8*i +: 8] <= txrom[(tx_la + i) & txrom_mask]; tx_valid <= 1; tx_cnt <= 0; end
	else tx_cnt <= tx_cnt - 1;
	bg_valid <= 0;
	if (bg_cnt == 0) begin if (bg_req && !SDRAM) begin if (LAT == 0) begin for (i = 0; i < 8; i = i + 1) bg_data[8*i +: 8] <= bgrom[(bg_addr + i) & bgrom_mask]; bg_valid <= 1; end else begin bg_la <= bg_addr; bg_cnt <= LAT; end end end
	else if (bg_cnt == 1) begin for (i = 0; i < 8; i = i + 1) bg_data[8*i +: 8] <= bgrom[(bg_la + i) & bgrom_mask]; bg_valid <= 1; bg_cnt <= 0; end
	else bg_cnt <= bg_cnt - 1;
	rz_valid <= 0;
	if (rz_cnt == 0) begin if (rz_req && !SDRAM) begin if (LAT == 0) begin for (i = 0; i < 8; i = i + 1) rz_data[8*i +: 8] <= rozrom[(rz_addr + i) & rozrom_mask]; rz_valid <= 1; end else begin rz_la <= rz_addr; rz_cnt <= LAT; end end end
	else if (rz_cnt == 1) begin for (i = 0; i < 8; i = i + 1) rz_data[8*i +: 8] <= rozrom[(rz_la + i) & rozrom_mask]; rz_valid <= 1; rz_cnt <= 0; end
	else rz_cnt <= rz_cnt - 1;
	sp_valid <= 0;
	if (sp_cnt == 0) begin if (sp_req && !SDRAM) begin if (LAT == 0) begin for (i = 0; i < 8; i = i + 1) sp_data[8*i +: 8] <= sprrom[(sp_addr + i) & sprrom_mask]; sp_valid <= 1; end else begin sp_la <= sp_addr; sp_cnt <= LAT; end end end
	else if (sp_cnt == 1) begin for (i = 0; i < 8; i = i + 1) sp_data[8*i +: 8] <= sprrom[(sp_la + i) & sprrom_mask]; sp_valid <= 1; sp_cnt <= 0; end
	else sp_cnt <= sp_cnt - 1;
end

// ------------------------------------------------------------ DDRAM model
// 64-bit words; the frame buffer's two banks at BASE (ms32_sprite_fb) are
// 0x80000 bytes = 0x10000 words. Avalon-MM bursts: a read command (RD
// while !BUSY) is followed, DDR_LAT clocks later, by BURSTCNT data beats
// on consecutive clocks; a write burst takes one beat per clock while WE
// and !BUSY, then BUSY for DDR_BUSY clocks. Same protocol assumptions as
// the RTL -- this model cannot prove them, only the board can.
localparam [27:0] FB_BASE = 28'h1000000;
reg [63:0] ddr [0:262143];   // 18-bit word index: frame buffer 0x00000-0x0FFFF, object copy 0x20000-0x21FFF
reg        ddr_busy = 0;
integer    ddr_busy_cnt = 0, ddr_rd_cnt = 0, ddr_rd_left = 0, ddr_wr_left = 0;
reg [17:0] ddr_rd_word, ddr_wr_word;
reg        ddr_ready = 0;
reg [63:0] ddr_dout;
integer    ddr_reads = 0, ddr_writes = 0, ddr_cmds = 0;
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
			ddr_dout <= ddr[ddr_rd_word]; ddr_ready <= 1; ddr_reads <= ddr_reads + 1;
			if (ddr_rd_left > 1) begin ddr_rd_left <= ddr_rd_left - 1; ddr_rd_word <= ddr_rd_word + 1; ddr_rd_cnt <= 1; end
			else begin ddr_rd_left <= 0; ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end
	end
	if (!ddr_busy) begin
		if (DDRAM_WE) begin
			if (ddr_wr_left == 0) begin ddr_wr_word = ddr_word; ddr_wr_left = DDRAM_BURSTCNT; ddr_cmds <= ddr_cmds + 1; end
			for (i = 0; i < 8; i = i + 1) if (DDRAM_BE[i]) ddr[ddr_wr_word][8*i +: 8] <= DDRAM_DIN[8*i +: 8];
			ddr_writes <= ddr_writes + 1;
			ddr_wr_word = ddr_wr_word + 1;
			ddr_wr_left = ddr_wr_left - 1;
			if (ddr_wr_left == 0) begin ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end else if (DDRAM_RD && ddr_rd_left == 0) begin
			ddr_rd_word <= ddr_word; ddr_rd_left <= DDRAM_BURSTCNT; ddr_rd_cnt <= DDR_LAT; ddr_cmds <= ddr_cmds + 1;
			ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY;
		end
	end
end

// ------------------------------------------------------------- capture
reg [23:0] out [0:320*224-1];
integer frame = 0;
wire [11:0] hcnt = u_video.hcnt, vcnt = u_video.vcnt;
always @(posedge clk) if (vblank_ev) frame <= frame + 1;
always @(posedge clk) begin
	if (ce_pix && !hblank && !vblank && frame == 3 && hcnt < 320 && vcnt < 224)
		out[vcnt * 320 + hcnt] <= {r, g, b};
end

// ------------------------------------------------------------- loading
reg [7:0] tmp [0:262143];
integer n, k, fd;

task write_ram(input integer which, input integer count);   // 0 tx 1 bg 2 roz 3 line 4 obj 5 pal 6 pri
	begin
		for (k = 0; k < count; k = k + 1) begin
			@(posedge clk);
			ram_addr  <= k;
			ram_wdata <= {tmp[4*k+1], tmp[4*k]};
			txram_we <= (which == 0); bgram_we <= (which == 1); rozram_we <= (which == 2); lineram_we <= (which == 3);
			objram_we <= (which == 4); palram_we <= (which == 5); priram_we <= (which == 6);
		end
		@(posedge clk);
		txram_we <= 0; bgram_we <= 0; rozram_we <= 0; lineram_we <= 0; objram_we <= 0; palram_we <= 0; priram_we <= 0;
	end
endtask

task write_regs(input integer base, input integer count);   // dwords -> 16-bit registers at base + 4k
	begin
		for (k = 0; k < count; k = k + 1) begin
			@(posedge clk);
			vreg_we <= 1; vreg_off <= base + 4 * k; vreg_data <= {tmp[4*k+1], tmp[4*k]};
		end
		@(posedge clk);
		vreg_we <= 0;
	end
endtask

initial begin
	if (!$value$plusargs("CAP=%s", CAP))   CAP = "tetrisp-title";
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 12;
	if (!$value$plusargs("DDR_BUSY=%d", DDR_BUSY)) DDR_BUSY = 6;
	if (!$value$plusargs("DDR_LAT=%d", DDR_LAT))   DDR_LAT = 20;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/", CAP};
	if (!$value$plusargs("STUB=%d", STUB)) STUB = 0;
	if (!$value$plusargs("SDRAM=%d", SDRAM)) SDRAM = 0;

	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); if (!fd) begin $display("FATAL no txtiles_dec.bin"); $finish; end
	n = $fread(txrom, fd); $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); if (!fd) begin $display("FATAL no bgtiles_dec.bin"); $finish; end
	n = $fread(bgrom, fd); $fclose(fd); bgrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb"); if (!fd) begin $display("FATAL no roztiles.bin"); $finish; end
	n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/sprite.bin"}, "rb"); if (!fd) begin $display("FATAL no sprite.bin"); $finish; end
	n = $fread(sprrom, fd); $fclose(fd); sprrom_mask = n - 1;
	if ((n & (n - 1)) != 0) sprrom_mask = (1 << $clog2(n)) - 1;   // p47aces: 14 MB, see tb_sprite
	$display("ROMs: tx %0d bg %0d roz %0d sprite %0d bytes", txrom_mask + 1, bgrom_mask + 1, rozrom_mask + 1, sprrom_mask + 1);
	if (SDRAM) begin
		// images into the chip model at the map bases, word by word; the
		// engines mask their addresses to the region, so the model wraps too
		// and a partial region holds the ROM repeated (as the .mra does)
		for (k = 0; k < (26'h028_0000 - 26'h020_0000) / 2; k = k + 1) u_chip.mem[W_TX  + k] = {txrom[(2*k+1) & txrom_mask],  txrom[(2*k) & txrom_mask]};
		for (k = 0; k < (26'h068_0000 - 26'h028_0000) / 2; k = k + 1) u_chip.mem[W_BG  + k] = {bgrom[(2*k+1) & bgrom_mask],  bgrom[(2*k) & bgrom_mask]};
		for (k = 0; k < (26'h0A8_0000 - 26'h068_0000) / 2; k = k + 1) u_chip.mem[W_ROZ + k] = {rozrom[(2*k+1) & rozrom_mask], rozrom[(2*k) & rozrom_mask]};
		for (k = 0; k < (26'h1A8_0000 - 26'h0A8_0000) / 2; k = k + 1) u_chip.mem[W_SPR + k] = {sprrom[(2*k+1) & sprrom_mask], sprrom[(2*k) & sprrom_mask]};
		$display("SDRAM chip model preloaded; the real memory stack serves the ROM ports");
	end
	if (STUB) begin
		// MS32.sv ROM_STUB: pen = addr[7:0] ^ addr[15:8] ^ addr[23:16] of the granule address, every byte
		txrom_mask = (1 << 19) - 1; bgrom_mask = (1 << 22) - 1; rozrom_mask = (1 << 22) - 1; sprrom_mask = (1 << 24) - 1;
		for (k = 0; k < (1 << 19); k = k + 1) txrom[k]  = ((k & ~7) & 8'hFF) ^ (((k & ~7) >> 8) & 8'hFF) ^ (((k & ~7) >> 16) & 8'hFF);
		for (k = 0; k < (1 << 22); k = k + 1) bgrom[k]  = ((k & ~7) & 8'hFF) ^ (((k & ~7) >> 8) & 8'hFF) ^ (((k & ~7) >> 16) & 8'hFF);
		for (k = 0; k < (1 << 22); k = k + 1) rozrom[k] = ((k & ~7) & 8'hFF) ^ (((k & ~7) >> 8) & 8'hFF) ^ (((k & ~7) >> 16) & 8'hFF);
		for (k = 0; k < (1 << 24); k = k + 1) sprrom[k] = ((k & ~7) & 8'hFF) ^ (((k & ~7) >> 8) & 8'hFF) ^ (((k & ~7) >> 16) & 8'hFF);
		$display("ROM STUB pattern in place of the ROMs");
	end
	for (k = 0; k < 262144; k = k + 1) ddr[k] = 64'd0;
	for (k = 0; k < 320*224; k = k + 1) out[k] = 24'h000000;

	repeat (20) @(posedge clk);
	sd_init = 0;
	repeat (200) @(posedge clk);   // the controller's init sequence before any request
	reset = 0;
	repeat (4) @(posedge clk);

	fd = $fopen({"debug/", CAP, "/", GAME, "_txram.bin"}, "rb");   n = $fread(tmp, fd); $fclose(fd); write_ram(0, 8192);
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgram.bin"}, "rb");   n = $fread(tmp, fd); $fclose(fd); write_ram(1, 8192);
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozram.bin"}, "rb");  n = $fread(tmp, fd); $fclose(fd); write_ram(2, 32768);
	fd = $fopen({"debug/", CAP, "/", GAME, "_lineram.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd); write_ram(3, 2048);
	fd = $fopen({"debug/", CAP, "/", GAME, "_sprram_vbl.bin"}, "rb");
	if (!fd) fd = $fopen({"debug/", CAP, "/", GAME, "_sprram.bin"}, "rb");
	n = $fread(tmp, fd); $fclose(fd); write_ram(4, 32768);
	fd = $fopen({"debug/", CAP, "/", GAME, "_palram.bin"}, "rb");  n = $fread(tmp, fd); $fclose(fd); write_ram(5, 65536);
	fd = $fopen({"debug/", CAP, "/", GAME, "_priram.bin"}, "rb");  n = $fread(tmp, fd); $fclose(fd); write_ram(6, 8192);
	fd = $fopen({"debug/", CAP, "/", GAME, "_txscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd); write_regs(12'hA00, 6);
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgscroll.bin"}, "rb"); n = $fread(tmp, fd); $fclose(fd); write_regs(12'hA20, 6);
	fd = $fopen({"debug/", CAP, "/", GAME, "_bgmode.bin"}, "rb");   n = $fread(tmp, fd); $fclose(fd); write_regs(12'hA7C, 1);
	fd = $fopen({"debug/", CAP, "/", GAME, "_rozctrl.bin"}, "rb");  n = $fread(tmp, fd); $fclose(fd); write_regs(12'h600, 24);
	fd = $fopen({"debug/", CAP, "/", GAME, "_sprctrl.bin"}, "rb");  n = $fread(tmp, fd); $fclose(fd); write_regs(12'h200, 32);
	// brightness: the last values in the write log, when there is one
	begin : brt
		integer wl, fr, ln, ad, mk, dt, pc, b0, b1;
		b0 = 0; b1 = 0;
		wl = $fopen({"debug/", CAP, "/", GAME, "_writes.log"}, "r");
		if (wl) begin
			while (!$feof(wl)) begin
				if ($fscanf(wl, "%d %d %h %h %h %h\n", fr, ln, ad, mk, dt, pc) == 6) begin
					if (ad == 32'hFCE00280) b0 = dt;
					if (ad == 32'hFCE00284) b1 = dt;
				end else begin
					void'($fgets(tmp_line, wl));
				end
			end
			$fclose(wl);
		end
		@(posedge clk); vreg_we <= 1; vreg_off <= 12'h280; vreg_data <= b0[15:0];
		@(posedge clk); vreg_off <= 12'h284; vreg_data <= b1[15:0];
		@(posedge clk); vreg_we <= 0;
		$display("%s: brightness %04x %04x, LAT %0d, DDR busy %0d lat %0d", CAP, b0[15:0], b1[15:0], LAT, DDR_BUSY, DDR_LAT);
	end

	wait (frame == 4);
	@(posedge clk);
	fd = $fopen({OUTDIR, "/sim_rgb.txt"}, "w"); if (!fd) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%06x\n", out[k]);
	$fclose(fd);
	$display("frame written to %s; overrun tx=%0d bg=%0d roz=%0d spr=%0d fb=%0d bad_primask=%0d", OUTDIR, tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm);
	$display("sprites: %0d drawn in %0d clk (%0d%% of a frame); DDRAM %0d commands, %0d read beats, %0d write beats per run", spr_drawn, spr_cycles, spr_cycles * 100 / 1615872, ddr_cmds, ddr_reads, ddr_writes);
	$finish;
end
string tmp_line;

endmodule
