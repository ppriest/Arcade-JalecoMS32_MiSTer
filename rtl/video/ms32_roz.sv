// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 ROZ line engine: the rotate/zoom tilemap (128x128 tiles of 16x16,
// 8bpp, palette base 0x2000), transcribed from ms32_v.cpp draw_roz and
// tilemap_t::draw_roz_core, as the pixel-exact model has it
// (scripts/render_model.py render_roz):
//
//   simple mode (roz_ctrl[0x5c] bit 0 clear), per frame registers:
//     cx = (startx + offsx) << 16  +  x * (incxx << 8)  +  y * (incyx << 8)
//     cy = (starty + offsy) << 16  +  x * (incxy << 8)  +  y * (incyy << 8)
//   super mode (bit 0 set), per line from line RAM at 8 * (y & 0xff):
//     cx = (start2x + startx + offsx) << 16  +  x * (lineincxx << 8)
//     cy = (start2y + starty + offsy) << 16  +  x * (lineincxy << 8)
//   px = (cx >> 16) & 2047,  py = (cy >> 16) & 2047      (wrap always on)
//   ti = (py / 16) * 128 + px / 16;  tile = vram[2 ti];  colour = vram[2 ti + 1] & 0xf
//   pen = rom[tile * 256 + (py & 15) * 16 + (px & 15)]
//
// startx/starty/start2x/start2y are 18-bit two's complement (bit 17 sign),
// the increments 17-bit; offsx/offsy are the 16-bit registers at 0x30/0x34
// plus 0x400 when 0x38/0x3c bit 0 is set. All of it is 32-bit wrapping
// arithmetic in MAME; only bits 26:16 of the accumulators reach the map, and
// addition modulo 2^27 leaves those bits as MAME's, so the accumulators and
// every term added into them are 27 bits.
//
// SHAPE: the same one-line-ahead double line buffer as ms32_tilemap. Per
// pixel: two VRAM reads, then an 8-byte ROM granule (half a tile row) from
// the cache. Five clocks a pixel on a hit (1,600 per line against 6,144),
// plus the ROM latency per miss. A line the engine cannot finish before its
// display shows what it got and raises fetch_overrun/overrun_ev.
// line_cycles/line_misses report each finished line's cost so the bench can
// find the heaviest one.
//
// CACHE: 2,048 sets of two ways, each way a valid bit, a 19-bit tag (tile
// number bits 13:0 -- the region is 16,384 tiles -- row, half) and the
// granule; one bit per set names the way used last, and a miss replaces the
// other. The set is an XOR hash of the tag (fixed random parities, no
// arithmetic). A rotated line needs about as many granules as the line
// before it, and at steep angles the tiles along one line share rows, so a
// cache indexed by row alone (the 64-entry one this replaces) was refilled
// on nearly every pixel: 257 misses on a line at 1:1 and 60-75 degrees. A
// model of this cache on a map of all-different tiles (the sweep in README,
// "Status") keeps a 1:1 line under 50 misses at any angle but exactly 90
// degrees, where every eighth line starts a new half of every row. The tile
// ROM changes only with a download, under reset: reset clears the valid bits
// (2,048 clocks), and no line starts until the clear is done.
//
// WARM PASS. The first line of a frame follows the last one, far away in the
// map, so the cache holds none of its granules; with the cache alone that
// line was a frame's worst (191 misses in the sweep). Every line of vblank
// the engine walks line 0 with the line buffer write off, so line 0 is
// fetched from a warm cache, with the registers as they stand at the end of
// vblank.
module ms32_roz (
	input  logic        clk,
	input  logic        reset,

	input  logic        line_start,
	input  logic [11:0] hcnt,
	input  logic [11:0] vcnt_next2,
	input  logic        fetch_line_active,
	input  logic [11:0] hdisplay,

	// registers, raw fields as the driver assembles them
	input  logic [17:0] startx,
	input  logic [17:0] starty,
	input  logic [16:0] incxx,
	input  logic [16:0] incxy,
	input  logic [16:0] incyx,
	input  logic [16:0] incyy,
	input  logic [15:0] offsx,
	input  logic [15:0] offsy,
	input  logic        offsx_hi,      // roz_ctrl[0x38] bit 0
	input  logic        offsy_hi,      // roz_ctrl[0x3c] bit 0
	input  logic        super_mode,    // roz_ctrl[0x5c] bit 0

	// line RAM: u16 index, one-cycle synchronous read
	output logic [10:0] line_addr,
	input  logic [15:0] line_data,

	// VRAM: u16 index, one-cycle synchronous read
	output logic [14:0] vram_addr,
	input  logic [15:0] vram_data,

	// tile ROM, region-local byte address, 8-byte granules (see ms32_tilemap)
	output logic        rom_req,
	output logic [23:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

	output logic [7:0]  pen,
	output logic [3:0]  colour,
	output logic        opaque,

	output logic        fetch_overrun,
	output logic        overrun_ev,
	output logic        line_done,       // one clk when a line's fetch completes
	output logic [15:0] line_cycles,     // clocks from line_start to line_done
	output logic [15:0] line_misses,     // ROM fetches in that line
	// one clk each, for the ISSP probe
	output logic        dbg_fill,        // a granule written into the cache
	output logic        dbg_hit,         // a pixel served from the cache
	output logic        dbg_pen_nz       // a non-zero pen written to the line buffer
);

	function automatic logic [26:0] sx18(input logic [17:0] v);
		sx18 = {{9{v[17]}}, v};
	endfunction
	function automatic logic [26:0] sx17(input logic [16:0] v);
		sx17 = {{10{v[16]}}, v};
	endfunction

	// ------------------------------------------------------------ line setup
	typedef enum logic [3:0] {S_IDLE, S_LINERAM, S_SETUP, P0, P1, P2, P3, P4, P_ROM} state_t;
	state_t state;

	logic        fetch_bank, line_busy, warm;
	logic [11:0] y;
	logic [3:0]  lr_cnt;
	logic [15:0] lr [0:7];
	logic [26:0] cx, cy, dxx, dxy;
	// Simple mode's y terms, y*(incyx<<8) and y*(incyy<<8), as accumulators
	// stepped once per fetched line (WORKFLOW "No multiplies, no divides"):
	// zero at line 0, +inc per line. Lines are fetched in order once per
	// frame, so the sum is the product MAME computes for registers held
	// across the frame -- the only case MAME renders as intended, since
	// screen_update reads them once.
	logic [26:0] acc_yx, acc_yy;
	wire  [26:0] acc_yx_now = (y == 12'd0) ? 27'd0 : acc_yx + (sx17(incyx) << 8);
	wire  [26:0] acc_yy_now = (y == 12'd0) ? 27'd0 : acc_yy + (sx17(incyy) << 8);
	logic [9:0]  x;
	logic [15:0] cyc_cnt, miss_cnt;

	// per-line constants, from registers or line RAM
	wire [26:0] offsx32 = {11'd0, offsx} + (offsx_hi ? 27'h400 : 27'h0);
	wire [26:0] offsy32 = {11'd0, offsy} + (offsy_hi ? 27'h400 : 27'h0);
	wire [26:0] st2x = sx18({lr[1][1:0], lr[0]});
	wire [26:0] st2y = sx18({lr[3][1:0], lr[2]});
	wire [26:0] lixx = sx17({lr[5][0], lr[4]});
	wire [26:0] lixy = sx17({lr[7][0], lr[6]});

	// pixel coordinates from the accumulators
	wire [10:0] px = cx[26:16];
	wire [10:0] py = cy[26:16];
	wire [13:0] ti = {py[10:4], px[10:4]};
	logic [10:0] px_r, py_r;
	logic [15:0] tileno;
	logic [3:0]  tcol;

	// granule address for the pixel in flight (P3 onward)
	wire [23:0] gaddr = {tileno, py_r[3:0], px_r[3], 3'b000};

	// ------------------------------------------------------------ ROM cache
	// set word: [168] way B used last, [167] A valid, [166:148] A tag,
	// [147:84] A granule, [83] B valid, [82:64] B tag, [63:0] B granule
	wire [18:0] gkey = {tileno[13:0], py_r[3:0], px_r[3]};
	localparam logic [18:0] HM [0:10] = '{19'h1132d, 19'h48dba, 19'h6c78b, 19'h66b09, 19'h61c35, 19'h0813e,
	                                      19'h20a61, 19'h0f17f, 19'h3f6a6, 19'h61673, 19'h3988e};
	logic [10:0] gset;
	always_comb for (int i = 0; i < 11; i++) gset[i] = ^(gkey & HM[i]);

	logic [168:0] c_q;
	logic         c_we;
	logic [10:0]  c_waddr;
	logic [168:0] c_wdata;
	dpram #(.ADDR_WIDTH(11), .DATA_WIDTH(169)) u_cache (
		.clk(clk),
		.a_addr(c_waddr), .a_wel(c_we), .a_weh(c_we), .a_wdata(c_wdata), .a_rdata(),
		.b_addr(gset), .b_re(state == P3), .b_rdata(c_q)   // never in a write's cycle (dpram.sv, b_re)
	);
	logic [10:0] c_idx_r;
	logic        clr_done = 1'b0, rst_d = 1'b0;
	logic [11:0] clr_ptr = 12'd0;
	always_ff @(posedge clk) rst_d <= reset;
	wire         hit_a = c_q[167] && (c_q[166:148] == gkey);
	wire         hit_b = c_q[83]  && (c_q[82:64]   == gkey);
	wire         c_hit = hit_a || hit_b;
	wire [63:0]  c_gran = hit_a ? c_q[147:84] : c_q[63:0];

	logic        rom_req_r;
	assign rom_req = rom_req_r & ~rom_valid;
	// A line_start abandons the pixel in flight. A granule it had requested
	// still arrives; rom_drop discards it, so it is neither drawn nor cached
	// under the next pixel's tag. A warm pass is cut short this way whenever it
	// outlasts its line.
	logic        rom_pend, rom_drop;

	// line buffer write
	logic        wr_en;
	logic [7:0]  wr_pen;
	logic [9:0]  wr_x;

	always_ff @(posedge clk) begin
		if (reset) begin
			state         <= S_IDLE;
			fetch_bank    <= 1'b1;
			line_busy     <= 1'b0;
			rom_req_r     <= 1'b0;
			rom_pend      <= 1'b0;
			rom_drop      <= 1'b0;
			// clear the valid bits, one set a clock, from the first clock of reset
			c_wdata       <= '0;
			if (!rst_d) begin
				c_we     <= 1'b0;
				clr_ptr  <= 12'd0;
				clr_done <= 1'b0;
			end else begin
				c_we     <= !clr_ptr[11];
				c_waddr  <= clr_ptr[10:0];
				if (!clr_ptr[11]) clr_ptr <= clr_ptr + 12'd1;
				clr_done <= clr_ptr[11];
			end
			wr_en         <= 1'b0;
			overrun_ev    <= 1'b0;
			fetch_overrun <= 1'b0;
			line_done     <= 1'b0;
		end else begin
			overrun_ev <= 1'b0;
			c_we       <= 1'b0;
			wr_en      <= 1'b0;
			line_done  <= 1'b0;
			cyc_cnt    <= cyc_cnt + 16'd1;
			if (rom_valid) rom_pend <= 1'b0; else if (rom_req) rom_pend <= 1'b1;
			if (rom_valid) rom_drop <= 1'b0;
			if (!clr_done) begin
				// a reset too short to finish the clear finishes it here; lines
				// keep their bank toggle but fetch nothing until it is done
				c_we    <= !clr_ptr[11];
				c_waddr <= clr_ptr[10:0];
				c_wdata <= '0;
				if (!clr_ptr[11]) clr_ptr <= clr_ptr + 12'd1;
				clr_done <= clr_ptr[11];
			end
			if (line_start) begin
				overrun_ev    <= line_busy;
				fetch_overrun <= fetch_overrun | line_busy;
				fetch_bank    <= ~fetch_bank;
				rom_req_r     <= 1'b0;
				warm          <= !fetch_line_active;
				rom_drop      <= (rom_pend || rom_req) && !rom_valid;   // rom_req: requested this very clock
				y             <= fetch_line_active ? vcnt_next2 : 12'd0;
				lr_cnt        <= 4'd0;
				cyc_cnt       <= 16'd0;
				miss_cnt      <= 16'd0;
				line_busy     <= fetch_line_active && clr_done;
				state         <= !clr_done ? S_IDLE : super_mode ? S_LINERAM : S_SETUP;
			end else begin
				unique case (state)
					S_IDLE: ;

					// eight u16 at 8*(y & 0xff): address k registered at the end of
					// cycle k, sampled by the RAM at the end of k+1, data in at k+2
					S_LINERAM: begin
						line_addr <= {y[7:0], lr_cnt[2:0]};
						if (lr_cnt >= 4'd2) lr[lr_cnt - 4'd2] <= line_data;
						if (lr_cnt == 4'd9) state <= S_SETUP;
						lr_cnt <= lr_cnt + 4'd1;
					end

					S_SETUP: begin
						if (super_mode) begin
							cx  <= (st2x + sx18(startx) + offsx32) << 16;
							cy  <= (st2y + sx18(starty) + offsy32) << 16;
							dxx <= lixx << 8;
							dxy <= lixy << 8;
						end else begin
							cx  <= ((sx18(startx) + offsx32) << 16) + acc_yx_now;
							cy  <= ((sx18(starty) + offsy32) << 16) + acc_yy_now;
							acc_yx <= acc_yx_now;
							acc_yy <= acc_yy_now;
							dxx <= sx17(incxx) << 8;
							dxy <= sx17(incxy) << 8;
						end
						x     <= 10'd0;
						state <= P0;
					end

					P0: begin
						px_r      <= px;
						py_r      <= py;
						vram_addr <= {ti, 1'b0};
						state     <= P1;
					end
					P1: begin
						vram_addr <= {ti, 1'b1};
						state     <= P2;
					end
					P2: begin
						tileno <= vram_data;
						state  <= P3;
					end
					P3: begin
						// cache read address is gaddr[8:3], combinational from tileno/py_r/px_r,
						// sampled by the RAM at the end of this cycle
						tcol    <= vram_data[3:0];
						c_idx_r <= gset;
						state   <= P4;
					end
					P4: begin
						if (c_hit) begin
							if (c_q[168] != hit_b) begin     // the other way was used last: note this one
								c_we    <= 1'b1;
								c_waddr <= c_idx_r;
								c_wdata <= {hit_b, c_q[167:0]};
							end
							wr_en  <= !warm;
							wr_pen <= c_gran[8 * px_r[2:0] +: 8];
							wr_x   <= x;
							cx     <= cx + dxx;
							cy     <= cy + dxy;
							x      <= x + 10'd1;
							if (x == hdisplay[9:0] - 10'd1) begin
								line_busy   <= 1'b0;
								line_done   <= !warm;
								line_cycles <= cyc_cnt;
								line_misses <= miss_cnt;
								state       <= S_IDLE;
							end else begin
								state <= P0;
							end
						end else begin
							rom_addr  <= gaddr;
							rom_req_r <= 1'b1;
							miss_cnt  <= miss_cnt + 16'd1;
							state     <= P_ROM;
						end
					end
					P_ROM: if (rom_valid && !rom_drop) begin
						rom_req_r <= 1'b0;
						c_we      <= 1'b1;
						c_waddr   <= c_idx_r;
						// replace the way not used last; the new one is now the one used last
						c_wdata   <= c_q[168] ? {1'b0, 1'b1, gkey, rom_data, c_q[83:0]}
						                      : {1'b1, c_q[167:84], 1'b1, gkey, rom_data};
						wr_en  <= !warm;
						wr_pen <= rom_data[8 * px_r[2:0] +: 8];
						wr_x   <= x;
						cx     <= cx + dxx;
						cy     <= cy + dxy;
						x      <= x + 10'd1;
						if (x == hdisplay[9:0] - 10'd1) begin
							line_busy   <= 1'b0;
							line_done   <= !warm;
							line_cycles <= cyc_cnt;
							line_misses <= miss_cnt + 16'd1;
							state       <= S_IDLE;
						end else begin
							state <= P0;
						end
					end
					default: state <= S_IDLE;
				endcase
			end
		end
	end

	logic fill_p = 1'b0;
	always_ff @(posedge clk) fill_p <= (state == P_ROM) && rom_valid;
	assign dbg_fill   = fill_p;
	assign dbg_hit    = (state == P4) && c_hit;
	assign dbg_pen_nz = wr_en && (wr_pen != 8'd0);

	// ---------------------------------------------------------- line buffer
	logic [11:0] rd_q;
	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(12)) u_buf (
		.clk(clk),
		.a_addr({fetch_bank, wr_x[8:0]}),
		.a_wel(wr_en),
		.a_weh(wr_en),
		.a_wdata({tcol, wr_pen}),
		.a_rdata(),
		.b_addr({~fetch_bank, hcnt[8:0]}),
		.b_re(1'b1), .b_rdata(rd_q)
	);

	assign colour = rd_q[11:8];
	assign pen    = rd_q[7:0];
	assign opaque = (rd_q[7:0] != 8'd0);

endmodule
