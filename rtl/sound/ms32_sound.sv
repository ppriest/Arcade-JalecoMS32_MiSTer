// SPDX-License-Identifier: GPL-3.0-or-later
//
// The MS32 sound board's CPU side, on clk_sys: the Z80 (T80se) with its RAM,
// banked program ROM and the two latches, and the YMF271's bus face
// (ms32_ymf271_timers) until the synthesis half is vendored.
//
// ms32.cpp (base_sound_map, ms32_snd_bank_w, latch_r, to_main_w):
//   0000-3EFF  program ROM, fixed: audiocpu region 0x00000-0x03EFF
//   3F00-3F0F  YMF271
//   3F10       read: the V70's command, inverted; write: to_main
//   3F20       second latch, not connected
//   3F40, 3F70 writes, not connected
//   3F80       bank select: low nibble the 8000 window, high nibble C000
//   4000-7FFF  RAM, 16 KB
//   8000-BFFF  ROM, 0x4000 + 0x4000 x bank
//   C000-FFFF  ROM, 0x4000 + 0x4000 x bank
//   At reset the two banks are 0 and 1 (machine_reset). Unmapped reads are 0.
//
// The command latch is MAME's generic_latch_8 with its data_pending on NMI:
// a V70 write sets pending, a Z80 read of 3F10 clears it, and the T80 takes
// NMI on pending's rising edge. The V70-side register (to_main, the result
// read and its interrupt, sysctrl's sound ack) lives in ms32_cpu_sys; this
// module reports each Z80 write to 3F10 and receives each command, both
// through ms32_cdc there.
//
// sysctrl 0xFCE00038 bit 0 pulses the Z80's reset (sound_reset_line_w, a
// zero-length pulse in MAME): the CPU restarts at 0, the banks and the latch
// keep their state. The pulse is stretched to RESET_HOLD clocks here so the
// T80 sees it across clock enables.
//
// Bus timing, WAIT_n and the ROM handshake: as the Fuuki core's fg3_sound.sv.
module ms32_sound #(
	parameter int CEN_DIV    = 12,         // clk_sys 96 MHz / 12 = 8 MHz
	parameter int TICK_INC   = 441,        // YMF271 sample rate from clk_sys
	parameter int TICK_MOD   = 960_000,
	parameter int RESET_HOLD = 1024
) (
	input  logic        clk,
	input  logic        reset,

	input  logic        snd_reset,      // one clock: sysctrl 0x38 written with bit 0 set
	input  logic        cmd_we,         // one clock: the V70 wrote the command latch
	input  logic [7:0]  cmd_data,
	output logic        to_main_we,     // one clock: the Z80 wrote 3F10
	output logic [7:0]  to_main_data,

	// audiocpu ROM, 256 KB, byte req/valid: req pulses once per access
	output logic        rom_req,
	output logic [17:0] rom_addr,
	input  logic        rom_valid,
	input  logic [7:0]  rom_data,

	// the YMF271 bus, for the synthesis half: one clock per write
	output logic        ymf_wr,
	output logic [3:0]  ymf_addr,
	output logic [7:0]  ymf_wdata
);

	// ---------------------------------------------------------------- clock enable, reset
	// 8 MHz on average. A real Z80 never waits for this board's memory; the
	// T80 does, a T-state or two per SDRAM fetch, which ran the ROM test at
	// boot 25% slow against MAME in sim/sound_tb. Every clock enable spent
	// waiting is owed and repaid by an extra enable at the half period, so
	// the Z80's time, which the V70 sees through the latch, stays at 8 MHz.
	logic [3:0] cen_cnt;
	logic       cen, wait_n, rd_n;
	logic [7:0] owed;
	wire        lost  = cen && !wait_n && !rd_n;     // a read held in T2
	wire        extra = cen_cnt == 4'((CEN_DIV >> 1) - 1) && owed != 8'd0;
	always_ff @(posedge clk) begin
		if (reset || cen_cnt == 4'(CEN_DIV - 1)) cen_cnt <= 4'd0;
		else cen_cnt <= cen_cnt + 4'd1;
		cen <= (cen_cnt == 4'(CEN_DIV - 1)) || extra;
		if (reset) owed <= 8'd0;
		else if (lost && !extra && owed != 8'hFF) owed <= owed + 8'd1;
		else if (extra && !lost) owed <= owed - 8'd1;
	end

	logic [10:0] zrst_cnt;
	always_ff @(posedge clk) begin
		if (reset || snd_reset) zrst_cnt <= 11'(RESET_HOLD);
		else if (zrst_cnt != 11'd0) zrst_cnt <= zrst_cnt - 11'd1;
	end
	wire zreset = reset || zrst_cnt != 11'd0;

	// ---------------------------------------------------------------- Z80
	logic        m1_n, mreq_n, iorq_n, wr_n, rfsh_n, halt_n, busak_n;
	logic [15:0] a;
	logic [7:0]  di, d_out;
	logic        pending;

	T80se #(
		.Mode(0), .T2Write(0), .IOWait(1)
	) u_cpu (
		.RESET_n(~zreset), .CLK_n(clk), .CLKEN(cen), .WAIT_n(wait_n),
		.INT_n(1'b1), .NMI_n(~pending), .BUSRQ_n(1'b1),
		.M1_n(m1_n), .MREQ_n(mreq_n), .IORQ_n(iorq_n),
		.RD_n(rd_n), .WR_n(wr_n), .RFSH_n(rfsh_n), .HALT_n(halt_n), .BUSAK_n(busak_n),
		.A(a), .DI(di), .DO(d_out)
	);

	// ---------------------------------------------------------------- decode
	wire is_fixed = a < 16'h3F00;
	wire is_ymf   = a[15:4] == 12'h3F0;
	wire is_latch = a == 16'h3F10;
	wire is_ram   = a[15:14] == 2'b01;
	wire is_win0  = a[15:14] == 2'b10;
	wire is_win1  = a[15:14] == 2'b11;
	wire is_rom   = is_fixed || is_win0 || is_win1;

	logic [3:0] bank0, bank1;
	wire  [4:0] page = is_win0 ? 5'(bank0) + 5'd1 : is_win1 ? 5'(bank1) + 5'd1 : 5'd0;
	assign rom_addr = 18'({page, a[13:0]});

	wire mem_rd = !mreq_n && !rd_n;
	wire mem_wr = !mreq_n && !wr_n;
	wire io_rd  = !iorq_n && !rd_n;

	// A read's side effect at the start of its window; a write takes the
	// address and data from the window's last clock, as the chip's /WR edge.
	logic        mem_rd_d, mem_wr_d;
	logic [15:0] wa;
	logic [7:0]  wd;
	always_ff @(posedge clk) begin
		mem_rd_d <= mem_rd;
		mem_wr_d <= mem_wr;
		if (mem_wr) begin wa <= a; wd <= d_out; end
	end
	wire rd_start = mem_rd && !mem_rd_d;
	wire wr_end   = mem_wr_d && !mem_wr;

	// ---------------------------------------------------------------- RAM, 16 KB
	logic [7:0] ram [0:16383];
	logic [7:0] ram_q;
	always_ff @(posedge clk) begin
		if (wr_end && wa[15:14] == 2'b01) ram[wa[13:0]] <= wd;
		ram_q <= ram[a[13:0]];
	end

	// ---------------------------------------------------------------- latches, bank
	logic [7:0] cmd;
	always_ff @(posedge clk) begin
		if (reset) begin
			cmd <= 8'd0; pending <= 1'b0; bank0 <= 4'd0; bank1 <= 4'd1;
		end else begin
			if (rd_start && is_latch) pending <= 1'b0;
			if (cmd_we) begin cmd <= cmd_data; pending <= 1'b1; end
			if (wr_end && wa == 16'h3F80) begin bank0 <= wd[3:0]; bank1 <= wd[7:4]; end
		end
	end
	assign to_main_we   = wr_end && wa == 16'h3F10;
	assign to_main_data = wd;

	// ---------------------------------------------------------------- YMF271
	logic [7:0] ymf_q;
	assign ymf_wr    = wr_end && wa[15:4] == 12'h3F0;
	assign ymf_addr  = wa[3:0];
	assign ymf_wdata = wd;
	ms32_ymf271_timers #(.TICK_INC(TICK_INC), .TICK_MOD(TICK_MOD)) u_ymf (
		.clk(clk), .reset(reset),
		.wr(ymf_wr), .wr_addr(wa[3:0]), .din(wd), .rd_addr(a[3:0]), .dout(ymf_q)
	);

	// ---------------------------------------------------------------- read mux, WAIT_n, ROM
	logic       rom_done, rom_pending;
	logic [7:0] rom_hold;
	wire        is_rom_read = mem_rd && is_rom;

	always_comb begin
		if (mem_rd) begin
			if      (is_rom)   di = rom_hold;
			else if (is_ram)   di = ram_q;
			else if (is_ymf)   di = ymf_q;
			else if (is_latch) di = ~cmd;
			else               di = 8'h00;
		end else if (io_rd) di = 8'hFF;
		else                di = 8'hFF;
	end

	// RAM and I/O: one fixed wait cycle for the registered RAM read
	logic access_started;
	wire  access_nonrom = (!mreq_n || !iorq_n) && (!rd_n || !wr_n) && !is_rom_read;
	always_ff @(posedge clk) access_started <= zreset ? 1'b0 : access_nonrom;

	// ROM: one request per M-cycle, valid stretched to the end of the window
	always_ff @(posedge clk) begin
		if (zreset) rom_pending <= 1'b0;
		else if (is_rom_read && !rom_pending && !rom_done) rom_pending <= 1'b1;
		else if (rom_valid) rom_pending <= 1'b0;
	end
	assign rom_req = is_rom_read && !rom_pending && !rom_done && !zreset;

	always_ff @(posedge clk) begin
		if (zreset) begin
			rom_done <= 1'b0; rom_hold <= 8'd0;
		end else if (rom_valid) begin
			rom_done <= 1'b1; rom_hold <= rom_data;
		end else if (!is_rom_read) begin
			rom_done <= 1'b0;
		end
	end

	assign wait_n = is_rom_read   ? rom_done
	              : access_nonrom ? access_started
	              : 1'b1;

endmodule
