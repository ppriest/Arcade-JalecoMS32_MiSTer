// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-port RAM, one clock: port A reads and writes (byte-lane enables, so
// a CPU's 16-bit halves land without a read-modify-write), port B reads.
// Both ports are in ONE always_ff so Quartus infers an M10K true dual-port
// block (ROADMAP "RAM budget": two blocks writing one array build it out of
// logic). Depth is 2**ADDR_WIDTH -- a power of two -- for the same reason.
// Reads are synchronous, one cycle: data for the address presented at edge
// N is on rdata after edge N+1.
module dpram #(
	parameter int ADDR_WIDTH = 13,
	parameter int DATA_WIDTH = 16
) (
	input  logic                   clk,

	input  logic [ADDR_WIDTH-1:0] a_addr,
	input  logic                   a_wel,    // write a_wdata[7:0]
	input  logic                   a_weh,    // write a_wdata[DATA_WIDTH-1:8]
	input  logic [DATA_WIDTH-1:0] a_wdata,
	output logic [DATA_WIDTH-1:0] a_rdata,

	input  logic [ADDR_WIDTH-1:0] b_addr,
	output logic [DATA_WIDTH-1:0] b_rdata
);

	logic [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH) - 1];

	always_ff @(posedge clk) begin
		a_rdata <= mem[a_addr];
		if (a_wel) mem[a_addr][7:0]            <= a_wdata[7:0];
		if (a_weh) mem[a_addr][DATA_WIDTH-1:8] <= a_wdata[DATA_WIDTH-1:8];
		b_rdata <= mem[b_addr];
	end

endmodule
