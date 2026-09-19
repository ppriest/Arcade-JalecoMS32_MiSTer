// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clock-domain crossings between clk_cpu (the V70's domain) and clk_sys.
// The SDC treats the two clocks as asynchronous; everything that crosses
// goes through one of these four shapes, and nothing else may.
//
//   ms32_cdc_event    a one-clock pulse, as a toggle; events must be further
//                     apart than three destination clocks
//   ms32_cdc_mailbox  a pulse with a payload; the payload is held in the
//                     source domain from the pulse until the next one, so it
//                     is stable for as long as the toggle takes to cross.
//                     Same spacing rule: the source is a bus write, at most
//                     one per three CPU clocks, which clk_sys crosses in three
//   ms32_cdc_req      a request with a payload and a response with a payload,
//                     four-phase: the source holds s_req until s_ack (one
//                     clock), the destination sees d_req for one clock and
//                     must answer with d_valid (and d_rdata) once
//   ms32_cdc_fifo     a queue: pushes in the source clock, pops in the
//                     destination's; an entry is written before the pointer
//                     that exposes it crosses (the V70's posted object RAM
//                     writes)
//
// Payloads are never synchronised bit by bit: they are launched before the
// control signal that announces them and captured after it has crossed.

module ms32_cdc_event (
	input  logic clk_s,
	input  logic s_pulse,
	input  logic clk_d,
	output logic d_pulse
);
	logic tog = 1'b0;
	always_ff @(posedge clk_s) if (s_pulse) tog <= ~tog;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [2:0] sy = 3'b000;
	always_ff @(posedge clk_d) begin
		sy      <= {sy[1:0], tog};
		d_pulse <= sy[2] ^ sy[1];
	end
endmodule

module ms32_cdc_mailbox #(
	parameter int W = 28
) (
	input  logic         clk_s,
	input  logic         s_pulse,
	input  logic [W-1:0] s_data,
	input  logic         clk_d,
	output logic         d_pulse,
	output logic [W-1:0] d_data
);
	logic         tog = 1'b0;
	logic [W-1:0] hold;
	always_ff @(posedge clk_s) if (s_pulse) begin tog <= ~tog; hold <= s_data; end
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [2:0] sy = 3'b000;
	always_ff @(posedge clk_d) begin
		sy      <= {sy[1:0], tog};
		d_pulse <= sy[2] ^ sy[1];
		if (sy[2] ^ sy[1]) d_data <= hold;
	end
endmodule

module ms32_cdc_req #(
	parameter int AW = 18,
	parameter int DW = 64
) (
	input  logic          clk_s,
	input  logic          rst_s,
	input  logic          s_req,
	input  logic [AW-1:0] s_addr,
	output logic          s_ack,
	output logic [DW-1:0] s_rdata,

	input  logic          clk_d,
	input  logic          rst_d,
	output logic          d_req,       // one clock
	output logic [AW-1:0] d_addr,      // held from d_req until d_valid
	input  logic          d_valid,
	input  logic [DW-1:0] d_rdata
);
	// source side
	logic          r;
	logic [AW-1:0] a_hold;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [1:0]    ack_sy;
	logic          dst_ack;
	logic [DW-1:0] data_hold;
	typedef enum logic [1:0] {S_IDLE, S_WAIT, S_DROP} sst_t;
	sst_t sst;
	always_ff @(posedge clk_s) begin
		ack_sy <= {ack_sy[0], dst_ack};
		s_ack  <= 1'b0;
		if (rst_s) begin
			sst <= S_IDLE; r <= 1'b0;
		end else case (sst)
			S_IDLE: if (s_req) begin a_hold <= s_addr; r <= 1'b1; sst <= S_WAIT; end
			S_WAIT: if (ack_sy[1]) begin s_rdata <= data_hold; s_ack <= 1'b1; r <= 1'b0; sst <= S_DROP; end
			S_DROP: if (!ack_sy[1]) sst <= S_IDLE;
			default: sst <= S_IDLE;
		endcase
	end

	// destination side
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [1:0] req_sy;
	typedef enum logic [1:0] {D_IDLE, D_WAIT, D_HOLD} dst_t;
	dst_t dstt;
	always_ff @(posedge clk_d) begin
		req_sy <= {req_sy[0], r};
		d_req  <= 1'b0;
		if (rst_d) begin
			dstt <= D_IDLE; dst_ack <= 1'b0;
		end else case (dstt)
			D_IDLE: if (req_sy[1]) begin d_addr <= a_hold; d_req <= 1'b1; dstt <= D_WAIT; end
			D_WAIT: if (d_valid) begin data_hold <= d_rdata; dst_ack <= 1'b1; dstt <= D_HOLD; end
			D_HOLD: if (!req_sy[1]) begin dst_ack <= 1'b0; dstt <= D_IDLE; end
			default: dstt <= D_IDLE;
		endcase
	end
