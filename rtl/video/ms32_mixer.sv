// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 mixer, palette and brightness: ms32_v.cpp screen_update() as the
// pixel-exact model has it (scripts/render_model.py mix()), per dot:
//
//  1. Layer order from three priority-RAM probes, read once per frame:
//       priram[0x2b00/2] == 0x34 -> TX above ROZ, else ROZ above TX
//       priram[0x2e00/2] == 0x34 -> TX above BG,  else BG above TX
//       priram[0x3a00/2] == 0x09 -> TX rank 3;  & 0x30 == 0 -> BG above ROZ else ROZ above BG
//     (each "above" adds one to that layer's rank; ranks 0..3, higher on top)
//  2. Tile resolve: the highest-ranked opaque layer's palette index, and
//     tpri = OR of the bits of every opaque layer (BG 1, ROZ 2, TX 4).
//  3. primask from the sprite pixel's priority nibble p through eight
//     probes priram[({p,4'b0} | 0x0a00 | k) / 2] & 0x38 != 0, k in
//     1500,1400,1100,1000,0500,0400,0100,0000 -> bits 0..7. Sixteen
//     possible p, so a 16 x 8 table, rebuilt every frame from the RAM.
//  4. MAME's case table on (primask, tpri, sprite opaque):
//       0x00 sprite if opaque              0xf0 ... and tpri <= 3
//       0xfc ... and tpri <= 1             0xfe ... and tpri == 0; tile at half brightness for tpri 1..3
//       0xf8 ... and tpri == 2             0xcc ... and (tpri & 2) == 0
//       anything else: black (MAME draws noise for 0xc0 and pops a message)
//  5. Palette: word 0 = RRRRRRRR GGGGGGGG, word 1 = ........ BBBBBBBB;
//     brightness x (0x100 - reg) / 0x100 per channel unless index bit 14;
//     then the shadow halves R, G and B.
//
// The priority RAM is 0x2000 bytes of 8-bit entries; the mixer holds only
// the 3 + 128 probe results, refreshed by walking the RAM at frame_start,
// so a change the game makes takes effect at the next frame -- the same
// granularity as MAME, which reads them once per screen_update.
//
// Pipeline: resolve (1) -> palette read (2) -> brightness (3) -> rgb.
// Inputs describe the dot at hcnt and are stable for the dot period; rgb
// is valid four clocks after hcnt changes.
module ms32_mixer (
	input  logic        clk,
	input  logic        reset,
	input  logic        frame_start,

	// tile layers, the dot at hcnt
	input  logic [7:0]  tx_pen,  input logic [3:0] tx_col,  input logic tx_op,
	input  logic [7:0]  bg_pen,  input logic [3:0] bg_col,  input logic bg_op,
	input  logic [7:0]  roz_pen, input logic [3:0] roz_col, input logic roz_op,
	// sprite pixel {pri, colour, pen}, pen 0 = none
	input  logic [15:0] spr,

	// priority RAM read port (dword index, 8-bit entry, one-cycle read)
	output logic [12:0] pri_addr,
	input  logic [7:0]  pri_data,

	// palette RAM read port: entry index, both words
	output logic [14:0] pal_addr,
	input  logic [15:0] pal_w0,
	input  logic [15:0] pal_w1,

	// brightness registers (0xFCE00280/284 low halves)
	input  logic [15:0] brt0,
	input  logic [15:0] brt1,

	// OSD layer disables
	input  logic        dis_tx, dis_bg, dis_roz, dis_spr,

	output logic [7:0]  r, g, b,
	output logic        unhandled_primask   // sticky, for the debug page
);

	// ------------------------------------------------- per-frame tables
	logic [1:0]  rank_bg, rank_roz, rank_tx;
	logic [7:0]  primask_tab [0:15];
	logic [7:0]  tp0, tp1, tp2;             // the three probes
	logic [7:0]  tstate;                    // walk counter: 0..2 probes, 3..130 primask, 131 done
	logic [7:0]  tstate_d;
	localparam logic [7:0] T_DONE = 8'd131;   // 3 probes + 16 x 8; tstate_d == 131 writes nothing

	// probe k of sprite priority p: index = ({p,4'b0} | 0x0a00 | K[k]) >> 1
	function automatic logic [12:0] pm_index(input logic [3:0] p, input logic [2:0] k);
		logic [15:0] kk;
		case (k)
			3'd0: kk = 16'h1500; 3'd1: kk = 16'h1400; 3'd2: kk = 16'h1100; 3'd3: kk = 16'h1000;
			3'd4: kk = 16'h0500; 3'd5: kk = 16'h0400; 3'd6: kk = 16'h0100; default: kk = 16'h0000;
		endcase
		pm_index = (({8'd0, p, 4'd0}) | 16'h0a00 | kk) >> 1;
	endfunction

	always_comb begin
		case (tstate)
			8'd0: pri_addr = 13'(16'h2b00 >> 1);
			8'd1: pri_addr = 13'(16'h2e00 >> 1);
			8'd2: pri_addr = 13'(16'h3a00 >> 1);
			default: pri_addr = pm_index(4'((tstate - 8'd3) >> 3), 3'((tstate - 8'd3) & 8'd7));
		endcase
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			tstate   <= T_DONE;
			tstate_d <= T_DONE;
		end else begin
			tstate_d <= tstate;
			if (frame_start) tstate <= 8'd0;
			else if (tstate != T_DONE) tstate <= tstate + 8'd1;
			// data for the address of cycle tstate_d arrives now
			if (tstate_d < T_DONE) begin
				case (tstate_d)
					8'd0: tp0 <= pri_data;
					8'd1: tp1 <= pri_data;
					8'd2: tp2 <= pri_data;
					default: primask_tab[(tstate_d - 8'd3) >> 3][(tstate_d - 8'd3) & 8'd7] <= (pri_data & 8'h38) != 8'd0;
				endcase
			end
			if (tstate_d == 8'd3) begin       // tp0..tp2 are in: derive the ranks
				rank_tx  <= ((tp0 == 8'h34) ? 2'd1 : 2'd0) + ((tp1 == 8'h34) ? 2'd1 : 2'd0);
				rank_roz <= ((tp0 == 8'h34) ? 2'd0 : 2'd1);
				rank_bg  <= ((tp1 == 8'h34) ? 2'd0 : 2'd1);
			end
			if (tstate_d == 8'd4) begin
				if (tp2 == 8'h09) rank_tx <= 2'd3;
				if ((tp2 & 8'h30) == 8'd0) rank_bg <= rank_bg + 2'd1; else rank_roz <= rank_roz + 2'd1;
			end
		end
	end

	// ------------------------------------------------------ stage 1: resolve
	wire txo  = tx_op  && !dis_tx;
	wire bgo  = bg_op  && !dis_bg;
	wire rozo = roz_op && !dis_roz;
	wire spro = (spr[7:0] != 8'd0) && !dis_spr;

	wire [14:0] tx_idx  = 15'h6000 + {3'd0, tx_col, tx_pen};
	wire [14:0] bg_idx  = 15'h1000 + {3'd0, bg_col, bg_pen};
	wire [14:0] roz_idx = 15'h2000 + {3'd0, roz_col, roz_pen};
	wire [14:0] spr_idx = {3'd0, spr[11:0]};

	// highest-ranked opaque layer
	logic [14:0] tile_idx;
	logic        tile_op;
	always_comb begin
		tile_idx = 15'd0; tile_op = 1'b0;
		for (int rk = 0; rk < 4; rk++) begin
			if (bgo  && rank_bg  == 2'(rk)) begin tile_idx = bg_idx;  tile_op = 1'b1; end
			if (rozo && rank_roz == 2'(rk)) begin tile_idx = roz_idx; tile_op = 1'b1; end
			if (txo  && rank_tx  == 2'(rk)) begin tile_idx = tx_idx;  tile_op = 1'b1; end
		end
	end
	wire [2:0] tpri = {txo, rozo, bgo};
	wire [7:0] primask = primask_tab[spr[15:12]];

	logic sprite_over, shadow, bad;
	always_comb begin
		sprite_over = 1'b0; shadow = 1'b0; bad = 1'b0;
		case (primask)
			8'h00: sprite_over = spro;
			8'hf0: sprite_over = spro && (tpri <= 3'd3);
			8'hfc: sprite_over = spro && (tpri <= 3'd1);
			8'hfe: begin sprite_over = spro && (tpri == 3'd0); shadow = (tpri >= 3'd1) && (tpri <= 3'd3); end
			8'hf8: sprite_over = spro && (tpri == 3'd2);
			8'hcc: sprite_over = spro && !tpri[1];
			default: bad = 1'b1;
		endcase
	end

	// stage 1 registers. Where nothing is opaque MAME shows the tilemap's
	// pen 0, i.e. palette entry 0 (the model's zero-initialised tile array);
	// an unhandled primask is black (the model's out[m] = 0).
	logic [14:0] s1_idx;
	logic        s1_shadow, s1_black;
	always_ff @(posedge clk) begin
		s1_idx    <= sprite_over ? spr_idx : tile_op ? tile_idx : 15'd0;
		s1_shadow <= shadow && !sprite_over;
		s1_black  <= bad;
		if (reset) unhandled_primask <= 1'b0;
		else if (bad) unhandled_primask <= 1'b1;
	end

	// ------------------------------------------------ stage 2: palette read
	assign pal_addr = s1_idx;
	logic        s2_shadow, s2_dim, s2_black;
	always_ff @(posedge clk) begin
		s2_shadow <= s1_shadow;
		s2_dim    <= !s1_idx[14];
		s2_black  <= s1_black;
	end

	// ------------------------------------------------- stage 3: brightness
	// Three 8x9 products at pixel rate: the one place in the video path that
	// keeps a multiplier (WORKFLOW "No multiplies, no divides" names this
	// exception). A serial shift-add over the dot period would fit at 6 MHz
	// (16 clocks) with 9 steps but has no margin at 8 MHz (12 clocks); three
	// DSP-sized multipliers are the cheaper certainty until the brightness
	// mechanism itself is understood (ROADMAP: MAME's is a known divergence).
	wire [8:0] brt_r = 9'h100 - {1'b0, brt0[15:8]};
	wire [8:0] brt_g = 9'h100 - {1'b0, brt0[7:0]};
	wire [8:0] brt_b = 9'h100 - {1'b0, brt1[7:0]};
	wire [16:0] pr = {9'd0, pal_w0[15:8]} * brt_r;
	wire [16:0] pg = {9'd0, pal_w0[7:0]}  * brt_g;
	wire [16:0] pb = {9'd0, pal_w1[7:0]}  * brt_b;
	logic [7:0] r3, g3, b3;
	logic       s3_shadow;
	always_ff @(posedge clk) begin
		r3 <= s2_black ? 8'd0 : s2_dim ? pr[15:8] : pal_w0[15:8];
		g3 <= s2_black ? 8'd0 : s2_dim ? pg[15:8] : pal_w0[7:0];
		b3 <= s2_black ? 8'd0 : s2_dim ? pb[15:8] : pal_w1[7:0];
		s3_shadow <= s2_shadow;
	end

	// stage 4: shadow (alpha_blend_r32(tile, black, 128) = halve)
	always_ff @(posedge clk) begin
		r <= s3_shadow ? {1'b0, r3[7:1]} : r3;
		g <= s3_shadow ? {1'b0, g3[7:1]} : g3;
		b <= s3_shadow ? {1'b0, b3[7:1]} : b3;
	end

endmodule
