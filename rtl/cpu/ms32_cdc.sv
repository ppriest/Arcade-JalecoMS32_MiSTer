// SPDX-License-Identifier: GPL-3.0-or-later
//
// Clock-domain crossings between clk_cpu (the V70's domain) and clk_sys.
// The SDC treats the two clocks as asynchronous; everything that crosses
// goes through one of these three shapes, and nothing else may.
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
