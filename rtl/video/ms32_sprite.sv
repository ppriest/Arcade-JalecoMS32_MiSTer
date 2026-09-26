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
// DDR=1 (F-1 Super Battle: sprite ROM read from DDR3 through ms32_ddr_reader).
// Here the ROM fetch, not the walk, was the frame: 71% of the bridge frame in
// sprite_tb after the one-clock pixel loop, 62% of the worst frame on the
// board. So the walk and the drawing come apart. S_PIX walks a pixel a clock
// and pushes {x, y, priority, colour, byte, new} into a 64-deep queue; a pixel
// whose granule differs from the last one asked for is "new", and that
// granule is requested as it is pushed. The drawer takes the answers in order,
// one per new pixel, keeps the last, and writes the frame buffer. At the end
// of the list S_WR waits for the queue and the drawer to empty; frame_start
// flushes both, and the reader drops what was in flight.
module ms32_sprite #(
	parameter bit DDR = 1'b0,
	parameter int GW  = 22             // DDR=1: granule index width (sprite region 32 MB)
) (
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
	output logic [11:0] first_fy_idx,
	// Where a frame's time goes: clocks waiting for sprite ROM data (S_ROM),
	// for the frame buffer to take a pixel (fb_we held, fb_ready low), and for
	// the object list (obj_ready low in S_READ). Latched at each frame_start,
	// so a frame that overran is counted too; {max, last} of each, 24 bits.
	output logic [143:0] dbg_wait,

	// DDR=1: requests to and answers from ms32_ddr_reader, and its flush
	output logic          rq_valid,
	output logic [GW-1:0] rq_gran,
	input  logic          rq_ready,
	input  logic          rs_valid,
	input  logic [63:0]   rs_data,
	output logic          rs_pop,
	output logic          flush
);

	typedef enum logic [3:0] {S_IDLE, S_READ, S_SETUP, S_MUL, S_CLIP, S_ROW, S_PIX, S_ROM, S_WR, S_NEXT} state_t;   // S_WR: DDR=1's end-of-frame drain
	state_t state;

	logic [11:0] idx;                 // sprite slot
	logic [3:0]  rd_cnt;
	logic [15:0] w [0:7];
	logic [23:0] cyc;
	logic [23:0] w_rom, w_fb, w_obj, l_rom, l_fb, l_obj, m_rom, m_fb, m_obj;
	assign dbg_wait = {m_obj, m_fb, m_rom, l_obj, l_fb, l_rom};
	function automatic logic [23:0] sat24(input logic [23:0] v, input logic e);
		sat24 = (e && v != 24'hFFFFFF) ? v + 24'd1 : v;
	endfunction
	always_ff @(posedge clk) begin
		if (reset) begin
			w_rom <= '0; w_fb <= '0; w_obj <= '0; l_rom <= '0; l_fb <= '0; l_obj <= '0;
			m_rom <= '0; m_fb <= '0; m_obj <= '0;
		end else if (frame_start) begin
			l_rom <= w_rom; l_fb <= w_fb; l_obj <= w_obj;
			if (w_rom > m_rom) m_rom <= w_rom;
			if (w_fb  > m_fb)  m_fb  <= w_fb;
			if (w_obj > m_obj) m_obj <= w_obj;
			w_rom <= '0; w_fb <= '0; w_obj <= '0;
		end else begin
			w_rom <= sat24(w_rom, (state == S_ROM && !rom_valid) || (DDR && d_head && !d_have));
			w_fb  <= sat24(w_fb,  fb_we && !fb_ready);
			w_obj <= sat24(w_obj, state == S_READ && !obj_ready);
		end
	end
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
	// the pixel S_PIX is looking at this clock: its granule, and its pen if
	// that granule is the one held
	wire [27:0] gaddr_now = {page, drawy[7:3], pxabs[15:11], drawy[2:0], 3'b000};
	wire        hit_now   = last_valid && (last_gaddr == gaddr_now);
	wire [7:0]  pen_now   = last_data[8 * pxabs[10:8] +: 8];

	// the frame buffer port: the walk's own (DDR=0) or the drawer's (DDR=1)
	logic        m_fb_we;
	logic [8:0]  m_fb_x;
	logic [7:0]  m_fb_y;
	logic [15:0] m_fb_data;
	logic        d_fb_we;
	logic [8:0]  d_fb_x;
	logic [7:0]  d_fb_y;
	logic [15:0] d_fb_data;
	assign fb_we   = DDR ? d_fb_we   : m_fb_we;
	assign fb_x    = DDR ? d_fb_x    : m_fb_x;
	assign fb_y    = DDR ? d_fb_y    : m_fb_y;
	assign fb_data = DDR ? d_fb_data : m_fb_data;

	// ---------------------------------------------- DDR=1: the pixel queue
	localparam int QL = 6;
	localparam int QD = 1 << QL;
	localparam int QW = 9 + 8 + 4 + 4 + 3 + 1;      // {x, y, pri, colour, byte, new}
	(* ramstyle = "MLAB, no_rw_check" *) logic [QW-1:0] q_mem [0:QD-1];
	logic [QW-1:0] q_in;
	logic          q_push;
	logic [QL-1:0] q_wr, q_rd;
	logic [QL:0]   q_level;
	// the walk tests this before a push that lands the clock after, and the
	// push before it may still be landing
	wire           q_full = (q_level >= QD[QL:0] - 2'd2);
	always_ff @(posedge clk) if (q_push) q_mem[q_wr] <= q_in;
	wire  [QW-1:0] q_head  = q_mem[q_rd];
	wire  [8:0]    hq_x    = q_head[QW-1 -: 9];
	wire  [7:0]    hq_y    = q_head[19:12];
	wire  [7:0]    hq_pc   = q_head[11:4];         // {pri, colour}
	wire  [2:0]    hq_byte = q_head[3:1];
	wire           hq_new  = q_head[0];

	// the granule last asked for
	logic        lr_valid;
	logic [27:0] lr_gaddr;
	wire         p_new  = !lr_valid || (lr_gaddr != gaddr_now);
	wire         p_wait = q_full || (p_new && !rq_ready);

	// ---------------------------------------------- DDR=1: the drawer
	logic [63:0] d_hold;
	wire         d_head = (q_level != 0);
	wire         d_have = !hq_new || rs_valid;
	wire [63:0]  d_src  = hq_new ? rs_data : d_hold;
	wire [7:0]   d_pen  = d_src[8 * hq_byte +: 8];
	wire         d_free = !d_fb_we || fb_ready;
	wire         d_pop  = DDR && d_head && d_have && d_free;
	assign rs_pop = d_pop && hq_new;
	always_ff @(posedge clk) begin
		if (reset || frame_start) begin
			q_wr <= '0; q_rd <= '0; q_level <= '0; d_fb_we <= 1'b0;
		end else begin
			if (d_fb_we && fb_ready) d_fb_we <= 1'b0;
			if (d_pop) begin
				q_rd <= q_rd + 1'b1;
				if (hq_new) d_hold <= rs_data;
				if (d_pen != 8'd0) begin
					d_fb_we   <= 1'b1;
					d_fb_x    <= hq_x;
					d_fb_y    <= hq_y;
					d_fb_data <= {hq_pc, d_pen};
				end
			end
			if (q_push) q_wr <= q_wr + 1'b1;
			q_level <= q_level + {{QL{1'b0}}, q_push} - {{QL{1'b0}}, d_pop};
		end
	end
	// the drawer is done when the queue is empty, nothing is landing in it and
	// its last write has gone
	wire d_idle = (q_level == 0) && !q_push && !d_fb_we;

	always_ff @(posedge clk) begin
		if (reset) begin
			state         <= S_IDLE;
			rom_req_r     <= 1'b0;
			m_fb_we       <= 1'b0;
			frame_done    <= 1'b0;
			q_push        <= 1'b0;
			rq_valid      <= 1'b0;
			flush         <= 1'b0;
			lr_valid      <= 1'b0;
			frame_overrun <= 1'b0;
			last_valid    <= 1'b0;
			cyc           <= 24'd0;
		end else begin
			frame_done <= 1'b0;
			q_push     <= 1'b0;
			rq_valid   <= 1'b0;
			flush      <= 1'b0;
			if (m_fb_we && fb_ready) m_fb_we <= 1'b0;
			cyc <= cyc + 24'd1;

			if (frame_start) begin
				frame_overrun <= frame_overrun | (state != S_IDLE);
				idx    <= reverse ? 12'd0 : 12'd4094;
				rd_cnt <= 4'd0;
				cyc    <= 24'd0;
				drawn  <= 13'd0; n_flipx <= 13'd0; n_flipy <= 13'd0;
				fy_seen <= 1'b0; fy_attr <= 16'd0; fy_idx <= 12'd0;
				m_fb_we <= 1'b0;
				rom_req_r <= 1'b0;
				flush   <= DDR;                              // ms32_ddr_reader drops the last frame's
				lr_valid <= 1'b0;
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

					// One clock a pixel while its granule is the one held: the
					// pen is written (once the frame buffer has taken the last
					// one) and the walk steps on in the same clock. A pixel in
					// another granule asks the ROM; S_ROM comes back here with
					// it held, and the pixel then goes out as a hit. (Three
					// clocks a pixel before, through S_WR and S_NEXT: 41% of
					// the attract's bridge frame in sprite_tb.)
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
						end else if (DDR) begin
							// push the pixel for the drawer, and its granule if new
							if (!p_wait) begin
								q_push <= 1'b1;
								q_in   <= {curx[8:0], cury[7:0], pri, colour, pxabs[10:8], p_new};
								if (p_new) begin
									rq_valid <= 1'b1;
									rq_gran  <= gaddr_now[GW+2:3];
									lr_valid <= 1'b1;
									lr_gaddr <= gaddr_now;
								end
								curx    <= curx + 12'd1;
								cursrcx <= cursrcx + {2'd0, incx};
								pxabs   <= pxnext;
							end
						end else if (hit_now) begin
							if (!m_fb_we || fb_ready) begin
								if (pen_now != 8'd0) begin
									m_fb_we   <= 1'b1;
									m_fb_x    <= curx[8:0];
									m_fb_y    <= cury[7:0];
									m_fb_data <= {pri, colour, pen_now};
								end
								curx    <= curx + 12'd1;
								cursrcx <= cursrcx + {2'd0, incx};
								pxabs   <= pxnext;
							end
						end else begin
							drawx     <= pxabs[16:8];
							rom_addr  <= gaddr_now;
							rom_req_r <= 1'b1;
							state     <= S_ROM;
						end
					end

					S_ROM: if (rom_valid) begin
						rom_req_r  <= 1'b0;
						last_valid <= 1'b1;
						last_gaddr <= gaddr;
						last_data  <= rom_data;
						state      <= S_PIX;
					end

					// the next sprite, or the end of the list
					S_NEXT: begin
						begin
							if (DDR && ((reverse && idx == 12'd4095) || (!reverse && idx == 12'd0))) begin
								state <= S_WR;                  // the drawer still has the queue to draw
							end else if ((reverse && idx == 12'd4095) || (!reverse && idx == 12'd0)) begin
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

					// DDR=1: the walk is done; the frame is when the drawer is
					S_WR: if (d_idle) begin
						frame_cycles  <= cyc;
						sprites_drawn <= drawn;
						drawn_flipx   <= n_flipx;
						drawn_flipy   <= n_flipy;
						first_fy_attr <= fy_attr;
						first_fy_idx  <= fy_idx;
						frame_done    <= 1'b1;
						state         <= S_IDLE;
					end

					default: state <= S_IDLE;
				endcase
			end
		end
	end

endmodule
