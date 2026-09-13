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

// ROTATION (HDMI, through screen_rotate_two). Auto follows the set's ROT from
// the mod byte (bit 3: ROT270, desertwr and gametngk), which wants the picture
// turned counter-clockwise to stand upright. The explicit settings are for a
// monitor that is already turned. Flip 180 turns the OUTPUT round; it is not
// the games' Flip Screen DIP (sysctrl control bit 1), which is not implemented.
wire       game_vertical;
wire [1:0] rot_sel    = status[64:63];
wire       rotate_en  = (rot_sel == 2'd0) ? game_vertical : (rot_sel != 2'd1);
wire       rotate_ccw = (rot_sel == 2'd0) ? game_vertical : (rot_sel == 2'd3);
wire       flip_180   = status[65];

// the physical screen is 4:3; turned to portrait it is 3:4
assign VIDEO_ARX = (!ar) ? (rotate_en ? 12'd3 : 12'd4) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (rotate_en ? 12'd4 : 12'd3) : 12'd0;
assign FB_FORCE_BLANK = 0;

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
	"O[64:63],Rotation,Auto,Off,CW,CCW;",
	"O[65],Flip 180,Off,On;",
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
wire        ioctl_upload;
wire  [7:0] nv_rdata;
wire        nv_written;

// NVRAM SAVE. The core cannot write the SD card itself; it asks the HPS to
// read the NVRAM back into the .mra's <nvram> file. It asks when the OSD
// opens, if the game has written NVRAM since the last save -- the usual
// shape for arcade cores, and no game knowledge is needed.
reg nvram_dirty = 1'b0, nvram_save = 1'b0, osd_d = 1'b0;
always @(posedge clk_sys) begin
	osd_d <= OSD_STATUS;
	nvram_save <= 1'b0;
	if (nv_written) nvram_dirty <= 1'b1;
	if (OSD_STATUS && !osd_d && nvram_dirty) begin
		nvram_save  <= 1'b1;
		nvram_dirty <= 1'b0;
	end
