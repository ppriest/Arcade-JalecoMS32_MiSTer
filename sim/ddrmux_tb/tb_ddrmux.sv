// SPDX-License-Identifier: GPL-3.0-or-later
//
//  ms32_ddram_mux with all three clients against a DDR3 model:
//    core     80-beat read and write bursts, RD offered only when !c_busy
//             (as ms32_sprite_fb does), every read beat checked
//    g        single-beat reads, as many in flight as the tags allow,
//             every answer checked, in order
//    rotator  single-beat writes on random clocks
//  The model takes a command when !BUSY (busy on a random share of clocks),
//  answers reads in order LAT clocks after, one beat a clock, with a pattern
//  of the word address, so any beat that goes to the wrong client, arrives
//  out of order or twice fails the check.
//
//      python scripts/run_verilator.py ddrmux_tb +LAT=60 +BUSY=4 +N=200000
`timescale 1ns/1ps

module tb_ddrmux;

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;

integer LAT, BUSY, N, NOG;
function automatic [63:0] pat(input [28:0] a);
	pat = {3'd0, a, ~a[28:0], 6'h2A};
endfunction

// --------------------------------------------------------------- the DUT
wire        c_busy, c_dout_ready, g_ack, g_dout_ready, fifo_overflow;
wire [63:0] c_dout;
reg  [7:0]  c_burstcnt = 8'd80;
reg  [28:0] c_addr = 0;
reg         c_we = 0;
wire        c_rd;
reg  [63:0] c_din = 0;
reg  [28:0] r_addr = 0;
reg         r_we = 0;
reg         g_rd = 0;
reg  [28:0] g_addr = 0;

wire        DDRAM_BUSY;
wire [7:0]  DDRAM_BURSTCNT;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT;
wire        DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
wire [63:0] DDRAM_DIN;
wire [7:0]  DDRAM_BE;

ms32_ddram_mux u_mux (
	.clk(clk), .reset(reset),
	.c_busy(c_busy), .c_burstcnt(c_burstcnt), .c_addr(c_addr), .c_dout(c_dout), .c_dout_ready(c_dout_ready),
	.c_rd(c_rd), .c_din(c_din), .c_be(8'hFF), .c_we(c_we),
	.r_addr(r_addr), .r_din(64'h1234), .r_be(8'h0F), .r_we(r_we),
	.g_rd(g_rd), .g_addr(g_addr), .g_ack(g_ack), .g_dout_ready(g_dout_ready),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.fifo_overflow(fifo_overflow)
);

// ----------------------------------------------------------- DDR3 model
reg busy_r = 0;
assign DDRAM_BUSY = busy_r;
integer cyc = 0, errors = 0;
// read beats due: address and due clock, in order
reg  [28:0] q_addr [0:65535];
integer     q_due  [0:65535];
integer     q_wp = 0, q_rp = 0;
integer     wr_left = 0;          // beats still owed by a write burst
reg  [63:0] dout_r; reg dout_ready_r;
assign DDRAM_DOUT = dout_r; assign DDRAM_DOUT_READY = dout_ready_r;
integer k;
always @(posedge clk) begin
	cyc <= cyc + 1;
	busy_r <= !reset && (BUSY != 0) && (($urandom % BUSY) == 0);
	dout_ready_r <= 0;
	if (!reset && !busy_r) begin
		if (DDRAM_RD && DDRAM_WE) begin $display("ERROR %0d: RD and WE together", cyc); errors = errors + 1; end
		if (DDRAM_RD) begin
			if (wr_left != 0) begin $display("ERROR %0d: read inside a write burst", cyc); errors = errors + 1; end
			for (k = 0; k < DDRAM_BURSTCNT; k = k + 1) begin
				q_addr[(q_wp + k) % 65536] = DDRAM_ADDR + k;
				q_due[(q_wp + k) % 65536]  = cyc + LAT + k;
			end
			q_wp = q_wp + DDRAM_BURSTCNT;
		end
		if (DDRAM_WE) begin
			if (wr_left == 0) wr_left = DDRAM_BURSTCNT - 1;
			else wr_left = wr_left - 1;
		end
	end
	if (q_rp != q_wp && q_due[q_rp % 65536] <= cyc) begin
		dout_r <= pat(q_addr[q_rp % 65536]);
		dout_ready_r <= 1;
		q_rp = q_rp + 1;
	end
end

// -------------------------------------------------------------- the core
// ms32_sprite_fb's shape: RD for one clock when !busy, then its beats; a
// write burst holds WE and moves a beat on every !busy clock
integer c_state = 0, c_beat = 0, c_reads = 0, c_writes = 0;
reg [28:0] c_base;
always @(posedge clk) begin
	if (reset) begin c_state <= 0; c_we <= 0; end
	else case (c_state)
		0: if (($urandom % 50) == 0) begin
			c_base  <= 29'h0400000 + ($urandom % 65536) * 80;
			c_state <= (($urandom % 2) == 0) ? 1 : 3;
		end
		1: begin c_addr <= c_base; c_burstcnt <= 8'd80; c_state <= 11; end
		11: if (!c_busy) begin c_state <= 2; c_beat <= 0; end   // RD went out this clock
		2: begin
			if (c_dout_ready) begin
				if (c_dout !== pat(c_base + c_beat)) begin
					$display("ERROR %0d: core beat %0d got %h want %h", cyc, c_beat, c_dout, pat(c_base + c_beat)); errors = errors + 1;
				end
				c_beat <= c_beat + 1;
				if (c_beat == 79) begin c_state <= 0; c_reads <= c_reads + 1; end
			end
		end
		3: begin c_addr <= c_base; c_burstcnt <= 8'd80; c_we <= 1; c_beat <= 0; c_state <= 4; end
		4: if (!c_busy) begin
			c_beat <= c_beat + 1;
			if (c_beat == 79) begin c_we <= 0; c_state <= 0; c_writes <= c_writes + 1; end
		end
	endcase
end
// RD in the same clock as !BUSY, as ms32_sprite_fb drives it
assign c_rd = (c_state == 11) && !c_busy;
// a read beat for the core only while it is waiting for one
always @(posedge clk) if (!reset && c_dout_ready && c_state != 2) begin
	$display("ERROR %0d: core beat outside a read", cyc); errors = errors + 1;
end

// ---------------------------------------------------------------- g
reg [28:0] g_q [0:65535];
integer    g_wp = 0, g_rp = 0, g_done = 0;
always @(posedge clk) begin
	if (reset) g_rd <= 0;
	else begin
		if (g_rd && g_ack) begin g_q[g_wp % 65536] = g_addr; g_wp = g_wp + 1; end
		if (!g_rd || g_ack) begin
			// ms32_gfx5_ddr keeps at most 32 in flight
			g_rd   <= !NOG && (($urandom % 8) != 0) && (g_wp - g_rp + (g_rd && g_ack ? 1 : 0) < 32);
			g_addr <= 29'h01D0000 + ($urandom % 1000000);
		end
		if (g_dout_ready) begin
			if (g_rp == g_wp) begin $display("ERROR %0d: g beat with nothing asked", cyc); errors = errors + 1; end
			else if (c_dout !== pat(g_q[g_rp % 65536])) begin
				$display("ERROR %0d: g answer %0d got %h want %h", cyc, g_rp, c_dout, pat(g_q[g_rp % 65536])); errors = errors + 1;
			end
			g_rp = g_rp + 1; g_done = g_done + 1;
		end
	end
end

// ---------------------------------------------------------------- rotator
always @(posedge clk) begin
	r_we   <= !reset && (($urandom % 12) == 0);
	r_addr <= 29'h0200000 + ($urandom % 100000);
end

initial begin
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 60;
	if (!$value$plusargs("BUSY=%d", BUSY)) BUSY = 4;
	if (!$value$plusargs("N=%d", N))       N = 200000;
	if (!$value$plusargs("NOG=%d", NOG))   NOG = 0;      // the main MS32 core: g never asks
	repeat (10) @(posedge clk);
	reset = 0;
	repeat (N) @(posedge clk);
	$display("DDRMUX: %0d clocks, latency %0d, busy 1/%0d: core %0d reads %0d writes, g %0d answers, %0d still due, rotator overflow %0d, %0d errors",
	         N, LAT, BUSY, c_reads, c_writes, g_done, g_wp - g_rp, fifo_overflow, errors);
	$finish;
end

endmodule
