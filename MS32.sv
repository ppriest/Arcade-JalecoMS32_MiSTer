// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Jaleco MegaSystem 32 for MiSTer -- top level.
//
//  State: the board (rtl/ms32_core.sv: the V70 and its memory map on
//  clk_cpu, the video path on clk_sys) on the framework, with the DDR3
//  window (sprite frame buffer) and the SDRAM (every ROM, through
//  rtl/memory/ms32_sdram_top.sv, tile decryption on the way in). No sound
//  yet. A capture blob (scripts/build_capture_blob.py, ioctl index 2) can
//  still be loaded with the CPU held (mod byte bit 7), so a frame MAME
//  rendered is rendered by the hardware from the real ROMs.
//
//  Download indices: 0 the ROM set (.mra), 1 the mod byte, 2 a capture blob,
//  254 the DIP switches.
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
	"DIP;",
	"-;",
	// Debug page. The all-zero configuration must stay the correct one, so
	// every switch is worded so that 0 = normal.
	"H1P1,Debug;",
	"H1P1-;",
	"H1P1O[81],TX layer,On,Off;",
	"H1P1O[82],BG layer,On,Off;",
	"H1P1O[83],ROZ layer,On,Off;",
	"H1P1O[84],Sprites,On,Off;",
	"-;",
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Start,Coin,Pause,Service,Test;",
	"jn,A,B,X,Y,R,Start,Select,L,,;",
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
wire  [31:0] joystick_0, joystick_1;

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

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
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
// bit 2 ms32_invert_lines (tp2m32, wpksocv2); bit 7 holds the V70 in reset
// (capture playback .mra files).
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_byte <= ioctl_dout;

///////////////////////   INPUTS   ////////////////////////////////

// DIPs: .mra <switches> arrive as index 254, one byte per switch bank,
// low byte first: the 32-bit word ms32_map reads at 0xFCC00010.
reg [7:0] sw[4] = '{8'hFF, 8'hFF, 8'hFF, 8'hFF};
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:2]) sw[ioctl_addr[1:0]] <= ioctl_dout;
wire [31:0] dsw = {sw[3], sw[2], sw[1], sw[0]};

// ms32.cpp INPUTS at 0xFCC00004, active low. MiSTer joystick bits: 0 R, 1 L,
// 2 D, 3 U, then the J1 list from bit 4.
function automatic [7:0] player(input [31:0] j);
	player = ~{j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};   // B4 B3 B2 B1 right left down up
endfunction
wire [31:0] inputs = {8'hFF,
                      ~joystick_1[8], ~joystick_0[8],                    // 23,22 button 5
                      ~joystick_1[9], ~joystick_0[9],                    // 21,20 start
                      ~(joystick_0[13] | joystick_1[13]),                // 19 test
                      ~(joystick_0[12] | joystick_1[12]),                // 18 service
                      ~joystick_1[10], ~joystick_0[10],                  // 17,16 coin
                      player(joystick_1), player(joystick_0)};

///////////////////////   CAPTURE LOADER   ////////////////////////

wire        sys_reset, cap_wait, ld_req, ld_ack;
wire [31:0] ld_addr, ld_data;
wire [3:0]  ld_be;
ms32_capture_loader u_capload (
	.clk(clk_sys), .reset(reset),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(cap_wait),
	.sys_reset(sys_reset),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack)
);

///////////////////////   SDRAM   /////////////////////////////////

wire        prg_req, tx_req, bg_req, roz_req, spr_req;
wire [17:0] prg_addr;
wire [23:0] tx_addr, bg_addr, roz_addr;
wire [27:0] spr_addr;
wire        prg_valid, tx_valid, bg_valid, roz_valid, spr_valid;
wire [63:0] prg_data, tx_data, bg_data, roz_data, spr_data;
wire        sd_wait;
assign ioctl_wait = sd_wait | cap_wait;
wire        dbg_dl_req, dbg_dl_busy, dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz;

// reset & ~ioctl_download: MiSTer holds RESET for the whole download, and a
// memory path gated by it never sees a byte (seta_sdram_top's header).
ms32_sdram_top u_sdram (
	.clk(clk_sys), .reset(reset & ~ioctl_download), .init(~pll_locked),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout), .ioctl_wait(sd_wait), .key(mod_byte[1:0]),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.if_req(prg_req), .if_addr(prg_addr), .if_valid(prg_valid), .if_data(prg_data),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(1'b0), .z80_addr(18'd0), .z80_valid(), .z80_data(),
	.dbg_dl_req(dbg_dl_req), .dbg_dl_busy(dbg_dl_busy)
);

///////////////////////   VIDEO   /////////////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

assign DDRAM_CLK = clk_sys;

// The V70 runs once the download is over, unless the mod byte holds it for
// capture playback; sys_reset leaves the bus side out of reset while a
// capture loads (ms32_capture_loader).
ms32_core u_core (
	.clk_sys(clk_sys), .clk_cpu(clk_cpu), .sys_reset(sys_reset), .cpu_run(~reset & ~mod_byte[7]), .invert_lines(mod_byte[2]),
	.inputs(inputs), .dsw(dsw),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack),
	.prg_req(prg_req), .prg_addr(prg_addr), .prg_valid(prg_valid), .prg_data(prg_data),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(),
	.dis_tx(status[81]), .dis_bg(status[82]), .dis_roz(status[83]), .dis_spr(status[84]),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.dbg_roz_fill(dbg_roz_fill), .dbg_roz_hit(dbg_roz_hit), .dbg_roz_pen_nz(dbg_roz_pen_nz), .dbg_pc()
);

`ifdef DEBUG_ISSP
// JTAG counters for the memory path and the ROZ cache (rtl/debug/issp_probe.sv;
// read with scripts/read_issp.py, which holds the machine-wide JTAG lock).
issp_probe #(.INSTANCE_ID("M")) u_issp (
	.clk(clk_sys),
	.dl_byte(ioctl_download && ioctl_wr && ioctl_index == 16'd0), .dl_addr_lo(ioctl_addr[15:0]),
	.dl_req(dbg_dl_req), .dl_busy(dbg_dl_busy),
	.rom_valid(prg_valid | tx_valid | bg_valid | roz_valid | spr_valid),
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