end

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

	// the .mra's <nvram index="4">: downloaded after the ROM, uploaded when
	// nvram_save rises
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save),
	.ioctl_upload_index(8'd4),
	.ioctl_din(nv_rdata),
	.ioctl_rd(),

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
// bit 2 ms32_invert_lines (tp2m32, wpksocv2); bit 3 the set is ROT270;
// bit 4 the 25-bit sprite address mask (bbbxing's 17 MB sprite ROM);
// bit 5 mahjong inputs (the ms32_mahjong port: suchie2, akiss, kirarast, bnstars);
// bit 7 holds the V70 in reset (capture playback .mra files).
reg [7:0] mod_byte = 8'd0;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_byte <= ioctl_dout;
assign game_vertical = mod_byte[3];

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
wire mahjong = mod_byte[5];
wire [31:0] inputs = {8'hFF,
                      ~joystick_1[8], ~joystick_0[8],                    // 23,22 button 5
                      ~joystick_1[9] | mahjong, ~joystick_0[9] | mahjong, // 21,20 start (in the key matrix on mahjong sets)
                      ~(joystick_0[13] | joystick_1[13]),                // 19 test
                      ~(joystick_0[12] | joystick_1[12]),                // 18 service
                      ~joystick_1[10], ~joystick_0[10],                  // 17,16 coin
                      player(joystick_1) | {8{mahjong}}, player(joystick_0)};   // 15:8 unused on mahjong sets

// Mahjong panel (ms32.cpp ms32_mahjong, mahjong.cpp mahjong_matrix_1p) from a
// PS/2 keyboard with MAME's default keys: A-N, Kan LCtrl, Pon LAlt, Chi Space,
// Reach LShift, Ron Z, Start 1 (or joystick Start). ps2_key: [10] toggles per
// event, [9] pressed, [8] extended, [7:0] set 2 scancode.
reg  [19:0] mjk = 20'd0;   // A..N (14), Kan, Pon, Chi, Reach, Ron, Start
reg         ps2_tog = 1'b0;
always @(posedge clk_sys) begin
	ps2_tog <= ps2_key[10];
	if (ps2_key[10] != ps2_tog && !ps2_key[8]) case (ps2_key[7:0])
		8'h1C: mjk[0]  <= ps2_key[9];  8'h32: mjk[1]  <= ps2_key[9];  8'h21: mjk[2]  <= ps2_key[9];
		8'h23: mjk[3]  <= ps2_key[9];  8'h24: mjk[4]  <= ps2_key[9];  8'h2B: mjk[5]  <= ps2_key[9];
		8'h34: mjk[6]  <= ps2_key[9];  8'h33: mjk[7]  <= ps2_key[9];  8'h43: mjk[8]  <= ps2_key[9];
		8'h3B: mjk[9]  <= ps2_key[9];  8'h42: mjk[10] <= ps2_key[9];  8'h4B: mjk[11] <= ps2_key[9];
		8'h3A: mjk[12] <= ps2_key[9];  8'h31: mjk[13] <= ps2_key[9];
		8'h14: mjk[14] <= ps2_key[9];  8'h11: mjk[15] <= ps2_key[9];  8'h29: mjk[16] <= ps2_key[9];
		8'h12: mjk[17] <= ps2_key[9];  8'h1A: mjk[18] <= ps2_key[9];  8'h16: mjk[19] <= ps2_key[9];
		default: ;
	endcase
end
wire mj_start = mjk[19] | joystick_0[9];
// rows KEY0..KEY4, bits 0..5, active low
wire [29:0] mj_keys = ~{6'd0,                                                 // KEY4
                        2'b00, mjk[15], mjk[11], mjk[7],  mjk[3],             // KEY3: D H L Pon
                        1'b0,  mjk[18], mjk[16], mjk[10], mjk[6],  mjk[2],    // KEY2: C G K Chi Ron
                        1'b0,  mjk[17], mjk[13], mjk[9],  mjk[5],  mjk[1],    // KEY1: B F J N Reach
                        mj_start, mjk[14], mjk[12], mjk[8], mjk[4], mjk[0]};  // KEY0: A E I M Kan Start

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

wire        z80_req, z80_valid;
wire [17:0] z80_addr;
wire  [7:0] z80_data;
wire        prg_req, tx_req, bg_req, roz_req, spr_req;
wire [17:0] prg_addr;
wire [23:0] tx_addr, bg_addr, roz_addr;
wire [27:0] spr_addr;
wire        prg_valid, tx_valid, bg_valid, roz_valid, spr_valid;
wire [63:0] prg_data, tx_data, bg_data, roz_data, spr_data;
wire        sd_wait;
assign ioctl_wait = sd_wait | cap_wait;
wire        dbg_dl_req, dbg_dl_busy, dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz;

// FAST ROM LOAD. The .mra's <rom index="0" address="0x30000000"> makes the HPS
// write the image straight into DDR3: the download then has no ioctl_wr at
// all, and ms32_rom_loader replays the image from DDR3 into the download port
// below with the core held. An .mra without the attribute (the capture ones)
// streams bytes as before; which one ran is told by whether any byte arrived.
// A copy is due once per index-0 download, after reset releases (MiSTer
// resets the core when the ROM is in place); later resets do not repeat it.
// (After Seta.sv's, from Fuuki.)
wire        ldr_active, l_wr;
wire [26:0] l_addr;
wire  [7:0] l_dout;
reg  dl0_d = 1'b0, dl_seen_wr = 1'b0, ldr_pending = 1'b0, ldr_start = 1'b0, ldr_done = 1'b0;
reg  rom_loaded = 1'b0, ldr_active_d = 1'b0;
wire dl0 = ioctl_download && (ioctl_index == 16'd0);
// an index-0 download has happened since configuration (the capture-only launcher has none)
reg dl0_seen = 1'b0;
always @(posedge clk_sys) if (dl0) dl0_seen <= 1'b1;
always @(posedge clk_sys) begin
	ldr_start    <= 1'b0;
	dl0_d        <= dl0;
	ldr_active_d <= ldr_active;
	if (dl0 && !dl0_d)          begin dl_seen_wr <= 1'b0; ldr_done <= 1'b0; rom_loaded <= 1'b0; end
	else if (dl0 && ioctl_wr)   dl_seen_wr <= 1'b1;
	if (dl0_d && !dl0 && dl_seen_wr)    rom_loaded <= 1'b1;   // the byte path wrote SDRAM
	if (ldr_active_d && !ldr_active)    rom_loaded <= 1'b1;   // the copy finished
	if (reset) ldr_pending <= 1'b1;
	else if (ldr_pending && !ioctl_download && !ldr_active) begin
		ldr_pending <= 1'b0;
		if (!dl_seen_wr && !ldr_done && dl0_seen) begin ldr_start <= 1'b1; ldr_done <= 1'b1; end
	end
end

// the download port the SDRAM sees: the HPS's bytes, or the loader's
wire        sd_dl    = ioctl_download | ldr_active;
wire [15:0] sd_index = ldr_active ? 16'd0  : ioctl_index;
wire        sd_wr    = ldr_active ? l_wr   : ioctl_wr;
wire [26:0] sd_addr  = ldr_active ? l_addr : ioctl_addr;
wire  [7:0] sd_dout  = ldr_active ? l_dout : ioctl_dout;

// reset & ~sd_dl: MiSTer holds RESET for the whole download, and a memory
// path gated by it never sees a byte (seta_sdram_top's header).
ms32_sdram_top u_sdram (
	.clk(clk_sys), .reset(reset & ~sd_dl), .init(~pll_locked),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(),
	.ioctl_download(sd_dl), .ioctl_index(sd_index), .ioctl_wr(sd_wr),
	.ioctl_addr(sd_addr), .ioctl_dout(sd_dout), .ioctl_wait(sd_wait), .key(mod_byte[1:0]), .spr25(mod_byte[4]),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.if_req(prg_req), .if_addr(prg_addr), .if_valid(prg_valid), .if_data(prg_data),
	.cpu_req(1'b0), .cpu_addr(21'd0), .cpu_valid(), .cpu_data(),
	.z80_req(z80_req), .z80_addr(z80_addr), .z80_valid(z80_valid), .z80_data(z80_data),
	.dbg_dl_req(dbg_dl_req), .dbg_dl_busy(dbg_dl_busy)
);

///////////////////////   VIDEO   /////////////////////////////////

wire        ce_pix, hblank, vblank, hsync, vsync;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;

assign DDRAM_CLK = clk_sys;

// the core's side of the DDRAM port (c_*), which ms32_ddram_mux shares with
// the rotator; during a fast load the loader's ddram_phy has it instead of
// the video path (k_*), which is held in reset
wire        c_busy, c_rd, c_we, c_dout_ready;
wire [7:0]  c_burstcnt, c_be;
wire [28:0] c_addr;
wire [63:0] c_din, c_dout;
wire        k_rd, k_we;
wire [7:0]  k_burstcnt, k_be;
wire [28:0] k_addr;
wire [63:0] k_din;
wire        p_rd, p_we;
wire [7:0]  p_burstcnt, p_be;
wire [28:0] p_addr;
wire [63:0] p_din;
assign c_rd       = ldr_active ? p_rd       : k_rd;
assign c_we       = ldr_active ? p_we       : k_we;
assign c_burstcnt = ldr_active ? p_burstcnt : k_burstcnt;
assign c_be       = ldr_active ? p_be       : k_be;
assign c_addr     = ldr_active ? p_addr     : k_addr;
assign c_din      = ldr_active ? p_din      : k_din;

wire        ldr_ddr_req, ldr_ddr_busy, ldr_ddr_valid;
wire [27:0] ldr_ddr_addr;
wire [63:0] ldr_ddr_rdata;
ddram_phy u_ldr_ddram (
	.clk(clk_sys), .reset(~ldr_active),
	.DDRAM_BUSY(c_busy), .DDRAM_BURSTCNT(p_burstcnt), .DDRAM_ADDR(p_addr), .DDRAM_DOUT(c_dout),
	.DDRAM_DOUT_READY(c_dout_ready), .DDRAM_RD(p_rd), .DDRAM_DIN(p_din), .DDRAM_BE(p_be), .DDRAM_WE(p_we),
	.req(ldr_ddr_req), .we(1'b0), .addr(ldr_ddr_addr), .wdata(8'd0),
	.busy(ldr_ddr_busy), .valid(ldr_ddr_valid), .rdata(ldr_ddr_rdata)
);
ms32_rom_loader u_ldr (
	.clk(clk_sys), .reset(~pll_locked),
	.start(ldr_start), .active(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy), .ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.l_wr(l_wr), .l_addr(l_addr), .l_dout(l_dout), .l_wait(sd_wait)
);

// The V70 runs once the ROM is in SDRAM (by either path) and nothing is
// loading, unless the mod byte holds it for capture playback; sys_reset leaves
// the bus side out of reset while a capture or NVRAM loads
// (ms32_capture_loader), and the fast load holds all of it.
wire core_run = ~reset & ~mod_byte[7] & ~ldr_active & (rom_loaded | ~dl0_seen);
wire       snd_reset, snd_cmd_we, snd_tomain_we;
wire [7:0] snd_cmd_data, snd_tomain_data;

ms32_core u_core (
	.clk_sys(clk_sys), .clk_cpu(clk_cpu), .sys_reset(sys_reset | ldr_active),
	.cpu_run(core_run), .invert_lines(mod_byte[2]),
	.inputs(inputs), .dsw(dsw), .mahjong(mahjong), .mj_keys(mj_keys),
	.nv_addr(ioctl_addr[12:0]), .nv_rdata(nv_rdata), .nv_written(nv_written),
	.snd_reset(snd_reset), .snd_cmd_we(snd_cmd_we), .snd_cmd_data(snd_cmd_data),
	.snd_tomain_we(snd_tomain_we), .snd_tomain_data(snd_tomain_data),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack),
	.prg_req(prg_req), .prg_addr(prg_addr), .prg_valid(prg_valid), .prg_data(prg_data),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.DDRAM_BUSY(c_busy | ldr_active), .DDRAM_BURSTCNT(k_burstcnt), .DDRAM_ADDR(k_addr), .DDRAM_DOUT(c_dout),
	.DDRAM_DOUT_READY(c_dout_ready & ~ldr_active), .DDRAM_RD(k_rd), .DDRAM_DIN(k_din), .DDRAM_BE(k_be), .DDRAM_WE(k_we),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(),
	.dis_tx(status[81]), .dis_bg(status[82]), .dis_roz(status[83]), .dis_spr(status[84]),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.dbg_roz_fill(dbg_roz_fill), .dbg_roz_hit(dbg_roz_hit), .dbg_roz_pen_nz(dbg_roz_pen_nz), .dbg_pc()
);

///////////////////////   SOUND   /////////////////////////////////

// The Z80 side of the sound board; held in reset with the V70. The YMF271's
// synthesis is not in yet (docs/ROADMAP.md, "The YMF271"), so AUDIO stays 0.
ms32_sound u_sound (
	.clk(clk_sys), .reset(~core_run),
	.snd_reset(snd_reset), .cmd_we(snd_cmd_we), .cmd_data(snd_cmd_data),
	.to_main_we(snd_tomain_we), .to_main_data(snd_tomain_data),
	.rom_req(z80_req), .rom_addr(z80_addr), .rom_valid(z80_valid), .rom_data(z80_data),
	.ymf_wr(), .ymf_addr(), .ymf_wdata()
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

///////////////////////   HDMI ROTATION   /////////////////////////

// A tap on the final output: the analog output keeps the native raster, a
// rotated or flipped copy goes into DDR3 and the HPS framebuffer shows it.
// Its writes share the DDRAM port with the core through ms32_ddram_mux,
// which queues them (the rotator does not honour DDRAM_BUSY).
wire        r_we, r_rd, rot_overflow;
wire [7:0]  r_burstcnt, r_be;
wire [28:0] r_addr;
wire [63:0] r_din;
screen_rotate_two screen_rotate_two (
	.CLK_VIDEO(CLK_VIDEO), .CE_PIXEL(CE_PIXEL),
	.VGA_R(VGA_R), .VGA_G(VGA_G), .VGA_B(VGA_B), .VGA_HS(VGA_HS), .VGA_VS(VGA_VS), .VGA_DE(VGA_DE),
	.rotate_ccw(rotate_ccw), .no_rotate(~rotate_en), .flip(flip_180), .two_screen(1'b0), .video_rotated(),
	.FB_EN(FB_EN), .FB_FORMAT(FB_FORMAT), .FB_WIDTH(FB_WIDTH), .FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE), .FB_STRIDE(FB_STRIDE), .FB_VBL(FB_VBL), .FB_LL(FB_LL),
	.DDRAM_CLK(), .DDRAM_BUSY(1'b0), .DDRAM_BURSTCNT(r_burstcnt), .DDRAM_ADDR(r_addr), .DDRAM_DIN(r_din),
	.DDRAM_BE(r_be), .DDRAM_WE(r_we), .DDRAM_RD(r_rd)
);

ms32_ddram_mux u_ddram_mux (
	.clk(clk_sys), .reset(1'b0),
	.c_busy(c_busy), .c_burstcnt(c_burstcnt), .c_addr(c_addr), .c_dout(c_dout), .c_dout_ready(c_dout_ready),
	.c_rd(c_rd), .c_din(c_din), .c_be(c_be), .c_we(c_we),
	.r_addr(r_addr), .r_din(r_din), .r_be(r_be), .r_we(r_we),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.fifo_overflow(rot_overflow)
);

// An engine that could not keep up, or a lost rotated pixel, lights the LED:
// the sticky flags are the first thing to read on a wrong picture
// (docs/phase1_video.md).
assign LED_USER = tx_ovr | bg_ovr | roz_ovr | spr_ovr | fb_ovr | bad_pm | rot_overflow;

endmodule
