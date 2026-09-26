// SPDX-License-Identifier: GPL-3.0-or-later
//
// F-1 Super Battle's line plane: the engine that draws its road, and its ROZ
// layer, which is the same thing with another map and another ROM.
//
// Transcribed from ms32_v.cpp draw_line_plane() as MAME PR 16135 adds it, and
// checked against scripts/render_model.py, which renders a whole f1superb
// frame pixel for pixel (ROADMAP, "F-1 Super Battle").
//
//   f1layout makes a tile one 2048x1 strip of 8bpp texture, and the map is one
//   tile wide by 0x400 tall, so a row of the map IS a scanline of road:
//
//     per line, from line RAM at 8 * (y & 0xff):
//       cx = (start2x + startx + offsx) << 16  +  x * (lineincxx << 8)
//       cy = (start2y + starty + offsy) << 16  +  x * (lineincxy << 8)
//     row    = (start2y + starty + offsy) & 0x3ff      -- the line's own row
//     vram[2 row] == 0 leaves the whole line transparent
//     line_colour = vram[2 row + 1]; bits 6-4 are the depth the priority RAM
//                                    is indexed with (ms32_mixer)
//     per pixel: px = (cx >> 16), py = (cy >> 16)
//       tile = vram[2 py], colour = vram[2 py + 1] & 0xf
//       pen  = rom[tile * 2048 + px]
//
// WRAP: the road plane wraps (px and py simply truncate); the ROZ plane does
// not, and a pixel whose coordinate leaves the map is transparent. The
// accumulators are 35 bits so that test can be made -- ms32_roz gets away with
// 27 because it always wraps.
//
// TWO PARTS WITH A QUEUE BETWEEN THEM. The generator walks x, reads the map for
// each pixel and pushes what that pixel needs -- granule, which byte of it, the
// colour, whether it draws at all -- into a four-deep queue. The fetcher pops
// from the queue and touches the ROM only when the granule differs from the one
// it holds. Because the address of every granule is known well before it is
// wanted, the generator keeps its lead while the ROM answers, and a run of
// misses costs about one latency each rather than a latency plus the walk. That
// is what the horizon is made of: there one pixel spans 31 texture pixels, so
// every pixel misses. Measured on a driving frame, worst line of 6,144 clocks:
// 5,773 without the queue and 4,818 with it at ROM latency 12, and at latency
// 16 it is the difference between overrunning and 6,098. Beyond that the limit
// is one request in flight -- 320 pixels that each need their own granule
// cannot be served in 6,144 clocks at latency 20 -- which would take a second
// outstanding request in the memory stack to fix.
//
// NO CACHE, ONE HELD GRANULE. Along a line the walk is monotonic, so a granule
// is used by the pixels that land in it and then never again, and consecutive
// lines read different strips. A 64-entry direct-mapped cache was tried and
// measured on a driving frame (263 lines): it saved 3.8% of the fetches (13,669
// against 14,184) and cost a pipeline stage, because a tag in an M10K must be
// read before it can be compared. The held granule compares in the same cycle.
// Two M10K saved.
//
// SHAPE: as ms32_roz -- the same one-line-ahead double line buffer, and the
// same overrun reporting when a line cannot be finished before it is shown.
//
// DDR=1 (the road, whose gfx5 is read from DDR3 through ms32_gfx5_ddr): the
// one-request fetcher above would pay the DDR3's latency per granule, so the
// queue deepens to 32, in MLAB. A pixel whose granule differs from the last
// one asked for is pushed with "new" set, and that granule is requested as it
// is pushed; the fetcher takes the answers in order, one per "new" pixel, and
// draws the rest from the granule it holds. How many reads are in flight is
// ms32_gfx5_ddr's to bound; the generator waits while it has no room.
module ms32_lineplane #(
	parameter bit WRAP = 1'b1,         // road: wraps; ROZ: clips
	parameter bit DDR  = 1'b0          // road: gfx5 through ms32_gfx5_ddr
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        line_start,
	input  logic [11:0] hcnt,
	input  logic [11:0] vcnt_next2,
	input  logic        fetch_line_active,
	input  logic [11:0] hdisplay,

	// control block, raw fields as the driver assembles them
	input  logic [17:0] startx,
	input  logic [17:0] starty,
	input  logic [15:0] offsx,
	input  logic [15:0] offsy,
	input  logic        offsx_hi,      // ctrl[0x38] bit 0
	input  logic        offsy_hi,      // ctrl[0x3c] bit 0

	// line RAM: u16 index, one-cycle synchronous read
	output logic [10:0] line_addr,
	input  logic [15:0] line_data,

	// map RAM: u16 index, one-cycle synchronous read
	output logic [10:0] vram_addr,
	input  logic [15:0] vram_data,

	// tile ROM, region-local byte address, 8-byte granules (see ms32_tilemap)
	output logic        rom_req,
	output logic [23:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

	output logic [7:0]  pen,
	output logic [3:0]  colour,
	output logic        opaque,
	output logic [15:0] line_colour,   // the displayed line's, for the mixer's depth

	output logic        fetch_overrun,
	output logic        overrun_ev,
	output logic        line_done,     // one clk when a line's fetch completes
	output logic [15:0] line_cycles,
	output logic [15:0] line_misses,
	output logic        line_drawn,    // one clk per line whose vram[2 row] is non-zero
	output logic        pen_nz,        // one clk per non-zero pen written to the line buffer
	output logic [9:0]  dbg_row,       // the row the last line selected
	output logic [15:0] dbg_rowword,   // and what vram[2 row] gave back

	// DDR=1: requests to and answers from ms32_gfx5_ddr, and its flush
	output logic        rq_valid,
	output logic [19:0] rq_gran,
	input  logic        rq_ready,
	input  logic        rs_valid,
	input  logic [63:0] rs_data,
	output logic        rs_pop,
	output logic        flush
);

	function automatic logic [34:0] sx18(input logic [17:0] v);
		sx18 = {{17{v[17]}}, v};
	endfunction
	function automatic logic [34:0] sx17(input logic [16:0] v);
		sx17 = {{18{v[16]}}, v};
	endfunction

	logic        fetch_bank, line_busy, blank;
	logic [1:0]  blank_bank;           // per line buffer bank: the line drew nothing
	logic [15:0] lcol_bank [0:1];
	logic [11:0] y;
	logic [15:0] cyc_cnt, miss_cnt;
	logic [9:0]  row, hlast;

	// ---------------------------------------------------- address generator
	typedef enum logic [3:0] {G_IDLE, G_LINERAM, G_SETUP, G_ROW0, G_ROW1, G_ROW2, G_P0, G_P1, G_P2, G_P3} gst_t;
	gst_t gst;
	logic [3:0]  lr_cnt;
	logic [15:0] lr [0:7];
	logic [34:0] cx, cy, dxx, dxy;
	logic [9:0]  gx;                   // the pixel being described
	logic [10:0] px_r;
	logic        in_r;
	logic [11:0] tileno;

	wire [34:0] offsx32 = {19'd0, offsx} + (offsx_hi ? 35'h400 : 35'h0);
	wire [34:0] offsy32 = {19'd0, offsy} + (offsy_hi ? 35'h400 : 35'h0);
	wire [34:0] st2x = sx18({lr[1][1:0], lr[0]});
	wire [34:0] st2y = sx18({lr[3][1:0], lr[2]});
	wire [34:0] lixx = sx17({lr[5][0], lr[4]});
	wire [34:0] lixy = sx17({lr[7][0], lr[6]});
	wire [34:0] cy0  = st2y + sx18(starty) + offsy32;
	wire  [2:0] lr_idx = lr_cnt[2:0] - 3'd2;

	wire [10:0] px = cx[26:16];
	wire  [9:0] py = cy[25:16];
	wire        in_x = WRAP ? 1'b1 : (cx[34:27] == 8'd0);
	wire        in_y = WRAP ? 1'b1 : (cy[34:26] == 9'd0);

	// ------------------------------------------------------------ the queue
	// One entry per pixel, pushed complete, so the fetcher can take the head the
	// clock after it appears. Four deep: enough for the generator to keep its
	// lead across a ROM answer, and the queue is only ever this engine's.
	// DDR=1: 32 deep, so the reads in flight at the DDR3's latency have pixels
	// queued behind them.
	localparam int QL = DDR ? 5 : 2;
	localparam int QD = 1 << QL;
	// {granule (bits 23:3), byte, colour, clear, x, new}. clear: transparent,
	// off the map or a blank line. new (DDR=1): this pixel's granule is the
	// next answer.
	localparam int QW = 20 + 3 + 4 + 1 + 10 + 1;
	(* ramstyle = "MLAB, no_rw_check" *) logic [QW-1:0] q_mem [0:QD-1];
	logic [QW-1:0] q_in;
	logic [QL-1:0] q_wr, q_rd;
	logic [QL:0]   q_level;
	wire  [QW-1:0] q_head = q_mem[q_rd];
	wire  [19:0]   hq_gran  = q_head[QW-1 -: 20];
	wire  [2:0]    hq_byte  = q_head[18:16];
	wire  [3:0]    hq_col   = q_head[15:12];
	wire           hq_clear = q_head[11];
	wire  [9:0]    hq_x     = q_head[10:1];
	wire           hq_new   = q_head[0];
	// push and pop are what happens THIS clock, so the head a stalled fetcher
	// sees is never the one it has already taken
	logic        q_push;
	wire         q_pop;
	// the generator tests this four clocks before it pushes, and its previous
	// push may land in between, so it must leave room for that one too --
	// without the -1 a full queue is overwritten under the fetcher's head
	wire         q_full = (q_level >= QD[QL:0] - 1'b1);
	always_ff @(posedge clk) if (q_push) q_mem[q_wr] <= q_in;

	// ----------------------------------------------------------- the fetcher
	logic        g_valid;              // a granule is held
	logic [19:0] g_tag;
	logic [63:0] g_data;
	wire  [19:0] h_gran  = hq_gran;
	wire         h_hit   = g_valid && (g_tag == h_gran);
	wire         h_clear = hq_clear;
	wire         h_ready = (q_level != 0);      // entries are pushed complete
	logic        rom_req_r, rom_pend, rom_drop;
	assign rom_req  = rom_req_r & ~rom_valid;
	assign rom_addr = {1'b0, h_gran, 3'b000};

	// What the fetcher does this clock. These are wires, not registers: a
	// registered pop reaches the pointer a clock late, and the fetcher would
	// take the same head twice.
	wire f_fast, f_ask, f_fill;
	wire [63:0] fill_data = DDR ? rs_data : rom_data;
	generate if (DDR) begin : g_ddr_fetch
		// the answer to a "new" pixel is the head of ms32_gfx5_ddr's FIFO
		assign f_fast = h_ready && (h_clear || !hq_new);
		assign f_ask  = 1'b0;
		assign f_fill = h_ready && !h_clear && hq_new && rs_valid;
	end else begin : g_rom_fetch
		assign f_fast = h_ready && (h_clear || h_hit);                  // no fetch needed
		assign f_ask  = h_ready && !h_clear && !h_hit && !rom_req_r;     // ask the ROM
		assign f_fill = h_ready && !h_clear && !h_hit && rom_req_r && rom_valid && !rom_drop;
	end endgenerate
	assign q_pop  = f_fast || f_fill;
	assign rs_pop = DDR && f_fill;

	// DDR=1: the granule last asked for, this line
	logic        lr_valid;
	logic [19:0] lr_gran;
	wire  [19:0] p3_gran  = {tileno, px_r[10:3]};
	wire         p3_clear = blank || !in_r;
	wire         p3_new   = DDR && !p3_clear && (!lr_valid || lr_gran != p3_gran);
	wire         p3_wait  = p3_new && !rq_ready;

	logic       wr_en;
	logic [7:0] wr_pen;
	wire [7:0]  next_pen = h_clear ? 8'd0
	                     : f_fill  ? fill_data[8 * hq_byte +: 8]
	                               : g_data[8 * hq_byte +: 8];
	logic [3:0] wr_col;
	logic [9:0] wr_x;
	wire        h_last = (hq_x == hlast);

	always_ff @(posedge clk) begin
		wr_en      <= 1'b0;
		pen_nz     <= 1'b0;
		line_done  <= 1'b0;
		line_drawn <= 1'b0;
		q_push     <= 1'b0;
		rq_valid   <= 1'b0;
		flush      <= 1'b0;

		if (reset) begin
			gst           <= G_IDLE;
			fetch_bank    <= 1'b1;
			line_busy     <= 1'b0;
			rom_req_r     <= 1'b0;
			rom_pend      <= 1'b0;
			rom_drop      <= 1'b0;
			blank         <= 1'b1;
			blank_bank    <= 2'b11;
			g_valid       <= 1'b0;
			q_wr          <= '0;
			q_rd          <= '0;
			q_level       <= '0;
			lr_valid      <= 1'b0;
			overrun_ev    <= 1'b0;
			fetch_overrun <= 1'b0;
		end else begin
			overrun_ev <= 1'b0;
			cyc_cnt    <= cyc_cnt + 16'd1;
			if (rom_valid) rom_pend <= 1'b0; else if (rom_req) rom_pend <= 1'b1;
			if (rom_valid) rom_drop <= 1'b0;

			if (line_start) begin
				overrun_ev    <= line_busy;
				fetch_overrun <= fetch_overrun | line_busy;
				fetch_bank    <= ~fetch_bank;
				rom_req_r     <= 1'b0;
				rom_drop      <= (rom_pend || rom_req) && !rom_valid;
				g_valid       <= 1'b0;             // a line starts holding nothing
				q_wr          <= '0;
				q_rd          <= '0;
				q_level       <= '0;
				lr_valid      <= 1'b0;
				flush         <= DDR;              // ms32_gfx5_ddr drops the last line's
				y             <= fetch_line_active ? vcnt_next2 : 12'd0;
				hlast         <= hdisplay[9:0] - 10'd1;
				lr_cnt        <= 4'd0;
				cyc_cnt       <= 16'd0;
				miss_cnt      <= 16'd0;
				blank         <= 1'b1;
				blank_bank[~fetch_bank] <= 1'b1;
				line_busy     <= fetch_line_active;
				gst           <= G_LINERAM;
			end else begin

				// ------------------------------------------------- generator
				unique case (gst)
					G_IDLE: ;

					// eight u16 at 8*(y & 0xff), as ms32_roz reads them
					G_LINERAM: begin
						line_addr <= {y[7:0], lr_cnt[2:0]};
						if (lr_cnt >= 4'd2) lr[lr_idx] <= line_data;
						if (lr_cnt == 4'd9) gst <= G_SETUP;
						lr_cnt <= lr_cnt + 4'd1;
					end

					G_SETUP: begin
						cx  <= (st2x + sx18(startx) + offsx32) << 16;
						cy  <= cy0 << 16;
						dxx <= lixx << 8;
						dxy <= lixy << 8;
						row <= cy0[9:0];
						gx  <= 10'd0;
						gst <= G_ROW0;
					end

					// the line's own row: vram[2 row] enables it, vram[2 row + 1] is its colour
					G_ROW0: begin vram_addr <= {row, 1'b0}; gst <= G_ROW1; end
					G_ROW1: begin vram_addr <= {row, 1'b1}; gst <= G_ROW2; end
					G_ROW2: begin
						dbg_row     <= row;
						dbg_rowword <= vram_data;
						blank <= (vram_data == 16'd0);
						blank_bank[fetch_bank] <= (vram_data == 16'd0);
						line_drawn <= (vram_data != 16'd0);
						gst   <= G_P0;
					end

					// four clocks a pixel: the map answers two cycles after its
					// address, so the tile word lands in G_P2 and the colour word
					// in G_P3, which pushes the finished entry
					G_P0: if (!q_full) begin
						px_r      <= px;
						in_r      <= in_x & in_y;
						vram_addr <= {py, 1'b0};
						// G_ROW2 left the line's colour word here; a line that draws
						// nothing reports zero, as MAME's line_colour[] does, so the
						// mixer's depth bits match when both planes are blank
						if (gx == 10'd0) lcol_bank[fetch_bank] <= blank ? 16'd0 : vram_data;
						gst       <= G_P1;
					end
					G_P1: begin
						vram_addr <= {py, 1'b1};
						gst       <= G_P2;
					end
					G_P2: begin                        // vram_data is the tile word
						tileno <= vram_data[11:0];
						gst    <= G_P3;
					end
					// vram_data is the colour word, and holds while this waits
					// for ms32_gfx5_ddr to take a request
					G_P3: if (!p3_wait) begin
						q_push <= 1'b1;
						q_in   <= {p3_gran, px_r[2:0], vram_data[3:0], p3_clear, gx, p3_new};
						if (p3_new) begin
							rq_valid <= 1'b1;
							rq_gran  <= p3_gran;
							lr_valid <= 1'b1;
							lr_gran  <= p3_gran;
						end
						cx  <= cx + dxx;
						cy  <= cy + dxy;
						gx  <= gx + 10'd1;
						gst <= (gx == hlast) ? G_IDLE : G_P0;
					end

					default: gst <= G_IDLE;
				endcase

				// --------------------------------------------- queue pointers
				if (q_push) q_wr <= q_wr + 1'b1;
				if (q_pop)  q_rd <= q_rd + 1'b1;
				q_level <= q_level + {{QL{1'b0}}, q_push} - {{QL{1'b0}}, q_pop};

				// --------------------------------------------------- fetcher
				if (f_ask) begin
					rom_req_r <= 1'b1;
					miss_cnt  <= miss_cnt + 16'd1;
				end
				if (f_fill) begin
					rom_req_r <= 1'b0;
					g_valid   <= 1'b1;
					g_tag     <= h_gran;
					g_data    <= fill_data;
					if (DDR) miss_cnt <= miss_cnt + 16'd1;
				end
				if (f_fast || f_fill) begin
					wr_en  <= 1'b1;
					// pen_nz counts the pens the ROM actually gives, not the
					// pixels attempted: a plane fetching zeros draws its whole
					// line transparently and looks identical to one not running.
					pen_nz <= (next_pen != 8'd0);
					wr_pen <= next_pen;
					wr_col <= hq_col;
					wr_x   <= hq_x;
					if (h_last) begin
						line_busy   <= 1'b0;
						line_done   <= 1'b1;
						line_cycles <= cyc_cnt;
						line_misses <= miss_cnt + {15'd0, f_fill && !DDR};
					end
				end
			end
		end
	end

	// ---------------------------------------------------------- line buffer
	logic [11:0] rd_q;
	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(12)) u_buf (
		.clk(clk),
		.a_addr({fetch_bank, wr_x[8:0]}),
		.a_wel(wr_en), .a_weh(wr_en), .a_wdata({wr_col, wr_pen}), .a_rdata(),
		.b_addr({~fetch_bank, hcnt[8:0]}),
		.b_re(1'b1), .b_rdata(rd_q)
	);

	assign colour      = rd_q[11:8];
	assign pen         = rd_q[7:0];
	assign opaque      = (rd_q[7:0] != 8'd0) && !blank_bank[~fetch_bank];
	assign line_colour = lcol_bank[~fetch_bank];

endmodule
