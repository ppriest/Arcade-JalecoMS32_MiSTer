// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sprite frame buffer: two 320x224x16-bit banks in the HPS DDR3 window
// (ROADMAP "Memory plan": 2.29 Mbit, cannot be BRAM), behind three jobs
// on one DDRAM port:
//
//   1. the sprite engine's pixel writes, combined into 64-bit words (four
//      pixels) with byte enables, so a row of a 1:1 sprite is one DDRAM
//      write per four pixels and no read-modify-write anywhere;
//   2. the display-side line reader, one line ahead like every other
//      engine here: at line_start it fetches the 80 words of line
//      vcnt_next2 from the display bank into a double line buffer;
//   3. the clear: each line is written back as zeros right after it is
//      read, so the display bank is empty again by the time it becomes
//      the render bank at the next swap. That replaces a 17,920-word
//      clear burst at the start of every render with the same writes
//      spread over the frame, and needs no state beyond the reader's.
//
// Banks swap at frame_start (vblank start). The render bank is then the
// one just displayed and cleared; the display bank the one just rendered.
// The sprite engine starts a little later, once the object-RAM copy is
// done, so its first write lands after the swap.
//
// DDRAM protocol: MiSTer's Avalon-style port. Line reads and clears are
// 80-beat bursts, sprite words single beats (the phy below says what is
// hardware-verified and what is not). At BURSTCNT=1 throughout, a DDRAM
// with 20 busy clocks and 60 of read latency starved the sprite writes in
// sim/video_tb (docs/phase1_video.md); MiSTer documents the latency as
// unbounded, which is why the reader has a whole line of lead and the
// sticky rd_overrun flag.
//
// Pixel (x, y) of bank b lives at byte BASE + b*0x40000 + y*640 + x*2,
// little-endian, {pri, colour, pen}; 0 means empty.
module ms32_sprite_fb #(
	parameter logic [27:0] BASE = 28'h1000000   // byte offset inside the 0x30000000 window
) (
	input  logic        clk,
	input  logic        reset,

	// raster, from ms32_crtc
	input  logic        frame_start,        // vblank start: swap banks
	input  logic        line_start,
	input  logic [11:0] hcnt,
	input  logic [11:0] vcnt_next2,
	input  logic        fetch_line_active,

	// from ms32_sprite
	input  logic        fb_we,
	input  logic [8:0]  fb_x,
	input  logic [7:0]  fb_y,
	input  logic [15:0] fb_data,
	output logic        fb_ready,
	input  logic        flush,              // sprite engine frame_done: push the last word out

	// the sprite pixel at dot hcnt
	output logic [15:0] pix,

	// DDRAM
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic        DDRAM_WE,

	output logic        rd_overrun,         // sticky: a line was not read before its display
	output logic        rd_overrun_ev,
	output logic [15:0] wr_stall_cycles     // cycles fb_ready was low in the last frame
);

	// ------------------------------------------------------------ banks
	logic disp_bank;                        // bank being displayed; ~disp_bank is rendered into
	always_ff @(posedge clk) begin
		if (reset) disp_bank <= 1'b0;
		else if (frame_start) disp_bank <= ~disp_bank;
	end

	function automatic logic [27:0] pixaddr(input logic bank, input logic [7:0] y, input logic [8:0] x);
		pixaddr = BASE + {9'd0, bank, 18'd0} + {11'd0, y, 9'd0} + {13'd0, y, 7'd0} + {18'd0, x, 1'b0};   // y*640 = y*512 + y*128
	endfunction

	// ---------------------------------------------------- write combiner
	logic        wc_valid;
	logic [27:3] wc_addr;
	logic [63:0] wc_data;
	logic [7:0]  wc_be;
	logic [4:0]  wc_idle;                   // cycles since the last write
	logic        pend_valid;
	logic [27:3] pend_addr;
	logic [63:0] pend_data;
	logic [7:0]  pend_be;
	logic        pend_issue;                // arbiter took pend this cycle

	wire [27:0] wr_pa   = pixaddr(~disp_bank, fb_y, fb_x);
	wire        wr_same = wc_valid && (wr_pa[27:3] == wc_addr);
	assign fb_ready = wr_same || !wc_valid || !pend_valid;
	wire wc_flush = wc_valid && (flush || (wc_idle == 5'd31)) && !pend_valid && !(fb_we && wr_same);

	always_ff @(posedge clk) begin
		if (reset) begin
			wc_valid   <= 1'b0;
			pend_valid <= 1'b0;
			wc_idle    <= 5'd0;
		end else begin
			if (pend_issue) pend_valid <= 1'b0;
			wc_idle <= (wc_idle == 5'd31) ? wc_idle : wc_idle + 5'd1;
			if (fb_we && fb_ready) begin
				wc_idle <= 5'd0;
				if (wr_same) begin
					wc_data[16 * fb_x[1:0] +: 16] <= fb_data;
					wc_be  [2 * fb_x[1:0] +: 2]   <= 2'b11;
				end else begin
					if (wc_valid) begin           // pend is free (fb_ready)
						pend_valid <= 1'b1;
						pend_addr  <= wc_addr;
						pend_data  <= wc_data;
						pend_be    <= wc_be;
					end
					wc_valid <= 1'b1;
					wc_addr  <= wr_pa[27:3];
					wc_data  <= {4{fb_data}};
					wc_be    <= 8'h03 << (2 * fb_x[1:0]);
				end
			end else if (wc_flush) begin
				pend_valid <= 1'b1;
				pend_addr  <= wc_addr;
				pend_data  <= wc_data;
				pend_be    <= wc_be;
				wc_valid   <= 1'b0;
			end
		end
	end

	// ------------------------------------------------- line reader/clearer
	// Per line: 80 reads of the display bank into the line buffer, then 80
	// zero writes to the same words.
	typedef enum logic [1:0] {R_IDLE, R_READ, R_CLEAR} rstate_t;
	rstate_t rstate;
	logic [6:0]  r_word;                    // 0..79
	logic [7:0]  r_line;
	logic        lb_bank;                   // line buffer bank being filled
	logic        rd_issue;
	logic        clr_issue;
	logic        line_busy;

	wire [27:0] r_pa = pixaddr(disp_bank, r_line, {r_word, 2'b00});

	// --------------------------------------------------------- DDRAM phy
	// Line reads and clears are 80-beat bursts, sprite words single beats.
	// Read burst as sys/ddr_svc.sv does it (the framework's own, on
	// hardware): RD for one cycle with BURSTCNT, then a data beat on every
	// cycle with DOUT_READY and !BUSY. Write burst per Avalon-MM: WE held
	// with the first address and BURSTCNT, one beat transferred on every
	// cycle with !BUSY, DIN/BE advanced per beat -- NOT yet confirmed on
	// hardware (ddr_svc reads only); the first board test of this module
	// is the test of that. Single-beat writes are the shape Psikyo's
	// ddram_phy verified.
	typedef enum logic [1:0] {D_IDLE, D_RD, D_WR} dstate_t;
	dstate_t dstate;
	logic       issued;
	logic [1:0] owner;                      // 1 read, 2 clear, 3 sprite
	logic [6:0] beat;                       // beats done in the current burst
	logic [7:0] nbeats;

	assign DDRAM_BURSTCNT = nbeats;
	assign DDRAM_RD = (dstate == D_RD) && !issued && !DDRAM_BUSY;
	assign DDRAM_WE = (dstate == D_WR) && !issued;

	wire want_rd  = (rstate == R_READ);
	wire want_clr = (rstate == R_CLEAR);
	wire want_spr = pend_valid;
	assign rd_issue   = (dstate == D_IDLE) && want_rd;
	assign clr_issue  = (dstate == D_IDLE) && !want_rd && want_clr;
	assign pend_issue = (dstate == D_IDLE) && !want_rd && !want_clr && want_spr;

	// A read beat is DOUT_READY, BUSY or not: readdatavalid is independent
	// of waitrequest in Avalon-MM, and a bridge that raised BUSY on the last
	// beat of a burst would otherwise lose it (the bench's model does exactly
	// that, and this phy hung at beat 79 while gated on !BUSY).
	wire rd_beat   = (dstate == D_RD) && issued && DDRAM_DOUT_READY;
	wire wr_beat   = (dstate == D_WR) && !issued && !DDRAM_BUSY;
	wire last_beat = ({1'b0, beat} == nbeats - 8'd1);

	always_ff @(posedge clk) begin
		if (reset) begin
			dstate <= D_IDLE;
			issued <= 1'b0;
			beat   <= 7'd0;
			nbeats <= 8'd1;
		end else begin
			case (dstate)
				D_IDLE: begin
					issued <= 1'b0;
					beat   <= 7'd0;
					if (rd_issue) begin
						DDRAM_ADDR <= {4'b0011, r_pa[27:3]};
						nbeats     <= 8'd80;
						owner      <= 2'd1;
						dstate     <= D_RD;
					end else if (clr_issue) begin
						DDRAM_ADDR <= {4'b0011, r_pa[27:3]};
						DDRAM_DIN  <= 64'd0;
						DDRAM_BE   <= 8'hFF;
						nbeats     <= 8'd80;
						owner      <= 2'd2;
						dstate     <= D_WR;
					end else if (pend_issue) begin
						DDRAM_ADDR <= {4'b0011, pend_addr};
						DDRAM_DIN  <= pend_data;
						DDRAM_BE   <= pend_be;
						nbeats     <= 8'd1;
						owner      <= 2'd3;
						dstate     <= D_WR;
					end
				end
				D_RD: begin
					if (!issued && !DDRAM_BUSY) issued <= 1'b1;   // RD pulsed this cycle
					if (rd_beat) begin
						beat <= beat + 7'd1;
						if (last_beat) dstate <= D_IDLE;
					end
				end
				D_WR: begin
					if (wr_beat) begin
						beat <= beat + 7'd1;
						if (last_beat) issued <= 1'b1;             // WE drops next cycle
					end
					if (issued && !DDRAM_BUSY) dstate <= D_IDLE;
				end
				default: dstate <= D_IDLE;
			endcase
		end
	end

	wire rd_done  = rd_beat;                                  // one word of the line
	wire clr_done = wr_beat && (owner == 2'd2);

	// line buffer write: word r_word of the line = pixels 4*r_word .. +3
	logic        lb_we;
	logic [6:0]  lb_word;
	logic [63:0] lb_data;

	always_ff @(posedge clk) begin
		if (reset) begin
			rstate        <= R_IDLE;
			lb_bank       <= 1'b0;
			line_busy     <= 1'b0;
			rd_overrun    <= 1'b0;
			rd_overrun_ev <= 1'b0;
			lb_we         <= 1'b0;
		end else begin
			rd_overrun_ev <= 1'b0;
			lb_we         <= 1'b0;
			if (line_start) begin
				rd_overrun_ev <= line_busy;
				rd_overrun    <= rd_overrun | line_busy;
				lb_bank       <= ~lb_bank;
				r_line        <= vcnt_next2[7:0];
				r_word        <= 7'd0;
				line_busy     <= fetch_line_active && (vcnt_next2 < 12'd224);
				rstate        <= (fetch_line_active && (vcnt_next2 < 12'd224)) ? R_READ : R_IDLE;
			end else begin
				case (rstate)
					R_IDLE: ;
					R_READ: begin
						if (rd_done) begin
							lb_we   <= 1'b1;
							lb_word <= r_word;
							lb_data <= DDRAM_DOUT;
							if (r_word == 7'd79) begin
								r_word <= 7'd0;
								rstate <= R_CLEAR;
							end else begin
								r_word <= r_word + 7'd1;
							end
						end
					end
					R_CLEAR: begin
						if (clr_done) begin
							if (r_word == 7'd79) begin
								line_busy <= 1'b0;
								rstate    <= R_IDLE;
							end else begin
								r_word <= r_word + 7'd1;
							end
						end
					end
					default: rstate <= R_IDLE;
				endcase
			end
		end
	end

	// --------------------------------------------------------- line buffer
	// 2 banks x 128 words x 64 bits, read as 16-bit pixels: word hcnt[8:2],
	// lane hcnt[1:0]
	logic [63:0] lb_q;
	dpram #(.ADDR_WIDTH(8), .DATA_WIDTH(64)) u_lb (
		.clk(clk),
		.a_addr({lb_bank, lb_word}), .a_wel(lb_we), .a_weh(lb_we), .a_wdata(lb_data), .a_rdata(),
		.b_addr({~lb_bank, hcnt[8:2]}), .b_re(1'b1), .b_rdata(lb_q)
	);
	// hcnt[1:0] one cycle late to match the read
	logic [1:0] lane;
	always_ff @(posedge clk) lane <= hcnt[1:0];
	assign pix = lb_q[16 * lane +: 16];

	// ---------------------------------------------------------- statistics
	logic [15:0] stall_cnt;
	always_ff @(posedge clk) begin
		if (reset) begin
			stall_cnt       <= 16'd0;
			wr_stall_cycles <= 16'd0;
		end else if (frame_start) begin
			wr_stall_cycles <= stall_cnt;
			stall_cnt       <= 16'd0;
		end else if (fb_we && !fb_ready && stall_cnt != 16'hFFFF) begin
			stall_cnt <= stall_cnt + 16'd1;
		end
	end

endmodule
