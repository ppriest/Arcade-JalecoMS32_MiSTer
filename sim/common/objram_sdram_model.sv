// SPDX-License-Identifier: GPL-3.0-or-later
//
// ms32_sdram_top's object RAM client as the benches see it: a 64 KB byte
// array (zero at start, like the M10K it replaces) behind one transaction at
// a time. A read is taken on its request's rising edge and answers LAT clocks
// later with the granule; a write shows busy for one clock and lands, as
// sdram_arbiter's download path does. mem is public so a bench can preload a
// capture.
`timescale 1ns/1ps

module objram_sdram_model #(
	parameter int LAT = 12
) (
	input  logic        clk,
	input  logic        rreq,
	input  logic [12:0] raddr,
	output logic        rvalid,
	output logic [63:0] rdata,
	input  logic        wreq,
	input  logic [15:0] waddr,
	input  logic        we16,
	input  logic [15:0] wdata,
	output logic        wbusy
);
	// plain always blocks: the benches preload mem from their own processes
	logic [7:0] mem [0:65535];
	initial for (int i = 0; i < 65536; i++) mem[i] = 8'h00;

	logic        rreq_d = 1'b0, rpend = 1'b0, wtaken = 1'b0;
	logic [12:0] ra;
	int          cnt = 0;
	initial begin rvalid = 1'b0; wbusy = 1'b0; end

	always @(posedge clk) begin
		rvalid <= 1'b0;
		wbusy  <= 1'b0;
		rreq_d <= rreq;
		if (!wreq) wtaken <= 1'b0;
		if (rreq && !rreq_d) begin rpend <= 1'b1; ra <= raddr; end

		if (cnt > 1) cnt <= cnt - 1;
		else if (cnt == 1) begin
			for (int i = 0; i < 8; i++) rdata[8*i +: 8] <= mem[{ra, 3'(i)}];
			rvalid <= 1'b1;
			cnt    <= 0;
		end else if (wreq && !wtaken) begin
			if (we16) begin mem[{waddr[15:1], 1'b0}] <= wdata[7:0]; mem[{waddr[15:1], 1'b1}] <= wdata[15:8]; end
			else mem[waddr] <= wdata[7:0];
			wbusy  <= 1'b1;
			wtaken <= 1'b1;
		end else if (rpend) begin
			rpend <= 1'b0;
			cnt   <= LAT;
		end
	end
endmodule
