// SPDX-License-Identifier: GPL-3.0-or-later
//
// The MS32 board without the MiSTer framework: ms32_cpu_sys (V70, memory
// map, interrupts, on clk_cpu) wired to ms32_video (on clk_sys). MS32.sv
// puts the SDRAM, DDR3 and HPS around it; sim/capload_tb and sim/system_tb
// put models around the same module, so what the benches run is what the
// board runs.
module ms32_core (
	input  logic        clk_sys,
	input  logic        clk_cpu,
	input  logic        sys_reset,        // clk_sys; low while a capture loads
	input  logic        cpu_run,          // clk_sys; 0 holds the V70 in reset
	input  logic        invert_lines,

	input  logic [31:0] inputs,
	input  logic [31:0] dsw,
	input  logic        mahjong,
	input  logic [29:0] mj_keys,

	// clk_sys: NVRAM read-back and write events
	input  logic [12:0] nv_addr,
	output logic [7:0]  nv_rdata,
	output logic        nv_written,

	// clk_sys: the sound board (ms32_sound, outside the core: the T80 is VHDL
	// and the Verilator benches run this module)
	output logic        snd_reset,        // one clock: sysctrl 0x38 written with bit 0 set
	output logic        snd_cmd_we,
	output logic [7:0]  snd_cmd_data,
	input  logic        snd_tomain_we,
	input  logic [7:0]  snd_tomain_data,

	// clk_sys: capture loader writes
	input  logic        ld_req,
	input  logic [31:0] ld_addr,
	input  logic [3:0]  ld_be,
	input  logic [31:0] ld_data,
	output logic        ld_ack,

	// clk_sys: ROMs
	output logic        prg_req,  output logic [17:0] prg_addr, input logic prg_valid, input logic [63:0] prg_data,
	output logic        tx_req,   output logic [23:0] tx_addr,  input logic tx_valid,  input logic [63:0] tx_data,
	output logic        bg_req,   output logic [23:0] bg_addr,  input logic bg_valid,  input logic [63:0] bg_data,
	output logic        roz_req,  output logic [23:0] roz_addr, input logic roz_valid, input logic [63:0] roz_data,
	output logic        spr_req,  output logic [27:0] spr_addr, input logic spr_valid, input logic [63:0] spr_data,

	// clk_sys: sprite frame buffer
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic        DDRAM_WE,

	// clk_sys: video
	output logic        ce_pix,
	output logic        hblank, vblank, hsync, vsync,
	output logic [7:0]  r, g, b,
	output logic        vblank_ev,

	input  logic        dis_tx, dis_bg, dis_roz, dis_spr,

	output logic        tx_overrun, bg_overrun, roz_overrun, spr_overrun, fb_overrun, bad_primask,
	output logic        dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz,
	output logic [31:0] dbg_pc                                   // clk_cpu
);

	logic        vreg_we;
	logic [11:0] vreg_off;
	logic [15:0] vreg_data;
	logic        field_ev;
	logic [15:0] vram_wdata;
	logic [12:0] txram_addr, bgram_addr, priram_addr;
	logic [14:0] rozram_addr, objram_addr;
	logic [10:0] lineram_addr;
	logic [15:0] palram_addr;
	logic        txram_wel, txram_weh, bgram_wel, bgram_weh, rozram_wel, rozram_weh, lineram_wel, lineram_weh;
	logic        objram_wel, objram_weh, palram_wel, palram_weh, priram_we;
	logic [15:0] txram_rdata, bgram_rdata, rozram_rdata, lineram_rdata, objram_rdata, palram_rdata;
	logic [7:0]  priram_rdata;

	ms32_cpu_sys u_sys (
		.clk_cpu(clk_cpu), .clk_sys(clk_sys), .rst_sys(sys_reset), .cpu_run_sys(cpu_run), .invert_lines(invert_lines),
		.inputs(inputs), .dsw(dsw), .mahjong(mahjong), .mj_keys(mj_keys),
		.nv_addr(nv_addr), .nv_rdata(nv_rdata), .nv_written(nv_written),
		.vreg_we(vreg_we), .vreg_off(vreg_off), .vreg_data(vreg_data),
		.vblank_ev(vblank_ev), .field_ev(field_ev),
		.snd_cmd_we(snd_cmd_we), .snd_cmd_data(snd_cmd_data),
		.snd_tomain_we(snd_tomain_we), .snd_tomain_data(snd_tomain_data),
		.rom_req(prg_req), .rom_addr(prg_addr), .rom_valid(prg_valid), .rom_data(prg_data),
		.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack),
		.txram_addr(txram_addr), .txram_wel(txram_wel), .txram_weh(txram_weh), .txram_rdata(txram_rdata),
		.bgram_addr(bgram_addr), .bgram_wel(bgram_wel), .bgram_weh(bgram_weh), .bgram_rdata(bgram_rdata),
		.rozram_addr(rozram_addr), .rozram_wel(rozram_wel), .rozram_weh(rozram_weh), .rozram_rdata(rozram_rdata),
		.lineram_addr(lineram_addr), .lineram_wel(lineram_wel), .lineram_weh(lineram_weh), .lineram_rdata(lineram_rdata),
		.objram_addr(objram_addr), .objram_wel(objram_wel), .objram_weh(objram_weh), .objram_rdata(objram_rdata),
		.palram_addr(palram_addr), .palram_wel(palram_wel), .palram_weh(palram_weh), .palram_rdata(palram_rdata),
		.priram_addr(priram_addr), .priram_we(priram_we), .priram_rdata(priram_rdata),
		.vram_wdata(vram_wdata),
		.dbg_pc(dbg_pc), .dbg_accesses(), .dbg_cache_hits(), .dbg_cache_misses()
	);

	// jaleco_ms32_sysctrl sound_reset_w: bit 0 pulses the Z80's reset
	assign snd_reset = vreg_we && vreg_off == 12'h038 && vreg_data[0];

	ms32_video u_video (
		.clk(clk_sys), .reset(sys_reset),
		.vreg_we(vreg_we), .vreg_off(vreg_off), .vreg_data(vreg_data),
		.cpu_clk(clk_cpu), .cpu_wdata(vram_wdata),
		.txram_addr(txram_addr), .txram_wel(txram_wel), .txram_weh(txram_weh), .txram_rdata(txram_rdata),
		.bgram_addr(bgram_addr), .bgram_wel(bgram_wel), .bgram_weh(bgram_weh), .bgram_rdata(bgram_rdata),
		.rozram_addr(rozram_addr), .rozram_wel(rozram_wel), .rozram_weh(rozram_weh), .rozram_rdata(rozram_rdata),
		.lineram_addr(lineram_addr), .lineram_wel(lineram_wel), .lineram_weh(lineram_weh), .lineram_rdata(lineram_rdata),
		.objram_addr(objram_addr), .objram_wel(objram_wel), .objram_weh(objram_weh), .objram_rdata(objram_rdata),
		.palram_addr(palram_addr), .palram_wel(palram_wel), .palram_weh(palram_weh), .palram_rdata(palram_rdata),
		.priram_addr(priram_addr), .priram_we(priram_we), .priram_rdata(priram_rdata),
		.tx_rom_req(tx_req),   .tx_rom_addr(tx_addr),   .tx_rom_valid(tx_valid),   .tx_rom_data(tx_data),
		.bg_rom_req(bg_req),   .bg_rom_addr(bg_addr),   .bg_rom_valid(bg_valid),   .bg_rom_data(bg_data),
		.roz_rom_req(roz_req), .roz_rom_addr(roz_addr), .roz_rom_valid(roz_valid), .roz_rom_data(roz_data),
		.spr_rom_req(spr_req), .spr_rom_addr(spr_addr), .spr_rom_valid(spr_valid), .spr_rom_data(spr_data),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
		.vblank_ev(vblank_ev), .field_ev(field_ev), .timer_enable(),
		.dis_tx(dis_tx), .dis_bg(dis_bg), .dis_roz(dis_roz), .dis_spr(dis_spr),
		.tx_overrun(tx_overrun), .bg_overrun(bg_overrun), .roz_overrun(roz_overrun), .spr_overrun(spr_overrun),
		.fb_overrun(fb_overrun), .bad_primask(bad_primask),
		.spr_frame_cycles(), .spr_drawn(),
		.dbg_roz_fill(dbg_roz_fill), .dbg_roz_hit(dbg_roz_hit), .dbg_roz_pen_nz(dbg_roz_pen_nz)
	);

endmodule
