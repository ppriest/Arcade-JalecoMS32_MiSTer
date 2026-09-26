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

// AUDIO_L/AUDIO_R come from the YMF271 (SOUND below). The mainboard's own
// output is mono (ms32.cpp header), so the OSD's Stereo Mix defaults to it:
// status 0 Mono (AUDIO_MIX 3), 1 None (0), 2 25% (1), 3 50% (2).
assign AUDIO_S = 1;
assign AUDIO_MIX = status[67:66] - 2'd1;

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

// The Debug page and Load capture are hidden in the release revision. Each of
// their lines carries an H1 prefix, so status_menumask bit 1 hides them all;
// the bits still work if a .CFG sets them, only the MENU goes away. DEBUG_ISSP is
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
	"O[67:66],Stereo Mix,Mono,None,25%,50%;",
	"-;",
	"O[94],CRT adjust,Off,On;",
	"H3O[99:95],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[106:100],CRT H-Position,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,+32,+33,+34,+35,+36,+37,+38,+39,+40,+41,+42,+43,+44,+45,+46,+47,+48,-48,-47,-46,-45,-44,-43,-42,-41,-40,-39,-38,-37,-36,-35,-34,-33,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"H3O[112:107],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,+15,+16,+17,+18,+19,+20,+21,+22,+23,+24,+25,+26,+27,+28,+29,+30,+31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	"-;",
	// capture playback is a development tool: in the menu of the stp build only
	"H1F2,BIN,Load capture;",
	"H1-;",
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
`ifdef F1SUPERB
	"H1P1O[85],Road layer,On,Off;",
`endif
	"-;",
	// Reset ahead of the joystick lines, as every other core here has it: after
	// them the OSD entry was shown but status[0] never rose (ISSP probe V)
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"J1,Button 1,Button 2,Button 3,Button 4,Button 5,Start,Coin,Pause,Service,Test;",
	"jn,A,B,X,Y,R,Start,Select,L;",
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
wire  [15:0] joy_analog_0;              // {y, x}, signed, for F-1 Super Battle's wheel

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
// A RAM dump rides the NVRAM upload (DEBUG_ISSP builds, JTAG source D bit
// 21): the .mra's <nvram size> decides how much the HPS takes and it lands in
// config/nvram, for SFTP. File layout, 128 KB slots: slot 0 the NVRAM (so the
// next launch loads a valid one back -- the loader takes the first 8 KB),
// slot k+1 video-RAM window region k, k = 0..7; 1,179,648 bytes in all.
// dumping holds from the request until the upload ends.
wire        dump_req;
wire        dbg_mem_en;
wire [3:0]  dbg_mem_reg;
wire [15:0] dbg_mem_addr;
wire [15:0] dbg_mem_data;
reg dumping = 1'b0, dump_d = 1'b0, dump_pulse = 1'b0, upl_d = 1'b0;
always @(posedge clk_sys) begin
	dump_d     <= dump_req;
	upl_d      <= ioctl_upload;
	dump_pulse <= dump_req && !dump_d;
	if (dump_req && !dump_d)        dumping <= 1'b1;
	else if (upl_d && !ioctl_upload) dumping <= 1'b0;
