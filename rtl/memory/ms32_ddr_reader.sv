// SPDX-License-Identifier: GPL-3.0-or-later
//
// A ROM region of the fast-load image read from the HPS DDR3 rather than the
// SDRAM: 8-byte granules, many reads in flight, answers in request order.
// F-1 Super Battle uses two, for the road textures (gfx5, 8 MB) and for the
// sprite ROM (32 MB).
//
// Why. The SDRAM controller serves one access at a time for the whole chip,
// about 11 clocks each, so a 6,144-clock line has room for ~550 of them for
// every client together. At the horizon the road alone wants one granule per
// pixel (320) and the ROZ plane as many again: on the board both planes
// overran most lines. On the attract's bridge frame the sprite engine waited
// on SDRAM for 62% of its worst frame and ran into the next one, so the car,
// drawn on top, dropped out. DDR3 takes pipelined reads, so the latency is
// paid once per run of requests rather than once per granule.
//
// The .mra loads the ROM image into DDR3 at 0x30000000 (MS32.sv, "FAST ROM
// LOAD") laid out as the SDRAM map, and nothing writes the image afterwards:
// the F1 build keeps the sprite frame buffer and the object RAM copy at
// 0x4000000 and 0x4100000, above its 58.75 MB image. Region byte address a is
// image offset BASE + a; the granule index is a[GW+2:3].
//
// Requests come from ms32_lineplane or ms32_sprite (DDR=1), one per granule
// a pixel moves into. A read is issued only while the answer FIFO has room
// for it and for every read still in flight, so nothing the DDR3 returns is
// ever refused. flush drops the queued requests and the queued answers, and
// the answers to reads already in flight are discarded as they arrive: a
// line (or frame) that ran late leaves nothing behind for the next.
//
// The DDR side is a client of ms32_ddram_mux (through ms32_ddr_g2 when there
// are two): g_rd held until g_ack, one beat per read, g_dout_ready for each
// beat that is this client's. g_rd and g_addr come from a one-entry slot of
// flops, loaded a clock ahead: computed from the FIFO pointers they were the
// worst clk_sys path of the build (-1.396 ns, rs_rp through ms32_ddr_g2 and
// the mux into the HPS's f2sdram inputs). And a read once offered is never
// withdrawn -- the mux holds one it was offered while busy (M_GRD) and issues
// it whatever -- so a flush lets it go and throws its answer away.
module ms32_ddr_reader #(
	parameter logic [27:0] BASE = 28'h0E80000,  // the region's image offset (ms32_sdram_top's map)
	parameter int          GW   = 20,           // granule index width: log2(region size / 8)
	parameter int          LOG2 = 5              // request and answer FIFO depth, 2^LOG2
) (
	input  logic          clk,
	input  logic          reset,
	input  logic          flush,

	// from the engine
	input  logic          rq_valid,
	input  logic [GW-1:0] rq_gran,
	output logic          rq_ready,       // room for a request next clock too

	// to the engine, in request order
	output logic          rs_valid,
	output logic [63:0]   rs_data,
	input  logic          rs_pop,

	// ms32_ddram_mux client
	output logic          g_rd,
	output logic [28:0]   g_addr,
	input  logic          g_ack,
	input  logic [63:0]   g_dout,
	input  logic          g_dout_ready
);
	localparam int D = 1 << LOG2;

	// ----------------------------------------------------------- requests
	(* ramstyle = "MLAB, no_rw_check" *) logic [GW-1:0] rq_mem [0:D-1];
	logic [LOG2:0] rq_wp, rq_rp;
	wire  [LOG2:0] rq_level = rq_wp - rq_rp;
	// the engines register their request, so they ask with a clock's margin
	assign rq_ready = (rq_level < D[LOG2:0] - 2);

	// ------------------------------------------------------------ answers
	(* ramstyle = "MLAB, no_rw_check" *) logic [63:0] rs_mem [0:D-1];
	logic [LOG2:0] rs_wp, rs_rp;
	wire  [LOG2:0] rs_level = rs_wp - rs_rp;
	assign rs_valid = (rs_level != 0);
	assign rs_data  = rs_mem[rs_rp[LOG2-1:0]];

	// reads in the slot or issued and not yet answered, and answers to throw away
	logic [LOG2:0] inflight, drop;

	// the slot: the read offered to the mux
	logic          slot_valid;
	logic [28:0]   slot_addr;
	assign g_rd   = slot_valid;
	assign g_addr = slot_addr;
	wire   taken  = slot_valid && g_ack;

	// load the slot while every read in flight, and this one, has a place
	wire  [27:0] byte_addr = BASE + 28'({rq_mem[rq_rp[LOG2-1:0]], 3'b000});
	wire  load = !flush && (rq_level != 0) && (!slot_valid || taken)
	             && ({1'b0, inflight} + {1'b0, rs_level} < {1'b0, D[LOG2:0]});

	wire beat   = g_dout_ready;
	wire keep   = beat && (drop == 0);

	always_ff @(posedge clk) begin
		if (rq_valid) rq_mem[rq_wp[LOG2-1:0]] <= rq_gran;
		if (keep && !flush) rs_mem[rs_wp[LOG2-1:0]] <= g_dout;
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			rq_wp <= '0; rq_rp <= '0; rs_wp <= '0; rs_rp <= '0;
			inflight <= '0; drop <= '0; slot_valid <= 1'b0;
		end else begin
			inflight <= inflight + {{LOG2{1'b0}}, load} - {{LOG2{1'b0}}, beat};
			if (load) begin
				slot_valid <= 1'b1;
				slot_addr  <= {4'b0011, byte_addr[27:3]};
			end else if (taken) begin
				slot_valid <= 1'b0;
			end
			if (flush) begin
				rq_wp <= '0; rq_rp <= '0; rs_wp <= '0; rs_rp <= '0;
				// every read in the slot or in flight after this clock is the
				// old line's (load is off while flush is up)
				drop <= inflight - {{LOG2{1'b0}}, beat};
			end else begin
				if (rq_valid) rq_wp <= rq_wp + 1'b1;
				if (load)     rq_rp <= rq_rp + 1'b1;
				if (keep)     rs_wp <= rs_wp + 1'b1;
				if (rs_pop)   rs_rp <= rs_rp + 1'b1;
				if (beat && drop != 0) drop <= drop - 1'b1;
			end
		end
	end

endmodule
