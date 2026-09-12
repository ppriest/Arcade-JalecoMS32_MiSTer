// SPDX-License-Identifier: GPL-3.0-or-later
//
// SDRAM backend for MS32: every ROM the core reads at runtime, on the one
// 32 MB chip, behind Seta's controller stack (rtl/memory/sdram/PROVENANCE.md).
//
// ADDRESS MAP -- fixed, one layout for every set. Region sizes are the largest
// in the game list (ROADMAP "Game scope"); an .mra fills each region by
// REPEATING its ROM data to the region size, which reproduces MAME's
// tile-number wrap (off % rom_length) for any ROM length, so the engines
// simply mask their addresses to the region.
//
//   maincpu   0x000_0000   2 MB     V70 program, ROM_LOAD32_BYTE x4 interleaved by the .mra
//   txtiles   0x020_0000   0.5 MB   8x8x8 tiles, DECRYPTED on the way in
//   bgtiles   0x028_0000   4 MB     16x16x8 tiles, DECRYPTED on the way in
//   roztiles  0x068_0000   4 MB     16x16x8 tiles
//   sprite    0x0A8_0000   16 MB    256x256 pages, ROM_LOAD32_WORD x2 interleaved by the .mra
//   audiocpu  0x1A8_0000   256 KB   Z80 program
//   (ymf samples, 4 MB, are Phase 3: they fit after audiocpu, 0x1AC_0000..0x1EC_0000)
//
// PORTS -- sdram.sv's three ports are FIXED PRIORITY 0 > 1 > 2 on one chip:
//   port 0   TX, BG and ROZ tile fetch (arbiter of 3): the hardest deadline, one line of lead
//   port 1   sprite graphics: a frame of lead
//   port 2   CPU instruction granules, CPU data words, Z80 bytes, and the download
//
// TILE DECRYPTION happens on the way in (ms32_jalcrpt_pkg.sv, generated and
// checked by scripts/gen_jalcrpt.py): a source byte at region offset j is
// stored at Linv(j) ^ addr_xor, XORed with (dest & 0xff) ^ data_xor. Those
// destinations are not sequential, so sdram_download's byte-pair
// coalescing does not apply inside those regions (it flushes every byte as
// a single write, which it does by itself when addresses do not pair). The
// key comes from the .mra mod byte.
//
// Every client is on the arbiter's hold-until-acknowledged contract; the
// video engines' req drops on valid, so each gets the latch Seta uses.
`default_nettype none

module ms32_sdram_top (
	input  wire         clk,
	input  wire         reset,          // MUST be reset & ~ioctl_download (seta_sdram_top's header)
	input  wire         init,           // ~pll_locked, never a core reset

	output wire [12:0]  SDRAM_A,
	inout  wire [15:0]  SDRAM_DQ,
	output wire         SDRAM_DQML,
	output wire         SDRAM_DQMH,
	output wire  [1:0]  SDRAM_BA,
	output wire         SDRAM_nCS,
	output wire         SDRAM_nWE,
	output wire         SDRAM_nRAS,
	output wire         SDRAM_nCAS,
	output wire         SDRAM_CKE,
	output wire         SDRAM_CLK,

	// HPS download, ioctl index 0
	input  wire         ioctl_download,
	input  wire [15:0]  ioctl_index,
	input  wire         ioctl_wr,
	input  wire [26:0]  ioctl_addr,
	input  wire  [7:0]  ioctl_dout,
	output wire         ioctl_wait,
	input  wire  [1:0]  key,            // decryption key select (mod byte)

	// tile engines: region-local byte address of an 8-byte granule
	input  wire         tx_req,  input wire [23:0] tx_addr,  output wire tx_valid,  output wire [63:0] tx_data,
	input  wire         bg_req,  input wire [23:0] bg_addr,  output wire bg_valid,  output wire [63:0] bg_data,
	input  wire         roz_req, input wire [23:0] roz_addr, output wire roz_valid, output wire [63:0] roz_data,
	input  wire         spr_req, input wire [27:0] spr_addr, output wire spr_valid, output wire [63:0] spr_data,

	// V70 instruction fetch: one 8-byte granule, region-local
	input  wire         if_req,  input wire [20:3] if_addr,  output wire if_valid,  output wire [63:0] if_data,
	// V70 data reads from ROM: 32-bit words, region-local byte address
	input  wire         cpu_req, input wire [20:0] cpu_addr, output wire cpu_valid, output wire [31:0] cpu_data,
	// Z80 program: bytes, region-local
	input  wire         z80_req, input wire [17:0] z80_addr, output wire z80_valid, output wire  [7:0] z80_data,

	// for the ISSP probe
	output wire         dbg_dl_req,
	output wire         dbg_dl_busy
);

	import ms32_jalcrpt_pkg::*;

	localparam logic [25:0] BASE_MAINCPU  = 26'h000_0000;
	localparam logic [25:0] BASE_TXTILES  = 26'h020_0000;
	localparam logic [25:0] BASE_BGTILES  = 26'h028_0000;
	localparam logic [25:0] BASE_ROZTILES = 26'h068_0000;
	localparam logic [25:0] BASE_SPRITE   = 26'h0A8_0000;
	localparam logic [25:0] BASE_AUDIOCPU = 26'h1A8_0000;
	localparam logic [25:0] END_AUDIOCPU  = 26'h1AC_0000;
	localparam logic [23:0] MASK_TX  = 24'h07_FFFF;
	localparam logic [23:0] MASK_BG  = 24'h3F_FFFF;
	localparam logic [23:0] MASK_ROZ = 24'h3F_FFFF;
	localparam logic [27:0] MASK_SPR = 28'h0FF_FFFF;

	// ------------------------------------------------------------ download
	// One registered stage computes where each byte goes and what it becomes.
	wire in_tx = (ioctl_addr[25:0] >= BASE_TXTILES) && (ioctl_addr[25:0] < BASE_BGTILES);
	wire in_bg = (ioctl_addr[25:0] >= BASE_BGTILES) && (ioctl_addr[25:0] < BASE_ROZTILES);
	wire [18:0] tx_j = ioctl_addr[18:0];                          // region offset, 512 KB
	wire [21:0] bg_j = ioctl_addr[25:0] - BASE_BGTILES;           // region offset, 4 MB
	wire [18:0] tx_i = tx_linv(tx_j) ^ TX_AXOR[key];
	wire [19:0] bg_i = bg_linv(bg_j[19:0]) ^ BG_AXOR[key];        // bits above 19 pass through
	wire [25:0] dl_addr_c = in_tx ? BASE_TXTILES + {7'd0, tx_i}
	                      : in_bg ? BASE_BGTILES + {4'd0, bg_j[21:20], bg_i}
	                      : ioctl_addr[25:0];
	wire  [7:0] dl_data_c = in_tx ? ioctl_dout ^ tx_i[7:0] ^ TX_DXOR[key]
	                      : in_bg ? ioctl_dout ^ bg_i[7:0] ^ BG_DXOR[key]
	                      : ioctl_dout;

	logic [26:0] ioctl_addr_q;
	logic        ioctl_wr_q, ioctl_dl_q;
	logic [15:0] ioctl_index_q;
	logic  [7:0] ioctl_dout_q;
	always_ff @(posedge clk) begin
		ioctl_addr_q  <= {1'b0, dl_addr_c};
		ioctl_wr_q    <= ioctl_wr;
		ioctl_dl_q    <= ioctl_download;
		ioctl_index_q <= ioctl_index;
		ioctl_dout_q  <= dl_data_c;
	end

	wire        dl_req, dl_we16, dl_busy, dl_ioctl_wait;
	assign dbg_dl_req  = dl_req;
	assign dbg_dl_busy = dl_busy;
	wire [25:0] dl_addr;
	wire [15:0] dl_data;
	// The registered stage delays the byte by a cycle, and sdram_download only
	// raises its own wait the cycle after it accepts: without ioctl_wr_q here
	// there is a one-cycle hole in which a fast sender's next byte arrives
	// while the download FSM is busy and is dropped (sim/sdram_dl_tb found
	// half the bytes missing). hps_io never sends that fast; the bench did.
	assign ioctl_wait = dl_ioctl_wait | ioctl_wr | ioctl_wr_q;
	sdram_download u_dl (
		.clk(clk), .reset(reset),
		.ioctl_download(ioctl_dl_q), .ioctl_index(ioctl_index_q),
		.ioctl_wr(ioctl_wr_q), .ioctl_addr(ioctl_addr_q), .ioctl_dout(ioctl_dout_q),
		.ioctl_wait(dl_ioctl_wait),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
	);

	// ------------------------------------------------------------ controller
	logic [25:1] p_addr [0:2];
	logic        p_wrl  [0:2], p_wrh [0:2], p_req [0:2];
	logic [15:0] p_din  [0:2];
	wire  [63:0] p_dout [0:2];
	wire         p_ack  [0:2];
	sdram u_sdram (
		.SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
		.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
		.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CLK(SDRAM_CLK), .SDRAM_CKE(SDRAM_CKE),
		.init(init), .clk(clk),
		.addr0(p_addr[0]), .wrl0(p_wrl[0]), .wrh0(p_wrh[0]), .din0(p_din[0]), .dout0(p_dout[0]), .req0(p_req[0]), .ack0(p_ack[0]),
		.addr1(p_addr[1]), .wrl1(p_wrl[1]), .wrh1(p_wrh[1]), .din1(p_din[1]), .dout1(p_dout[1]), .req1(p_req[1]), .ack1(p_ack[1]),
		.addr2(p_addr[2]), .wrl2(p_wrl[2]), .wrh2(p_wrh[2]), .din2(p_din[2]), .dout2(p_dout[2]), .req2(p_req[2]), .ack2(p_ack[2])
	);

	logic        phy_req  [0:2], phy_we [0:2], phy_we16 [0:2];
	logic [25:0] phy_addr [0:2];
	logic [15:0] phy_wdata[0:2];
	wire         phy_busy [0:2], phy_valid[0:2];
	wire  [63:0] phy_rdata[0:2];
	genvar gi;
	generate
		for (gi = 0; gi < 3; gi = gi + 1) begin : g_phy
			sdram_phy u_phy (
				.clk(clk), .reset(reset),
				.port_addr(p_addr[gi]), .port_wrl(p_wrl[gi]), .port_wrh(p_wrh[gi]),
				.port_din(p_din[gi]), .port_dout(p_dout[gi]), .port_req(p_req[gi]), .port_ack(p_ack[gi]),
				.req(phy_req[gi]), .we(phy_we[gi]), .we16(phy_we16[gi]),
				.addr(phy_addr[gi]), .wdata(phy_wdata[gi]),
				.busy(phy_busy[gi]), .valid(phy_valid[gi]), .rdata(phy_rdata[gi])
			);
		end
	endgenerate

	// ---------------------------------------------- request latches (level until valid)
	logic tx_l, bg_l, roz_l, spr_l, if_l;
	always_ff @(posedge clk) begin
		if (reset) begin tx_l <= 1'b0; bg_l <= 1'b0; roz_l <= 1'b0; spr_l <= 1'b0; if_l <= 1'b0; end
		else begin
			if (tx_valid)  tx_l  <= 1'b0; else if (tx_req)  tx_l  <= 1'b1;
			if (bg_valid)  bg_l  <= 1'b0; else if (bg_req)  bg_l  <= 1'b1;
			if (roz_valid) roz_l <= 1'b0; else if (roz_req) roz_l <= 1'b1;
			if (spr_valid) spr_l <= 1'b0; else if (spr_req) spr_l <= 1'b1;
			if (if_valid)  if_l  <= 1'b0; else if (if_req)  if_l  <= 1'b1;
		end
	end

	// ------------------------------------------------------ port 0: tiles
	wire [2:0]  arb0_valid;
	wire [63:0] arb0_rdata;
	assign tx_valid  = arb0_valid[0];  assign tx_data  = arb0_rdata;
	assign bg_valid  = arb0_valid[1];  assign bg_data  = arb0_rdata;
	assign roz_valid = arb0_valid[2];  assign roz_data = arb0_rdata;
	sdram_arbiter #(.N(3)) u_arb0 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[0]), .phy_we(phy_we[0]), .phy_we16(phy_we16[0]),
		.phy_addr(phy_addr[0]), .phy_wdata(phy_wdata[0]),
		.phy_busy(phy_busy[0]), .phy_valid(phy_valid[0]), .phy_rdata(phy_rdata[0]),
		.c_req({roz_l, bg_l, tx_l}),
		.c_addr({BASE_ROZTILES + {2'd0, roz_addr & MASK_ROZ},
		         BASE_BGTILES  + {2'd0, bg_addr  & MASK_BG},
		         BASE_TXTILES  + {2'd0, tx_addr  & MASK_TX}}),
		.c_valid(arb0_valid), .c_rdata(arb0_rdata),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ---------------------------------------------------- port 1: sprites
	sdram_arbiter #(.N(1)) u_arb1 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[1]), .phy_we(phy_we[1]), .phy_we16(phy_we16[1]),
		.phy_addr(phy_addr[1]), .phy_wdata(phy_wdata[1]),
		.phy_busy(phy_busy[1]), .phy_valid(phy_valid[1]), .phy_rdata(phy_rdata[1]),
		.c_req(spr_l), .c_addr(BASE_SPRITE + {2'd0, spr_addr[23:0] & MASK_SPR[23:0]}),
		.c_valid(spr_valid), .c_rdata(spr_data),
		.dl_req(1'b0), .dl_addr(26'd0), .dl_data(16'd0), .dl_we16(1'b0), .dl_busy()
	);

	// ------------------------------------------- port 2: CPUs and the download
	wire        cpu_g_req, cpu_g_valid, z80_g_req, z80_g_valid;
	wire [25:0] cpu_g_addr, z80_g_addr;
	wire [63:0] cpu_g_data, z80_g_data;
	sdram_narrow_bridge #(.WORD_BYTES(4)) u_cpu_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(cpu_req), .addr({5'd0, cpu_addr}), .valid(cpu_valid), .data(cpu_data),
		.g_req(cpu_g_req), .g_addr(cpu_g_addr), .g_valid(cpu_g_valid), .g_data(cpu_g_data)
	);
	sdram_narrow_bridge #(.WORD_BYTES(1)) u_z80_bridge (
		.clk(clk), .reset(reset), .inval(ioctl_download),
		.req(z80_req), .addr({8'd0, z80_addr}), .valid(z80_valid), .data(z80_data),
		.g_req(z80_g_req), .g_addr(z80_g_addr), .g_valid(z80_g_valid), .g_data(z80_g_data)
	);
	wire [2:0]  arb2_valid;
	wire [63:0] arb2_rdata;
	assign if_valid    = arb2_valid[0];  assign if_data    = arb2_rdata;
	assign cpu_g_valid = arb2_valid[1];  assign cpu_g_data = arb2_rdata;
	assign z80_g_valid = arb2_valid[2];  assign z80_g_data = arb2_rdata;
	sdram_arbiter #(.N(3)) u_arb2 (
		.clk(clk), .reset(reset),
		.phy_req(phy_req[2]), .phy_we(phy_we[2]), .phy_we16(phy_we16[2]),
		.phy_addr(phy_addr[2]), .phy_wdata(phy_wdata[2]),
		.phy_busy(phy_busy[2]), .phy_valid(phy_valid[2]), .phy_rdata(phy_rdata[2]),
		.c_req({z80_g_req, cpu_g_req, if_l}),
		.c_addr({BASE_AUDIOCPU + z80_g_addr,
		         BASE_MAINCPU  + cpu_g_addr,
		         BASE_MAINCPU  + {5'd0, if_addr, 3'd0}}),
		.c_valid(arb2_valid), .c_rdata(arb2_rdata),
		.dl_req(dl_req), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we16(dl_we16), .dl_busy(dl_busy)
	);

endmodule
`default_nettype wire