end
wire dump_win = dumping && ioctl_addr[20:17] != 4'd0;
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
	.status_menumask({12'd0, ~status[94], 1'b0, debug_menu_hide, 1'b0}),  // H1: the Debug page, H3: CRT adjust's settings

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	// the .mra's <nvram index="4">: downloaded after the ROM, uploaded when
	// nvram_save rises
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(nvram_save | dump_pulse),
	.ioctl_upload_index(8'd4),
	.ioctl_din(dump_win ? (ioctl_addr[0] ? dbg_mem_data[15:8] : dbg_mem_data[7:0]) : nv_rdata),
	.ioctl_rd(),

	.joystick_0(joystick_0),
	.joystick_l_analog_0(joy_analog_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

///////////////////////   CLOCKS   ///////////////////////////////

// ROADMAP "Clock plan": clk_sys 96 MHz for video, memory and sound; clk_cpu
// 20 MHz for the V70 (Phase 2); SDRAM_CLK is clk_sys shifted 180 degrees.
// One PLL, VCO 960 MHz; outclk_3, 960/17 = 56.47 MHz, is the YMF271's (ms32_sound).
wire clk_sys, clk_cpu, clk_sdram_shifted, clk_ymf, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_cpu),
	.outclk_2(clk_sdram_shifted),
	.outclk_3(clk_ymf),
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
`ifdef F1SUPERB
// f1superb has a second bank on the MB-93159 board (SW3, comms mode and car ID)
// at 0xFD0D0000, so its .mra sends eight switch bytes and bytes 4-7 are it.
reg [7:0] sw[8] = '{8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h00, 8'hFF, 8'hFF, 8'hFF};
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;
wire [31:0] dsw2 = {sw[7], sw[6], sw[5], sw[4]};
`else
wire [31:0] dsw2 = 32'hFFFF_FF00;   // unused: ms32_cpu_sys only reads it under F1SUPERB
reg [7:0] sw[4] = '{8'hFF, 8'hFF, 8'hFF, 8'hFF};
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254 && !ioctl_addr[24:2]) sw[ioctl_addr[1:0]] <= ioctl_dout;
`endif
wire [31:0] dsw = {sw[3], sw[2], sw[1], sw[0]};
// F-1 Super Battle's controls (ms32.cpp analog_r and the f1superb ports).
// The word at 0xFD0E0000 is {AN2, AN2, AN1 steering, AN0 accelerator}; the
// brake and the shifter are not analog at all, they are INPUTS bits 1 and 0.
//
//   AN0  the accelerator pot rests at 0x50 and falls towards 0 as it is
//        pressed -- the game takes the rest value at boot and subtracts.
//   AN1  steering, 0x80 centre, full lock 0x00 and 0xFF.
//   AN2  eight switches, all pulled up: MAME calls bit 7 "Shift Brake" and
//        does not know the rest. Left at 0xFF, as MAME leaves them.
//
// Unverified on hardware: nothing here has been tried on a DE10-nano yet.
wire signed [7:0] joy_x = joy_analog_0[7:0];
// The stick when it is off centre, otherwise the d-pad, which ramps towards
// lock while it is held and returns to centre when it is not -- steering that
// jumps to full lock is not steering. One step per frame-ish tick, ~0.9 s lock
// to lock; clk_sys/2^18 is about 366 Hz, so 128 steps is 0.35 s each way.
reg  [7:0] wheel_digital = 8'h80;
reg [17:0] wheel_tick = 18'd0;
always @(posedge clk_sys) begin
	wheel_tick <= wheel_tick + 18'd1;
	if (&wheel_tick) begin
		if (joystick_0[1] && wheel_digital != 8'h00) wheel_digital <= wheel_digital - 8'd1;        // left
		else if (joystick_0[0] && wheel_digital != 8'hFF) wheel_digital <= wheel_digital + 8'd1;   // right
		else if (!joystick_0[0] && !joystick_0[1])
			wheel_digital <= (wheel_digital > 8'h80) ? wheel_digital - 8'd1 :
			                 (wheel_digital < 8'h80) ? wheel_digital + 8'd1 : 8'h80;
	end
end
wire [7:0] analog_wheel = (joy_x != 8'sd0) ? (8'h80 + joy_x) : wheel_digital;
// The shifter is a two-position lever, so MAME gives it PORT_TOGGLE: one press
// of the button changes gear rather than holding it there.
reg shift_hi = 1'b0, shift_d = 1'b0;
always @(posedge clk_sys) begin
	shift_d <= joystick_0[6];
	if (joystick_0[6] && !shift_d) shift_hi <= ~shift_hi;
end
wire [7:0] analog_accel = joystick_0[4] ? 8'h00 : 8'h50;   // button 1, pressed falls to 0
wire [7:0] analog_an2   = 8'hFF;
wire       f1_brake     = joystick_0[5];                   // button 2, INPUTS bit 1

// ms32.cpp INPUTS at 0xFCC00004, active low. MiSTer joystick bits: 0 R, 1 L,
// 2 D, 3 U, then the J1 list from bit 4.
function automatic [7:0] player(input [31:0] j);
	player = ~{j[7], j[6], j[5], j[4], j[0], j[1], j[2], j[3]};   // B4 B3 B2 B1 right left down up
endfunction
wire mahjong = mod_byte[5];
reg  key_coin1 = 1'b0, key_coin2 = 1'b0;   // keyboard 5 and 6, MAME's coin keys, on every set (decoded below)
wire [31:0] inputs_std = {8'hFF,
                      ~joystick_1[8], ~joystick_0[8],                    // 23,22 button 5
                      ~joystick_1[9] | mahjong, ~joystick_0[9] | mahjong, // 21,20 start (in the key matrix on mahjong sets)
                      ~(joystick_0[13] | joystick_1[13]),                // 19 test
                      ~(joystick_0[12] | joystick_1[12]),                // 18 service
                      ~(joystick_1[10] | key_coin2), ~(joystick_0[10] | key_coin1), // 17,16 coin (joystick, or keyboard 6 / 5)
                      player(joystick_1) | {8{mahjong}}, player(joystick_0)};   // 15:8 unused on mahjong sets
`ifdef F1SUPERB
// f1superb keeps the coin, service, test and start bits and nothing else: bit 0
// is the shifter, bit 1 the brake, and 15:2 and 23:22 are unused.
wire [31:0] inputs = {8'hFF, 2'b11, inputs_std[21:16], 14'h3FFF, ~f1_brake, ~shift_hi};
`else
wire [31:0] inputs = inputs_std;
`endif

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
		8'h2E: key_coin1 <= ps2_key[9];  8'h36: key_coin2 <= ps2_key[9];
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

wire        z80_req, z80_valid, pcm_req, pcm_ack;
wire [21:0] pcm_addr;
wire [63:0] pcm_data;
wire [17:0] z80_addr;
wire  [7:0] z80_data;
wire        prg_req, tx_req, bg_req, roz_req, spr_req, gfx5_req, gfx5_valid;
wire [23:0] gfx5_addr;
wire [63:0] gfx5_data;
// F-1 Super Battle's road textures come from DDR3 (ms32_gfx5_ddr, a client
// of ms32_ddram_mux), not the SDRAM; held off while the ROM loader owns DDR3
wire        g_rd, g_ack, g_dout_ready;
wire [28:0] g_addr;
wire [15:0] dbg_road_over, dbg_fpu_runs, dbg_road_vw, dbg_road_lw, dbg_road_lines, dbg_road_pens;
wire [12:0] dbg_spr_flipx, dbg_spr_flipy, dbg_spr_drawn;
wire [15:0] dbg_fy_attr;
wire [11:0] dbg_fy_idx;
wire [9:0]  dbg_road_row;
wire [15:0] dbg_road_rowword, dbg_road_starty, dbg_road_offsy;
wire [19:0] dbg_fpu_max;
wire [127:0] dbg_fpu_cnt;
wire [63:0]  dbg_pass;
wire [15:0]  dbg_fpu_ovl;
wire [15:0]  dbg_chains;
wire [31:0]  dbg_pre;
wire [17:0] prg_addr;
wire [23:0] tx_addr, bg_addr, roz_addr;
wire [27:0] spr_addr;
wire        prg_valid, tx_valid, bg_valid, roz_valid, spr_valid;
wire [63:0] prg_data, tx_data, bg_data, roz_data, spr_data;
wire        sd_wait;
assign ioctl_wait = sd_wait | cap_wait;
wire        dbg_dl_req, dbg_dl_busy, dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz;
wire        dbg_spr_ovr_ev, dbg_fb_ovr_ev, dbg_roz_ovr_ev, dbg_road_ovr_ev, dbg_copy_done, core_vblank_ev;
wire        road_ovr;
wire [23:0] dbg_spr_cycles;
wire [15:0] dbg_ymf_wait_max, dbg_if_wait_max, dbg_ymf_overrun;

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

wire        obj_rreq, obj_rvalid, obj_wreq, obj_we16, obj_wbusy;
wire [12:0] obj_raddr;
wire [15:0] obj_waddr, obj_wdata;
wire [63:0] obj_rdata;

// reset & ~sd_dl: MiSTer holds RESET for the whole download, and a memory
// path gated by it never sees a byte (seta_sdram_top's header).
ms32_sdram_top u_sdram (
	.clk(clk_sys), .reset(reset & ~sd_dl), .init(~pll_locked),
	.SDRAM_A(SDRAM_A), .SDRAM_DQ(SDRAM_DQ), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE), .SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE), .SDRAM_CLK(),
	.ioctl_download(sd_dl), .ioctl_index(sd_index), .ioctl_wr(sd_wr),
	.ioctl_addr(sd_addr), .ioctl_dout(sd_dout), .ioctl_wait(sd_wait), .key(mod_byte[1:0]), .spr25(mod_byte[4]), .bigmap(mod_byte[6]),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.gfx5_req(gfx5_req), .gfx5_addr(gfx5_addr), .gfx5_valid(gfx5_valid), .gfx5_data(gfx5_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.if_req(prg_req), .if_addr(prg_addr), .if_valid(prg_valid), .if_data(prg_data),
	.z80_req(z80_req), .z80_addr(z80_addr), .z80_valid(z80_valid), .z80_data(z80_data),
	.ymf_req(pcm_req), .ymf_addr(pcm_addr), .ymf_ack(pcm_ack), .ymf_data(pcm_data),
	.obj_rreq(obj_rreq), .obj_raddr(obj_raddr), .obj_rvalid(obj_rvalid), .obj_rdata(obj_rdata),
	.obj_wreq(obj_wreq), .obj_waddr(obj_waddr), .obj_we16(obj_we16), .obj_wdata(obj_wdata), .obj_wbusy(obj_wbusy),
	.dbg_dl_req(dbg_dl_req), .dbg_dl_busy(dbg_dl_busy), .dbg_ymf_wait_max(dbg_ymf_wait_max), .dbg_if_wait_max(dbg_if_wait_max)
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
	.clk(clk_sys), .reset(~pll_locked), .bigmap(mod_byte[6]),
	.start(ldr_start), .active(ldr_active),
	.ddr_req(ldr_ddr_req), .ddr_addr(ldr_ddr_addr), .ddr_busy(ldr_ddr_busy), .ddr_valid(ldr_ddr_valid), .ddr_rdata(ldr_ddr_rdata),
	.l_wr(l_wr), .l_addr(l_addr), .l_dout(l_dout), .l_wait(sd_wait)
);

// The V70 runs once the ROM is in SDRAM (by either path) and nothing is
// loading, unless the mod byte holds it for capture playback; sys_reset leaves
// the bus side out of reset while a capture or NVRAM loads
// (ms32_capture_loader), and the fast load holds all of it.
wire core_run = ~reset & ~mod_byte[7] & ~ldr_active & (rom_loaded | ~dl0_seen);

// Pause: the J1 list's Pause (joystick bit 11) toggles it, from either
// joystick; a reset clears it. It suspends the main CPU only: the video keeps
// showing the frame and the sound board keeps running.
wire pause_btn = joystick_0[11] | joystick_1[11];
reg  pause_btn_d = 1'b0, pause_toggle = 1'b0;
always @(posedge clk_sys) begin
	pause_btn_d <= pause_btn;
	if (reset)                         pause_toggle <= 1'b0;
	else if (pause_btn & ~pause_btn_d) pause_toggle <= ~pause_toggle;
end
wire       snd_reset, snd_cmd_we, snd_tomain_we;
wire [7:0] snd_cmd_data, snd_tomain_data;

ms32_core u_core (
	.clk_sys(clk_sys), .clk_cpu(clk_cpu), .sys_reset(sys_reset | ldr_active),
	.cpu_run(core_run), .pause(pause_toggle), .invert_lines(mod_byte[2]),
	.inputs(inputs), .dsw(dsw), .mahjong(mahjong), .mj_keys(mj_keys),
	.analog_wheel(analog_wheel), .analog_accel(analog_accel), .analog_an2(analog_an2), .dsw2(dsw2),
	.gfx5_req(gfx5_req), .gfx5_addr(gfx5_addr), .gfx5_valid(gfx5_valid), .gfx5_data(gfx5_data),
	.g_rd(g_rd), .g_addr(g_addr), .g_ack(g_ack), .g_dout(c_dout), .g_dout_ready(g_dout_ready),
	.dbg_road_over(dbg_road_over), .dbg_road_vw(dbg_road_vw), .dbg_road_lw(dbg_road_lw), .dbg_road_lines(dbg_road_lines),
	.dbg_road_pens(dbg_road_pens), .dbg_spr_flipx(dbg_spr_flipx), .dbg_spr_flipy(dbg_spr_flipy),
	.dbg_spr_drawn(dbg_spr_drawn), .dbg_fy_attr(dbg_fy_attr), .dbg_fy_idx(dbg_fy_idx),
	.dbg_road_row(dbg_road_row), .dbg_road_rowword(dbg_road_rowword),
	.dbg_road_starty(dbg_road_starty), .dbg_road_offsy(dbg_road_offsy),
	.dbg_mem_en(dbg_mem_en), .dbg_mem_reg(dbg_mem_reg), .dbg_mem_addr(dbg_mem_addr), .dbg_mem_data(dbg_mem_data),
	.dbg_fpu_max(dbg_fpu_max), .dbg_fpu_runs(dbg_fpu_runs), .dbg_fpu_cnt(dbg_fpu_cnt), .dbg_pass(dbg_pass), .dbg_fpu_ovl(dbg_fpu_ovl), .dbg_chains(dbg_chains), .dbg_pre(dbg_pre),
	.nv_addr(ioctl_addr[12:0]), .nv_rdata(nv_rdata), .nv_written(nv_written),
	.snd_reset(snd_reset), .snd_cmd_we(snd_cmd_we), .snd_cmd_data(snd_cmd_data),
	.snd_tomain_we(snd_tomain_we), .snd_tomain_data(snd_tomain_data),
	.ld_req(ld_req), .ld_addr(ld_addr), .ld_be(ld_be), .ld_data(ld_data), .ld_ack(ld_ack),
	.prg_req(prg_req), .prg_addr(prg_addr), .prg_valid(prg_valid), .prg_data(prg_data),
	.tx_req(tx_req),   .tx_addr(tx_addr),   .tx_valid(tx_valid),   .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),   .bg_valid(bg_valid),   .bg_data(bg_data),
	.roz_req(roz_req), .roz_addr(roz_addr), .roz_valid(roz_valid), .roz_data(roz_data),
	.spr_req(spr_req), .spr_addr(spr_addr), .spr_valid(spr_valid), .spr_data(spr_data),
	.obj_rreq(obj_rreq), .obj_raddr(obj_raddr), .obj_rvalid(obj_rvalid), .obj_rdata(obj_rdata),
	.obj_wreq(obj_wreq), .obj_waddr(obj_waddr), .obj_we16(obj_we16), .obj_wdata(obj_wdata), .obj_wbusy(obj_wbusy),
	.DDRAM_BUSY(c_busy | ldr_active), .DDRAM_BURSTCNT(k_burstcnt), .DDRAM_ADDR(k_addr), .DDRAM_DOUT(c_dout),
	.DDRAM_DOUT_READY(c_dout_ready & ~ldr_active), .DDRAM_RD(k_rd), .DDRAM_DIN(k_din), .DDRAM_BE(k_be), .DDRAM_WE(k_we),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(core_vblank_ev),
	.dis_tx(status[81]), .dis_bg(status[82]), .dis_roz(status[83]), .dis_spr(status[84]), .dis_road(status[85]),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .road_overrun(road_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.dbg_roz_fill(dbg_roz_fill), .dbg_roz_hit(dbg_roz_hit), .dbg_roz_pen_nz(dbg_roz_pen_nz),
	.dbg_spr_ovr_ev(dbg_spr_ovr_ev), .dbg_fb_ovr_ev(dbg_fb_ovr_ev), .dbg_roz_ovr_ev(dbg_roz_ovr_ev), .dbg_road_ovr_ev(dbg_road_ovr_ev), .dbg_copy_done(dbg_copy_done), .dbg_spr_cycles(dbg_spr_cycles),
	.dbg_pc()
);

///////////////////////   SOUND   /////////////////////////////////

// The sound board, held in reset with the V70: the Z80 and the YMF271, whose
// sample ROM is the ymf region of ms32_sdram_top.
wire signed [15:0] snd_l, snd_r;
assign AUDIO_L = snd_l;
assign AUDIO_R = snd_r;
ms32_sound u_sound (
	.clk(clk_sys), .clk_ymf(clk_ymf), .reset(~core_run),
	.snd_reset(snd_reset), .cmd_we(snd_cmd_we), .cmd_data(snd_cmd_data),
	.to_main_we(snd_tomain_we), .to_main_data(snd_tomain_data),
	.rom_req(z80_req), .rom_addr(z80_addr), .rom_valid(z80_valid), .rom_data(z80_data),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_data(pcm_data),
	.audio_l(snd_l), .audio_r(snd_r), .dbg_ymf_overrun(dbg_ymf_overrun)
);

`ifdef DEBUG_ISSP
// A window on the video RAMs, read over JTAG by scripts/dump_ram.py: source
// [21:0] = {dump, enable, region[3:0], address[15:0]}, probe = the 16-bit word.
// Regions 0-7 are the video RAMs, 8 and 9 the two FPUs' data RAMs, 10 the FPU0 read log.
// scripts/render_model.py then renders the board's own RAM, which is the only
// way to tell "the RTL is wrong" from "the RAM is wrong". While the enable is
// held the read ports are taken over and the picture is garbage, so the game
// wants pausing first.
wire [21:0] memwin_src;
wire [3:0]  win_reg  = memwin_src[19:16];
wire [15:0] win_addr = memwin_src[15:0];
wire [3:0]  dump_slot = ioctl_addr[20:17] - 4'd1;
assign dump_req = memwin_src[21];
// While the HPS is streaming a dump out, the window follows the upload
// address instead of the one JTAG set (layout above: word in bits 16:1).
assign dbg_mem_en   = memwin_src[20] | dump_win;
assign dbg_mem_reg  = dump_win ? {1'b0, dump_slot[2:0]} : win_reg;
assign dbg_mem_addr = dump_win ? ioctl_addr[16:1] : win_addr;
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("D"),
	.probe_width(16), .source_width(22), .source_initial_value("0"),
	.enable_metastability("NO"), .lpm_type("altsource_probe")
) u_memwin (
	.probe(dbg_mem_data), .source(memwin_src), .source_clk(clk_sys), .source_ena(1'b1)
);
// JTAG counters for the memory path and the ROZ cache (rtl/debug/issp_probe.sv;
// read with scripts/read_issp.py, which holds the machine-wide JTAG lock).
// Not in the F-1 Super Battle build: half of it is the ROZ cache, which
// F1SUPERB replaces with line planes, and the download counters have done
// their job. That revision fills the device to 94% and the framework scaler's
// HDMI pixel clock is decided by the fitter seed at that point, so 118 ALMs is
// worth more here than counters nothing reads.
`ifndef F1SUPERB
issp_probe #(.INSTANCE_ID("M")) u_issp (
	.clk(clk_sys),
	.dl_byte(ioctl_download && ioctl_wr && ioctl_index == 16'd0), .dl_addr_lo(ioctl_addr[15:0]),
	.dl_req(dbg_dl_req), .dl_busy(dbg_dl_busy),
	.rom_valid(prg_valid | tx_valid | bg_valid | roz_valid | spr_valid),
	.ioctl_wait(ioctl_wait), .ioctl_download(ioctl_download), .pll_locked(pll_locked),
	.roz_fill(dbg_roz_fill), .roz_hit(dbg_roz_hit), .roz_pen_nz(dbg_roz_pen_nz)
);
`endif
// the video engines' time: which have overrun, how often, and the margins
issp_video_probe #(.INSTANCE_ID("V")) u_issp_v (
	.clk(clk_sys),
	.flags({rot_overflow, bad_pm, fb_ovr, spr_ovr, roz_ovr, bg_ovr, tx_ovr}),
	.vblank_ev(core_vblank_ev), .spr_ovr_ev(dbg_spr_ovr_ev), .fb_ovr_ev(dbg_fb_ovr_ev), .roz_ovr_ev(dbg_roz_ovr_ev),
	.copy_done(dbg_copy_done), .spr_frame_cycles(dbg_spr_cycles),
	.ymf_overrun(dbg_ymf_overrun), .ymf_wait_max(dbg_ymf_wait_max), .if_wait_max(dbg_if_wait_max),
	.road_over(dbg_road_over), .road_ovr(road_ovr), .road_ovr_ev(dbg_road_ovr_ev),
	.fpu_max(dbg_fpu_max), .fpu_runs(dbg_fpu_runs),
	.road_vw(dbg_road_vw), .road_lw(dbg_road_lw), .road_lines(dbg_road_lines),
	.road_pens(dbg_road_pens), .spr_flipx(dbg_spr_flipx), .spr_flipy(dbg_spr_flipy),
	.spr_drawn(dbg_spr_drawn), .fy_attr(dbg_fy_attr), .fy_idx(dbg_fy_idx),
	.road_row(dbg_road_row), .road_rowword(dbg_road_rowword),
	.road_starty(dbg_road_starty), .road_offsy(dbg_road_offsy)
);
// F-1 Super Battle, per FPU, since reset (clk_cpu, wrapping; ms32_cpu_sys),
// read with scripts/read_issp.py. A second instance: one is capped at 511 bits.
//   [15:0] FPU0 host reads   [31:16] FPU0 host writes
//   [47:32] FPU1 host reads  [63:48] FPU1 host writes
//   [79:64] FPU0 irqs raised [95:80] FPU1 irqs raised
//   [111:96] FPU0 starts     [127:112] FPU1 starts
// and per field pass (ms32_cpu_sys dbg_pass):
//   [135:128] lowest road line written in the last pass  [143:136] highest
//   [159:144] road line RAM writes in the last pass
//   [175:160] writes to FEE10000 (the main loop's idle flag)  [191:176] field events
//   [207:192] V70 data/register writes that land while FPU0 runs a routine
//   [223:208] FPU0 chains started (PC writes of 0x338; read log in window region 10)
//   [239:224] hash of FPU0 writes before chain 0   [255:240] their count
altsource_probe #(
	.sld_auto_instance_index("YES"), .instance_id("F"),
	.probe_width(256), .source_width(1), .source_initial_value("0"),
	.enable_metastability("NO"), .lpm_type("altsource_probe")
) u_issp_f (
	.probe({dbg_pre, dbg_chains, dbg_fpu_ovl, dbg_pass, dbg_fpu_cnt}), .source(), .source_clk(clk_sys), .source_ena(1'b1)
);
`else
assign dump_req = 1'b0;
assign dbg_mem_en = 1'b0;
assign dbg_mem_reg = 4'd0;
assign dbg_mem_addr = 16'd0;
`endif

// CRT adjust (rtl/video/ms32_crt.sv): H-Size, H-Position, V-Shift on the
// output, not on the rotated HDMI copy below; out of the path when it is off
// or the scandoubler runs.
wire [7:0] crt_r, crt_g, crt_b;
wire       crt_hs, crt_vs, crt_hb, crt_vb, crt_on, crt_ce;
ms32_crt u_crt (
	.clk(clk_sys), .ce(ce_pix),
	.adjust(status[94] & ~forced_scandoubler),
	.hsize_idx(status[99:95]), .hpos_idx(status[106:100]), .vshift_idx(status[112:107]),
	.r_in(r), .g_in(g), .b_in(b),
	.hs_in(hsync), .vs_in(vsync), .hb_in(hblank), .vb_in(vblank),
	.active(crt_on), .ce_out(crt_ce),
	.r_out(crt_r), .g_out(crt_g), .b_out(crt_b),
	.hs_out(crt_hs), .vs_out(crt_vs), .hb_out(crt_hb), .vb_out(crt_vb)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = crt_on ? crt_ce : ce_pix;
assign VGA_DE = crt_on ? ~(crt_hb | crt_vb) : ~(hblank | vblank);
assign VGA_HS = crt_on ? crt_hs : hsync;
assign VGA_VS = crt_on ? crt_vs : vsync;
assign VGA_R  = crt_on ? crt_r  : r;
assign VGA_G  = crt_on ? crt_g  : g;
assign VGA_B  = crt_on ? crt_b  : b;

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
	.CLK_VIDEO(clk_sys), .CE_PIXEL(ce_pix),   // the native raster, whatever CRT adjust does
	.VGA_R(r), .VGA_G(g), .VGA_B(b), .VGA_HS(hsync), .VGA_VS(vsync), .VGA_DE(~(hblank | vblank)),
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
	.g_rd(g_rd & ~ldr_active), .g_addr(g_addr), .g_ack(g_ack), .g_dout_ready(g_dout_ready),
	.fifo_overflow(rot_overflow)
);

// An engine that could not keep up, or a lost rotated pixel, lights the LED:
// the sticky flags are the first thing to read on a wrong picture
// (docs/phase1_video.md).
assign LED_USER = tx_ovr | bg_ovr | roz_ovr | spr_ovr | fb_ovr | bad_pm | rot_overflow;

endmodule
