// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Download bench: stream a set's ENCRYPTED txtiles and the first 1 MB of
//  its bgtiles through ms32_sdram_top's ioctl port, in the order and at the
//  addresses the .mra would deliver them, then compare the chip model's
//  contents with build_rom_image.py's decrypted images (txtiles_dec.bin,
//  bgtiles_dec.bin). This is the test of the decryption on the way in and
//  of sdram_download's single-byte fallback for scrambled destinations.
//
//      scripts/run_sim.sh sdram_dl_tb +GAME=tetrisp +KEY=1
//
//  KEY is the mod byte's key index (build_mra.py's KEY_INDEX for the set).
`timescale 1ns/1ps

module tb_sdram_dl;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1, init = 1;

string GAME;
integer KEY;

reg [7:0] txenc [0:(1 << 19) - 1];
reg [7:0] txdec [0:(1 << 19) - 1];
reg [7:0] bgenc [0:(1 << 20) - 1];
reg [7:0] bgdec [0:(1 << 20) - 1];

wire [12:0] SDRAM_A;
wire [15:0] SDRAM_DQ;
wire  [1:0] SDRAM_BA;
wire        SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CLK, SDRAM_CKE;

reg         ioctl_download = 0, ioctl_wr = 0;
reg  [26:0] ioctl_addr = 0;
reg  [7:0]  ioctl_dout = 0;
wire        ioctl_wait;

ms32_sdram_top u_sdram (
	.clk(clk), .reset(reset), .init(init),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(SDRAM_CLK),
	.ioctl_download(ioctl_download), .ioctl_index(16'd0), .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait), .key(KEY[1:0]),
	.tx_req(1'b0), .tx_addr(24'd0), .tx_valid(), .tx_data(),
	.bg_req(1'b0), .bg_addr(24'd0), .bg_valid(), .bg_data(),
	.roz_req(1'b0), .roz_addr(24'd0), .roz_valid(), .roz_data(),
	.spr_req(1'b0), .spr_addr(28'd0), .spr_valid(), .spr_data(),
	.if_req(1'b0), .if_addr(18'd0), .if_valid(), .if_data(),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(1'b0), .z80_addr(18'd0), .z80_valid(), .z80_data()
);
sdram_chip_model_wide u_chip (
	.clk(clk), .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS)
);

localparam [25:0] BASE_TX = 26'h020_0000, BASE_BG = 26'h028_0000;

// hps_io's byte stream: one ioctl_wr pulse per byte, the next only once
// ioctl_wait has been seen low after the pulse. Back-to-back bytes with no
// gap are faster than the HPS ever is; GAP models its pacing (0 is the
// worst case the RTL must survive).
integer GAP;
task send(input [26:0] addr, input [7:0] d);
	begin
		ioctl_addr <= addr; ioctl_dout <= d; ioctl_wr <= 1;
		@(posedge clk);
		ioctl_wr <= 0;
		repeat (GAP) @(posedge clk);
		@(posedge clk);
		while (ioctl_wait) @(posedge clk);
	end
endtask

integer fd, n, k, bad, a;
reg [15:0] w;
initial begin
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("KEY=%d", KEY)) KEY = 1;
	if (!$value$plusargs("GAP=%d", GAP)) GAP = 0;
	fd = $fopen({"roms/", GAME, "/txtiles.bin"}, "rb");     n = $fread(txenc, fd); $fclose(fd);
	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); n = $fread(txdec, fd); $fclose(fd);
	fd = $fopen({"roms/", GAME, "/bgtiles.bin"}, "rb");     n = $fread(bgenc, fd); $fclose(fd);
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); n = $fread(bgdec, fd); $fclose(fd);
	for (k = 0; k < (1 << 24); k = k + 1) u_chip.mem[k] = 16'hEEEE;

	repeat (20) @(posedge clk);
	init = 0;
	repeat (300) @(posedge clk);
	reset = 0;                       // the memory path's reset is NOT the download's
	repeat (10) @(posedge clk);

	ioctl_download <= 1;
	repeat (4) @(posedge clk);
	for (k = 0; k < (1 << 19); k = k + 1) send(BASE_TX + k, txenc[k]);
	for (k = 0; k < (1 << 20); k = k + 1) send(BASE_BG + k, bgenc[k]);
	repeat (50) @(posedge clk);
	ioctl_download <= 0;
	repeat (200) @(posedge clk);

	bad = 0;
	for (k = 0; k < (1 << 19); k = k + 1) begin
		a = (BASE_TX + k) >> 1; w = u_chip.mem[a];
		if ((k[0] ? w[15:8] : w[7:0]) !== txdec[k]) begin
			if (bad < 8) $display("TX mismatch at %06x: chip %02x, expected %02x", k, k[0] ? w[15:8] : w[7:0], txdec[k]);
			bad = bad + 1;
		end
	end
	$display("txtiles: %0d of %0d bytes differ", bad, 1 << 19);
	bad = 0;
	for (k = 0; k < (1 << 20); k = k + 1) begin
		a = (BASE_BG + k) >> 1; w = u_chip.mem[a];
		if ((k[0] ? w[15:8] : w[7:0]) !== bgdec[k]) begin
			if (bad < 8) $display("BG mismatch at %06x: chip %02x, expected %02x", k, k[0] ? w[15:8] : w[7:0], bgdec[k]);
			bad = bad + 1;
		end
	end
	$display("bgtiles (first 1 MB): %0d of %0d bytes differ", bad, 1 << 20);
	$finish;
end

endmodule
