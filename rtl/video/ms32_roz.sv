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
// arithmetic in MAME; only bits 26:16 of the accumulators reach the map, so
// a 32-bit accumulator here is exact.
//
// SHAPE: the same one-line-ahead double line buffer as ms32_tilemap. Per
// pixel: two VRAM reads, then an 8-byte ROM granule (half a tile row) from
// a 64-entry direct-mapped cache indexed by granule address bits 8:3 --
// a horizontal 1:1 line fetches one granule per 8 pixels; a rotated line
// re-touches the same tile's rows and the cache holds them. Five clocks a
// pixel on a hit (1,600 per line against 6,144), plus the ROM latency per
// miss. The tile ROM never changes, so the cache is never invalidated; a
// line the engine cannot finish before its display shows what it got and
// raises fetch_overrun/overrun_ev. line_cycles/line_misses report each
// finished line's cost so the bench can find the heaviest one.
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
	output logic [15:0] line_misses      // ROM fetches in that line
);

	function automatic logic [31:0] sx18(input logic [17:0] v);
		sx18 = {{14{v[17]}}, v};
	endfunction
	function automatic logic [31:0] sx17(input logic [16:0] v);
		sx17 = {{15{v[16]}}, v};
	endfunction

	// ------------------------------------------------------------ line setup
	typedef enum logic [3:0] {S_IDLE, S_LINERAM, S_SETUP, P0, P1, P2, P3, P4, P_ROM} state_t;
	state_t state;

	logic        fetch_bank, line_busy;
	logic [11:0] y;
	logic [3:0]  lr_cnt;
	logic [15:0] lr [0:7];
	logic [31:0] cx, cy, dxx, dxy;
	// Simple mode's y terms, y*(incyx<<8) and y*(incyy<<8), as accumulators
	// stepped once per fetched line (WORKFLOW "No multiplies, no divides"):
	// zero at line 0, +inc per line. Lines are fetched in order once per
	// frame, so the sum is the product MAME computes for registers held
	// across the frame -- the only case MAME renders as intended, since
	// screen_update reads them once.
	logic [31:0] acc_yx, acc_yy;
	wire  [31:0] acc_yx_now = (y == 12'd0) ? 32'd0 : acc_yx + (sx17(incyx) << 8);
	wire  [31:0] acc_yy_now = (y == 12'd0) ? 32'd0 : acc_yy + (sx17(incyy) << 8);
	logic [9:0]  x;
	logic [15:0] cyc_cnt, miss_cnt;

	// per-line constants, from registers or line RAM
	wire [31:0] offsx32 = {16'd0, offsx} + (offsx_hi ? 32'h400 : 32'h0);
	wire [31:0] offsy32 = {16'd0, offsy} + (offsy_hi ? 32'h400 : 32'h0);
	wire [31:0] st2x = sx18({lr[1][1:0], lr[0]});
	wire [31:0] st2y = sx18({lr[3][1:0], lr[2]});
	wire [31:0] lixx = sx17({lr[5][0], lr[4]});
	wire [31:0] lixy = sx17({lr[7][0], lr[6]});

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
	// 64 x {tag[14:0], data[63:0]}, indexed by gaddr[8:3]; valid bits in regs
	logic [63:0] cvalid;
	logic [78:0] c_q;
	logic        c_we;
	logic [5:0]  c_waddr;
	logic [78:0] c_wdata;
	dpram #(.ADDR_WIDTH(6), .DATA_WIDTH(79)) u_cache (
		.clk(clk),
		.a_addr(c_waddr), .a_wel(c_we), .a_weh(c_we), .a_wdata(c_wdata), .a_rdata(),
		.b_addr(gaddr[8:3]), .b_re(state == P3), .b_rdata(c_q)   // never in the write's cycle (dpram.sv, b_re)
	);
	logic [5:0]  c_idx_r;
	wire         c_hit = cvalid[c_idx_r] && (c_q[78:64] == gaddr[23:9]);

	logic        rom_req_r;
	assign rom_req = rom_req_r & ~rom_valid;

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
			cvalid        <= 64'd0;
			c_we          <= 1'b0;
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
			if (line_start) begin
				overrun_ev    <= line_busy;
				fetch_overrun <= fetch_overrun | line_busy;
				fetch_bank    <= ~fetch_bank;
				rom_req_r     <= 1'b0;
				y             <= vcnt_next2;
				lr_cnt        <= 4'd0;
				cyc_cnt       <= 16'd0;
				miss_cnt      <= 16'd0;
				line_busy     <= fetch_line_active;
				state         <= !fetch_line_active ? S_IDLE : super_mode ? S_LINERAM : S_SETUP;
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
						c_idx_r <= gaddr[8:3];
						state   <= P4;
					end
					P4: begin
						if (c_hit) begin
							wr_en  <= 1'b1;
							wr_pen <= c_q[8 * px_r[2:0] +: 8];
							wr_x   <= x;
							cx     <= cx + dxx;
							cy     <= cy + dxy;
							x      <= x + 10'd1;
							if (x == hdisplay[9:0] - 10'd1) begin
								line_busy   <= 1'b0;
								line_done   <= 1'b1;
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
					P_ROM: if (rom_valid) begin
						rom_req_r <= 1'b0;
						c_we      <= 1'b1;
						c_waddr   <= c_idx_r;
						c_wdata   <= {gaddr[23:9], rom_data};
						cvalid[c_idx_r] <= 1'b1;
						wr_en  <= 1'b1;
						wr_pen <= rom_data[8 * px_r[2:0] +: 8];
						wr_x   <= x;
						cx     <= cx + dxx;
						cy     <= cy + dxy;
						x      <= x + 10'd1;
						if (x == hdisplay[9:0] - 10'd1) begin
							line_busy   <= 1'b0;
							line_done   <= 1'b1;
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
