// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Jaleco MegaSystem 32 for MiSTer -- top level.
//
//  Phase 1 state: the video path (rtl/video/ms32_video.sv) is wired to the
//  framework and the DDR3 window; there is no CPU, no SDRAM and no sound
//  yet. The video RAMs and registers are loaded through the HPS download
//  path from a capture blob (scripts/build_capture_blob.py), so a frame
//  MAME rendered can be rendered by the hardware and compared -- the same
//  test the simulation benches run, on the board. The tile and sprite ROM
//  ports are stubbed until the SDRAM backend exists (Phase 2), so a
//  capture on hardware shows the right geometry with placeholder pens.
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
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

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
	"F1,BIN,Load capture;",
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
	.ioctl_wait(1'b0),

	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// ROADMAP "Clock plan": clk_sys 96 MHz for video, memory and sound; clk_cpu
// 20 MHz for the V70 (Phase 2). One PLL, VCO 960 MHz.
wire clk_sys, clk_cpu, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_cpu),
	.locked(pll_locked)
);

wire reset = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;

///////////////////////   CAPTURE LOADER   ////////////////////////

// A capture blob is a stream of little-endian u16 words in the order
// scripts/build_capture_blob.py writes them; the word index selects the
// destination. Menu index 1 is "Load capture".
localparam int W_TXRAM   = 0;                      // 0x2000 words
localparam int W_BGRAM   = W_TXRAM   + 'h2000;     // 0x2000
localparam int W_ROZRAM  = W_BGRAM   + 'h2000;     // 0x8000
localparam int W_LINERAM = W_ROZRAM  + 'h8000;     // 0x800
localparam int W_OBJRAM  = W_LINERAM + 'h800;      // 0x8000
localparam int W_PALRAM  = W_OBJRAM  + 'h8000;     // 0x10000
localparam int W_PRIRAM  = W_PALRAM  + 'h10000;    // 0x2000 (u8 in the low byte)
localparam int W_VREGS   = W_PRIRAM  + 'h2000;     // 0x400 words: register byte offset = 4 * k
localparam int W_END     = W_VREGS   + 'h400;

reg  [7:0]  ld_lo;
reg         ld_we;
reg  [17:0] ld_word;
reg  [15:0] ld_data;
wire        ld_capture = ioctl_download && (ioctl_index[5:0] == 6'd1);
always @(posedge clk_sys) begin
	ld_we <= 1'b0;
	if (ld_capture && ioctl_wr) begin
		if (!ioctl_addr[0]) ld_lo <= ioctl_dout;
		else begin
			ld_we   <= 1'b1;
			ld_word <= ioctl_addr[18:1];
			ld_data <= {ioctl_dout, ld_lo};
		end
	end
end
wire ld_tx   = ld_we && (ld_word >= W_TXRAM)   && (ld_word < W_BGRAM);
wire ld_bg   = ld_we && (ld_word >= W_BGRAM)   && (ld_word < W_ROZRAM);
wire ld_roz  = ld_we && (ld_word >= W_ROZRAM)  && (ld_word < W_LINERAM);
wire ld_line = ld_we && (ld_word >= W_LINERAM) && (ld_word < W_OBJRAM);
wire ld_obj  = ld_we && (ld_word >= W_OBJRAM)  && (ld_word < W_PALRAM);
wire ld_pal  = ld_we && (ld_word >= W_PALRAM)  && (ld_word < W_PRIRAM);
wire ld_pri  = ld_we && (ld_word >= W_PRIRAM)  && (ld_word < W_VREGS);
wire ld_vreg = ld_we && (ld_word >= W_VREGS)   && (ld_word < W_END);
wire [17:0] ld_rel = ld_word - (ld_tx ? 18'(W_TXRAM) : ld_bg ? 18'(W_BGRAM) : ld_roz ? 18'(W_ROZRAM) : ld_line ? 18'(W_LINERAM) :
                                ld_obj ? 18'(W_OBJRAM) : ld_pal ? 18'(W_PALRAM) : ld_pri ? 18'(W_PRIRAM) : 18'(W_VREGS));

///////////////////////   ROM STUBS   /////////////////////////////

// Until the SDRAM backend exists: a granule one clock after the request,
// with a pen pattern derived from the address so nothing downstream is
// optimised away.
`define ROM_STUB(REQ, ADDR, VALID, DATA) \
	always @(posedge clk_sys) begin \
		VALID <= REQ; \
		DATA  <= {8{ADDR[7:0] ^ ADDR[15:8] ^ ADDR[23:16]}}; \
	end

wire        tx_req, bg_req, roz_req, spr_req;
wire [23:0] tx_addr, bg_addr, roz_addr;
wire [27:0] spr_addr;
reg         tx_valid, bg_valid, roz_valid, spr_valid;
reg  [63:0] tx_data, bg_data, roz_data, spr_data;
`ROM_STUB(tx_req,  tx_addr,  tx_valid,  tx_data)
`ROM_STUB(bg_req,  bg_addr,  bg_valid,  bg_data)
`ROM_STUB(roz_req, roz_addr, roz_valid, roz_data)
`ROM_STUB(spr_req, spr_addr, spr_valid, spr_data)

///////////////////////   VIDEO   /////////////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

assign DDRAM_CLK = clk_sys;

ms32_video u_video (
	.clk(clk_sys), .reset(reset),
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
	.spr_frame_cycles(), .spr_drawn()
);

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
