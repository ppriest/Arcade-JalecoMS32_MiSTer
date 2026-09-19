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
// THE LIVE RAM IS IN SDRAM, THE COPY IN DDR3. Either as a 32,768-word M10K
// array costs 64 of the device's 553 blocks. The live RAM is 64 KB at
// ms32_sdram_top's BASE_OBJRAM. The V70's writes are posted into a queue
// (ms32_cpu_sys); its reads are requests it waits for (ROADMAP, "Offload
// candidates", measured the cost on three games). Live
// word n is lane n[1:0] of SDRAM granule n>>2; a record is eight words, so
// granule g is also DDR3 word BASE_W + g.
//
//   cpu    a read is the granule's lane; a write is one SDRAM write of one or
//          both byte lanes. Writes are posted by the CPU into a queue and
//          taken from it here in order, ahead of any read.
//   copy   at frame_start, granules 0..8191 in order into a 128-word staging
//          RAM, each full staging RAM one 128-beat DDR3 burst; after 64
//          bursts copy_done starts the sprite engine. The copy starts once the
//          writes queued before frame_start have landed; a later write to a
//          granule the copy has not read yet waits until it has, so the copy
//          is the RAM as it was at frame_start. CPU reads are served during
//          the copy.
//   read   the engine reads through obj_addr with a dpram's two-clock
//          latency, from a 64-record window RAM. obj_ready is low while the
//          record at obj_addr is outside the window; the window is then
//          refilled by one 128-beat burst read placed so the engine's next
//          63 records follow in its walk direction. The engine restarts a
//          record whenever obj_ready is low.
//
// One SDRAM transaction at a time from this module. The DDRAM port belongs to
// ms32_sprite_fb; these bursts are its j_* jobs.
module ms32_objram #(
	parameter logic [27:3] BASE_W = 25'h0420000   // byte 0x2100000 of the DDR3 window, above the fast-load ROM image
) (
	input  logic        clk,
	input  logic        reset,

	// CPU writes, posted: the head of ms32_cpu_sys's queue (ms32_cdc_fifo),
	// {lanes[1:0] ([0] low byte, [1] high), u16 index[14:0], data[15:0]},
	// popped one at a time
	input  logic        wq_valid,
	input  logic [32:0] wq_data,
	output logic        wq_pop,
	input  logic [5:0]  wq_level,
	// CPU reads (ms32_cpu_sys's crossing, clk): cpu_req one clock with the
	// address held until cpu_valid, which answers once. The CPU issues a read
	// only when its writes have all left the queue; the ones popped and not yet
	// written go first here.
	input  logic        cpu_req,
	input  logic [14:0] cpu_addr,           // u16 index
	output logic        cpu_valid,
	output logic [15:0] cpu_rdata,

	// SDRAM (ms32_sdram_top): granule reads held until sd_rvalid; writes held
	// until sd_wbusy has been seen, done when it falls
	output logic        sd_rreq,
	output logic [12:0] sd_raddr,           // granule index
	input  logic        sd_rvalid,
	input  logic [63:0] sd_rdata,
	output logic        sd_wreq,
	output logic [15:0] sd_waddr,           // byte offset in the region
	output logic        sd_we16,            // both lanes from sd_wdata; else byte sd_wdata[7:0]
	output logic [15:0] sd_wdata,
	input  logic        sd_wbusy,

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

	// ------------------------------------------------------------ staging RAM
	logic        st_we;
	logic [6:0]  st_waddr, st_raddr;
	logic [63:0] st_wdata;
	logic        dwrite;             // the DDR3 FSM is writing a batch
	wire  [6:0]  st_rnext = (dwrite && j_beat) ? st_raddr + 7'd1 : st_raddr;   // next beat's data one clock ahead
	dpram #(.ADDR_WIDTH(7), .DATA_WIDTH(64)) u_stage (
		.clk(clk), .a_addr(st_waddr), .a_wel(st_we), .a_weh(st_we), .a_wdata(st_wdata), .a_rdata(),
		.b_addr(st_rnext), .b_re(1'b1), .b_rdata(j_din)
	);

	// ------------------------------------------------------------ window RAM
	logic [6:0]  wn_waddr;
	logic [63:0] wn_q;
	logic [11:0] win_base;
	logic        win_valid;
	logic        dload;              // the DDR3 FSM is loading the window
	logic        ready;              // the copy is complete
	wire  [11:0] ridx   = obj_addr[14:3];
	wire  [11:0] roff   = ridx - win_base;
	wire         in_win = win_valid && (ridx >= win_base) && (roff < 12'd64);
	wire         wn_we  = dload && j_beat;
	dpram #(.ADDR_WIDTH(7), .DATA_WIDTH(64)) u_win (
		.clk(clk), .a_addr(wn_waddr), .a_wel(wn_we), .a_weh(wn_we), .a_wdata(j_dout), .a_rdata(),
		.b_addr({roff[5:0], obj_addr[2]}), .b_re(1'b1), .b_rdata(wn_q)
	);
	logic [1:0] lane;
	always_ff @(posedge clk) lane <= obj_addr[1:0];
	assign obj_data  = wn_q[16 * lane +: 16];
	assign obj_ready = ready && !dload && in_win;

	wire [11:0] load_base = reverse ? ridx : ((ridx >= 12'd63) ? ridx - 12'd63 : 12'd0);

	// ------------------------------------------------------------ control
	typedef enum logic [2:0] {S_IDLE, S_RD, S_GAP, S_WR, S_WWAIT} sst_t;
	sst_t sst;
	logic        rd_pend, op_cpu;
	logic [14:0] rd_w;
	logic        w_have;             // a popped write, not yet written
	logic [14:0] w_w;
	logic [1:0]  w_ln;
	logic [15:0] w_d;
	logic [6:0]  pre;                // writes queued before frame_start still to land
	logic        copy_act, batch_full, pend_copy;
	logic [13:0] gptr;               // granules copied, 0..8192
	logic [5:0]  batch;

	assign copying = copy_act;
	assign wq_pop  = !reset && !w_have && wq_valid;
	wire   w_go    = w_have && (!copy_act || ({1'b0, w_w[14:2]} < gptr));
	wire   r_go    = rd_pend && !w_have && !wq_valid;
	// a write lands this clock (w_have covers a popped write until it has)
	wire   w_done  = (sst == S_IDLE && w_go && w_ln == 2'b00) || (sst == S_WWAIT && !sd_wbusy);

	always_ff @(posedge clk) begin
		copy_done <= 1'b0;
		st_we     <= 1'b0;
		cpu_valid <= 1'b0;
		if (reset) begin
			sst <= S_IDLE; sd_rreq <= 1'b0; sd_wreq <= 1'b0;
			rd_pend <= 1'b0; w_have <= 1'b0; pre <= 7'd0;
			copy_act <= 1'b0; batch_full <= 1'b0; pend_copy <= 1'b0; ready <= 1'b0;
			j_req <= 1'b0; dwrite <= 1'b0; dload <= 1'b0; win_valid <= 1'b0;
		end else begin
			if (cpu_req) begin rd_pend <= 1'b1; rd_w <= cpu_addr; end
			if (wq_pop) begin w_have <= 1'b1; {w_ln, w_w, w_d} <= wq_data; end

			// a new copy starts once the previous one, any window load and the
			// writes queued before frame_start are done
			if (frame_start) begin
				pend_copy <= 1'b1;
				pre <= 7'(wq_level) + 7'(w_have && !w_done);
			end else if (w_done && pre != 7'd0) pre <= pre - 7'd1;
			if (pend_copy && pre == 7'd0 && !copy_act && !dload) begin
				pend_copy <= 1'b0;
				copy_act  <= 1'b1;
				ready     <= 1'b0;
				win_valid <= 1'b0;
				gptr      <= 14'd0;
				batch     <= 6'd0;
			end

			// ---------------------------------------------------- SDRAM
			case (sst)
				S_IDLE: begin
					if (w_go) begin
						if (w_ln == 2'b00) begin
							w_have <= 1'b0;
						end else begin
							sd_wreq  <= 1'b1;
							sd_we16  <= (w_ln == 2'b11);
							sd_waddr <= {w_w, w_ln == 2'b10};
							sd_wdata <= (w_ln == 2'b10) ? {8'd0, w_d[15:8]} : w_d;
							sst      <= S_WR;
						end
					end else if (r_go) begin
						rd_pend <= 1'b0;
						op_cpu  <= 1'b1;
						sd_rreq <= 1'b1; sd_raddr <= rd_w[14:2]; sst <= S_RD;
					end else if (copy_act && !batch_full && gptr != 14'd8192) begin
						op_cpu  <= 1'b0;
						sd_rreq <= 1'b1; sd_raddr <= gptr[12:0]; sst <= S_RD;
					end
				end
				S_RD: if (sd_rvalid) begin
					sd_rreq <= 1'b0;
					if (op_cpu) begin
						cpu_rdata <= sd_rdata[16 * rd_w[1:0] +: 16];
						cpu_valid <= 1'b1;
					end else begin
						st_we    <= 1'b1;
						st_waddr <= gptr[6:0];
						st_wdata <= sd_rdata;
						gptr     <= gptr + 14'd1;
						if (gptr[6:0] == 7'd127) batch_full <= 1'b1;
					end
					sst <= S_GAP;           // the arbiter takes requests on their rising edge
				end
				S_GAP: sst <= S_IDLE;
				S_WR: if (sd_wbusy) begin sd_wreq <= 1'b0; sst <= S_WWAIT; end
				S_WWAIT: if (!sd_wbusy) begin
					w_have <= 1'b0;
					sst <= S_IDLE;
				end
				default: sst <= S_IDLE;
			endcase

			// ---------------------------------------------------- DDR3
			if (dwrite) begin
				if (j_beat) st_raddr <= st_raddr + 7'd1;
				if (j_done) begin
					j_req <= 1'b0; dwrite <= 1'b0; batch_full <= 1'b0;
					if (batch == 6'd63) begin
						copy_act  <= 1'b0;
						ready     <= 1'b1;
						copy_done <= 1'b1;
					end else
						batch <= batch + 6'd1;
				end
			end else if (dload) begin
				if (j_beat) wn_waddr <= wn_waddr + 7'd1;
				if (j_done) begin
					j_req <= 1'b0; dload <= 1'b0; win_valid <= 1'b1;
				end
			end else if (batch_full && !j_done) begin
				st_raddr <= 7'd0;
				j_req    <= 1'b1;
				j_we     <= 1'b1;
				j_addr   <= BASE_W + {12'd0, batch, 7'd0};   // 128 DDR words per batch
				dwrite   <= 1'b1;
			end else if (ready && obj_rd && !in_win && !pend_copy && !frame_start && !j_done) begin
				win_base  <= load_base;
				win_valid <= 1'b0;
				wn_waddr  <= 7'd0;
				j_req     <= 1'b1;
				j_we      <= 1'b0;
				j_addr    <= BASE_W + {12'd0, load_base, 1'b0};
				dload     <= 1'b1;
			end
		end
	end

endmodule
