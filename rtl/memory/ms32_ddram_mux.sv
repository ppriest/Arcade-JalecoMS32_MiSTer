// SPDX-License-Identifier: GPL-3.0-or-later
//
// The one DDRAM port, shared by the core (ms32_video: the sprite frame buffer
// and the object RAM copy, burst reads and writes) and screen_rotate_two
// (the HDMI rotation/flip framebuffer, one single-beat write per pixel).
//
// screen_rotate_two ignores DDRAM_BUSY: its write is a one-clock pulse, taken
// or lost. So its writes go into a FIFO here, and the FIFO head goes out
// whenever the core is between transactions and not starting one. The core's
// transactions are never interrupted: a read is granted from its RD to its
// last DOUT_READY beat, a write from its first WE to its last accepted beat
// (BURSTCNT beats in both cases). Once the FIFO is half full the core sees
// BUSY between transactions, so it cannot start another until the FIFO has
// drained; its line reads have a line of lead (ms32_sprite_fb) and absorb
// that. fifo_overflow is sticky if a pixel was ever lost anyway.
//
// c_busy depends only on this module's state and DDRAM_BUSY, never on the
// core's RD/WE: the core's RD is itself gated by c_busy.
//
// Everything is on one clock: CLK_VIDEO is clk_sys in this core.
module ms32_ddram_mux #(
	parameter int FIFO_LOG2 = 8
) (
	input  logic        clk,
	input  logic        reset,

	// the core
	output logic        c_busy,
	input  logic [7:0]  c_burstcnt,
	input  logic [28:0] c_addr,
	output logic [63:0] c_dout,
	output logic        c_dout_ready,
	input  logic        c_rd,
	input  logic [63:0] c_din,
	input  logic [7:0]  c_be,
	input  logic        c_we,

	// screen_rotate_two: single-beat writes of {data, data} with BE 0F or F0
	input  logic [28:0] r_addr,
	input  logic [63:0] r_din,
	input  logic [7:0]  r_be,
	input  logic        r_we,

	// the framework's port
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic        DDRAM_WE,

	output logic        fifo_overflow
);

	// ------------------------------------------------------------ rotator FIFO
	localparam int W = 29 + 32 + 1;             // addr, one copy of the data, upper-half select
	logic [W-1:0] fifo [0:(1 << FIFO_LOG2) - 1];
	logic [FIFO_LOG2:0] wp, rp;
	wire  [FIFO_LOG2:0] fill = wp - rp;         // entries not yet loaded into head
	wire                full = fill[FIFO_LOG2];
	wire                half = fill[FIFO_LOG2-1] | full;
	logic [W-1:0] head;
	logic         head_valid;
	logic         pop;

	// head is a registered read of fifo[rp], enabled only when it loads; an
	// entry is read no earlier than the clock after it was written
	wire load = (!head_valid || pop) && (fill != 0);
	always_ff @(posedge clk) begin
		if (r_we && !full) fifo[wp[FIFO_LOG2-1:0]] <= {r_addr, r_din[31:0], r_be[4]};
		if (load) head <= fifo[rp[FIFO_LOG2-1:0]];
	end
	always_ff @(posedge clk) begin
		if (reset) begin
			wp <= '0; rp <= '0; head_valid <= 1'b0; fifo_overflow <= 1'b0;
		end else begin
			if (r_we && !full) wp <= wp + 1'b1;
			if (r_we && full)  fifo_overflow <= 1'b1;
			if (load)          rp <= rp + 1'b1;
			if (load)          head_valid <= 1'b1;
			else if (pop)      head_valid <= 1'b0;
		end
	end

	// ------------------------------------------------------------ arbiter
	typedef enum logic [1:0] {M_IDLE, M_CRD, M_CWR, M_ROT} mst_t;
	mst_t st;
	logic [7:0] left;

	wire core_can = (st == M_IDLE) && !half;                      // the core may start now
	wire core_go  = core_can && (c_rd || c_we);
	wire rot_go   = (st == M_IDLE) && !core_go && head_valid;
	wire to_core  = core_go || st == M_CRD || st == M_CWR;
	wire to_rot   = rot_go || st == M_ROT;

	assign DDRAM_BURSTCNT = to_rot ? 8'd1 : c_burstcnt;
	assign DDRAM_ADDR     = to_rot ? head[W-1 -: 29] : c_addr;
	assign DDRAM_DIN      = to_rot ? {2{head[32:1]}} : c_din;
	assign DDRAM_BE       = to_rot ? (head[0] ? 8'hF0 : 8'h0F) : c_be;
	assign DDRAM_WE       = to_rot | (to_core & c_we);
	assign DDRAM_RD       = to_core & c_rd;
	assign c_busy         = (st == M_CRD || st == M_CWR || core_can) ? DDRAM_BUSY : 1'b1;
	assign c_dout         = DDRAM_DOUT;
	assign c_dout_ready   = (st == M_CRD) && DDRAM_DOUT_READY;

	assign pop = to_rot && !DDRAM_BUSY;

	always_ff @(posedge clk) begin
		if (reset) begin
			st <= M_IDLE;
		end else case (st)
			M_IDLE: begin
				if (core_go && c_rd && !DDRAM_BUSY) begin
					st <= M_CRD; left <= c_burstcnt;
				end else if (core_go && c_we && !DDRAM_BUSY && c_burstcnt != 8'd1) begin
					st <= M_CWR; left <= c_burstcnt - 8'd1;
				end else if (rot_go && DDRAM_BUSY) begin
					st <= M_ROT;
				end
			end
			M_CRD: if (DDRAM_DOUT_READY) begin
				left <= left - 8'd1;
				if (left == 8'd1) st <= M_IDLE;
			end
			M_CWR: if (c_we && !DDRAM_BUSY) begin
				left <= left - 8'd1;
				if (left == 8'd1) st <= M_IDLE;
			end
			M_ROT: if (!DDRAM_BUSY) st <= M_IDLE;
			default: st <= M_IDLE;
		endcase
	end

endmodule
