// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-port RAM, one clock: port A reads and writes (byte-lane enables, so
// a CPU's 16-bit halves land without a read-modify-write), port B reads.
// Both ports are in ONE always_ff so Quartus infers an M10K true dual-port
// block (ROADMAP "RAM budget": two blocks writing one array build it out of
// logic). Depth is 2**ADDR_WIDTH -- a power of two -- for the same reason.
// Reads are synchronous, one cycle: data for the address presented at edge
// N is on rdata after edge N+1.
//
// b_re EXISTS BECAUSE OF THE ROZ CACHE ON HARDWARE. A port-B read of the
// address port A is writing in the same cycle is "old data" in this RTL and
// in simulation, but the M10K in mixed-port read-during-write gives no such
// guarantee (the fitter's RAM table for the cache: "No - Unsupported Mixed
// Feed Through Setting"), and on the board the ROZ cache came up with lines
// that read as zero after being filled -- tile 0, whose tag is the empty
// RAM's zero, rendered as transparent while every other tile was fetched
// again and again (docs/phase1_video.md, "On the board"). A reader that
// only enables the read in the cycle it needs the data never collides with
// its own writes. Tie b_re high where the two ports never share an address.
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
	input  logic                   b_re,     // read enable: hold b_rdata when low
	output logic [DATA_WIDTH-1:0] b_rdata
);

	logic [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH) - 1];

	// The two lanes are written by separate conditional statements so
	// DATA_WIDTH == 8 (the priority RAM) has no upper lane to select.
	localparam int HI = (DATA_WIDTH > 8) ? DATA_WIDTH - 1 : 8;
	always_ff @(posedge clk) begin
		a_rdata <= mem[a_addr];
		if (a_wel) mem[a_addr][7:0] <= a_wdata[7:0];
		if (DATA_WIDTH > 8 && a_weh) mem[a_addr][HI:8] <= a_wdata[HI:8];
		if (b_re) b_rdata <= mem[b_addr];
	end

endmodule
