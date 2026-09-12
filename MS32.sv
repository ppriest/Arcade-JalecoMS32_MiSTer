// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Jaleco MegaSystem 32 for MiSTer -- top level.
//
//  State: the video path (rtl/video/ms32_video.sv) on the framework, the
//  DDR3 window (sprite frame buffer) and the SDRAM (every ROM, through
//  rtl/memory/ms32_sdram_top.sv, tile decryption on the way in). No CPU
//  and no sound yet: the video RAMs and registers can be loaded from a
//  capture blob (scripts/build_capture_blob.py, ioctl index 2) so a frame
//  MAME rendered is rendered by the hardware from the real ROMs.
//
//  Download indices: 0 the ROM set (.mra), 1 the mod byte, 2 a capture blob.
//
//  This file is derived from MiSTer_Template's Template.sv, which is
//  GPL-2.0-or-later; it is distributed here under GPL-3.0-or-later.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"

// The Debug page is hidden in the release revision. Every one of its lines
// carries an H1 prefix, so status_menumask bit 1 hides the whole page; the
// bits still work if a .CFG sets them, only the MENU goes away. DEBUG_ISSP is
// defined by MS32_stp.qsf and not by MS32.qsf (docs/WORKFLOW.md §1, §3).
`ifdef DEBUG_ISSP
localparam DEBUG_MENU_HIDE = 1'b0;
`else
localparam DEBUG_MENU_HIDE = 1'b1;
`endif
wire debug_menu_hide = DEBUG_MENU_HIDE;

localparam CONF_STR = {
	"MS32;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"F2,BIN,Load capture;",
	"-;",
	// Debug page. The all-zero configuration must stay the correct one, so
	// every switch is worded so that 0 = normal.
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[80],Pause CPU,Off,On;",
	"H1P1O[81],TX layer,On,Off;",
	"H1P1O[82],BG layer,On,Off;",
	"H1P1O[83],ROZ layer,On,Off;",
	"H1P1O[84],Sprites,On,Off;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;", // [optional] config version 0-99.
	        // If CONF_STR options are changed in incompatible way, then change version number too,
	        // so all options will get default values on first start.
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({14'd0, debug_menu_hide, 1'b0}),  // H1: the Debug page

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// ROADMAP "Clock plan": clk_sys 96 MHz for video, memory and sound; clk_cpu
// 20 MHz for the V70 (Phase 2); SDRAM_CLK is clk_sys shifted 180 degrees.
// One PLL, VCO 960 MHz.
wire clk_sys, clk_cpu, clk_sdram_shifted, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_cpu),
	.outclk_2(clk_sdram_shifted),
	.locked(pll_locked)
);
assign SDRAM_CLK = clk_sdram_shifted;

wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;

///////////////////////   MOD BYTE   //////////////////////////////

// .mra rom index 1: [1:0] the tile decryption key (ms32_jalcrpt_pkg's
// order: 0 ss91022_10, 1 ss92046_01, 2 ss92047_01, 3 ss92048_01);
// bit 2 will be ms32_invert_lines (tp2m32, wpksocv2).
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_byte <= ioctl_dout;

///////////////////////   CAPTURE LOADER   ////////////////////////

wire        video_reset, ld_tx, ld_bg, ld_roz, ld_line, ld_obj, ld_pal, ld_pri, ld_vreg;
wire [17:0] ld_rel;
wire [15:0] ld_data;
ms32_capture_loader u_capload (
	.clk(clk_sys), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.video_reset(video_reset),
	.ld_tx(ld_tx), .ld_bg(ld_bg), .ld_roz(ld_roz), .ld_line(ld_line), .ld_obj(ld_obj),
	.ld_pal(ld_pal), .ld_pri(ld_pri), .ld_vreg(ld_vreg), .ld_rel(ld_rel), .ld_data(ld_data)
);

///////////////////////   SDRAM   /////////////////////////////////

wire        tx_req, bg_req, roz_req, spr_req;
wire [23:0] tx_addr, bg_addr, roz_addr;
wire [27:0] spr_addr;
wire        tx_valid, bg_valid, roz_valid, spr_valid;
wire [63:0] tx_data, bg_data, roz_data, spr_data;
wire        dbg_dl_req, dbg_dl_busy, dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz;

// reset & ~ioctl_download: MiSTer holds RESET for the whole download, and a
// memory path gated by it never sees a byte (seta_sdram_top's header).
ms32_sdram_top u_sdram (
	.clk(clk_sys), .reset(reset & ~ioctl_download), .init(~pll_locked),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(ioctl_wait), .key(mod_byte[1:0]),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.if_req(1'b0), .if_addr(18'd0), .if_valid(), .if_data(),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(1'b0), .z80_addr(18'd0), .z80_valid(), .z80_data(),
	.dbg_dl_req(dbg_dl_req), .dbg_dl_busy(dbg_dl_busy)
);

///////////////////////   VIDEO   /////////////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

assign DDRAM_CLK = clk_sys;

ms32_video u_video (
	.clk(clk_sys), .reset(video_reset),   // not reset: see ms32_capture_loader
	.vreg_we(ld_vreg), .vreg_off({ld_rel[9:0], 2'b00}), .vreg_data(ld_data),
	.txram_we(ld_tx),     .txram_addr(ld_rel[12:0]),   .txram_wdata(ld_data),
	.bgram_we(ld_bg),     .bgram_addr(ld_rel[12:0]),   .bgram_wdata(ld_data),
	.rozram_we(ld_roz),   .rozram_addr(ld_rel[14:0]),  .rozram_wdata(ld_data),
	.lineram_we(ld_line), .lineram_addr(ld_rel[10:0]), .lineram_wdata(ld_data),
	.objram_we(ld_obj),   .objram_addr(ld_rel[14:0]),  .objram_wdata(ld_data),
	.palram_we(ld_pal),   .palram_addr(ld_rel[15:0]),  .palram_wdata(ld_data),
	.priram_we(ld_pri),   .priram_addr(ld_rel[12:0]),  .priram_wdata(ld_data[7:0]),
	.tx_rom_req(tx_req),   .tx_rom_addr(tx_addr),   .tx_rom_valid(tx_valid),   .tx_rom_data(tx_data),
	.bg_rom_req(bg_req),   .bg_rom_addr(bg_addr),   .bg_rom_valid(bg_valid),   .bg_rom_data(bg_data),
	.roz_rom_req(roz_req), .roz_rom_addr(roz_addr), .roz_rom_valid(roz_valid), .roz_rom_data(roz_data),
	.spr_rom_req(spr_req), .spr_rom_addr(spr_addr), .spr_rom_valid(spr_valid), .spr_rom_data(spr_data),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(), .field_ev(), .timer_enable(),
	.dis_tx(status[81]), .dis_bg(status[82]), .dis_roz(status[83]), .dis_spr(status[84]),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.spr_frame_cycles(), .spr_drawn(),
	.dbg_roz_fill(dbg_roz_fill), .dbg_roz_hit(dbg_roz_hit), .dbg_roz_pen_nz(dbg_roz_pen_nz)
);

`ifdef DEBUG_ISSP
// JTAG counters for the memory path and the ROZ cache (rtl/debug/issp_probe.sv;
// read with scripts/read_issp.py, which holds the machine-wide JTAG lock).
issp_probe #(.INSTANCE_ID("M")) u_issp (
	.clk(clk_sys),
	.dl_byte(ioctl_download && ioctl_wr && ioctl_index == 16'd0), .dl_addr_lo(ioctl_addr[15:0]),
	.dl_req(dbg_dl_req), .dl_busy(dbg_dl_busy),
	.rom_valid(tx_valid | bg_valid | roz_valid | spr_valid),
	.ioctl_wait(ioctl_wait), .ioctl_download(ioctl_download), .pll_locked(pll_locked),
	.roz_fill(dbg_roz_fill), .roz_hit(dbg_roz_hit), .roz_pen_nz(dbg_roz_pen_nz)
);
`endif

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = ce_pix;
assign VGA_DE = ~(hblank | vblank);
assign VGA_HS = hsync;
assign VGA_VS = vsync;
assign VGA_R  = r;
assign VGA_G  = g;
assign VGA_B  = b;

// An engine that could not keep up lights the LED: the sticky flags are
// the first thing to read on a wrong picture (docs/phase1_video.md).
assign LED_USER = tx_ovr | bg_ovr | roz_ovr | spr_ovr | fb_ovr | bad_pm;

endmodule
