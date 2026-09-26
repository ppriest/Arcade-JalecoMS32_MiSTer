// SPDX-License-Identifier: GPL-3.0-or-later
//
// MS32 zoom sprite engine: renders the whole object list once per frame
// into a frame buffer through a write port. Transcribed from ms32_v.cpp
// draw_sprites, ms32_sprite.cpp extract_parameters and
// draw_sprite_zoom_core, and checked against the pixel-exact model
// (scripts/render_model.py render_sprites).
//
// Object record, 8 u16 per sprite, 4,096 slots:
//   0 attr   bit0 flipx, bit1 flipy, bit2 visible (disable = ~attr & 4), bits 7:4 priority
//   1 code   tx = code[7:0], ty = code[15:8]  (start pixel within the page)
//   2 color  page = color[11:0] (256x256 pixels each), colour = color[15:12]
//   3 size   srcw = size[7:0] + 1, srch = size[15:8] + 1
//   4 y      10-bit two's complement       5 x  11-bit two's complement
//   6 incx   8.8 source step per screen pixel (0x100 = 1:1); 0 = not drawn
//   7 incy
//
// draw_sprite_zoom_core, per sprite:
//   srcstartx = tx << 8, srcendx = srcw << 8 (y likewise)
//   left clip:  if destx < 0: srcx = -destx * incx, destx = 0; skip if srcx >= srcendx
//   rows:  for cury = desty while cury < vdisplay and srcy < srcendy:
//            drawy = (srcstarty + (flipy ? srcendy - srcy - 1 : srcy)) >> 8; skip row if >= 256
//            for curx = destx while curx < hdisplay and cursrcx < srcendx:
//              drawx = (srcstartx + (flipx ? srcendx - cursrcx - 1 : cursrcx)) >> 8; skip if >= 256
//              pen = page[drawy][drawx]; if pen: fb[cury][curx] = {pri, colour, pen}
//              cursrcx += incx
//            srcy += incy
//   page byte (x, y) = page*65536 + ((y>>3)*32 + (x>>3))*64 + (y&7)*8 + (x&7)
//
// ORDER. MAME walks the list tail->0 when sprite_ctrl[0x10] bit 15 is clear
// (0->tail-1 otherwise) with a first-drawn-wins pixel op. This engine
// overwrites, so it walks the OPPOSITE way: 0->4095 when bit 15 is clear,
// 4094->0 when set -- the same picture (docs/phase1_video.md, "Sprite
// engine"). The cost of that choice is that a frame which overruns drops
// the sprites the chip would have drawn first, i.e. the ones on top;
// frame_overrun and frame_cycles/sprites_drawn are there to show whether
// that ever happens.
//
// Sprite ROM: req/valid 8-byte granules (byte i at rom_data[8*i +: 8]),
// one granule per 8-pixel run of a tile row; the last granule is kept, so
// a 1:1 row costs one fetch per 8 pixels. The frame buffer write port is
// x/y/data with a ready for back-pressure; what is behind it (DDR3, and
// the per-frame clear) is ms32_sprite_fb's business.
module ms32_sprite (
	input  logic        clk,
	input  logic        reset,

	input  logic        frame_start,     // one clk: the vblank copy of object RAM is ready
	input  logic        reverse,         // sprite_ctrl[0x10] bit 15 CLEAR (MAME's "reverseorder")
	input  logic [11:0] hdisplay,
	input  logic [11:0] vdisplay,

	// object RAM (the vblank copy): u16 index, one-cycle synchronous read.
	// obj_ready low means the record at obj_addr is not readable yet (the
	// copy is in DDR3 behind a window, ms32_objram): the record restarts.
	output logic [14:0] obj_addr,
	input  logic [15:0] obj_data,
	input  logic        obj_ready,
	output logic        obj_rd,

	// sprite ROM, region-local byte address
	output logic        rom_req,
	output logic [27:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

	// frame buffer write port
	output logic        fb_we,
	output logic [8:0]  fb_x,
	output logic [7:0]  fb_y,
	output logic [15:0] fb_data,         // {pri[3:0], colour[3:0], pen[7:0]}
	input  logic        fb_ready,

	output logic        busy,
	output logic        frame_done,      // one clk
	output logic        frame_overrun,   // sticky: frame_start arrived while busy
	output logic [23:0] frame_cycles,    // of the last completed frame
	output logic [12:0] sprites_drawn,   // of the last completed frame
	// Of the last completed frame, how many drawn sprites carried each flip
	// bit. The question they answer is which side of the bus is wrong when a
	// sprite comes out mirrored: the game's own attribute, or this engine.
	output logic [12:0] drawn_flipx,
	output logic [12:0] drawn_flipy,
	// The first drawn sprite of the frame carrying flipy, with the slot it came
	// from: MAME never sets that bit in this game, so whatever is here says
	// whether the record is a plausible sprite or corrupted object RAM.
	output logic [15:0] first_fy_attr,
	output logic [11:0] first_fy_idx
);

	typedef enum logic [3:0] {S_IDLE, S_READ, S_SETUP, S_MUL, S_CLIP, S_ROW, S_PIX, S_ROM, S_WR, S_NEXT} state_t;
	state_t state;

	logic [11:0] idx;                 // sprite slot
	logic [3:0]  rd_cnt;
	logic [15:0] w [0:7];
	logic [23:0] cyc;
	logic [12:0] drawn, n_flipx, n_flipy;
	logic [15:0] fy_attr;
	logic [11:0] fy_idx;
	logic        fy_seen;

	// decoded record
	wire        flipx   = w[0][0];
	wire        flipy   = w[0][1];
	wire        disabled = ~w[0][2];
	wire [3:0]  pri     = w[0][7:4];
	wire [7:0]  tx      = w[1][7:0];
	wire [7:0]  ty      = w[1][15:8];
	wire [11:0] page    = w[2][11:0];
	wire [3:0]  colour  = w[2][15:12];
	// Widths are the largest value each can hold (MAME's are all 32 bits):
	//   srcend <= 0x10000 (17), srcstart <= 0xFF00 (16), inc <= 0xFFFF (16)
	//   srcx/srcy after the clip <= 1024 x 0xFFFF (26); in a row srcx < srcendx
	//   cursrcx < srcendx + incx (18); pxabs = srcstartx + source x <= 0x1FEFF (17)
	//   curx/cury and destx/desty are screen positions (12, >= 0 after the clip)
	wire [16:0] srcendx = {w[3][7:0] + 9'd1, 8'd0};      // (srcw) << 8
	wire [16:0] srcendy = {w[3][15:8] + 9'd1, 8'd0};
	wire [16:0] srcstartx = {1'b0, tx, 8'd0};
	wire [16:0] srcstarty = {1'b0, ty, 8'd0};
	wire signed [11:0] sy0 = {{2{w[4][9]}}, w[4][9:0]};
	wire signed [11:0] sx0 = {w[5][10], w[5][10:0]};
	wire [15:0] incx = w[6];
	wire [15:0] incy = w[7];

	// draw state
	logic [11:0] destx, desty;
	logic [25:0] srcx, srcy;
	logic [17:0] cursrcx;
	logic [16:0] pxabs;               // page x of the pixel in flight, << 8, stepped by +-incx
	logic [11:0] curx, cury;
	logic [8:0]  drawy;               // 9 bits: >= 256 means skip
	logic [8:0]  drawx;
	logic        last_valid;
	logic [27:0] last_gaddr;
	logic [63:0] last_data;
	logic [7:0]  pen;
	logic        rom_req_r;
	// left/top clip: srcx = -destx * incx as a shift-add over the 11 bits of
	// -destx (WORKFLOW "No multiplies, no divides"); only clipped sprites pay
	// the eleven cycles
	logic [10:0] negx;
	logic [9:0]  negy;
	logic [3:0]  mul_i;

	assign rom_req = rom_req_r & ~rom_valid;
	assign busy    = (state != S_IDLE);
	assign obj_rd  = (state == S_READ) && (rd_cnt != 4'd0);

	// Used only while srcy < srcendy (S_ROW) and srcx < srcendx (S_CLIP), so
	// the subtractions cannot go below zero.
	wire [16:0] rowsrc = flipy ? (srcendy - srcy[16:0] - 17'd1) : srcy[16:0];
	wire [16:0] drawy_full = srcstarty + rowsrc;           // page y << 8
	// A flipped row walks the page backwards: pxabs starts at the row's last
	// source pixel and subtracts incx where the forward walk adds it. MAME
	// recomputes srcend - cursrcx - 1 for every pixel; the two agree while
	// cursrcx < srcendx, which is the only time pxabs is used.
	wire [16:0] pxstart = srcstartx + (flipx ? (srcendx - srcx[16:0] - 17'd1) : srcx[16:0]);
	wire [16:0] pxnext  = flipx ? (pxabs - {1'b0, incx}) : (pxabs + {1'b0, incx});
	wire [27:0] gaddr = {page, drawy[7:3], drawx[7:3], drawy[2:0], 3'b000};

	// A row is in progress from S_ROW's start until S_PIX decides it is done;
	// S_NEXT is reached with row_active set only from S_WR/S_ROM.
	logic row_active;
	always_ff @(posedge clk) begin
		if (reset || frame_start)   row_active <= 1'b0;
		else if (state == S_WR)     row_active <= 1'b1;
		else if (state == S_PIX || state == S_ROW || state == S_SETUP || state == S_CLIP) row_active <= 1'b0;
	end

	always_ff @(posedge clk) begin
		if (reset) begin
			state         <= S_IDLE;
			rom_req_r     <= 1'b0;
			fb_we         <= 1'b0;
			frame_done    <= 1'b0;
			frame_overrun <= 1'b0;
			last_valid    <= 1'b0;
			cyc           <= 24'd0;
		end else begin
			frame_done <= 1'b0;
			if (fb_we && fb_ready) fb_we <= 1'b0;
			cyc <= cyc + 24'd1;

			if (frame_start) begin
				frame_overrun <= frame_overrun | (state != S_IDLE);
				idx    <= reverse ? 12'd0 : 12'd4094;
				rd_cnt <= 4'd0;
				cyc    <= 24'd0;
				drawn  <= 13'd0; n_flipx <= 13'd0; n_flipy <= 13'd0;
				fy_seen <= 1'b0; fy_attr <= 16'd0; fy_idx <= 12'd0;
				fb_we  <= 1'b0;
				rom_req_r <= 1'b0;
				state  <= S_READ;
			end else begin
				unique case (state)
					S_IDLE: ;

					// eight words, two-cycle read latency
					S_READ: begin
						obj_addr <= {idx, rd_cnt[2:0]};
						if (rd_cnt != 4'd0 && !obj_ready) begin
							rd_cnt <= 4'd0;                       // obj_addr now names this record; wait for it
						end else begin
							if (rd_cnt >= 4'd2) w[rd_cnt - 4'd2] <= obj_data;
							if (rd_cnt == 4'd9) state <= S_SETUP;
							rd_cnt <= rd_cnt + 4'd1;
						end
					end

					S_SETUP: begin
						if (disabled || w[6] == 16'd0 || w[7] == 16'd0) begin
							state <= S_NEXT;
						end else begin
							// left/top clip against 0
							destx <= (sx0 < 0) ? 12'd0 : sx0;
							desty <= (sy0 < 0) ? 12'd0 : sy0;
							negx  <= (sx0 < 0) ? 11'(12'd0 - sx0) : 11'd0;
							negy  <= (sy0 < 0) ? 10'(12'd0 - sy0) : 10'd0;
							srcx  <= 26'd0;
							srcy  <= 26'd0;
							mul_i <= 4'd0;
							state <= (sx0 < 0 || sy0 < 0) ? S_MUL : S_CLIP;
						end
					end

					S_MUL: begin
						if (negx[mul_i]) srcx <= srcx + ({10'd0, incx} << mul_i);
						if (mul_i < 4'd10 && negy[mul_i]) srcy <= srcy + ({10'd0, incy} << mul_i);
						mul_i <= mul_i + 4'd1;
						if (mul_i == 4'd10) state <= S_CLIP;
					end

					S_CLIP: begin
						if (srcx >= {9'd0, srcendx} || srcy >= {9'd0, srcendy}) begin
							state <= S_NEXT;
						end else begin
							cury  <= desty;
							drawn <= drawn + 13'd1;
							if (flipx) n_flipx <= n_flipx + 13'd1;
							if (flipy) begin
								n_flipy <= n_flipy + 13'd1;
								if (!fy_seen) begin
									fy_seen <= 1'b1;
									fy_attr <= w[0];
									fy_idx  <= idx;
								end
							end
							state <= S_ROW;
						end
					end

					// start a row, or finish the sprite
					S_ROW: begin
						if (cury >= vdisplay || srcy >= {9'd0, srcendy}) begin
							state <= S_NEXT;
						end else begin
							drawy   <= drawy_full[16:8];            // bit 8 set: >= 256, the row is skipped
							cursrcx <= {1'b0, srcx[16:0]};
							pxabs   <= pxstart;
							curx    <= destx;
							state   <= S_PIX;
						end
					end

					S_PIX: begin
						if (drawy[8] || curx >= hdisplay || cursrcx >= {1'b0, srcendx}) begin
							// row done
							cury  <= cury + 12'd1;
							srcy  <= srcy + {10'd0, incy};
							state <= S_ROW;
						end else if (pxabs[16]) begin               // page x >= 256: skip the pixel
							curx    <= curx + 12'd1;
							cursrcx <= cursrcx + {2'd0, incx};
							pxabs   <= pxnext;
						end else begin
							drawx <= pxabs[16:8];
							state <= S_WR;      // S_WR decides between the kept granule and a fetch
						end
					end

					S_WR: begin
						if (last_valid && last_gaddr == gaddr) begin
							pen <= last_data[8 * drawx[2:0] +: 8];
							state <= S_NEXT;    // S_NEXT with busy row: write and advance (see below)
						end else begin
							rom_addr  <= gaddr;
							rom_req_r <= 1'b1;
							state     <= S_ROM;
						end
					end

					S_ROM: if (rom_valid) begin
						rom_req_r  <= 1'b0;
						last_valid <= 1'b1;
						last_gaddr <= gaddr;
						last_data  <= rom_data;
						pen        <= rom_data[8 * drawx[2:0] +: 8];
						state      <= S_NEXT;
					end

					// Two jobs, told apart by whether a row is in progress
					// (drawx valid): emit the pixel and advance, or move to
					// the next sprite.
					S_NEXT: begin
						if (row_active) begin
							if (!fb_we || fb_ready) begin
								if (pen != 8'd0) begin
									fb_we   <= 1'b1;
									fb_x    <= curx[8:0];
									fb_y    <= cury[7:0];
									fb_data <= {pri, colour, pen};
								end
								curx    <= curx + 12'd1;
								cursrcx <= cursrcx + {2'd0, incx};
								pxabs   <= pxnext;
								state   <= S_PIX;
							end
						end else begin
							if ((reverse && idx == 12'd4095) || (!reverse && idx == 12'd0)) begin
								frame_cycles  <= cyc;
								sprites_drawn <= drawn;
								drawn_flipx   <= n_flipx;
								drawn_flipy   <= n_flipy;
								first_fy_attr <= fy_attr;
								first_fy_idx  <= fy_idx;
								frame_done    <= 1'b1;
								state         <= S_IDLE;
							end else begin
								idx    <= reverse ? idx + 12'd1 : idx - 12'd1;
								rd_cnt <= 4'd0;
								state  <= S_READ;
							end
						end
					end

					default: state <= S_IDLE;
				endcase
			end
		end
	end

endmodule
