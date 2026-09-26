// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 mixer: the priority RAM decides every pixel. From ms32_v.cpp
// mix_layers() as of MAME PR 16243 (ms32_state's for the twenty-one sets,
// ms32_f1superbattle_state's for F1=1), checked against
// scripts/render_model.py mix() and mix_f1(). Per dot a 13-bit index:
//
//   bit 12     sprite transparent
//   bit 11     text transparent
//   bit 10     always 1
//   bit  9     ROZ transparent
//   bit  8     road plane transparent (always 1 unless F1)
//   bit  7     BG transparent
//   bits 6-3   the sprite's priority nibble
//   bits 2-0   line depth (F1 only, else 0): colour bits 6-4 of the ROZ
//              line, or of the road line where the ROZ plane is transparent
//
// and the byte there says what to show: bits 5-3 the layer (0 sprite, 1 BG,
// 2 ROZ, 4 road, 6 text, anything else nothing), bit 6 the backdrop instead.
//
//   F1=0: bits 1-0 pick the brightness bank -- 3 bank 0, 0 bank 1 unless the
//         layer is text, 2 bank 1 for a sprite, else none -- and bit 2 clear
//         glows a sprite (halfway to white) and halves anything else.
//   F1=1: no brightness (MAME's f1superb mixer applies none), and bit 2 clear
//         halves every layer.
//
// Not here: MAME's apply_sprite_effects() second pass, which redoes the
// lookup where a sprite's box covers a pixel but no pen of it is opaque. It
// needs box coverage from the sprite engine, which the frame buffer does not
// carry, and changed no pixel in any capture (render_model.py prints the
// count).
//
// The index is formed and read every dot, so a change the game makes to the
// priority RAM takes effect immediately, as MAME reads it per pixel.
//
// Pipeline: index (0) -> priority RAM read (1) -> select and palette read (2)
// -> palette words (2b) -> brightness (3) -> glow/half (4). Six clocks,
// inside the shortest dot period of 12.
module ms32_mixer #(
	parameter bit F1 = 1'b0
) (
	input  logic        clk,
	input  logic        reset,

	// the dot at hcnt
	input  logic [7:0]  tx_pen,   input logic [3:0] tx_col,   input logic tx_op,
	input  logic [7:0]  bg_pen,   input logic [3:0] bg_col,   input logic bg_op,
	input  logic [7:0]  roz_pen,  input logic [3:0] roz_col,  input logic roz_op,
	input  logic [7:0]  road_pen, input logic [3:0] road_col, input logic road_op,
	input  logic [15:0] roz_line,     // the ROZ plane's line colour word (F1)
	input  logic [15:0] road_line,    // the road plane's (F1)
	input  logic [15:0] spr,          // {pri, colour, pen}, pen 0 = none

	// priority RAM read port (byte index, one-cycle read)
	output logic [12:0] pri_addr,
	input  logic [7:0]  pri_data,

	// palette RAM read port
	output logic [14:0] pal_addr,
	input  logic [15:0] pal_w0,
	input  logic [15:0] pal_w1,

	// brightness registers 0xFCE00280..28C, low halves: bank 0, then bank 1
	input  logic [15:0] brt0, brt1, brt2, brt3,

	input  logic        dis_tx, dis_bg, dis_roz, dis_spr, dis_road,

	output logic [7:0]  r, g, b
);

	// --------------------------------------------------- stage 0: the index
	wire tx_o   = tx_op   && !dis_tx;
	wire bg_o   = bg_op   && !dis_bg;
	wire roz_o  = roz_op  && !dis_roz;
	wire road_o = F1 && road_op && !dis_road;
	wire spr_o  = (spr[7:0] != 8'd0) && !dis_spr;      // MAME tests the pen's low byte
	wire [2:0] depth = !F1 ? 3'd0 : roz_o ? roz_line[6:4] : road_line[6:4];

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
	logic        s2_fx, s2_spr, s2_bank0, s2_bank1;
	wire  [2:0]  layer = pri_data[5:3];
	always_ff @(posedge clk) begin
		s2_fx    <= !pri_data[2];
		s2_spr   <= !F1 && layer == 3'd0;              // bit 2 clear glows, not halves
		s2_bank0 <= !F1 && pri_data[1:0] == 2'd3;
		s2_bank1 <= !F1 && ((pri_data[1:0] == 2'd0 && layer != 3'd6) ||
		                    (pri_data[1:0] == 2'd2 && layer == 3'd0));
		if (pri_data[6]) begin
			s2_idx <= 15'd0;                            // backdrop
		end else begin
			unique case (layer)
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
	logic s3_fx, s3_spr, s3_bank0, s3_bank1;
	always_ff @(posedge clk) begin
		s3_fx <= s2_fx; s3_spr <= s2_spr; s3_bank0 <= s2_bank0; s3_bank1 <= s2_bank1;
	end

	// ----------------------------------- stage 2b: the palette words, registered
	// (the RAM's output straight into the products was the worst clk_sys path
	// in three fitted builds, 0cf1b86)
	logic [15:0] pw0, pw1;
	logic        s3b_fx, s3b_spr;
	logic [8:0]  m_r, m_g, m_b;                         // the bank's factors, 0x100 = none
	always_ff @(posedge clk) begin
		pw0 <= pal_w0;
		pw1 <= pal_w1;
		s3b_fx <= s3_fx; s3b_spr <= s3_spr;
		m_r <= s3_bank0 ? 9'h100 - {1'b0, brt0[15:8]} : s3_bank1 ? 9'h100 - {1'b0, brt2[15:8]} : 9'h100;
		m_g <= s3_bank0 ? 9'h100 - {1'b0, brt0[7:0]}  : s3_bank1 ? 9'h100 - {1'b0, brt2[7:0]}  : 9'h100;
		m_b <= s3_bank0 ? 9'h100 - {1'b0, brt1[7:0]}  : s3_bank1 ? 9'h100 - {1'b0, brt3[7:0]}  : 9'h100;
	end

	// ------------------------------------------------- stage 3: brightness
	// Three 8x9 products at pixel rate: the one place in the video path that
	// keeps a multiplier (WORKFLOW "No multiplies, no divides" names this
	// exception). F1 never sets a bank, so its factors are constant 0x100 and
	// the products fold away.
	wire [16:0] pr = {9'd0, pw0[15:8]} * m_r;
	wire [16:0] pg = {9'd0, pw0[7:0]}  * m_g;
	wire [16:0] pb = {9'd0, pw1[7:0]}  * m_b;
	logic [7:0] r3, g3, b3;
	logic       s4_fx, s4_spr;
	always_ff @(posedge clk) begin
		r3 <= pr[15:8]; g3 <= pg[15:8]; b3 <= pb[15:8];
		s4_fx <= s3b_fx; s4_spr <= s3b_spr;
	end

	// stage 4: bit 2 clear. A sprite glows, alpha_blend_r32(c, white, 128)
	// = (c + 255) >> 1; anything else halves.
	function automatic logic [7:0] fx(input logic [7:0] c, input logic on, input logic glow);
		logic [8:0] sum;
		sum = {1'b0, c} + 9'd255;
		fx = !on ? c : glow ? sum[8:1] : {1'b0, c[7:1]};
	endfunction
	always_ff @(posedge clk) begin
		r <= fx(r3, s4_fx, s4_spr);
		g <= fx(g3, s4_fx, s4_spr);
		b <= fx(b3, s4_fx, s4_spr);
	end

endmodule
