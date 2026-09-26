// SPDX-License-Identifier: GPL-3.0-or-later
//
// F-1 Super Battle's road textures (gfx5, 8 MB) read from the HPS DDR3 rather
// than the SDRAM. The SDRAM controller serves one access at a time for the
// whole chip, about 11 clocks each, so a line has room for ~550 of them for
// every client together; at the horizon the road alone wants one 8-byte
// granule per pixel (320) and the ROZ plane as many again, and on the board
// both planes overran most lines (road and ROZ "lines late" saturated). DDR3
// takes pipelined reads, so here the latency is paid once per burst of
// requests rather than once per granule.
//
// The .mra loads the ROM image into DDR3 at 0x30000000 (MS32.sv, "FAST ROM
// LOAD") laid out as the SDRAM map, and nothing writes that part of it
// afterwards: gfx5 is image offset BASE; the sprite frame buffer and the
// object RAM copy sit at 0x2000000 and 0x2100000.
//
// Requests come from ms32_lineplane (DDR=1), one per granule a pixel moves
// into; answers go back in request order. A read is issued only while the
// answer FIFO has room for it and for every read still in flight, so nothing
// the DDR3 returns is ever refused. flush (the line plane's line_start) drops
// the queued requests and the queued answers, and the answers to reads
// already in flight are discarded as they arrive: a line that ran late leaves
// nothing behind for the next.
//
// The DDR side is a client of ms32_ddram_mux: g_rd held until g_ack, one
// beat per read, g_dout_ready for each beat that is this client's.
module ms32_gfx5_ddr #(
	parameter logic [27:0] BASE = 28'h0E80000,  // gfx5 in the image, ms32_sdram_top's BASE_GFX5 in the F-1 map
	parameter int          LOG2 = 5              // request and answer FIFO depth, 2^LOG2
) (
	input  logic        clk,
	input  logic        reset,
	input  logic        flush,

	// from the line plane
	input  logic        rq_valid,
	input  logic [19:0] rq_gran,        // granule: region byte address [22:3]
	output logic        rq_ready,       // room for a request next clock too

	// to the line plane, in request order
	output logic        rs_valid,
	output logic [63:0] rs_data,
	input  logic        rs_pop,

	// ms32_ddram_mux client
	output logic        g_rd,
	output logic [28:0] g_addr,
	input  logic        g_ack,
	input  logic [63:0] g_dout,
	input  logic        g_dout_ready
);
	localparam int D = 1 << LOG2;

	// ----------------------------------------------------------- requests
	(* ramstyle = "MLAB, no_rw_check" *) logic [19:0] rq_mem [0:D-1];
	logic [LOG2:0] rq_wp, rq_rp;
	wire  [LOG2:0] rq_level = rq_wp - rq_rp;
	// the line plane registers its request, so it asks with a clock's margin
	assign rq_ready = (rq_level < D[LOG2:0] - 2);

	// ------------------------------------------------------------ answers
	(* ramstyle = "MLAB, no_rw_check" *) logic [63:0] rs_mem [0:D-1];
	logic [LOG2:0] rs_wp, rs_rp;
	wire  [LOG2:0] rs_level = rs_wp - rs_rp;
	assign rs_valid = (rs_level != 0);
	assign rs_data  = rs_mem[rs_rp[LOG2-1:0]];

	// reads issued and not yet answered, and answers to throw away
	logic [LOG2:0] inflight, drop;

	// issue only while every read in flight, and this one, has a place
	wire can_issue = (rq_level != 0) && ({1'b0, inflight} + {1'b0, rs_level} < {1'b0, D[LOG2:0]});
	assign g_rd   = can_issue && !flush;
	wire  [27:0] byte_addr = BASE + {5'd0, rq_mem[rq_rp[LOG2-1:0]], 3'b000};
	assign g_addr = {4'b0011, byte_addr[27:3]};

	wire issued = g_rd && g_ack;
	wire beat   = g_dout_ready;
	wire keep   = beat && (drop == 0);

	always_ff @(posedge clk) begin
		if (rq_valid) rq_mem[rq_wp[LOG2-1:0]] <= rq_gran;
		if (keep && !flush) rs_mem[rs_wp[LOG2-1:0]] <= g_dout;
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			rq_wp <= '0; rq_rp <= '0; rs_wp <= '0; rs_rp <= '0;
			inflight <= '0; drop <= '0;
		end else begin
			inflight <= inflight + {{LOG2{1'b0}}, issued} - {{LOG2{1'b0}}, beat};
			if (flush) begin
				rq_wp <= '0; rq_rp <= '0; rs_wp <= '0; rs_rp <= '0;
				// every read in flight after this clock is the old line's
				drop <= inflight + {{LOG2{1'b0}}, issued} - {{LOG2{1'b0}}, beat};
			end else begin
				if (rq_valid) rq_wp <= rq_wp + 1'b1;
				if (issued)   rq_rp <= rq_rp + 1'b1;
				if (keep)     rs_wp <= rs_wp + 1'b1;
				if (rs_pop)   rs_rp <= rs_rp + 1'b1;
				if (beat && drop != 0) drop <= drop - 1'b1;
			end
		end
	end

endmodule
