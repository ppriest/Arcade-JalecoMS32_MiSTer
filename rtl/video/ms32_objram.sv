// SPDX-License-Identifier: GPL-3.0-or-later
//
// Object RAM (0x10000 bytes, 16-bit behind umask32, 4,096 sprite records)
// and its vblank copy. ms32_v.cpp screen_vblank() copies the whole RAM
// into m_sprram_buffer at the START of vblank and draw_sprites renders
// from the copy; the game rewrites the live RAM during that same vblank.
// A bank swap is not a copy (LESSONS_LEARNED, and the capture tooling
// found the same thing): the game keeps writing to the same RAM it wrote
// last frame, so the copy has to be a copy.
//
// THE COPY LIVES IN DDR3. As a second 32,768-word M10K array it cost 64 of
// the device's 553 blocks, and the first fit with the CPU needed more than
// 553 (README, "Resource usage"). A record is eight u16 words, i.e. two
// 64-bit DDR3 words: live word n is lane n[1:0] of DDR word BASE_W + n>>2.
//
//   copy   at frame_start, 64 records at a time: 512 live words into a
//          128-word staging RAM, then one 128-beat burst write. 64 bursts,
//          then copy_done starts the sprite engine.
//   read   the engine reads through obj_addr with a dpram's two-clock
//          latency, from a 64-record window RAM. obj_ready is low while the
//          record at obj_addr is outside the window; the window is then
//          refilled by one 128-beat burst read placed so the engine's next
//          63 records follow in its walk direction. The engine restarts a
//          record whenever obj_ready is low.
//
// The DDRAM port belongs to ms32_sprite_fb; these bursts are its j_* jobs.
module ms32_objram #(
	parameter logic [27:3] BASE_W = 25'h0220000   // byte 0x1100000 of the DDR3 window
) (
	input  logic        clk,
	input  logic        reset,

	// CPU port, u16 index, on cpu_clk
	input  logic        cpu_clk,
	input  logic [14:0] cpu_addr,
	input  logic        cpu_wel,
	input  logic        cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	input  logic        frame_start,        // vblank start
	output logic        copy_done,          // one clk
	output logic        copying,

	// sprite engine port into the copy
	input  logic        reverse,            // the engine walks idx upward
	input  logic        obj_rd,             // obj_addr holds the record being read
	input  logic [14:0] obj_addr,
	output logic [15:0] obj_data,
	output logic        obj_ready,

	// DDR3 jobs, served by ms32_sprite_fb: 128 beats each
	output logic        j_req,              // held until j_done
	output logic        j_we,
	output logic [27:3] j_addr,
	output logic [63:0] j_din,              // write data for the current beat
	input  logic        j_beat,             // a beat transferred this clock
	input  logic [63:0] j_dout,             // read data, valid with j_beat
	input  logic        j_done
);

	typedef enum logic [2:0] {O_IDLE, O_FILL, O_WRITE, O_READY, O_LOAD} ost_t;
	ost_t ost;

	// ------------------------------------------------------------ live RAM
	logic [14:0] li;
	logic [15:0] live_q;
	dpram_dc #(.ADDR_WIDTH(15), .DATA_WIDTH(16)) u_live (
		.clk_a(cpu_clk),
		.a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
		.clk_b(clk), .b_addr(li), .b_re(1'b1), .b_rdata(live_q)
	);

	// ------------------------------------------------------------ staging RAM
	logic        st_we;
	logic [6:0]  st_waddr, st_raddr;
	logic [63:0] st_wdata;
	wire  [6:0]  st_rnext = (ost == O_WRITE && j_beat) ? st_raddr + 7'd1 : st_raddr;   // next beat's data one clock ahead
	dpram #(.ADDR_WIDTH(7), .DATA_WIDTH(64)) u_stage (
		.clk(clk), .a_addr(st_waddr), .a_wel(st_we), .a_weh(st_we), .a_wdata(st_wdata), .a_rdata(),
		.b_addr(st_rnext), .b_re(1'b1), .b_rdata(j_din)
	);

	// ------------------------------------------------------------ window RAM
	logic [6:0]  wn_waddr;
	logic [63:0] wn_q;
	logic [11:0] win_base;
	logic        win_valid;
	wire  [11:0] ridx   = obj_addr[14:3];
	wire  [11:0] roff   = ridx - win_base;
	wire         in_win = win_valid && (ridx >= win_base) && (roff < 12'd64);
	wire         wn_we  = (ost == O_LOAD) && j_beat;
	dpram #(.ADDR_WIDTH(7), .DATA_WIDTH(64)) u_win (
		.clk(clk), .a_addr(wn_waddr), .a_wel(wn_we), .a_weh(wn_we), .a_wdata(j_dout), .a_rdata(),
		.b_addr({roff[5:0], obj_addr[2]}), .b_re(1'b1), .b_rdata(wn_q)
	);
	logic [1:0] lane;
	always_ff @(posedge clk) lane <= obj_addr[1:0];
	assign obj_data  = wn_q[16 * lane +: 16];
	assign obj_ready = (ost == O_READY) && in_win;

	// ------------------------------------------------------------ control
	logic [9:0]  n;             // live words requested in this batch
	logic [8:0]  k;             // live words received in this batch
	logic        rv;            // live_q is word k
	logic [63:0] acc;
	logic [5:0]  batch;         // 0..63
	logic        pend_copy;

	assign copying = (ost == O_FILL) || (ost == O_WRITE);

	wire [11:0] load_base = reverse ? ridx : ((ridx >= 12'd63) ? ridx - 12'd63 : 12'd0);

	always_ff @(posedge clk) begin
		copy_done <= 1'b0;
		st_we     <= 1'b0;
		if (reset) begin
			ost <= O_IDLE; j_req <= 1'b0; win_valid <= 1'b0; pend_copy <= 1'b0;
		end else begin
			if (frame_start) pend_copy <= 1'b1;
			case (ost)
				O_IDLE, O_READY: begin
					if (pend_copy || frame_start) begin
						pend_copy <= 1'b0;
						win_valid <= 1'b0;
						li <= 15'd0; n <= 10'd0; k <= 9'd0; rv <= 1'b0; batch <= 6'd0;
						ost <= O_FILL;
					end else if (ost == O_READY && obj_rd && !in_win) begin
						win_base <= load_base;
						win_valid <= 1'b0;
						wn_waddr <= 7'd0;
						j_req  <= 1'b1;
						j_we   <= 1'b0;
						j_addr <= BASE_W + {12'd0, load_base, 1'b0};
						ost    <= O_LOAD;
					end
				end

				// live word li is on live_q the clock after it is addressed
				O_FILL: begin
					rv <= (n < 10'd512);
					if (n < 10'd512) begin li <= li + 15'd1; n <= n + 10'd1; end
					if (rv) begin
						acc <= {live_q, acc[63:16]};
						k   <= k + 9'd1;
						if (k[1:0] == 2'd3) begin
							st_we    <= 1'b1;
							st_waddr <= k[8:2];
							st_wdata <= {live_q, acc[63:16]};
						end
						if (k == 9'd511) begin
							st_raddr <= 7'd0;
							j_req  <= 1'b1;
							j_we   <= 1'b1;
							j_addr <= BASE_W + {12'd0, batch, 7'd0};   // 128 DDR words per batch
							ost    <= O_WRITE;
						end
					end
				end

				O_WRITE: begin
					if (j_beat) st_raddr <= st_raddr + 7'd1;
					if (j_done) begin
						j_req <= 1'b0;
						if (batch == 6'd63) begin
							copy_done <= 1'b1;
							ost <= O_READY;
						end else begin
							batch <= batch + 6'd1;
							n <= 10'd0; k <= 9'd0; rv <= 1'b0;
							ost <= O_FILL;
						end
					end
				end

				O_LOAD: begin
					if (j_beat) wn_waddr <= wn_waddr + 7'd1;
					if (j_done) begin
						j_req <= 1'b0;
						win_valid <= 1'b1;
						ost <= O_READY;
					end
				end

				default: ost <= O_IDLE;
			endcase
		end
	end

endmodule