endmodule

// A first-in first-out queue between two clocks: Gray-coded pointers, each
// crossing through two flops, one push per source clock while not full, one
// pop per destination clock while not empty (d_data shows the head). Each side
// sees the other's pointer two or three clocks late, so it may think the queue
// fuller (source) or emptier (destination) than it is, never the reverse.
// s_empty tells the source when everything it pushed has been popped;
// d_level is how many entries the destination can see.
module ms32_cdc_fifo #(
	parameter int W  = 33,
	parameter int AW = 5              // 2**AW entries
) (
	input  logic          clk_s,
	input  logic          rst_s,
	input  logic          s_push,
	input  logic [W-1:0]  s_data,
	output logic          s_full,
	output logic          s_empty,

	input  logic          clk_d,
	input  logic          rst_d,
	input  logic          d_pop,
	output logic [W-1:0]  d_data,
	output logic          d_valid,
	output logic [AW:0]   d_level
);
	logic [W-1:0] mem [0:(1 << AW) - 1];
	logic [AW:0]  wbin = '0, rbin = '0, wgray = '0, rgray = '0;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [AW:0]  rg_s1 = '0, rg_s2 = '0;       // read pointer in the source clock
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [AW:0]  wg_d1 = '0, wg_d2 = '0;       // write pointer in the destination clock

	function automatic logic [AW:0] g2b(input logic [AW:0] g);
		for (int i = AW; i >= 0; i--) g2b[i] = (i == AW) ? g[i] : g2b[i + 1] ^ g[i];
	endfunction

	// source side
	wire [AW:0] rb_s = g2b(rg_s2);
	assign s_full  = (wbin[AW] != rb_s[AW]) && (wbin[AW-1:0] == rb_s[AW-1:0]);
	assign s_empty = (wbin == rb_s);
	wire [AW:0] wbin_n = wbin + (AW+1)'(1);
	always_ff @(posedge clk_s) begin
		{rg_s2, rg_s1} <= {rg_s1, rgray};
		if (rst_s) begin
			wbin <= '0; wgray <= '0;
		end else if (s_push && !s_full) begin
			mem[wbin[AW-1:0]] <= s_data;
			wbin  <= wbin_n;
			wgray <= wbin_n ^ (wbin_n >> 1);
		end
	end

	// destination side
	wire [AW:0] wb_d = g2b(wg_d2);
	assign d_valid = (wb_d != rbin);
	assign d_level = wb_d - rbin;
	assign d_data  = mem[rbin[AW-1:0]];
	wire [AW:0] rbin_n = rbin + (AW+1)'(1);
	always_ff @(posedge clk_d) begin
		{wg_d2, wg_d1} <= {wg_d1, wgray};
		if (rst_d) begin
			rbin <= '0; rgray <= '0;
		end else if (d_pop && d_valid) begin
			rbin  <= rbin_n;
			rgray <= rbin_n ^ (rbin_n >> 1);
		end
	end
endmodule

