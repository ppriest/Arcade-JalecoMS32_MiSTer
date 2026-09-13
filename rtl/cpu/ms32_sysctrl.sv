// SPDX-License-Identifier: GPL-3.0-or-later
//
// The interrupt side of jaleco_ms32_sysctrl plus ms32.cpp's irq_raise, in
// the CPU's clock domain. The CRTC half of the same register block lives in
// ms32_crtc, which receives the writes through the register mailbox.
//
// ms32.cpp: m_irqreq is a 16-bit set of levels; the V70's line is asserted
// while any bit is set and irq_callback() returns the highest set bit. The
// core adds 0x40 to the vector itself. Sources and the levels they set:
//   0  programmable timer        (jaleco_ms32_sysctrl prg_timer_cb)
//   1  sound CPU wrote to_main   (cleared by reading 0xFD000000)
//   9  field, 30 Hz              (vblank with invert_lines)
//   10 vblank                    (field with invert_lines)
// Acks are writes to the sysctrl block (byte offsets into 0xFCE00000; the
// amap is 16-bit behind umask32, so amap slot k is at 4*(k/2)):
//   0x00 control: bit 3 timer enable   0x30 timer interval   0x34 timer ack
//   0x3C irq ack (clears vblank and field)   0x58 field ack   0x5C vblank ack
// A set and an acknowledge in the same clock: the acknowledge wins
// (LESSONS_LEARNED, "Give a held interrupt line's acknowledge priority").
//
// The timer period is MAME's guess, 500 us * interval (the driver says the
// real timing is unknown); at clk_cpu = 20 MHz that is 10,000 clocks.
module ms32_sysctrl #(
	parameter int TICKS_500US = 10_000
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        invert_lines,

	input  logic        wr,            // a write to the 0xFCE00000 block
	input  logic [11:0] wr_off,        // byte offset
	input  logic [15:0] wr_data,

	input  logic        vblank_ev,     // from the CRTC, in this domain
	input  logic        field_ev,
	input  logic        sound_irq_set, // to_main written
	input  logic        sound_irq_clr, // 0xFD000000 read

	output logic        irq_n,
	output logic [7:0]  irq_vector
);

	logic [15:0] irqreq;
	logic        timer_en;
	logic [11:0] interval;
	logic [11:0] ticks_left;     // intervals left in this period
	logic [13:0] sub;            // clocks within the current 500 us
	logic        timer_fire;

	wire w_ctrl  = wr && wr_off == 12'h000;
	wire w_intv  = wr && wr_off == 12'h030;
	wire w_tack  = wr && wr_off == 12'h034;
	wire w_iack  = wr && wr_off == 12'h03C;
	wire w_fack  = wr && wr_off == 12'h058;
	wire w_vack  = wr && wr_off == 12'h05C;

	// flush_prg_timer: every control or interval write restarts the period
	wire restart = w_ctrl || w_intv;
	always_ff @(posedge clk) begin
		timer_fire <= 1'b0;
		if (reset) begin
			timer_en <= 1'b0; interval <= 12'd1; ticks_left <= 12'd1; sub <= 14'd0;
		end else begin
			if (w_ctrl) timer_en <= wr_data[3];
			if (w_intv) interval <= 12'h000 - wr_data[11:0];   // clamp_to_12bits_neg; 0 means 0x1000
			if (restart) begin
				sub <= 14'd0;
				ticks_left <= w_intv ? (12'h000 - wr_data[11:0]) : interval;
			end else if (timer_en) begin
				if (sub == 14'(TICKS_500US - 1)) begin
					sub <= 14'd0;
					if (ticks_left == 12'd1) begin
						timer_fire <= 1'b1;
						ticks_left <= interval;
					end else begin
						ticks_left <= ticks_left - 12'd1;
					end
				end else begin
					sub <= sub + 14'd1;
				end
			end
		end
	end

	wire [3:0] vbl_level = invert_lines ? 4'd9  : 4'd10;
	wire [3:0] fld_level = invert_lines ? 4'd10 : 4'd9;

	// invert_lines swaps which event raises which level; the acks do not
	// move. jaleco_ms32_sysctrl calls m_field_cb at the vblank line when
	// inverted, and ms32.cpp wires m_vblank_cb to level 10 and m_field_cb to
	// level 9 unconditionally, so vblank_ack (m_vblank_cb(0)) clears 10 and
	// field_ack clears 9 on every set.
	logic [15:0] set_m, clr_m;
	always_comb begin
		set_m = 16'h0000;
		clr_m = 16'h0000;
		if (timer_fire)    set_m[0] = 1'b1;
		if (sound_irq_set) set_m[1] = 1'b1;
		if (vblank_ev)     set_m[vbl_level] = 1'b1;
		if (field_ev)      set_m[fld_level] = 1'b1;
		// flush_prg_timer with the timer disabled drops its line: a control
		// write clearing bit 3, or an interval write while disabled
		if (w_tack || (w_ctrl && !wr_data[3]) || (w_intv && !timer_en)) clr_m[0] = 1'b1;
		if (sound_irq_clr) clr_m[1] = 1'b1;
		if (w_vack || w_iack) clr_m[10] = 1'b1;
		if (w_fack || w_iack) clr_m[9]  = 1'b1;
	end

	always_ff @(posedge clk) begin
		if (reset) irqreq <= 16'h0000;
		else       irqreq <= (irqreq | set_m) & ~clr_m;
	end

	always_comb begin
		irq_vector = 8'd0;
		for (int i = 0; i < 16; i++) if (irqreq[i]) irq_vector = 8'(i);
	end
	assign irq_n = (irqreq == 16'h0000);

endmodule
