// SPDX-License-Identifier: GPL-3.0-or-later
//
// The MS32 main CPU and its memory map: the vendored V70 (s32_v60, IS_V70)
// behind ms32_v70_bus, ms32.cpp's ms32_map decoded with its mirrors, work
// RAM and NVRAM, the CPU port of every video RAM (the RAMs live in
// ms32_video as dual-clock blocks), the register block at 0xFCE00000,
// inputs and DIPs, the sound latch, the interrupt controller and the
// program ROM behind ms32_rom_cache.
//
// CLOCK DOMAINS. Everything here runs on clk_cpu except the ports marked
// "clk_sys", which cross through ms32_cdc.sv's three shapes and nothing
// else: register writes to the video path (mailbox), vblank and field
// (events), ROM granules (request), the capture loader's writes (request),
// the sound latches (mailboxes).
//
// DECODE. As sim/v70_boot_tb, which matched MAME over 5M accesses of the
// tetrisp boot: every RAM region mirrors address bits 29:26, so
// am = a & 0xC3FFFFFF picks the region and the bits each mirror leaves
// live index it. The 8- and 16-bit regions sit behind umask32: a read
// returns one byte or halfword zero-extended, a write takes lanes 0 or 0-1.
// I/O is decoded on the full address. Unmapped reads return 0, except where
// MacDonald's notes give a value (the unused FC600000 block, a read of the
// sound latch).
//
// BUS TIMING. ms32_v70_bus holds m_req until m_ack. Every access here is
// accepted in B_IDLE (RAM address and write enable driven that clock, the
// RAMs' read data registered on the same edge), answered from B_ACK one
// clock later with one clock of m_ack, and B_DRAIN lets m_req fall. ROM
// reads wait in B_ROM for the cache.
//
// HARDWARE NOTES. Charles MacDonald's measurements of a Desert War board head
// MAME's ms32.cpp; docs/HARDWARE_NOTES.md checks this module against each
// (memory map, mirroring, sound latches, I/O ports, unused-space reads).
//
// CAPTURE PLAYBACK. While the core is held in reset (cpu_run low) the bus
// belongs to the capture loader, whose writes arrive from clk_sys at real
// CPU addresses: playback exercises the same decode the game does.
module ms32_cpu_sys #(
	// ms32.cpp sound_command_w spins the V70 for 40 us after a latch write "to
	// give the Z80 time to respond"; 800 clk_cpu clocks at 20 MHz
	parameter int SND_SPIN = 800
) (
	input  logic        clk_cpu,
	input  logic        clk_sys,
	input  logic        rst_sys,          // clk_sys: whole block (not held by a capture load)
	input  logic        cpu_run_sys,      // clk_sys: 0 holds the V70 in reset
	input  logic        pause_sys,        // clk_sys: 1 suspends the V70 (level)
	input  logic        invert_lines,     // static, from the mod byte

	// clk_sys: inputs, active low as the board reads them
	input  logic [31:0] inputs,
	input  logic [31:0] dsw,
	input  logic        mahjong,          // static: the INPUTS low byte is the mahjong key matrix
	input  logic [29:0] mj_keys,          // rows KEY0-KEY4, 6 bits each, active low

	// clk_sys: register writes to ms32_video (byte offset in 0xFCE00000, low halfword)
	output logic        vreg_we,
	output logic [11:0] vreg_off,
	output logic [15:0] vreg_data,

	// clk_sys: CRTC events
	input  logic        vblank_ev,
	input  logic        field_ev,

	// clk_sys: the sound board (ms32_sound). The V70's latch writes out, the
	// Z80's writes to to_main in.
	output logic        snd_cmd_we,
	output logic [7:0]  snd_cmd_data,
	input  logic        snd_tomain_we,
	input  logic [7:0]  snd_tomain_data,

	// clk_sys: object RAM. Writes are posted into a queue (ms32_cdc_fifo) that
	// ms32_objram pops; reads are requests answered by it, issued once every
	// write before them has left the queue.
	output logic        wq_valid,         // the queue's head is on wq_data
	output logic [32:0] wq_data,          // {lanes[1:0], u16 index[14:0], data[15:0]}
	input  logic        wq_pop,
	output logic [5:0]  wq_level,         // entries ms32_objram can see
	output logic        obj_req,          // one clock; obj_addr holds until obj_valid
	output logic [14:0] obj_addr,
	input  logic        obj_valid,
	input  logic [15:0] obj_rdata,

	// clk_sys: program ROM granules, ROM-local granule index (x8 bytes)
	output logic        rom_req,
	output logic [17:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

	// clk_sys: NVRAM read-back for the HPS, and one pulse per CPU write to it
	input  logic [12:0] nv_addr,
	output logic [7:0]  nv_rdata,
	output logic        nv_written,

	// clk_sys: capture loader, one write per request
	input  logic        ld_req,           // held until ld_ack
	input  logic [31:0] ld_addr,
	input  logic [3:0]  ld_be,
	input  logic [31:0] ld_data,
	output logic        ld_ack,

	// clk_cpu: CPU ports of the video RAMs (u16 index, u8 for priority)
	output logic [12:0] txram_addr,  output logic txram_wel,  output logic txram_weh,  input logic [15:0] txram_rdata,
	output logic [12:0] bgram_addr,  output logic bgram_wel,  output logic bgram_weh,  input logic [15:0] bgram_rdata,
	output logic [14:0] rozram_addr, output logic rozram_wel, output logic rozram_weh, input logic [15:0] rozram_rdata,
	output logic [10:0] lineram_addr,output logic lineram_wel,output logic lineram_weh,input logic [15:0] lineram_rdata,
	// F1SUPERB: the road plane's map and line RAM (ms32_video sizes them to
	// what the game uses), and a count of any write that reaches past them
	output logic [9:0]  roadvram_addr, output logic roadvram_wel, output logic roadvram_weh, input logic [15:0] roadvram_rdata,
	output logic [10:0] roadline_addr, output logic roadline_wel, output logic roadline_weh, input logic [15:0] roadline_rdata,
	output logic [15:0] dbg_road_over,
	output logic [15:0] dbg_road_vw, dbg_road_lw,   // F1SUPERB: road map / line RAM writes
	output logic [19:0] dbg_fpu_max,                 // F1SUPERB: longest FPU routine, clk_cpu clocks
	output logic [15:0] dbg_fpu_runs,                // F1SUPERB: FPU routines started
	// F1SUPERB, per FPU, wrapping, clk_cpu: {starts1, starts0, irqs1, irqs0,
	// host writes1, host reads1, host writes0, host reads0}, 16 bits each
	output logic [127:0] dbg_fpu_cnt,
	// per field pass (field event to field event), clk_cpu: {field events,
	// writes to FEE10000, road line RAM writes in the last pass, highest and
	// lowest road line written in it}; 16/16/16/8/8 bits, counts wrapping
	output logic [63:0] dbg_pass,
	// F1SUPERB: V70 writes to FPU0's data RAM or registers that land while
	// FPU0 is running a routine (MAME: none), wrapping
	output logic [15:0] dbg_fpu_ovl,
	// the JTAG window on the two FPUs' data RAMs (clk_sys side, held static
	// while it is read): en, 0 = FPU0 / 1 = FPU1, word
	input  logic        dbg_fpu_ren,
	input  logic        dbg_fpu_sel,
	input  logic [11:0] dbg_fpu_raddr,
	output logic [15:0] dbg_fpu_rdata,
	// per-chain hashes of the V70's FPU0 traffic (JTAG window region 10):
	// word 2k = writes hash of chain k, 2k+1 = reads hash; chain count
	input  logic [9:0]  dbg_hash_raddr,
	output logic [15:0] dbg_hash_rdata,
	output logic [15:0] dbg_chains,
	output logic [31:0] dbg_pre,        // {count, hash} of FPU0 writes before chain 0
	// F1SUPERB: the analog controls, already in clk_cpu
	input  logic [7:0]  analog_wheel,
	input  logic [7:0]  analog_accel,
	input  logic [7:0]  analog_an2,
	input  logic [31:0] dsw2,
	output logic [15:0] palram_addr, output logic palram_wel, output logic palram_weh, input logic [15:0] palram_rdata,
	output logic [12:0] priram_addr, output logic priram_we,                            input logic [7:0]  priram_rdata,
	output logic [15:0] vram_wdata,

	// clk_cpu: debug
	output logic [31:0] dbg_pc,
	output logic [31:0] dbg_accesses,
	output logic [31:0] dbg_cache_hits, dbg_cache_misses
);

	// ------------------------------------------------------------- resets
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [2:0] rst_sy = 3'b111, run_sy = 3'b000;
	always_ff @(posedge clk_cpu) begin
		rst_sy <= {rst_sy[1:0], rst_sys};
		run_sy <= {run_sy[1:0], cpu_run_sys};
	end
	// PAUSE. The V70 is suspended at its bus, not by its clock enable: the bus
	// adapter samples the one-clock m_ack only while ce is high, so gating ce
	// could lose an acknowledge. Instead no new bus access or instruction
	// fetch is accepted while paused; a transfer already accepted completes,
	// and the core waits in its own handshake within an instruction or so.
	// Interrupts stay pending. Not while the capture loader owns the bus.
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [1:0] pause_sy = 2'b00;
	always_ff @(posedge clk_cpu) pause_sy <= {pause_sy[0], pause_sys};
	wire pause = pause_sy[1];

	wire rst      = rst_sy[2];
	wire rst_core = rst_sy[2] | ~run_sy[2];

	// ------------------------------------------------------------- CPU
	logic        c_req, c_we, c_ack;
	logic [31:0] c_addr, c_wdata, c_rdata;
	logic [1:0]  c_size;
	logic        cm_req, cm_we;
	logic [31:2] cm_addr;
	logic [31:0] cm_wdata;
	logic [3:0]  cm_be;
	logic        irq_n, irq_ack;
	logic [7:0]  irq_vector;
	logic        if_req, if_ack;
	logic [31:0] if_addr;
	logic [63:0] if_data;

	s32_v60 #(.START_PC(32'hFFFF_FFF0), .IS_V70(1'b1), .FAST_IFETCH(1'b1),
	          .IF_ROM0_MASK(32'hC3E0_0000), .IF_ROM0_MATCH(32'hC3E0_0000),
	          .IF_ROM1_MASK(32'hC3E0_0000), .IF_ROM1_MATCH(32'hC3E0_0000)) u_cpu (
		.clk(clk_cpu), .ce(1'b1), .rst(rst_core), .fast_ifetch(1'b1),
		.if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
		.bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
		.bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
		.irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(irq_ack), .nmi_n(1'b1)
	);
`ifdef VERILATOR
	assign dbg_pc = u_cpu.pc;   // a hierarchical reference: simulation only
`else
	assign dbg_pc = 32'd0;
`endif

	logic [31:0] m_rdata;
	logic        m_ack;
	ms32_v70_bus u_bus (
		.clk(clk_cpu), .ce(1'b1), .rst(rst_core),
		.c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
		.c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
		.m_req(cm_req), .m_we(cm_we), .m_addr(cm_addr), .m_wdata(cm_wdata),
		.m_be(cm_be), .m_rdata(m_rdata), .m_ack(m_ack & ~rst_core)
	);

	// ------------------------------------------------------------- loader master
	logic        lq_req, lq_valid;
	logic [67:0] lq_pay;
	ms32_cdc_req #(.AW(68), .DW(1)) u_ld_cdc (
		.clk_s(clk_sys), .rst_s(rst_sys),
		.s_req(ld_req), .s_addr({ld_addr, ld_be, ld_data}), .s_ack(ld_ack), .s_rdata(),
		.clk_d(clk_cpu), .rst_d(rst),
		.d_req(lq_req), .d_addr(lq_pay), .d_valid(lq_valid), .d_rdata(1'b0)
	);
	logic lm_pend;
	always_ff @(posedge clk_cpu) begin
		if (rst) lm_pend <= 1'b0;
		else if (lq_req) lm_pend <= 1'b1;
		else if (lq_valid) lm_pend <= 1'b0;
	end

	// the bus: the CPU's, or the loader's while the core is in reset
	wire        ld_owns = rst_core;
	wire        m_req   = ld_owns ? lm_pend : cm_req;
	wire        m_we    = ld_owns ? 1'b1    : cm_we;
	wire [31:2] m_addr  = ld_owns ? lq_pay[67:38] : cm_addr;
	wire [3:0]  m_be    = ld_owns ? lq_pay[35:32] : cm_be;
	wire [31:0] m_wdata = ld_owns ? lq_pay[31:0]  : cm_wdata;
	assign lq_valid = ld_owns && m_ack;

	// ------------------------------------------------------------- decode
	wire [31:0] a  = {m_addr, 2'b00};
	wire [31:0] am = a & 32'hC3FF_FFFF;
	wire is_rom     = (am[31:21] == 11'b1100_0011_111);          // c3e00000-c3ffffff
	wire is_wram    = (am[31:20] == 12'hc2e);                    // c2e00000, mirror 0x3c0e0000
	wire is_nvram   = (am[31:21] == 11'b1100_0000_000);          // c0000000
	wire is_priram  = (am[31:18] == 14'b1100_0001_0001_10);      // c1180000
	wire is_palram  = (am[31:21] == 11'b1100_0001_010);          // c1400000
	wire is_rozram  = (am[31:21] == 11'b1100_0010_000);          // c2000000
	wire is_lineram = (am[31:21] == 11'b1100_0010_001);          // c2200000
	wire is_objram  = (am[31:21] == 11'b1100_0010_100);          // c2800000
	wire is_txbg    = (am[31:21] == 11'b1100_0010_110);          // c2c00000
	// F-1 Super Battle's own devices (f1superb_map): the mask folds fd/fe to c1/c2
	wire is_roadv   = (am[31:21] == 11'b1100_0001_110);          // fdc00000
	wire is_roadl   = (am[31:21] == 11'b1100_0001_111);          // fde00000
	wire is_fpu0    = (am[31:16] == 16'hc110);                   // fd100000, 0x6000 window
	wire is_fpu1    = (am[31:16] == 16'hc114);                   // fd140000
	wire is_comms   = (am[31:16] == 16'hc10c) && !am[15:12];     // fd0c0000-fd0c0fff, 4 KB
	wire is_dsw2    = (am[31:16] == 16'hc10d);                   // fd0d0000
	wire is_analog  = (am[31:16] == 16'hc10e);                   // fd0e0000
	wire is_tx      = is_txbg && !a[15];
	wire is_bg      = is_txbg &&  a[15];
	wire is_regs    = (a[31:12] == 20'hfce00);
	wire is_sndcmd  = (a == 32'hfc80_0000);
	wire is_inputs  = (a == 32'hfcc0_0004);
	wire is_dsw     = (a == 32'hfcc0_0010);
	wire is_sndres  = (a == 32'hfd00_0000);
	wire is_mjsel   = (a == 32'hfd1c_0000);
	// MacDonald: FC600000-FC7FFFFF is unused and reads $FFFFFFFF; a read of the
	// sound latch at FC800000 returns $FFFF in D15-D0 (D31-D16 open bus, 0 here)
	wire is_unused_ff = (a[31:21] == 11'b1111_1100_011);
	// the register block's RAM-backed ranges read back; the rest is write-only
	wire regs_rd    = (a[11:0] >= 12'h200 && a[11:0] < 12'h280) || (a[11:0] >= 12'h600 && a[11:0] < 12'h660) ||
	                  (a[11:0] >= 12'ha00 && a[11:0] < 12'ha38);

	typedef enum logic [4:0] {
		R_NONE, R_ROM, R_WRAM, R_NVRAM, R_PRI, R_PAL, R_ROZ, R_LINE, R_OBJ, R_TX, R_BG, R_REGS, R_IN, R_DSW, R_SND,
		R_ROADV, R_ROADL, R_FPU, R_COMMS, R_DSW2, R_ANALOG,
		R_ALLF, R_CMDRD
	} region_t;
	region_t rsel;

	typedef enum logic [3:0] {B_IDLE, B_ACK, B_ROM, B_DRAIN, B_SPIN, B_OBJ, B_OBJW, B_OBJR, B_FPU} bst_t;
	logic [9:0] spin_cnt;
	bst_t bst;
	wire accept = (bst == B_IDLE) && m_req && !m_ack && (!pause || ld_owns);
	wire wr     = accept && m_we;

	// Simulation only: +WRAM_WAIT=n holds each work RAM access for n more
	// clocks, to measure what moving that RAM to SDRAM would cost the game
	// (ROADMAP, "Offload candidates").
`ifdef VERILATOR
	int unsigned sim_wram_wait = 0;
	initial void'($value$plusargs("WRAM_WAIT=%d", sim_wram_wait));
	wire [9:0] sim_wait = is_wram ? 10'(sim_wram_wait) : 10'd0;
`else
	wire [9:0] sim_wait = 10'd0;
`endif
	wire [1:0] lanes16 = m_be[1:0];

	// ------------------------------------------------------------- RAMs
	// work RAM: 0x20000 bytes, 32-bit
	logic [31:0] wram [0:32767];
	logic [31:0] wram_q;
	always_ff @(posedge clk_cpu) begin
		for (int i = 0; i < 4; i++) if (wr && is_wram && m_be[i]) wram[a[16:2]][8*i +: 8] <= m_wdata[8*i +: 8];
		wram_q <= wram[a[16:2]];
	end

	// NVRAM: 0x2000 bytes, 8-bit, battery-backed on the board. Port B is the
	// HPS's read-back when it saves the .mra's <nvram> file (clk_sys); the
	// file comes down through the loader port like a capture. Every CPU write
	// is an event in clk_sys, so the top level knows there is something to save.
	logic [7:0] nvram_q;
	wire        nv_we = wr && is_nvram && m_be[0];
	dpram_dc #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_nvram (
		.clk_a(clk_cpu), .a_addr(a[14:2]), .a_wel(nv_we), .a_weh(1'b0), .a_wdata(m_wdata[7:0]), .a_rdata(nvram_q),
		.clk_b(clk_sys), .b_addr(nv_addr), .b_re(1'b1), .b_rdata(nv_rdata)
	);
	ms32_cdc_event u_nv_ev (.clk_s(clk_cpu), .s_pulse(nv_we && !ld_owns), .clk_d(clk_sys), .d_pulse(nv_written));

	// register block readback: 0x400 dwords, 32-bit
	logic [31:0] regs [0:1023];
	logic [31:0] regs_q;
	always_ff @(posedge clk_cpu) begin
		for (int i = 0; i < 4; i++) if (wr && is_regs && m_be[i]) regs[a[11:2]][8*i +: 8] <= m_wdata[8*i +: 8];
		regs_q <= regs[a[11:2]];
	end

	// video RAMs, in ms32_video
	assign vram_wdata   = m_wdata[15:0];
	assign txram_addr   = a[14:2];  assign txram_wel   = wr && is_tx      && lanes16[0]; assign txram_weh   = wr && is_tx      && lanes16[1];
	assign bgram_addr   = a[14:2];  assign bgram_wel   = wr && is_bg      && lanes16[0]; assign bgram_weh   = wr && is_bg      && lanes16[1];
	assign rozram_addr  = a[16:2];  assign rozram_wel  = wr && is_rozram  && lanes16[0]; assign rozram_weh  = wr && is_rozram  && lanes16[1];
	assign lineram_addr = a[12:2];  assign lineram_wel = wr && is_lineram && lanes16[0]; assign lineram_weh = wr && is_lineram && lanes16[1];
	assign palram_addr  = a[17:2];  assign palram_wel  = wr && is_palram  && lanes16[0]; assign palram_weh  = wr && is_palram  && lanes16[1];
	assign priram_addr  = a[14:2];  assign priram_we   = wr && is_priram  && m_be[0];
	// The road RAMs hold what the game uses, not what MAME declares; a write
	// past the end wraps, and is counted so the probe can say it happened.
	assign roadvram_addr = a[11:2];  assign roadvram_wel = wr && is_roadv && lanes16[0]; assign roadvram_weh = wr && is_roadv && lanes16[1];
	assign roadline_addr = a[12:2];  assign roadline_wel = wr && is_roadl && lanes16[0]; assign roadline_weh = wr && is_roadl && lanes16[1];
	always_ff @(posedge clk_cpu) begin
		if (rst) begin dbg_road_vw <= 16'd0; dbg_road_lw <= 16'd0; end
		else begin
			if (wr && is_roadv && dbg_road_vw != 16'hffff) dbg_road_vw <= dbg_road_vw + 16'd1;
			if (wr && is_roadl && dbg_road_lw != 16'hffff) dbg_road_lw <= dbg_road_lw + 16'd1;
		end
		if (rst) dbg_road_over <= 16'd0;
		else if (wr && ((is_roadv && |a[16:12]) || (is_roadl && |a[16:13])) && dbg_road_over != 16'hffff)
			dbg_road_over <= dbg_road_over + 16'd1;
	end

	// ------------------------------------------------------------- inputs
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [31:0] in_s1, in_s2, dsw_s1, dsw_s2;
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [29:0] mj_s1, mj_s2;
	always_ff @(posedge clk_cpu) begin
		in_s1 <= inputs; in_s2 <= in_s1;
		dsw_s1 <= dsw;   dsw_s2 <= dsw_s1;
		mj_s1 <= mj_keys; mj_s2 <= mj_s1;
	end

	// ms32.cpp mahjong_ctrl_r: 0xFD1C0000 (write-only) selects key rows by
	// bits 0-4; the rows selected are ANDed, then bitswap<6>(v, 4,2,3,1,0,5)
	// puts the Start column in bit 0, and bits 7:6 read 1.
	logic [4:0] mj_sel;
	always_ff @(posedge clk_cpu) begin
		if (rst) mj_sel <= 5'd0;
		else if (wr && is_mjsel && m_be[0]) mj_sel <= m_wdata[4:0];
	end
	logic [5:0] mj_and;
	always_comb begin
		mj_and = 6'h3f;
		for (int i = 0; i < 5; i++) if (mj_sel[i]) mj_and = mj_and & mj_s2[6*i +: 6];
	end
	wire [7:0]  mj_byte   = {2'b11, mj_and[4], mj_and[2], mj_and[3], mj_and[1], mj_and[0], mj_and[5]};
	wire [31:0] in_read   = mahjong ? {in_s2[31:8], mj_byte} : in_s2;

	// ------------------------------------------------------------- sound latches
	// ms32.cpp: 0xFC800000 loads the Z80's command latch (in ms32_sound);
	// the Z80's write to 0x3F10 loads to_main and raises IRQ level 1;
	// 0xFD000000 returns to_main inverted and clears level 1; sysctrl's
	// sound ack (0xFCE0004C, sound_ack_w) sets to_main to 0xFF.
	ms32_cdc_mailbox #(.W(8)) u_snd_cmd (
		.clk_s(clk_cpu), .s_pulse(wr && is_sndcmd && m_be[0]), .s_data(m_wdata[7:0]),
		.clk_d(clk_sys), .d_pulse(snd_cmd_we), .d_data(snd_cmd_data)
	);
	logic       tomain_we;
	logic [7:0] tomain_data;
	ms32_cdc_mailbox #(.W(8)) u_snd_res (
		.clk_s(clk_sys), .s_pulse(snd_tomain_we), .s_data(snd_tomain_data),
		.clk_d(clk_cpu), .d_pulse(tomain_we), .d_data(tomain_data)
	);
	logic [7:0] to_main;
	always_ff @(posedge clk_cpu) begin
		if (rst) to_main <= 8'h00;
		else if (tomain_we) to_main <= tomain_data;
		else if (wr && is_regs && a[11:0] == 12'h04C) to_main <= 8'hFF;
	end
	wire snd_irq_clr = accept && !m_we && is_sndres;

	// ------------------------------------------------------------- ROM
	logic        d_req, d_ack;
	logic [31:0] d_rdata;
	logic        g_req, g_ack;
	logic [17:0] g_addr;
	logic [63:0] g_data;
	ms32_rom_cache u_cache (
		.clk(clk_cpu), .reset(rst),
		.if_req(if_req & ~pause), .if_addr(if_addr[20:0]), .if_ack(if_ack), .if_data(if_data),   // taken only from C_IDLE
		.d_req(d_req), .d_addr(a[20:0]), .d_ack(d_ack), .d_rdata(d_rdata),
		.g_req(g_req), .g_addr(g_addr), .g_ack(g_ack), .g_data(g_data),
		.hits(dbg_cache_hits), .misses(dbg_cache_misses)
	);
	ms32_cdc_req #(.AW(18), .DW(64)) u_rom_cdc (
		.clk_s(clk_cpu), .rst_s(rst),
		.s_req(g_req), .s_addr(g_addr), .s_ack(g_ack), .s_rdata(g_data),
		.clk_d(clk_sys), .rst_d(rst_sys),
		.d_req(rom_req), .d_addr(rom_addr), .d_valid(rom_valid), .d_rdata(rom_data)
	);

	// ------------------------------------------------------------- object RAM
	// In SDRAM behind ms32_objram. A write is acknowledged once it is in the
	// queue (B_OBJW only while the queue is full): waiting on SDRAM for each
	// one cost Gratia whole frames, up to 14,350 object RAM writes in one of
	// them (system_tb). A read waits in B_OBJR until every earlier write has
	// left the queue, then is a request the bus waits for in B_OBJ.
	logic wq_full, wq_empty;
	wire  wq_push = !wq_full && ((bst == B_IDLE && accept && is_objram && m_we) || bst == B_OBJW);
	ms32_cdc_fifo #(.W(33), .AW(5)) u_wq (
		.clk_s(clk_cpu), .rst_s(rst),
		.s_push(wq_push), .s_data({lanes16, a[16:2], m_wdata[15:0]}), .s_full(wq_full), .s_empty(wq_empty),
		.clk_d(clk_sys), .rst_d(rst_sys),
		.d_pop(wq_pop), .d_data(wq_data), .d_valid(wq_valid), .d_level(wq_level)
	);
	logic        o_req, o_ack;
	logic [15:0] o_rdata;
	ms32_cdc_req #(.AW(15), .DW(16)) u_obj_cdc (
		.clk_s(clk_cpu), .rst_s(rst),
		.s_req(o_req), .s_addr(a[16:2]), .s_ack(o_ack), .s_rdata(o_rdata),
		.clk_d(clk_sys), .rst_d(rst_sys),
		.d_req(obj_req), .d_addr(obj_addr), .d_valid(obj_valid), .d_rdata(obj_rdata)
	);

	// ------------------------------------------------------- F1SUPERB devices
	// The two maths coprocessors sit on this bus with a two-cycle window
	// (rtl/cpu/jalfpu), so a read or a write to them waits in B_FPU. The comms
	// RAM is the link board's, which is not emulated -- MAME keeps the RAM and
	// so does this, or the game's test mode reports FLAM ERROR.
	logic        fpu_req, fpu_we;
	logic [15:0] fpu_rdata0, fpu_rdata1, fpu_rdata;
	logic        fpu_valid0, fpu_valid1;
	wire         fpu_valid = (fpu_valid0 | fpu_valid1);
	wire         fpu_irq0, fpu_irq1;
	wire         fpu_busy0, fpu_busy1;
	logic [15:0] fpu_dbg0, fpu_dbg1;
`ifdef F1SUPERB
	jalfpu u_fpu0 (
		.clk(clk_cpu), .rst(rst),
		.h_req(fpu_req && is_fpu0), .h_we(fpu_we), .h_addr(a[14:0]), .h_wdata(m_wdata[15:0]),
		.h_rdata(fpu_rdata0), .h_valid(fpu_valid0), .irq(fpu_irq0), .busy(fpu_busy0),
		.dbg_stall(1'b0), .dbg_retire(), .dbg_ppc(), .dbg_op(), .dbg_s(),
		.dbg_c6(), .dbg_c7(), .dbg_sign(), .dbg_flags(), .dbg_sp(),
		.dbg_ren(dbg_fpu_ren && !dbg_fpu_sel), .dbg_raddr(dbg_fpu_raddr), .dbg_rdata(fpu_dbg0)
	);
	jalfpu u_fpu1 (
		.clk(clk_cpu), .rst(rst),
		.h_req(fpu_req && is_fpu1), .h_we(fpu_we), .h_addr(a[14:0]), .h_wdata(m_wdata[15:0]),
		.h_rdata(fpu_rdata1), .h_valid(fpu_valid1), .irq(fpu_irq1), .busy(fpu_busy1),
		.dbg_stall(1'b0), .dbg_retire(), .dbg_ppc(), .dbg_op(), .dbg_s(),
		.dbg_c6(), .dbg_c7(), .dbg_sign(), .dbg_flags(), .dbg_sp(),
		.dbg_ren(dbg_fpu_ren && dbg_fpu_sel), .dbg_raddr(dbg_fpu_raddr), .dbg_rdata(fpu_dbg1)
	);
	// By address, not by h_valid: h_valid is a one-clock pulse, and B_ACK
	// takes the data the clock after it, when a valid-selected mux had already
	// swung to FPU1 -- every V70 read of FPU0 returned FPU1's last answer. Each
	// FPU holds h_rdata until its next access, and the address holds for this one.
	assign fpu_rdata = is_fpu0 ? fpu_rdata0 : fpu_rdata1;
	assign dbg_fpu_rdata = dbg_fpu_sel ? fpu_dbg1 : fpu_dbg0;

	// Per FPU: routines started (busy rising), interrupts raised (irq rising),
	// and the V70's completed accesses to each window, reads and writes apart.
	// MAME, driving (frames 4001-4200): 4 starts per FPU every other frame.
	// They wrap rather than saturate: FPU0's reads pass 65,535 inside a
	// couple of minutes, and a rate needs two polls to difference.
	logic [15:0] c_st0, c_st1, c_irq0, c_irq1, c_rd0, c_wr0, c_rd1, c_wr1;
	logic        busy0_d, busy1_d, irq0_d, irq1_d;
	function automatic logic [15:0] inc(input logic [15:0] v, input logic e);
		inc = v + {15'd0, e};
	endfunction
	wire fpu_done = (bst == B_FPU) && fpu_valid;
	always_ff @(posedge clk_cpu) begin
		busy0_d <= fpu_busy0; busy1_d <= fpu_busy1; irq0_d <= fpu_irq0; irq1_d <= fpu_irq1;
		if (rst) begin
			c_st0 <= '0; c_st1 <= '0; c_irq0 <= '0; c_irq1 <= '0; c_rd0 <= '0; c_wr0 <= '0; c_rd1 <= '0; c_wr1 <= '0;
		end else begin
			c_st0  <= inc(c_st0,  fpu_busy0 && !busy0_d);
			c_st1  <= inc(c_st1,  fpu_busy1 && !busy1_d);
			c_irq0 <= inc(c_irq0, fpu_irq0 && !irq0_d);
			c_irq1 <= inc(c_irq1, fpu_irq1 && !irq1_d);
			c_rd0  <= inc(c_rd0,  fpu_done && is_fpu0 && !fpu_we);
			c_wr0  <= inc(c_wr0,  fpu_done && is_fpu0 &&  fpu_we);
			c_rd1  <= inc(c_rd1,  fpu_done && is_fpu1 && !fpu_we);
			c_wr1  <= inc(c_wr1,  fpu_done && is_fpu1 &&  fpu_we);
		end
	end
	assign dbg_fpu_cnt = {c_st1, c_st0, c_irq1, c_irq0, c_wr1, c_rd1, c_wr0, c_rd0};

	// Where the board first parts from MAME. FPU0 runs a chain of four
	// routines per field pass (338, 38B, 20D, 237), and a V70 write of 0x338
	// to its PC starts one. Per-chain hashes of the V70's FPU0 traffic (1b0bb80)
	// showed the writes equal to MAME's for 53 chains and the reads different
	// from chain 0: same inputs, other answers. So now:
	//   - the first 512 V70 reads of FPU0 from chain 0 on, {index, data} each
	//     (JTAG window region 10: word 2k = data, 2k+1 = dword index);
	//   - a hash and a count of every V70 write to FPU0 before chain 0 (the
	//     program and data upload), h' = rotl1(h) ^ data ^ (index << 3).
	// scripts/mame/fpureads.lua gives MAME's side.
	logic [15:0] chains, hpre, npre;
	logic [9:0]  rl_n;
	logic [31:0] rl_mem [0:511];
	wire [12:0] f0_x = a[14:2];
	wire        chain_start = fpu_done && is_fpu0 && fpu_we && (a[14:0] == 15'h24C0) && (m_wdata[9:0] == 10'h338);
	always_ff @(posedge clk_cpu) begin
		if (rst) begin
			chains <= '0; hpre <= '0; npre <= '0; rl_n <= '0;
		end else if (fpu_done && is_fpu0) begin
			if (chain_start) chains <= chains + 16'd1;
			if (fpu_we && chains == 16'd0 && !chain_start) begin
				hpre <= {hpre[14:0], hpre[15]} ^ m_wdata[15:0] ^ {f0_x, 3'b000};
				npre <= npre + 16'd1;
			end
			if (!fpu_we && chains != 16'd0 && !rl_n[9]) begin
				rl_mem[rl_n[8:0]] <= {3'd0, f0_x, fpu_rdata};
				rl_n <= rl_n + 10'd1;
			end
		end
	end
	logic [31:0] rl_q;
	always_ff @(posedge clk_cpu) rl_q <= rl_mem[dbg_hash_raddr[9:1]];
	assign dbg_hash_rdata = dbg_hash_raddr[0] ? rl_q[31:16] : rl_q[15:0];
	assign dbg_chains = chains;
	assign dbg_pre = {npre, hpre};
	// host data (below 0x2400) or register (0x2400-0x24ff) writes, not the
	// program RAM, while the routine runs
	wire fpu0_inwr = fpu_done && is_fpu0 && fpu_we && (a[14:0] < 15'h2500);
	always_ff @(posedge clk_cpu)
		if (rst) dbg_fpu_ovl <= '0;
		else if (fpu0_inwr && fpu_busy0) dbg_fpu_ovl <= dbg_fpu_ovl + 16'd1;

	// How long the FPUs hold the game up. One counter over "either is busy":
	// that is the window the V70 actually waits through, and against a frame
	// (333,333 clk_cpu clocks at 20 MHz) it is the only check on the rate
	// CE_DIV picks, the real chip's clock being unknown. 20 bits is 52 ms, far
	// past anything the game can wait for.
	wire         fpu_busy = fpu_busy0 | fpu_busy1;
	logic [19:0] fpu_run;
	logic        fpu_busy_d;
	always_ff @(posedge clk_cpu) begin
		fpu_busy_d <= fpu_busy;
		fpu_run <= fpu_busy ? (fpu_run == 20'hFFFFF ? fpu_run : fpu_run + 20'd1) : 20'd0;
		if (rst) begin
			dbg_fpu_max <= 20'd0; dbg_fpu_runs <= 16'd0;
		end else begin
			if (!fpu_busy && fpu_busy_d && fpu_run > dbg_fpu_max) dbg_fpu_max <= fpu_run;
			if (fpu_busy && !fpu_busy_d && dbg_fpu_runs != 16'hFFFF) dbg_fpu_runs <= dbg_fpu_runs + 16'd1;
		end
	end

	// 1,024 longs, FULL 32-bit. ms32.cpp maps this one as plain .ram() with no
	// umask32, unlike every other 16-bit region on this bus, so a 16-bit RAM
	// here drops the top half of every write. Same M10K either way: 32 Kbit.
	logic [31:0] comms [0:1023];
	logic [31:0] comms_q;
	always_ff @(posedge clk_cpu) begin
		for (int i = 0; i < 4; i++) if (wr && is_comms && m_be[i]) comms[a[11:2]][8*i +: 8] <= m_wdata[8*i +: 8];
		comms_q <= comms[a[11:2]];
	end
`else
	assign fpu_rdata  = 16'd0;
	assign fpu_valid0 = 1'b0;
	assign fpu_valid1 = 1'b0;
	assign fpu_irq0   = 1'b0;
	assign fpu_irq1   = 1'b0;
	assign fpu_busy0  = 1'b0;
	assign fpu_busy1  = 1'b0;
	always_comb begin dbg_fpu_max = 20'd0; dbg_fpu_runs = 16'd0; end
	assign dbg_fpu_cnt = '0;
	assign dbg_fpu_ovl = '0;
	assign dbg_hash_rdata = '0;
	assign dbg_chains = '0;
	assign dbg_pre = '0;
	assign dbg_fpu_rdata = 16'd0;
	wire [31:0] comms_q = 32'd0;
`endif

	// ------------------------------------------------------------- bus FSM
	always_ff @(posedge clk_cpu) begin
		m_ack <= 1'b0;
		if (rst) begin
			bst <= B_IDLE; d_req <= 1'b0; o_req <= 1'b0; fpu_req <= 1'b0; dbg_accesses <= 32'd0;
		end else case (bst)
			B_IDLE: if (accept) begin
				dbg_accesses <= dbg_accesses + 32'd1;
				rsel <= is_rom ? R_ROM : is_wram ? R_WRAM : is_nvram ? R_NVRAM : is_priram ? R_PRI :
				        is_palram ? R_PAL : is_rozram ? R_ROZ : is_lineram ? R_LINE : is_objram ? R_OBJ :
				        is_tx ? R_TX : is_bg ? R_BG : (is_regs && regs_rd) ? R_REGS :
				        is_inputs ? R_IN : is_dsw ? R_DSW : is_sndres ? R_SND :
				        is_roadv ? R_ROADV : is_roadl ? R_ROADL : (is_fpu0 || is_fpu1) ? R_FPU :
				        is_comms ? R_COMMS : is_dsw2 ? R_DSW2 : is_analog ? R_ANALOG :
				        is_unused_ff ? R_ALLF : is_sndcmd ? R_CMDRD : R_NONE;
				if (is_fpu0 || is_fpu1) begin fpu_req <= 1'b1; fpu_we <= m_we; bst <= B_FPU; end
				else if (is_rom && !m_we) begin d_req <= 1'b1; bst <= B_ROM; end
				else if (is_objram && m_we) bst <= wq_full ? B_OBJW : B_ACK;   // pushed now, or from B_OBJW
				else if (is_objram) bst <= B_OBJR;
				// A sound command holds the bus for SND_SPIN clocks before it is
				// acknowledged. Without it the games' command pairs (prefix, then
				// parameter) arrived 8 us apart and the Z80, which takes the latch
				// about 10 us after a write, lost the first of each pair.
				else if (is_sndcmd && m_we && !ld_owns) begin spin_cnt <= 10'(SND_SPIN); bst <= B_SPIN; end
				else if (sim_wait != 10'd0 && !ld_owns) begin spin_cnt <= sim_wait - 10'd1; bst <= B_SPIN; end
				else bst <= B_ACK;
			end
			B_ACK: begin
				m_ack <= 1'b1;
				if (!m_we) case (rsel)
					R_WRAM:  m_rdata <= wram_q;
					R_NVRAM: m_rdata <= {24'd0, nvram_q};
					R_PRI:   m_rdata <= {24'd0, priram_rdata};
					R_PAL:   m_rdata <= {16'd0, palram_rdata};
					R_ROZ:   m_rdata <= {16'd0, rozram_rdata};
					R_ROADV: m_rdata <= {16'd0, roadvram_rdata};
					R_ROADL: m_rdata <= {16'd0, roadline_rdata};
					R_FPU:   m_rdata <= {16'd0, fpu_rdata};
					R_COMMS: m_rdata <= comms_q;
					R_DSW2:  m_rdata <= dsw2;
					// analog_r(): AN2 twice in the top halves, then AN1 the steering,
					// then AN0 the accelerator. AN2 is a bank of eight pulled-up
					// switches; MAME names only bit 7, "Shift Brake", and reads them
					// all off. The brake and the shifter are INPUTS bits 1 and 0.
					R_ANALOG: m_rdata <= {analog_an2, analog_an2, analog_wheel, analog_accel};
					R_LINE:  m_rdata <= {16'd0, lineram_rdata};
					R_TX:    m_rdata <= {16'd0, txram_rdata};
					R_BG:    m_rdata <= {16'd0, bgram_rdata};
					R_REGS:  m_rdata <= regs_q;
					R_IN:    m_rdata <= in_read;
					R_DSW:   m_rdata <= dsw_s2;
					// MacDonald: D15-D8 read $FF, D7-D0 the Z80's byte inverted
					R_SND:   m_rdata <= {16'd0, 8'hFF, ~to_main};
					R_ALLF:  m_rdata <= 32'hFFFF_FFFF;
					R_CMDRD: m_rdata <= 32'h0000_FFFF;
					default: m_rdata <= 32'd0;
				endcase
				bst <= B_DRAIN;
			end
			B_ROM: if (d_ack) begin
				d_req   <= 1'b0;
				m_rdata <= d_rdata;
				m_ack   <= 1'b1;
				bst     <= B_DRAIN;
			end
			B_OBJW: if (!wq_full) bst <= B_ACK;
			// the FPU window answers in two clocks, read or write
			B_FPU: if (fpu_valid) begin fpu_req <= 1'b0; bst <= B_ACK; end
			B_OBJR: if (wq_empty) begin o_req <= 1'b1; bst <= B_OBJ; end
			B_OBJ: if (o_ack) begin
				o_req   <= 1'b0;
				m_rdata <= {16'd0, o_rdata};
				m_ack   <= 1'b1;
				bst     <= B_DRAIN;
			end
			B_SPIN: if (spin_cnt == 10'd0) bst <= B_ACK; else spin_cnt <= spin_cnt - 10'd1;
			B_DRAIN: bst <= B_IDLE;
			default: bst <= B_IDLE;
		endcase
	end


	// ------------------------------------------------------------- registers, interrupts
	logic vbl_cpu, fld_cpu;
	ms32_cdc_event u_vbl (.clk_s(clk_sys), .s_pulse(vblank_ev), .clk_d(clk_cpu), .d_pulse(vbl_cpu));
	ms32_cdc_event u_fld (.clk_s(clk_sys), .s_pulse(field_ev),  .clk_d(clk_cpu), .d_pulse(fld_cpu));

	wire reg_wr = wr && is_regs;
	ms32_sysctrl u_sysctrl (
		.clk(clk_cpu), .reset(rst), .invert_lines(invert_lines),
		.wr(reg_wr), .wr_off(a[11:0]), .wr_data(m_wdata[15:0]),
		.vblank_ev(vbl_cpu), .field_ev(fld_cpu),
		.sound_irq_set(tomain_we), .sound_irq_clr(snd_irq_clr),
		.fpu0_irq(fpu_irq0), .fpu1_irq(fpu_irq1),
		.irq_n(irq_n), .irq_vector(irq_vector)
	);

	logic [27:0] vreg_pay;
	ms32_cdc_mailbox #(.W(28)) u_vreg (
		.clk_s(clk_cpu), .s_pulse(reg_wr), .s_data({a[11:0], m_wdata[15:0]}),
		.clk_d(clk_sys), .d_pulse(vreg_we), .d_data(vreg_pay)
	);
	assign vreg_off  = vreg_pay[27:16];
	assign vreg_data = vreg_pay[15:0];

	// ------------------------------------------------------------- debug: field passes
	// f1superb's main loop idles on the halfword at FEE10000 until the field
	// handler (level 9) decrements it, then clears it and does the frame's
	// work -- the road line table among it, written by FFE19EC5-FFE19ED3 in one
	// run per pass (MAME, second attract drive: lines 119-223, 420 writes,
	// once every other frame). So per pass: the road line range and count, and
	// the FEE10000 writes (one by the handler, one by the loop).
	wire idle_flag_wr = wr && is_wram && (a[16:2] == 15'h4000) && |m_be[1:0];
	wire road_lw_ev   = wr && is_roadl;
	wire [7:0] road_line = a[12:5];
	logic [15:0] p_fld, p_flag, p_cnt, p_cnt_last;
	logic [7:0]  p_min, p_max, p_min_last, p_max_last;
	always_ff @(posedge clk_cpu) begin
		if (rst) begin
			p_fld <= '0; p_flag <= '0; p_cnt <= '0; p_cnt_last <= '0;
			p_min <= 8'hFF; p_max <= 8'h00; p_min_last <= 8'hFF; p_max_last <= 8'h00;
		end else begin
			if (idle_flag_wr) p_flag <= p_flag + 16'd1;
			if (fld_cpu) begin
				p_fld <= p_fld + 16'd1;
				p_cnt_last <= p_cnt; p_min_last <= p_min; p_max_last <= p_max;
				p_cnt <= {15'd0, road_lw_ev};
				p_min <= road_lw_ev ? road_line : 8'hFF;
				p_max <= road_lw_ev ? road_line : 8'h00;
			end else if (road_lw_ev) begin
				p_cnt <= p_cnt + 16'd1;
				if (road_line < p_min) p_min <= road_line;
				if (road_line > p_max) p_max <= road_line;
			end
		end
	end
	assign dbg_pass = {p_fld, p_flag, p_cnt_last, p_max_last, p_min_last};

endmodule
