// SPDX-License-Identifier: GPL-3.0-or-later
//
// F-1 Super Battle's mixer: the priority RAM decides every pixel, rather than
// the three probes and the case table the other twenty-one sets use.
//
// From ms32_v.cpp's ms32_f1superbattle_state::mix_layers() (MAME PR 16135),
// checked against scripts/render_model.py mix_f1(). Per dot a 13-bit index:
//
//   bit 12     sprite transparent
//   bit 11     text transparent
//   bit 10     always 1
//   bit  9     ROZ transparent
//   bit  8     road plane transparent
//   bit  7     BG transparent
//   bits 6-3   the sprite's priority nibble
//   bits 2-0   line depth: colour bits 6-4 of the ROZ line, or of the road
//              line where the ROZ plane is transparent
//
// and the byte there says what to show: bits 5-3 the layer (0 sprite, 1 BG,
// 2 ROZ, 4 road, 6 text, anything else nothing), bit 6 the backdrop instead,
// and bit 2 clear halves the brightness. Bits 1-0 are ignored, as in MAME.
//
// The index is formed and read every dot -- the priority RAM's second port is
// free at pixel rate -- so a change the game makes takes effect immediately,
// where the other mixer's tables wait for the next frame. That matches MAME,
// which reads the RAM per pixel here and once per frame there.
//
// Pipeline: index (0) -> priority RAM read (1) -> select and palette read (2)
// -> palette words (2b) -> brightness (3) -> half (4). Six clocks, inside the
// shortest dot period of 12.
module ms32_mixer_f1 (
	input  logic        clk,
	input  logic        reset,

	// the dot at hcnt
	input  logic [7:0]  tx_pen,   input logic [3:0] tx_col,   input logic tx_op,
	input  logic [7:0]  bg_pen,   input logic [3:0] bg_col,   input logic bg_op,
	input  logic [7:0]  roz_pen,  input logic [3:0] roz_col,  input logic roz_op,
	input  logic [7:0]  road_pen, input logic [3:0] road_col, input logic road_op,
	input  logic [15:0] roz_line,     // the ROZ plane's line colour word
	input  logic [15:0] road_line,    // the road plane's
	input  logic [15:0] spr,          // {pri, colour, pen}, pen 0 = none

	// priority RAM read port (byte index, one-cycle read)
	output logic [12:0] pri_addr,
	input  logic [7:0]  pri_data,

	// palette RAM read port
	output logic [14:0] pal_addr,
	input  logic [15:0] pal_w0,
	input  logic [15:0] pal_w1,

	input  logic [15:0] brt0,
	input  logic [15:0] brt1,

	input  logic        dis_tx, dis_bg, dis_roz, dis_spr, dis_road,

	output logic [7:0]  r, g, b
);

	// --------------------------------------------------- stage 0: the index
	wire tx_o   = tx_op   && !dis_tx;
	wire bg_o   = bg_op   && !dis_bg;
	wire roz_o  = roz_op  && !dis_roz;
	wire road_o = road_op && !dis_road;
	wire spr_o  = (spr[7:0] != 8'd0) && !dis_spr;      // MAME tests the pen's low byte
	wire [2:0] depth = roz_o ? roz_line[6:4] : road_line[6:4];

	assign pri_addr = {~spr_o, ~tx_o, 1'b1, ~roz_o, ~road_o, ~bg_o, spr[15:12], depth};

	// the layers as palette indices, carried alongside the read
	logic [14:0] s1_spr, s1_bg, s1_roz, s1_road, s1_tx;
	logic        s1_spr_o, s1_bg_o, s1_roz_o, s1_road_o, s1_tx_o;
	always_ff @(posedge clk) begin
		s1_spr  <= {3'b000, spr[11:0]};
		s1_bg   <= {3'b001, bg_col,   bg_pen};         // 0x1000
		s1_roz  <= {3'b010, roz_col,  roz_pen};        // 0x2000
		s1_road <= {3'b101, road_col, road_pen};       // 0x5000, gfx5's bank
		s1_tx   <= {3'b110, tx_col,   tx_pen};         // 0x6000
		s1_spr_o <= spr_o; s1_bg_o <= bg_o; s1_roz_o <= roz_o; s1_road_o <= road_o; s1_tx_o <= tx_o;
	end

	// ------------------------------------- stage 1: what the priority RAM says
	logic [14:0] s2_idx;
	logic        s2_half;
	always_ff @(posedge clk) begin
		s2_half <= !pri_data[2];
		if (pri_data[6]) begin
			s2_idx <= 15'd0;                            // backdrop
		end else begin
			unique case (pri_data[5:3])
				3'd0: s2_idx <= s1_spr_o  ? s1_spr  : 15'd0;
				3'd1: s2_idx <= s1_bg_o   ? s1_bg   : 15'd0;
				3'd2: s2_idx <= s1_roz_o  ? s1_roz  : 15'd0;
				3'd4: s2_idx <= s1_road_o ? s1_road : 15'd0;
				3'd6: s2_idx <= s1_tx_o   ? s1_tx   : 15'd0;
				default: s2_idx <= 15'd0;               // 3, 5, 7: nothing, as MAME
			endcase
		end
	end

	// ------------------------------------------------ stage 2: palette read
	assign pal_addr = s2_idx;
	logic s3_dim, s3_half;
	always_ff @(posedge clk) begin
		s3_dim  <= !s2_idx[14];                         // brightness skips bit 14
		s3_half <= s2_half;
	end

	// ----------------------------------- stage 2b: the palette words, registered
	// (ms32_mixer: the RAM's output straight into the products was the worst
	// clk_sys path in three fitted builds)
	logic [15:0] pw0, pw1;
	logic        s3b_dim, s3b_half;
	always_ff @(posedge clk) begin
		pw0 <= pal_w0;
		pw1 <= pal_w1;
		s3b_dim  <= s3_dim;
		s3b_half <= s3_half;
	end

	// ------------------------------------------------- stage 3: brightness
	wire [8:0] brt_r = 9'h100 - {1'b0, brt0[15:8]};
	wire [8:0] brt_g = 9'h100 - {1'b0, brt0[7:0]};
	wire [8:0] brt_b = 9'h100 - {1'b0, brt1[7:0]};
	wire [16:0] pr = {9'd0, pw0[15:8]} * brt_r;
	wire [16:0] pg = {9'd0, pw0[7:0]}  * brt_g;
	wire [16:0] pb = {9'd0, pw1[7:0]}  * brt_b;
	logic [7:0] r3, g3, b3;
	logic       s4_half;
	always_ff @(posedge clk) begin
		r3 <= s3b_dim ? pr[15:8] : pw0[15:8];
		g3 <= s3b_dim ? pg[15:8] : pw0[7:0];
		b3 <= s3b_dim ? pb[15:8] : pw1[7:0];
		s4_half <= s3b_half;
	end

	// stage 4: the priority byte's bit 2 clear means half brightness
	always_ff @(posedge clk) begin
		r <= s4_half ? {1'b0, r3[7:1]} : r3;
		g <= s4_half ? {1'b0, g3[7:1]} : g3;
		b <= s4_half ? {1'b0, b3[7:1]} : b3;
	end

endmodule
