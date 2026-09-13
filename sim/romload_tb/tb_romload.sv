// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Fast ROM load: the .mra's download stream sits in a DDR3 model, as the HPS
//  leaves it for an .mra with address="0x30000000", and ms32_rom_loader
//  replays it through ddram_phy into ms32_sdram_top's download port and the
//  SDRAM chip model. The chip is then compared, region by region, against
//  build_rom_image.py's images: txtiles and bgtiles decrypted, the rest as is.
//
//      scripts/run_sim.sh romload_tb +GAME=tetrisp +KEY=1 +LEN=380000
//
//  ModelSim, not Verilator: Verilator rejects the vendored sdram_arbiter.sv's
//  zero-width cast for a single-client port.
//
//  +STREAM  the stream file (default simout/<GAME>_stream.bin)
//  +LEN     bytes to copy, hex (default the whole map, 1BC0000)
`timescale 1ns/1ps

module tb_romload;

reg clk = 0;
always #5.208 clk = ~clk;
reg init = 1, rst = 1;

string  GAME, STREAM;
integer KEY;
reg [27:0] LEN;

// ------------------------------------------------------------- DDR3 model
// single-beat reads of 64-bit words at DDRAM_ADDR[24:0] (byte 0x30000000 +
// 8*word), a few clocks of latency
reg [7:0] stream [0:(1 << 25) - 1];
wire        DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY;
wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN;
reg  [63:0] DDRAM_DOUT;
reg         busy_r = 0, ready_r = 0;
integer     lat = 0, i;
reg  [24:0] rd_word;
assign DDRAM_BUSY = busy_r;
assign DDRAM_DOUT_READY = ready_r;
always @(posedge clk) begin
	ready_r <= 0;
	if (lat > 0) begin
		lat <= lat - 1;
		if (lat == 1) begin
			for (i = 0; i < 8; i = i + 1) DDRAM_DOUT[8*i +: 8] <= stream[{rd_word, 3'b000} + i];
			ready_r <= 1; busy_r <= 0;
		end
	end else if (DDRAM_RD && !busy_r) begin
		rd_word <= DDRAM_ADDR[24:0]; lat <= 5; busy_r <= 1;
	end
end

// ------------------------------------------------------------- loader, SDRAM
wire        l_wr, l_active, sd_wait;
wire [26:0] l_addr;
wire  [7:0] l_dout;
wire        ddr_req, ddr_busy, ddr_valid;
wire [27:0] ddr_addr;
wire [63:0] ddr_rdata;
reg         start = 0;

ddram_phy u_phy (
	.clk(clk), .reset(~l_active),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.req(ddr_req), .we(1'b0), .addr(ddr_addr), .wdata(8'd0),
	.busy(ddr_busy), .valid(ddr_valid), .rdata(ddr_rdata)
);
ms32_rom_loader #(.LENGTH(28'h1BC_0000)) u_ldr (
	.clk(clk), .reset(rst),
	.start(start), .active(l_active),
	.ddr_req(ddr_req), .ddr_addr(ddr_addr), .ddr_busy(ddr_busy), .ddr_valid(ddr_valid), .ddr_rdata(ddr_rdata),
	.l_wr(l_wr), .l_addr(l_addr), .l_dout(l_dout), .l_wait(sd_wait)
);

wire [12:0] SDRAM_A;
wire [15:0] SDRAM_DQ;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;
ms32_sdram_top u_sdram (
	.clk(clk), .reset(rst & ~l_active), .init(init),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.ioctl_download(l_active), .ioctl_index(16'd0), .ioctl_wr(l_wr), .ioctl_addr(l_addr),
	.ioctl_dout(l_dout), .ioctl_wait(sd_wait), .key(KEY[1:0]), .spr25(1'b0),
	.tx_req(1'b0), .tx_addr(24'd0), .tx_valid(), .tx_data(),
	.bg_req(1'b0), .bg_addr(24'd0), .bg_valid(), .bg_data(),
	.roz_req(1'b0), .roz_addr(24'd0), .roz_valid(), .roz_data(),
	.spr_req(1'b0), .spr_addr(28'd0), .spr_valid(), .spr_data(),
	.if_req(1'b0), .if_addr(18'd0), .if_valid(), .if_data(),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(1'b0), .z80_addr(18'd0), .z80_valid(), .z80_data(),
	.dbg_dl_req(), .dbg_dl_busy()
);
sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

// ------------------------------------------------------------- check
reg [7:0] img [0:(1 << 24) - 1];
integer fd, n, k, bad, total_bad;

task check(input string name, input integer base, input integer size, input integer block);
	// block: a partial copy only checks whole blocks the decryption scrambles within
	integer lim;
	begin
		lim = LEN - base;
		if (lim > size) lim = size;
		if (lim < 0) lim = 0;
		lim = lim - (lim % block);
		fd = $fopen({"roms/", GAME, "/", name, ".bin"}, "rb");
		if (fd == 0) begin $display("FATAL no %s", name); $finish; end
		n = $fread(img, fd); $fclose(fd);
		bad = 0;
		for (k = 0; k < lim; k = k + 1)
			if ((k[0] ? u_chip.mem[(base + k) >> 1][15:8] : u_chip.mem[(base + k) >> 1][7:0]) !== img[k % n]) begin
				if (bad < 4) $display("  %s +%06x: sdram %02x, image %02x", name, k,
				                      k[0] ? u_chip.mem[(base + k) >> 1][15:8] : u_chip.mem[(base + k) >> 1][7:0], img[k % n]);
				bad = bad + 1;
			end
		$display("%-16s %0d of %0d bytes differ", name, bad, lim);
		total_bad = total_bad + bad;
	end
endtask

integer t0;
initial begin
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("KEY=%d", KEY))   KEY = 1;
	if (!$value$plusargs("STREAM=%s", STREAM)) STREAM = {"simout/", GAME, "_stream.bin"};
	if (!$value$plusargs("LEN=%h", LEN))   LEN = 28'h1BC_0000;
	fd = $fopen(STREAM, "rb"); if (fd == 0) begin $display("FATAL no %s", STREAM); $finish; end
	n = $fread(stream, fd); $fclose(fd);
	$display("stream %0d bytes, copying %0d", n, LEN);
	for (k = 0; k < (1 << 24); k = k + 1) u_chip.mem[k] = 16'hEEEE;

	repeat (20) @(posedge clk); init = 0;
	repeat (300) @(posedge clk); rst = 0;
	repeat (10) @(posedge clk);
	start = 1; @(posedge clk); start = 0;
	t0 = $time;
	while (!l_active) @(posedge clk);
	while (l_active && u_ldr.base < LEN) @(posedge clk);
	repeat (200) @(posedge clk);
	$display("copy took %0d clocks", ($time - t0) * 1000 / 10416);
	total_bad = 0;
	check("maincpu",      26'h000_0000, 26'h020_0000, 1);
	check("txtiles_dec",  26'h020_0000, 26'h008_0000, 26'h008_0000);
	check("bgtiles_dec",  26'h028_0000, 26'h040_0000, 26'h010_0000);
	check("roztiles",     26'h068_0000, 26'h040_0000, 1);
	check("sprite",       26'h0A8_0000, 26'h110_0000, 1);
	$display("ROMLOAD: %0d bytes differ in total", total_bad);
	$finish;
end

endmodule
