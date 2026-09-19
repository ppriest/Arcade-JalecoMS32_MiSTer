// SPDX-License-Identifier: GPL-3.0-or-later
//
// CRT adjust: H-Size, H-Position and V-Shift through crt_adjust.sv (vendored,
// rmonic79's, via the Seta core), which moves and stretches the picture
// through a line buffer while the syncs stay native, so the CRT keeps lock.
// There is no V-size. After the Seta core's seta_crt.sv, with two changes for
// this core: the dot period is measured rather than assumed (ms32_crtc runs
// the dot clock at 6 or 8 MHz, the game's choice: 16 or 12 clk_sys), and the
// pixel enable out is one clock wide, since CE_PIXEL here is on clk_sys.
//
// H-Position is an index into 0, +1..+48, -48..-1 (wraps at 97); H-Size a
// signed step of a quarter clock of read period; V-Shift signed lines.

`default_nettype none

module ms32_crt (
	input  wire       clk,            // clk_sys, 96 MHz
	input  wire       ce,             // the core's dot clock enable, one clk
	input  wire       adjust,         // CRT adjust On
	input  wire [4:0] hsize_idx,
	input  wire [6:0] hpos_idx,
	input  wire [5:0] vshift_idx,

	input  wire [7:0] r_in, g_in, b_in,
	input  wire       hs_in, vs_in, hb_in, vb_in,

	output wire       active,         // module in the path
	output wire       ce_out,         // one clk
	output wire [7:0] r_out, g_out, b_out,
	output wire       hs_out, vs_out, hb_out, vb_out
);

	assign active = adjust;

	reg  signed [4:0] hsize = 5'sd0;
	reg         [6:0] hpos = 7'd0;
	always @(posedge clk) if (ce) begin
		hsize <= adjust ? $signed(hsize_idx) : 5'sd0;
		hpos  <= adjust ? hpos_idx : 7'd0;
	end
	wire signed [8:0] hoffset = (hpos <= 7'd48)
		? $signed({2'b00, hpos})
		: $signed({2'b00, hpos}) - 9'sd97;
	wire signed [5:0] voffset = adjust ? $signed(vshift_idx) : 6'sd0;

	// the dot period in clk_sys clocks, measured between enables (12 or 16)
	reg [4:0] dcnt = 5'd0, dper = 5'd12;
	always @(posedge clk) begin
		if (ce) begin dper <= dcnt + 5'd1; dcnt <= 5'd0; end
		else if (dcnt != 5'd31) dcnt <= dcnt + 5'd1;
	end

	// read enable in twentieths of a clock: 20 x the dot period per pixel, +5
	// per H-Size step; restarted on hs_ref (crt_adjust's reference HSync)
	wire       hs_ref;
	reg        hs_ref_d = 1'b0;
	reg  [9:0] acc = 10'd0;
	wire [9:0] base   = {dper, 4'b0000} + {3'b000, dper, 2'b00};          // 20 x dper
	wire [9:0] period = base + {{3{hsize[4]}}, hsize, 2'b00} + {{5{hsize[4]}}, hsize};
	wire       tick   = (acc + 10'd20) >= period;
	always @(posedge clk) begin
		hs_ref_d <= hs_ref;
		if (hs_ref & ~hs_ref_d) acc <= 10'd0;
		else if (tick)          acc <= acc + 10'd20 - period;
		else                    acc <= acc + 10'd20;
	end
	wire pxl2_cen = (hsize == 5'sd0) ? ce : tick;
	assign ce_out = pxl2_cen;

	crt_adjust #(.VTOTAL(263), .HTOTAL(384), .HPOS_MODE(1)) u_crt_adjust (
		.clk(clk), .pxl_cen(ce), .pxl2_cen(pxl2_cen),
		.active(active), .hsize(hsize),
		.hoffset(hoffset), .voffset(voffset),
		.r_in(r_in), .g_in(g_in), .b_in(b_in),
		.hs_in(hs_in), .vs_in(vs_in), .hb_in(hb_in), .vb_in(vb_in),
		.r_out(r_out), .g_out(g_out), .b_out(b_out),
		.hs_out(hs_out), .vs_out(vs_out), .hb_out(hb_out), .vb_out(vb_out),
		.hs_ref_out(hs_ref)
	);

endmodule

`default_nettype wire
