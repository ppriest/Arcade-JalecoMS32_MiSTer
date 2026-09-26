// SPDX-License-Identifier: GPL-3.0-or-later
//
// Two ms32_ddr_reader clients onto ms32_ddram_mux's one g port: F-1 Super
// Battle's road textures (a) and its sprite ROM (b). a goes first when both
// ask: the road has a line of lead, the sprite engine a frame. Each accepted
// read pushes its owner onto a FIFO, and each g beat goes to the owner at the
// head -- the mux answers g's reads in the order it took them.
//
// The request is whoever asks this clock; the mux holds a read it has been
// offered while its port is busy (M_GRD) and takes whatever is on g_addr when
// the port frees, and g_ack names that client, so a switch in between is
// harmless.
module ms32_ddr_g2 (
	input  logic        clk,
	input  logic        reset,

	input  logic        a_rd,
	input  logic [28:0] a_addr,
	output logic        a_ack,
	output logic        a_dout_ready,

	input  logic        b_rd,
	input  logic [28:0] b_addr,
	output logic        b_ack,
	output logic        b_dout_ready,

	output logic        g_rd,
	output logic [28:0] g_addr,
	input  logic        g_ack,
	input  logic        g_dout_ready
);
	// at most 32 in flight per reader
	localparam int L = 6;
	logic [(1 << L) - 1:0] owner;           // 1 = b
	logic [L:0] wp, rp;

	wire pick_b = !a_rd;
	assign g_rd   = a_rd | b_rd;
	assign g_addr = pick_b ? b_addr : a_addr;
	assign a_ack  = g_ack && !pick_b;
	assign b_ack  = g_ack &&  pick_b;

	wire head_b = owner[rp[L-1:0]];
	assign a_dout_ready = g_dout_ready && (wp != rp) && !head_b;
	assign b_dout_ready = g_dout_ready && (wp != rp) &&  head_b;

	always_ff @(posedge clk) begin
		if (reset) begin
			wp <= '0; rp <= '0;
		end else begin
			if (g_ack) begin owner[wp[L-1:0]] <= pick_b; wp <= wp + 1'b1; end
			if (g_dout_ready && wp != rp) rp <= rp + 1'b1;
		end
	end

endmodule
