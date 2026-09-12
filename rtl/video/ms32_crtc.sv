// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 CRTC: the programmable raster generator behind jaleco_ms32_sysctrl.
//
// Every dimension is a register the game writes, each as 0x1000 - (data &
// 0xfff) (sysctrl's clamp_to_12bits_neg); the dot clock is 48 MHz / 8 =
// 6 MHz or / 6 = 8 MHz by control bit 0. Reset values are MAME's defaults
// (384 x 263 total, 320 x 224 visible), which the sysctrl comments say the
// hardware must produce before any write because bnstars1 never programs
// the CRTC and still expects a vblank.
//
// Register offsets are the sysctrl amap's 16-bit slots (byte offset / 2):
//   0 control  bit0 dot clock (1 = 8 MHz), bit1 flip, bit3 timer enable
//   1 hblank   2 hdisplay   3 hbp   4 hfp
//   5 vblank   6 vdisplay   7 vbp   8 vfp
// The CPU sees them one per dword (umask32 0x0000ffff), so the top level
// derives reg_off from address bits [5:2].
//
// Raster: hcnt 0..htotal-1 with the active window first (0..hdisplay-1),
// then hblank; vcnt likewise. That is the MAME screen configuration
// (visarea 0..hdisplay-1) and the order the tilemap engines assume.
//
// SYNC PULSES ARE A DESIGN CHOICE. MAME only logs hbp/hfp/vbp/vfp
// ("HSYNC back porch", "front porch") and never uses them. Every captured
// game writes hbp 16, hfp 46, vbp 16, vfp 24 against hblank 64 / vblank 39,
// which reads naturally as "sync from blank+bp to blank+fp": a 30-dot
// (5 us) hsync and an 8-line vsync. That is what is generated here. The
// MiSTer framework only needs consistent edges; nothing downstream depends
// on the widths.
//
// ce_pix is a one-clk pulse once per dot; hcnt/vcnt advance on it and hold
// between pulses, so "the current dot" is (hcnt, vcnt) for the whole
// period. line_start pulses on the ce_pix that moves hcnt from the last
// active dot into hblank -- the engines get all of hblank plus the next
// active line to prefetch, because they run one line ahead (see
// ms32_tilemap). vcnt_next is the line that follows vcnt, wrapped at
// vtotal; vcnt_next2 the one after that.
//
// Interrupt events, one clk each, at the moments jaleco_ms32_sysctrl's
// scanline timer raises them: vblank_ev when vcnt reaches vdisplay,
// field_ev when vcnt reaches 0 on an odd frame (the 30 Hz "field" line).
// Which IRQ level each drives is the interrupt controller's business
// (ms32_invert_lines swaps them for tp2m32/wpksocv2).
module ms32_crtc #(
	parameter int CLK_HZ = 96_000_000
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        reg_we,
	input  logic [3:0]  reg_off,
	input  logic [15:0] reg_data,

	output logic        ce_pix,
	output logic [11:0] hcnt,
	output logic [11:0] vcnt,
	output logic [11:0] vcnt_next,
	output logic [11:0] vcnt_next2,
	output logic        h_active,
	output logic        v_active,
	output logic        hblank,
	output logic        vblank,
	output logic        hsync,
	output logic        vsync,
	output logic        line_start,
	output logic        frame_odd,
	output logic        vblank_ev,
	output logic        field_ev,

	output logic        flip,          // control bit 1, for whoever implements it
	output logic        timer_enable,  // control bit 3
	output logic [11:0] hdisplay_o,
	output logic [11:0] vdisplay_o
);

	localparam int DIV6 = CLK_HZ / 6_000_000;   // 16 at 96 MHz
	localparam int DIV8 = CLK_HZ / 8_000_000;   // 12 at 96 MHz

	logic [15:0] control;
	logic [11:0] r_hblank, r_hdisplay, r_hbp, r_hfp, r_vblank, r_vdisplay, r_vbp, r_vfp;

	function automatic logic [11:0] neg12(input logic [15:0] d);
		neg12 = 12'h000 - d[11:0];   // 0x1000 - (d & 0xfff), in 12 bits
	endfunction

	always_ff @(posedge clk) begin
		if (reset) begin
			control    <= 16'h0000;
			r_hblank   <= 12'd64;  r_hdisplay <= 12'd320; r_hbp <= 12'd16; r_hfp <= 12'd46;
			r_vblank   <= 12'd39;  r_vdisplay <= 12'd224; r_vbp <= 12'd16; r_vfp <= 12'd24;
		end else if (reg_we) begin
			case (reg_off)
				4'd0: control    <= reg_data;
				4'd1: r_hblank   <= neg12(reg_data);
				4'd2: r_hdisplay <= neg12(reg_data);
				4'd3: r_hbp      <= neg12(reg_data);
				4'd4: r_hfp      <= neg12(reg_data);
				4'd5: r_vblank   <= neg12(reg_data);
				4'd6: r_vdisplay <= neg12(reg_data);
				4'd7: r_vbp      <= neg12(reg_data);
				4'd8: r_vfp      <= neg12(reg_data);
				default: ;
			endcase
		end
	end

	assign flip         = control[1];
	assign timer_enable = control[3];
	assign hdisplay_o   = r_hdisplay;
	assign vdisplay_o   = r_vdisplay;

	wire [12:0] htotal = {1'b0, r_hdisplay} + {1'b0, r_hblank};
	wire [12:0] vtotal = {1'b0, r_vdisplay} + {1'b0, r_vblank};

	// dot clock enable
	logic [4:0] div;
	wire  [4:0] div_top = control[0] ? 5'(DIV8 - 1) : 5'(DIV6 - 1);
	always_ff @(posedge clk) begin
		if (reset) begin
			div    <= 5'd0;
			ce_pix <= 1'b0;
		end else begin
			ce_pix <= (div == div_top);
			div    <= (div == div_top) ? 5'd0 : div + 5'd1;
		end
	end

	// raster counters
	wire h_last = ({1'b0, hcnt} == htotal - 13'd1);
	wire v_last = ({1'b0, vcnt} == vtotal - 13'd1);
	always_ff @(posedge clk) begin
		if (reset) begin
			hcnt      <= 12'd0;
			vcnt      <= 12'd0;
			frame_odd <= 1'b0;
		end else if (ce_pix) begin
			if (h_last) begin
				hcnt <= 12'd0;
				if (v_last) begin
					vcnt      <= 12'd0;
					frame_odd <= ~frame_odd;
				end else begin
					vcnt <= vcnt + 12'd1;
				end
			end else begin
				hcnt <= hcnt + 12'd1;
			end
		end
	end

	assign h_active = (hcnt < r_hdisplay);
	assign v_active = (vcnt < r_vdisplay);
	assign hblank   = ~h_active;
	assign vblank   = ~v_active;
	assign hsync    = (hcnt >= r_hdisplay + r_hbp) && (hcnt < r_hdisplay + r_hfp);
	assign vsync    = (vcnt >= r_vdisplay + r_vbp) && (vcnt < r_vdisplay + r_vfp);

	assign vcnt_next  = v_last ? 12'd0 : vcnt + 12'd1;
	wire   v_last2    = ({1'b0, vcnt} == vtotal - 13'd2);
	assign vcnt_next2 = v_last ? 12'd1 : v_last2 ? 12'd0 : vcnt + 12'd2;

	// pulses, on the ce_pix that makes the transition
	always_ff @(posedge clk) begin
		if (reset) begin
			line_start <= 1'b0;
			vblank_ev  <= 1'b0;
			field_ev   <= 1'b0;
		end else begin
			line_start <= ce_pix && (hcnt == r_hdisplay - 12'd1);
			vblank_ev  <= ce_pix && h_last && (vcnt + 12'd1 == r_vdisplay);
			field_ev   <= ce_pix && h_last && v_last && ~frame_odd;   // frame about to start is odd
		end
	end

endmodule
