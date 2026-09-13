// SPDX-License-Identifier: GPL-3.0-or-later
//
// Program ROM cache, in the CPU's clock domain: a direct-mapped cache of
// 8-byte granules in front of the SDRAM, which is a clock-domain crossing
// and an arbiter away. ROADMAP Phase 2: the CPU's instruction port was
// measured at CPI 7.57 when served in one clock, against 20.1 through the
// data adapter, so the cache is there from the start.
//
// Two clients, served one at a time, data first:
//   if_*   the core's FAST_IFETCH port. if_addr is the frontier byte; the
//          answer is the granule containing it shifted down so byte 0 is the
//          frontier byte (the core appends 8 - if_addr[2:0] bytes). One
//          clock of if_ack.
//   d_*    a 32-bit data read from the bus decoder, aligned (d_addr[1:0] = 0),
//          one clock of d_ack with d_rdata.
// A miss goes out on g_* (granule index, held until g_ack) and is written
// into the cache as it is answered. Granule byte i is g_data[8*i +: 8],
// ms32_sdram_top's convention. valid bits are registers so reset empties
// the cache: the ROM behind it is reloaded by every download.
//
// Addresses are ROM-local byte offsets (21 bits, 2 MB).
module ms32_rom_cache #(
	parameter int LINES_LOG2 = 10
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        if_req,
	input  logic [20:0] if_addr,
	output logic        if_ack,
	output logic [63:0] if_data,

	input  logic        d_req,
	input  logic [20:0] d_addr,
	output logic        d_ack,
	output logic [31:0] d_rdata,

	output logic        g_req,
	output logic [17:0] g_addr,
	input  logic        g_ack,
	input  logic [63:0] g_data,

	output logic [31:0] hits, misses
);

	localparam int TAGW = 18 - LINES_LOG2;
	localparam int NL   = 1 << LINES_LOG2;

	logic [LINES_LOG2-1:0] line;
	logic [TAGW-1:0]       tag;
	logic [63:0]           c_data;
	logic [TAGW-1:0]       c_tag;
	logic                  c_we;
	logic [NL-1:0]         vld;

	logic [63+TAGW:0] mem [0:NL-1];
	logic [63+TAGW:0] rd;
	always_ff @(posedge clk) begin
		if (c_we) mem[line] <= {c_tag, c_data};
		rd <= mem[line];
	end

	typedef enum logic [2:0] {C_IDLE, C_LOOK, C_CMP, C_FETCH, C_DRAIN} cst_t;
	cst_t st;
	logic       who_d;          // 1: data client, 0: instruction port
	logic [2:0] off;            // byte offset in the granule (if) / word select (d)
	logic       vld_q;

	wire [63:0] line_data = rd[63:0];
	wire [TAGW-1:0] line_tag = rd[63+TAGW:64];

	task automatic answer(input logic [63:0] gr);
		if (who_d) begin
			d_rdata <= off[2] ? gr[63:32] : gr[31:0];
			d_ack   <= 1'b1;
		end else begin
			if_data <= gr >> {off, 3'b000};
			if_ack  <= 1'b1;
		end
	endtask

	always_ff @(posedge clk) begin
		if_ack <= 1'b0;
		d_ack  <= 1'b0;
		c_we   <= 1'b0;
		if (reset) begin
			st <= C_IDLE; g_req <= 1'b0; vld <= '0; hits <= 32'd0; misses <= 32'd0;
		end else case (st)
			C_IDLE: begin
				if (d_req) begin
					who_d <= 1'b1; off <= {d_addr[2], 2'b00};
					line <= d_addr[3 +: LINES_LOG2]; tag <= d_addr[20 -: TAGW]; g_addr <= d_addr[20:3];
					st <= C_LOOK;
				end else if (if_req) begin
					who_d <= 1'b0; off <= if_addr[2:0];
					line <= if_addr[3 +: LINES_LOG2]; tag <= if_addr[20 -: TAGW]; g_addr <= if_addr[20:3];
					st <= C_LOOK;
				end
			end
			C_LOOK: begin          // rd is the line after this edge
				vld_q <= vld[line];
				st <= C_CMP;
			end
			C_CMP: begin
				if (vld_q && line_tag == tag) begin
					answer(line_data);
					hits <= hits + 32'd1;
					st <= C_DRAIN;
				end else begin
					g_req <= 1'b1;
					misses <= misses + 32'd1;
					st <= C_FETCH;
				end
			end
			C_FETCH: if (g_ack) begin
				g_req  <= 1'b0;
				c_data <= g_data; c_tag <= tag; c_we <= 1'b1;
				vld[line] <= 1'b1;
				answer(g_data);
				st <= C_DRAIN;
			end
			C_DRAIN: st <= C_IDLE;  // the client drops its request on the ack clock
			default: st <= C_IDLE;
		endcase
	end

endmodule
