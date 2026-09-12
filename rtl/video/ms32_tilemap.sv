// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 tilemap line engine -- one instance for TX (8x8 tiles, 64x64 map)
// and one for BG (16x16 tiles, 64x64 map, or 256x16 when bgmode bit 0 is
// set). Transcribed from ms32_v.cpp's tilemap setup and the pixel-exact
// model in scripts/render_model.py (draw_tilemap):
//
//   ti      = (((y + scrolly) / T) mod rows) * cols + (((x + scrollx) / T) mod cols)
//   tile    = vram[2*ti]            colour = vram[2*ti + 1] & 0xf
//   pen     = rom[tile*T*T + fy*T + fx]      (8bpp, one byte per pixel)
//   palette = base + colour*256 + pen        pen 0 transparent
//
// scrollx/scrolly arrive already summed (scroll[0] + scroll[2] + const,
// scroll[3] + scroll[5]) -- the register block does that, so this engine
// has no constants to get wrong.
//
// SHAPE: a double line buffer in M10K, filled ONE LINE AHEAD. At line_start
// (the dot after the last active dot of line L) the display bank flips to
// the one filled during line L, which holds line L+1, and the fetch side
// starts on line L+2 into the other bank: a full line time (6,144 clk at
// the default CRTC) for 41 (TX) or 21 (BG) tile fetches, against the ~1,000
// that hblank alone would give. The Psikyo engine's per-tile prefetch ring
// is the same idea with a harder wrap; the line buffer costs one M10K and
// has no wrap.
//
// The display side reads buf[hcnt] continuously; the dpram's one-cycle
// read means pen/colour for dot hcnt are valid from the second clk after
// hcnt changes until it changes again, i.e. for every clk of the dot
// period but the first. Consumers sample on the ce_pix that ends the dot.
//
// Tile ROM port: req/valid, 8-byte granules, byte i of the granule at
// rom_data[8*i +: 8] -- the same order the bytes have in the ROM, which the
// SDRAM backend must deliver (Psikyo needed gfxrom_byte_reorder for exactly
// this; stating the contract here puts the burden on the backend, once).
// rom_req is held until rom_valid and drops COMBINATIONALLY on it --
// LESSONS_LEARNED (Psikyo): a registered clear leaves req high for the
// cycle the phy is back in IDLE, which launches a duplicate transaction and
// shifts every later fetch by one tile.
//
// Latency is not assumed anywhere; a line that does not finish fetching
// before its display starts shows what was fetched and sets fetch_overrun
// (sticky) and overrun_ev (one pulse per late line) for the debug page.
module ms32_tilemap #(
	parameter bit TILE_16 = 1'b0   // 0: TX 8x8, 1: BG 16x16
) (
	input  logic        clk,
	input  logic        reset,

	// raster, from ms32_crtc
	input  logic        line_start,
	input  logic [11:0] hcnt,
	input  logic [11:0] vcnt_next2,   // the line being prefetched
	input  logic        fetch_line_active,   // vcnt_next2 < vdisplay
	input  logic [11:0] hdisplay,

	// layer registers, sampled at line_start
	input  logic [15:0] scrollx,
	input  logic [15:0] scrolly,
	input  logic        bgmode,       // BG only: 1 = 256x16 map

	// VRAM read port: u16 index, one-cycle synchronous read (dpram port B)
	output logic [12:0] vram_addr,
	input  logic [15:0] vram_data,

	// tile ROM, region-local byte address
	output logic        rom_req,
	output logic [23:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

	// the dot at hcnt
	output logic [7:0]  pen,
	output logic [3:0]  colour,
	output logic        opaque,

	output logic        fetch_overrun,
	output logic        overrun_ev
);

	localparam int T      = TILE_16 ? 16 : 8;
	localparam int NTILES = TILE_16 ? 21 : 41;   // 320/T + 1 for the scroll remainder

	// ------------------------------------------------------------ fetch side
	typedef enum logic [2:0] {S_IDLE, S_VR0, S_VR1, S_VR2, S_VR3, S_ROM, S_ROM2, S_WRITE} state_t;
	state_t state;

	logic        fetch_bank;                 // bank being filled
	logic [15:0] sx, sy;                     // (x + scrollx) for tile k, (y + scrolly)
	logic [5:0]  tiles_left;
	logic [15:0] tileno;
	logic [3:0]  tcol;
	logic [127:0] row;                       // up to 16 pens
	logic [4:0]  wr_i;                       // pixel within the tile row
	logic [9:0]  wr_x0;                      // screen x of pixel 0 of this tile (signed 10-bit)
	logic        bgmode_l;
	logic        rom_req_r;
	logic        line_busy;                  // a fetch is in progress for the pending line

	assign rom_req = rom_req_r & ~rom_valid;

	// map index from the latched coordinates
	logic [12:0] ti;
	always_comb begin
		if (!TILE_16)      ti = {1'b0, sy[8:3], sx[8:3]};              // 64x64 of 8
		else if (!bgmode_l) ti = {1'b0, sy[9:4], sx[9:4]};              // 64x64 of 16
		else               ti = {1'b0, sy[7:4], sx[11:4]};             // 256x16 of 16
	end
	wire [3:0] fy = TILE_16 ? sy[3:0] : {1'b0, sy[2:0]};

	wire [9:0] x_of_tile = {4'd0, 6'(NTILES - tiles_left)} * 10'(T) - {6'd0, TILE_16 ? sx[3:0] : {1'b0, sx[2:0]}};

	always_ff @(posedge clk) begin
		if (reset) begin
			state      <= S_IDLE;
			rom_req_r  <= 1'b0;
			fetch_bank <= 1'b1;
			line_busy  <= 1'b0;
			overrun_ev <= 1'b0;
			fetch_overrun <= 1'b0;
		end else begin
			overrun_ev <= 1'b0;
			if (line_start) begin
				// A new line takes over whatever was in flight (Psikyo lesson:
				// checked before the state case, not only from S_IDLE).
				overrun_ev    <= line_busy;
				fetch_overrun <= fetch_overrun | line_busy;
				fetch_bank    <= ~fetch_bank;
				rom_req_r     <= 1'b0;
				bgmode_l      <= bgmode;
				sx            <= scrollx;                         // tile 0 at screen x = -(scrollx mod T)
				sy            <= scrolly + {4'd0, vcnt_next2};
				tiles_left    <= 6'(NTILES);
				line_busy     <= fetch_line_active;
				state         <= fetch_line_active ? S_VR0 : S_IDLE;
			end else begin
				unique case (state)
					S_IDLE: ;
					S_VR0: begin vram_addr <= {ti[11:0], 1'b0}; state <= S_VR1; end
					S_VR1: begin vram_addr <= {ti[11:0], 1'b1}; state <= S_VR2; end
					S_VR2: begin tileno <= vram_data;            state <= S_VR3; end
					S_VR3: begin
						tcol      <= vram_data[3:0];
						rom_addr  <= TILE_16 ? {tileno, fy, 1'b0, 3'b000} : {2'b00, tileno, fy[2:0], 3'b000};
						rom_req_r <= 1'b1;
						state     <= S_ROM;
					end
					S_ROM: if (rom_valid) begin
						rom_req_r <= 1'b0;
						row[63:0] <= rom_data;
						if (TILE_16) begin
							rom_addr[3] <= 1'b1;
							rom_req_r   <= 1'b1;
							state       <= S_ROM2;
						end else begin
							wr_i  <= 5'd0;
							wr_x0 <= x_of_tile;
							state <= S_WRITE;
						end
					end
					S_ROM2: if (rom_valid) begin
						rom_req_r  <= 1'b0;
						row[127:64] <= rom_data;
						wr_i  <= 5'd0;
						wr_x0 <= x_of_tile;
						state <= S_WRITE;
					end
					S_WRITE: begin
						if (wr_i == 5'(T - 1)) begin
							sx         <= sx + 16'(T);
							tiles_left <= tiles_left - 6'd1;
							if (tiles_left == 6'd1) begin
								line_busy <= 1'b0;
								state     <= S_IDLE;
							end else begin
								state <= S_VR0;
							end
						end
						wr_i <= wr_i + 5'd1;
					end
					default: state <= S_IDLE;
				endcase
			end
		end
	end

	// line buffer write: pixel wr_i of the tile lands at wr_x0 + wr_i
	wire [9:0]  wr_x   = wr_x0 + {5'd0, wr_i};
	wire        wr_en  = (state == S_WRITE) && !wr_x[9] && (wr_x[8:0] < hdisplay[8:0]);
	wire [7:0]  wr_pen = row[8 * wr_i +: 8];

	// ---------------------------------------------------------- line buffer
	// 2 banks x 512 x 12 bits: {colour, pen}
	logic [11:0] rd_q;
	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(12)) u_buf (
		.clk(clk),
		.a_addr({fetch_bank, wr_x[8:0]}),
		.a_wel(wr_en),
		.a_weh(wr_en),
		.a_wdata({tcol, wr_pen}),
		.a_rdata(),
		.b_addr({~fetch_bank, hcnt[8:0]}),
		.b_rdata(rd_q)
	);

	assign colour = rd_q[11:8];
	assign pen    = rd_q[7:0];
	assign opaque = (rd_q[7:0] != 8'd0);

endmodule
