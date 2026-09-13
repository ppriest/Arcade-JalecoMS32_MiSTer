// SPDX-License-Identifier: GPL-3.0-or-later
//
// The MS32 video path: CRTC, TX/BG/ROZ line engines, object RAM with its
// vblank copy, the zoom sprite engine and its DDR3 frame buffer, and the
// mixer with palette and brightness. Every video RAM lives here with a
// CPU-side write port; the tile and sprite ROMs are req/valid ports the
// SDRAM backend serves; the frame buffer's DDRAM port goes straight to the
// top level.
//
// The RAMs are dual-clock (dpram_dc): the CPU port reads and writes on
// cpu_clk (ms32_cpu_sys), the engines read on clk. Registers arrive already
// in clk, through ms32_cpu_sys's mailbox.
//
// Register writes arrive as (vreg_we, vreg_off, vreg_data): vreg_off is
// the byte offset inside the 0xFCE00000 block and vreg_data the low
// halfword the CPU wrote (every register here is 16-bit behind umask32):
//   0x000-0x011  sysctrl CRTC (ms32_crtc)         0x200-0x27F  sprite control
//   0x280/0x284  brightness                       0x600-0x65F  ROZ control
//   0xA00-0xA17  TX scroll   0xA20-0xA37 BG scroll   0xA7C bgmode
//
// Dot timing: ce_pix marks the end of dot (hcnt, vcnt); r/g/b, blanking
// and syncs describe that dot on the ce_pix clock, which is what the top
// level hands to the framework as CE_PIXEL.
module ms32_video (
	input  logic        clk,
	input  logic        reset,

	// registers
	input  logic        vreg_we,
	input  logic [11:0] vreg_off,
	input  logic [15:0] vreg_data,

	// CPU ports of the RAMs, on cpu_clk: u16 (or u8 for priority) index within
	// the region, byte-lane write enables, one-clock synchronous read
	input  logic        cpu_clk,
	input  logic [15:0] cpu_wdata,
	input  logic [12:0] txram_addr,   input logic txram_wel,   input logic txram_weh,   output logic [15:0] txram_rdata,
	input  logic [12:0] bgram_addr,   input logic bgram_wel,   input logic bgram_weh,   output logic [15:0] bgram_rdata,
	input  logic [14:0] rozram_addr,  input logic rozram_wel,  input logic rozram_weh,  output logic [15:0] rozram_rdata,
	input  logic [10:0] lineram_addr, input logic lineram_wel, input logic lineram_weh, output logic [15:0] lineram_rdata,
	input  logic [14:0] objram_addr,  input logic objram_wel,  input logic objram_weh,  output logic [15:0] objram_rdata,
	input  logic [15:0] palram_addr,  input logic palram_wel,  input logic palram_weh,  output logic [15:0] palram_rdata,
	input  logic [12:0] priram_addr,  input logic priram_we,                             output logic [7:0]  priram_rdata,

	// tile ROMs, region-local byte addresses, 8-byte granules
	output logic        tx_rom_req,  output logic [23:0] tx_rom_addr,  input logic tx_rom_valid,  input logic [63:0] tx_rom_data,
	output logic        bg_rom_req,  output logic [23:0] bg_rom_addr,  input logic bg_rom_valid,  input logic [63:0] bg_rom_data,
	output logic        roz_rom_req, output logic [23:0] roz_rom_addr, input logic roz_rom_valid, input logic [63:0] roz_rom_data,
	output logic        spr_rom_req, output logic [27:0] spr_rom_addr, input logic spr_rom_valid, input logic [63:0] spr_rom_data,

	// sprite frame buffer
	input  logic        DDRAM_BUSY,
	output logic [7:0]  DDRAM_BURSTCNT,
	output logic [28:0] DDRAM_ADDR,
	input  logic [63:0] DDRAM_DOUT,
	input  logic        DDRAM_DOUT_READY,
	output logic        DDRAM_RD,
	output logic [63:0] DDRAM_DIN,
	output logic [7:0]  DDRAM_BE,
	output logic        DDRAM_WE,

	// video out
	output logic        ce_pix,
	output logic        hblank, vblank, hsync, vsync,
	output logic [7:0]  r, g, b,

	// events for the interrupt controller
	output logic        vblank_ev,
	output logic        field_ev,
	output logic        timer_enable,

	// OSD
	input  logic        dis_tx, dis_bg, dis_roz, dis_spr,

	// debug
	output logic        tx_overrun, bg_overrun, roz_overrun, spr_overrun, fb_overrun, bad_primask,
	output logic [23:0] spr_frame_cycles,
	output logic [12:0] spr_drawn,
	output logic        dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz
);

	// ------------------------------------------------------------ registers
	logic [15:0] tx_scroll [0:5];
	logic [15:0] bg_scroll [0:5];
	logic [15:0] roz_ctrl  [0:23];
	logic [15:0] spr_ctrl10;
	logic [15:0] brt0, brt1;
	logic        bgmode;
	always_ff @(posedge clk) begin
		if (reset) begin
			bgmode <= 1'b0; brt0 <= 16'd0; brt1 <= 16'd0; spr_ctrl10 <= 16'd0;
		end else if (vreg_we) begin
			if (vreg_off[11:5] == 7'b1010_000 && vreg_off[4:2] < 3'd6) tx_scroll[vreg_off[4:2]] <= vreg_data;   // 0xA00-0xA17
			if (vreg_off[11:5] == 7'b1010_001 && vreg_off[4:2] < 3'd6) bg_scroll[vreg_off[4:2]] <= vreg_data;   // 0xA20-0xA37
			if (vreg_off == 12'hA7C) bgmode <= vreg_data[0];
			if (vreg_off[11:7] == 5'b01100 && vreg_off[6:2] < 5'd24) roz_ctrl[vreg_off[6:2]] <= vreg_data;   // 0x600-0x65F
			if (vreg_off == 12'h210) spr_ctrl10 <= vreg_data;
			if (vreg_off == 12'h280) brt0 <= vreg_data;
			if (vreg_off == 12'h284) brt1 <= vreg_data;
		end
	end
	wire crtc_we = vreg_we && (vreg_off[11:6] == 6'd0) && (vreg_off[5:2] <= 4'd8);

	// ------------------------------------------------------------------ CRTC
	logic [11:0] hcnt, vcnt, vcnt_next, vcnt_next2, hdisplay, vdisplay;
	logic        h_active, v_active, line_start;
	ms32_crtc u_crtc (
		.clk(clk), .reset(reset),
		.reg_we(crtc_we), .reg_off(vreg_off[5:2]), .reg_data(vreg_data),
		.ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
		.h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_odd(), .vblank_ev(vblank_ev), .field_ev(field_ev),
		.flip(), .timer_enable(timer_enable), .hdisplay_o(hdisplay), .vdisplay_o(vdisplay)
	);
	wire fetch_active = (vcnt_next2 < vdisplay);

	// ------------------------------------------------------------ tile RAMs
	logic [12:0] tx_va, bg_va;
	logic [14:0] roz_va;
	logic [10:0] roz_la;
	logic [15:0] tx_vd, bg_vd, roz_vd, roz_ld;
	dpram_dc #(.ADDR_WIDTH(13)) u_txram (.clk_a(cpu_clk), .a_addr(txram_addr), .a_wel(txram_wel), .a_weh(txram_weh), .a_wdata(cpu_wdata), .a_rdata(txram_rdata),
		.clk_b(clk), .b_addr(tx_va), .b_re(1'b1), .b_rdata(tx_vd));
	dpram_dc #(.ADDR_WIDTH(13)) u_bgram (.clk_a(cpu_clk), .a_addr(bgram_addr), .a_wel(bgram_wel), .a_weh(bgram_weh), .a_wdata(cpu_wdata), .a_rdata(bgram_rdata),
		.clk_b(clk), .b_addr(bg_va), .b_re(1'b1), .b_rdata(bg_vd));
	dpram_dc #(.ADDR_WIDTH(15)) u_rozram (.clk_a(cpu_clk), .a_addr(rozram_addr), .a_wel(rozram_wel), .a_weh(rozram_weh), .a_wdata(cpu_wdata), .a_rdata(rozram_rdata),
		.clk_b(clk), .b_addr(roz_va), .b_re(1'b1), .b_rdata(roz_vd));
	dpram_dc #(.ADDR_WIDTH(11)) u_lineram (.clk_a(cpu_clk), .a_addr(lineram_addr), .a_wel(lineram_wel), .a_weh(lineram_weh), .a_wdata(cpu_wdata), .a_rdata(lineram_rdata),
		.clk_b(clk), .b_addr(roz_la), .b_re(1'b1), .b_rdata(roz_ld));

	// ---------------------------------------------------------- tile engines
	logic [7:0] tx_pen, bg_pen, roz_pen;
	logic [3:0] tx_col, bg_col, roz_col;
	logic       tx_op, bg_op, roz_op;

	ms32_tilemap #(.TILE_16(1'b0)) u_tx (
		.clk(clk), .reset(reset),
		.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
		.scrollx(tx_scroll[0] + tx_scroll[2] + 16'h18), .scrolly(tx_scroll[3] + tx_scroll[5]), .bgmode(1'b0),
		.vram_addr(tx_va), .vram_data(tx_vd),
		.rom_req(tx_rom_req), .rom_addr(tx_rom_addr), .rom_valid(tx_rom_valid), .rom_data(tx_rom_data),
		.pen(tx_pen), .colour(tx_col), .opaque(tx_op), .fetch_overrun(tx_overrun), .overrun_ev()
	);
	ms32_tilemap #(.TILE_16(1'b1)) u_bg (
		.clk(clk), .reset(reset),
		.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
		.scrollx(bg_scroll[0] + bg_scroll[2] + 16'h10), .scrolly(bg_scroll[3] + bg_scroll[5]), .bgmode(bgmode),
		.vram_addr(bg_va), .vram_data(bg_vd),
		.rom_req(bg_rom_req), .rom_addr(bg_rom_addr), .rom_valid(bg_rom_valid), .rom_data(bg_rom_data),
		.pen(bg_pen), .colour(bg_col), .opaque(bg_op), .fetch_overrun(bg_overrun), .overrun_ev()
	);
	ms32_roz u_roz (
		.clk(clk), .reset(reset),
		.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
		.startx({roz_ctrl[1][1:0], roz_ctrl[0]}), .starty({roz_ctrl[3][1:0], roz_ctrl[2]}),
		.incxx({roz_ctrl[5][0], roz_ctrl[4]}), .incxy({roz_ctrl[7][0], roz_ctrl[6]}),
		.incyy({roz_ctrl[9][0], roz_ctrl[8]}), .incyx({roz_ctrl[11][0], roz_ctrl[10]}),
		.offsx(roz_ctrl[12]), .offsy(roz_ctrl[13]), .offsx_hi(roz_ctrl[14][0]), .offsy_hi(roz_ctrl[15][0]),
		.super_mode(roz_ctrl[23][0]),
		.line_addr(roz_la), .line_data(roz_ld),
		.vram_addr(roz_va), .vram_data(roz_vd),
		.rom_req(roz_rom_req), .rom_addr(roz_rom_addr), .rom_valid(roz_rom_valid), .rom_data(roz_rom_data),
		.pen(roz_pen), .colour(roz_col), .opaque(roz_op), .fetch_overrun(roz_overrun), .overrun_ev(),
		.line_done(), .line_cycles(), .line_misses(),
		.dbg_fill(dbg_roz_fill), .dbg_hit(dbg_roz_hit), .dbg_pen_nz(dbg_roz_pen_nz)
	);

	// --------------------------------------------------------------- sprites
	logic        copy_done, obj_ready, obj_rd;
	logic [14:0] obj_addr;
	logic [15:0] obj_data;
	logic        j_req, j_we, j_beat, j_done;
	logic [27:3] j_addr;
	logic [63:0] j_din, j_dout;
	ms32_objram u_objram (
		.clk(clk), .reset(reset),
		.cpu_clk(cpu_clk), .cpu_addr(objram_addr), .cpu_wel(objram_wel), .cpu_weh(objram_weh), .cpu_wdata(cpu_wdata), .cpu_rdata(objram_rdata),
		.frame_start(vblank_ev), .copy_done(copy_done), .copying(),
		.reverse(~spr_ctrl10[15]), .obj_rd(obj_rd), .obj_addr(obj_addr), .obj_data(obj_data), .obj_ready(obj_ready),
		.j_req(j_req), .j_we(j_we), .j_addr(j_addr), .j_din(j_din), .j_beat(j_beat), .j_dout(j_dout), .j_done(j_done)
	);

	logic        fb_we, fb_ready, spr_done;
	logic [8:0]  fb_x;
	logic [7:0]  fb_y;
	logic [15:0] fb_data, spr_pix;
	ms32_sprite u_spr (
		.clk(clk), .reset(reset),
		.frame_start(copy_done), .reverse(~spr_ctrl10[15]), .hdisplay(hdisplay), .vdisplay(vdisplay),
		.obj_addr(obj_addr), .obj_data(obj_data), .obj_ready(obj_ready), .obj_rd(obj_rd),
		.rom_req(spr_rom_req), .rom_addr(spr_rom_addr), .rom_valid(spr_rom_valid), .rom_data(spr_rom_data),
		.fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_data(fb_data), .fb_ready(fb_ready),
		.busy(), .frame_done(spr_done), .frame_overrun(spr_overrun), .frame_cycles(spr_frame_cycles), .sprites_drawn(spr_drawn)
	);
	ms32_sprite_fb u_fb (
		.clk(clk), .reset(reset),
		.frame_start(vblank_ev), .line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active),
		.fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_data(fb_data), .fb_ready(fb_ready), .flush(spr_done),
		.pix(spr_pix),
		.j_req(j_req), .j_we(j_we), .j_addr(j_addr), .j_din(j_din), .j_beat(j_beat), .j_dout(j_dout), .j_done(j_done),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.rd_overrun(fb_overrun), .rd_overrun_ev(), .wr_stall_cycles()
	);

	// ---------------------------------------------------- palette, priority
	// palette: 0x8000 entries x 2 u16; entry i is u16 words 2i (RG) and 2i+1 (B)
	logic [14:0] pal_addr;
	logic [15:0] pal_w0, pal_w1;
	logic [15:0] pal_r0, pal_r1;
	logic        pal_odd_q;
	dpram_dc #(.ADDR_WIDTH(15)) u_pal0 (.clk_a(cpu_clk), .a_addr(palram_addr[15:1]), .a_wel(palram_wel && !palram_addr[0]), .a_weh(palram_weh && !palram_addr[0]), .a_wdata(cpu_wdata), .a_rdata(pal_r0),
		.clk_b(clk), .b_addr(pal_addr), .b_re(1'b1), .b_rdata(pal_w0));
	dpram_dc #(.ADDR_WIDTH(15)) u_pal1 (.clk_a(cpu_clk), .a_addr(palram_addr[15:1]), .a_wel(palram_wel &&  palram_addr[0]), .a_weh(palram_weh &&  palram_addr[0]), .a_wdata(cpu_wdata), .a_rdata(pal_r1),
		.clk_b(clk), .b_addr(pal_addr), .b_re(1'b1), .b_rdata(pal_w1));
	always_ff @(posedge cpu_clk) pal_odd_q <= palram_addr[0];
	assign palram_rdata = pal_odd_q ? pal_r1 : pal_r0;
	logic [12:0] pri_addr;
	logic [7:0]  pri_data;
	dpram_dc #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_priram (.clk_a(cpu_clk), .a_addr(priram_addr), .a_wel(priram_we), .a_weh(1'b0), .a_wdata(cpu_wdata[7:0]), .a_rdata(priram_rdata),
		.clk_b(clk), .b_addr(pri_addr), .b_re(1'b1), .b_rdata(pri_data));

	ms32_mixer u_mix (
		.clk(clk), .reset(reset), .frame_start(vblank_ev),
		.tx_pen(tx_pen), .tx_col(tx_col), .tx_op(tx_op),
		.bg_pen(bg_pen), .bg_col(bg_col), .bg_op(bg_op),
		.roz_pen(roz_pen), .roz_col(roz_col), .roz_op(roz_op),
		.spr(spr_pix),
		.pri_addr(pri_addr), .pri_data(pri_data),
		.pal_addr(pal_addr), .pal_w0(pal_w0), .pal_w1(pal_w1),
		.brt0(brt0), .brt1(brt1),
		.dis_tx(dis_tx), .dis_bg(dis_bg), .dis_roz(dis_roz), .dis_spr(dis_spr),
		.r(r), .g(g), .b(b), .unhandled_primask(bad_primask)
	);

endmodule
