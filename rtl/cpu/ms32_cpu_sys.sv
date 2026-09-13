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
// (events), ROM granules (request), the capture loader's writes (request).
//
// DECODE. As sim/v70_boot_tb, which matched MAME over 5M accesses of the
// tetrisp boot: every RAM region mirrors address bits 29:26, so
// am = a & 0xC3FFFFFF picks the region and the bits each mirror leaves
// live index it. The 8- and 16-bit regions sit behind umask32: a read
// returns one byte or halfword zero-extended, a write takes lanes 0 or 0-1.
// I/O is decoded on the full address. Unmapped reads return 0.
//
// BUS TIMING. ms32_v70_bus holds m_req until m_ack. Every access here is
// accepted in B_IDLE (RAM address and write enable driven that clock, the
// RAMs' read data registered on the same edge), answered from B_ACK one
// clock later with one clock of m_ack, and B_DRAIN lets m_req fall. ROM
// reads wait in B_ROM for the cache.
//
// CAPTURE PLAYBACK. While the core is held in reset (cpu_run low) the bus
// belongs to the capture loader, whose writes arrive from clk_sys at real
// CPU addresses: playback exercises the same decode the game does.
module ms32_cpu_sys (
	input  logic        clk_cpu,
	input  logic        clk_sys,
	input  logic        rst_sys,          // clk_sys: whole block (not held by a capture load)
	input  logic        cpu_run_sys,      // clk_sys: 0 holds the V70 in reset
	input  logic        invert_lines,     // static, from the mod byte

	// clk_sys: inputs, active low as the board reads them
	input  logic [31:0] inputs,
	input  logic [31:0] dsw,

	// clk_sys: register writes to ms32_video (byte offset in 0xFCE00000, low halfword)
	output logic        vreg_we,
	output logic [11:0] vreg_off,
	output logic [15:0] vreg_data,

	// clk_sys: CRTC events
	input  logic        vblank_ev,
	input  logic        field_ev,

	// clk_sys: program ROM granules, ROM-local granule index (x8 bytes)
	output logic        rom_req,
	output logic [17:0] rom_addr,
	input  logic        rom_valid,
	input  logic [63:0] rom_data,

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
	output logic [14:0] objram_addr, output logic objram_wel, output logic objram_weh, input logic [15:0] objram_rdata,
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
	wire is_tx      = is_txbg && !a[15];
	wire is_bg      = is_txbg &&  a[15];
	wire is_regs    = (a[31:12] == 20'hfce00);
	wire is_sndcmd  = (a == 32'hfc80_0000);
	wire is_inputs  = (a == 32'hfcc0_0004);
	wire is_dsw     = (a == 32'hfcc0_0010);
	wire is_sndres  = (a == 32'hfd00_0000);
	// the register block's RAM-backed ranges read back; the rest is write-only
	wire regs_rd    = (a[11:0] >= 12'h200 && a[11:0] < 12'h280) || (a[11:0] >= 12'h600 && a[11:0] < 12'h660) ||
	                  (a[11:0] >= 12'ha00 && a[11:0] < 12'ha38);

	typedef enum logic [3:0] {
		R_NONE, R_ROM, R_WRAM, R_NVRAM, R_PRI, R_PAL, R_ROZ, R_LINE, R_OBJ, R_TX, R_BG, R_REGS, R_IN, R_DSW, R_SND
	} region_t;
	region_t rsel;

	typedef enum logic [2:0] {B_IDLE, B_ACK, B_ROM, B_DRAIN} bst_t;
	bst_t bst;
	wire accept = (bst == B_IDLE) && m_req && !m_ack;
	wire wr     = accept && m_we;
	wire [1:0] lanes16 = m_be[1:0];

	// ------------------------------------------------------------- RAMs
	// work RAM: 0x20000 bytes, 32-bit
	logic [31:0] wram [0:32767];
	logic [31:0] wram_q;
	always_ff @(posedge clk_cpu) begin
		for (int i = 0; i < 4; i++) if (wr && is_wram && m_be[i]) wram[a[16:2]][8*i +: 8] <= m_wdata[8*i +: 8];
		wram_q <= wram[a[16:2]];
	end

	// NVRAM: 0x2000 bytes, 8-bit
	logic [7:0] nvram [0:8191];
	logic [7:0] nvram_q;
	always_ff @(posedge clk_cpu) begin
		if (wr && is_nvram && m_be[0]) nvram[a[14:2]] <= m_wdata[7:0];
		nvram_q <= nvram[a[14:2]];
	end

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
	assign objram_addr  = a[16:2];  assign objram_wel  = wr && is_objram  && lanes16[0]; assign objram_weh  = wr && is_objram  && lanes16[1];
	assign palram_addr  = a[17:2];  assign palram_wel  = wr && is_palram  && lanes16[0]; assign palram_weh  = wr && is_palram  && lanes16[1];
	assign priram_addr  = a[14:2];  assign priram_we   = wr && is_priram  && m_be[0];

	// ------------------------------------------------------------- inputs
	(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
	logic [31:0] in_s1, in_s2, dsw_s1, dsw_s2;
	always_ff @(posedge clk_cpu) begin
		in_s1 <= inputs; in_s2 <= in_s1;
		dsw_s1 <= dsw;   dsw_s2 <= dsw_s1;
	end

	// ------------------------------------------------------------- sound latch (no Z80 until Phase 3)
	// ms32.cpp: 0xFC800000 loads the Z80's latch; 0xFD000000 returns to_main
	// inverted and clears IRQ level 1. With no sound CPU to_main stays 0.
	logic [7:0] to_main;
	logic [7:0] snd_latch;
	always_ff @(posedge clk_cpu) begin
		if (rst) begin to_main <= 8'h00; snd_latch <= 8'h00; end
		else if (wr && is_sndcmd) snd_latch <= m_wdata[7:0];
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
		.if_req(if_req), .if_addr(if_addr[20:0]), .if_ack(if_ack), .if_data(if_data),
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

	// ------------------------------------------------------------- bus FSM
	always_ff @(posedge clk_cpu) begin
		m_ack <= 1'b0;
		if (rst) begin
			bst <= B_IDLE; d_req <= 1'b0; dbg_accesses <= 32'd0;
		end else case (bst)
			B_IDLE: if (accept) begin
				dbg_accesses <= dbg_accesses + 32'd1;
				rsel <= is_rom ? R_ROM : is_wram ? R_WRAM : is_nvram ? R_NVRAM : is_priram ? R_PRI :
				        is_palram ? R_PAL : is_rozram ? R_ROZ : is_lineram ? R_LINE : is_objram ? R_OBJ :
				        is_tx ? R_TX : is_bg ? R_BG : (is_regs && regs_rd) ? R_REGS :
				        is_inputs ? R_IN : is_dsw ? R_DSW : is_sndres ? R_SND : R_NONE;
				if (is_rom && !m_we) begin d_req <= 1'b1; bst <= B_ROM; end
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
					R_LINE:  m_rdata <= {16'd0, lineram_rdata};
					R_OBJ:   m_rdata <= {16'd0, objram_rdata};
					R_TX:    m_rdata <= {16'd0, txram_rdata};
					R_BG:    m_rdata <= {16'd0, bgram_rdata};
					R_REGS:  m_rdata <= regs_q;
					R_IN:    m_rdata <= in_s2;
					R_DSW:   m_rdata <= dsw_s2;
					R_SND:   m_rdata <= {24'd0, ~to_main};
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
		.sound_irq_set(1'b0), .sound_irq_clr(snd_irq_clr),
		.irq_n(irq_n), .irq_vector(irq_vector)
	);

	logic [27:0] vreg_pay;
	ms32_cdc_mailbox #(.W(28)) u_vreg (
		.clk_s(clk_cpu), .s_pulse(reg_wr), .s_data({a[11:0], m_wdata[15:0]}),
		.clk_d(clk_sys), .d_pulse(vreg_we), .d_data(vreg_pay)
	);
	assign vreg_off  = vreg_pay[27:16];
	assign vreg_data = vreg_pay[15:0];

endmodule
