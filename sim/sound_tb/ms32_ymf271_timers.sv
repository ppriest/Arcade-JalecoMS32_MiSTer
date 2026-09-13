// SPDX-License-Identifier: GPL-3.0-or-later
//
// SIMULATION STAND-IN for rtl/sound/ymf271 in sim/sound_tb, selected by
// MS32_SIM_NO_YMF271: ModelSim 10.5b rejects the vendored engine's uses of
// signals before their declarations (Quartus and Verilator accept them), and
// this bench is ModelSim's because of the T80. The chip itself is checked in
// sim/ymf_tb under Verilator.
//
// The YMF271's bus face without its synthesis: the address latches, timers A
// and B and the status register, so the Z80's driver runs as it does on the
// board. The driver polls the timer flags for tempo (ms32.cpp: "IRQ is
// unused") and reads the status before each write, so a chip that never
// answers stalls the music loop. The synthesis half replaces this module when
// the Seibu SPI port is vendored (docs/ROADMAP.md, "The YMF271").
//
// From ymf271.cpp (ymf271_device::write, write_util, read):
//   even offsets latch an address, odd offsets write through it; only bank 6
//   (offsets C/D) matters here.
//   0x10/0x11  timer A, 10 bits: 0x10 the high 8, 0x11 the low 2
//   0x12       timer B, 8 bits
//   0x13       bit 0/1 load A/B on a rising edge, 4/5 clear flag A/B
//   period     A: 1024 - A samples, B: 16 x (256 - B) samples, at 44.1 kHz
//              (384 clocks of 16.9344 MHz); reloaded on expiry, never stopped
//   status     offset 0: bit 0 TiA, bit 1 TiB; End flags and Busy read 0
//              (no PCM engine). Offset 2 reads 0xFF with the external memory
//              window in write mode, as after reset; other offsets 0xFF.
module ms32_ymf271_timers #(
	// sample tick from clk: 44,100 / 96,000,000 = 441 / 960,000
	parameter int TICK_INC = 441,
	parameter int TICK_MOD = 960_000
) (
	input  logic       clk,
	input  logic       reset,
	input  logic       wr,        // one clock per write
	input  logic [3:0] wr_addr,
	input  logic [7:0] din,
	input  logic [3:0] rd_addr,
	output logic [7:0] dout       // combinational on rd_addr
);

	logic [19:0] acc;
	logic        tick;
	always_ff @(posedge clk) begin
		if (reset) begin
			acc <= 20'd0; tick <= 1'b0;
		end else if (acc >= 20'(TICK_MOD - TICK_INC)) begin
			acc <= acc + 20'(TICK_INC) - 20'(TICK_MOD); tick <= 1'b1;
		end else begin
			acc <= acc + 20'(TICK_INC); tick <= 1'b0;
		end
	end

	logic [7:0]  util_sel;
	logic [9:0]  timer_a;
	logic [7:0]  timer_b;
	logic [7:0]  ctrl;
	logic [1:0]  flags;
	logic        run_a, run_b;
	logic [10:0] cnt_a;          // samples left, 1..1024
	logic [12:0] cnt_b;          // samples left, 16..4096

	wire w_util = wr && wr_addr == 4'hD;
	wire w_ctrl = w_util && util_sel == 8'h13;

	always_ff @(posedge clk) begin
		if (reset) begin
			util_sel <= 8'd0; timer_a <= 10'd0; timer_b <= 8'd0; ctrl <= 8'd0; flags <= 2'b00;
			run_a <= 1'b0; run_b <= 1'b0; cnt_a <= 11'd0; cnt_b <= 13'd0;
		end else begin
			if (wr && wr_addr == 4'hC) util_sel <= din;
			if (w_util && util_sel == 8'h10) timer_a <= {din, timer_a[1:0]};
			if (w_util && util_sel == 8'h11) timer_a <= {timer_a[9:2], din[1:0]};
			if (w_util && util_sel == 8'h12) timer_b <= din;

			if (tick && run_a) begin
				if (cnt_a == 11'd1) begin flags[0] <= 1'b1; cnt_a <= 11'd1024 - {1'b0, timer_a}; end
				else cnt_a <= cnt_a - 11'd1;
			end
			if (tick && run_b) begin
				if (cnt_b == 13'd1) begin flags[1] <= 1'b1; cnt_b <= {9'd256 - {1'b0, timer_b}, 4'b0000}; end
				else cnt_b <= cnt_b - 13'd1;
			end

			// a load or clear in the same clock as an expiry wins
			if (w_ctrl) begin
				if (!ctrl[0] && din[0]) begin run_a <= 1'b1; cnt_a <= 11'd1024 - {1'b0, timer_a}; end
				if (!ctrl[1] && din[1]) begin run_b <= 1'b1; cnt_b <= {9'd256 - {1'b0, timer_b}, 4'b0000}; end
				if (din[4]) flags[0] <= 1'b0;
				if (din[5]) flags[1] <= 1'b0;
				ctrl <= din;
			end
		end
	end

	always_comb begin
		case (rd_addr)
			4'h0:    dout = {6'd0, flags};
			4'h1:    dout = 8'h00;
			default: dout = 8'hFF;
		endcase
	end

endmodule
