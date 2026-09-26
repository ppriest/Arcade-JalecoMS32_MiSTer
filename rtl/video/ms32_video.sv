// SPDX-License-Identifier: GPL-3.0-or-later
//
// The MS32 video path: CRTC, TX/BG/ROZ line engines, object RAM with its
// vblank copy, the zoom sprite engine and its DDR3 frame buffer, and the
// mixer with palette and brightness.
//
// F1SUPERB builds F-1 Super Battle instead (ROADMAP, "F-1 Super Battle"):
// its ROZ layer is a line plane rather than a rotating tilemap, it has a
// second line plane for the road with its own map, line RAM and gfx5
// textures, and its mixer reads the priority RAM per dot. The CRTC, TX, BG,
// sprites and palette are the same. The extra ports exist in both builds;
// ms32_core ties them off where they mean nothing. Every video RAM lives here with a
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
//   0x280-0x28C  brightness                       0x600-0x65F  ROZ control
//   0x800-0x85F  road plane control (F1SUPERB)
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
	// F1SUPERB: the road plane's map and line RAM, sized to what the game uses
	// (448 and 2,048 words measured over three minutes of play, ROADMAP)
	input  logic [9:0]  roadvram_addr, input logic roadvram_wel, input logic roadvram_weh, output logic [15:0] roadvram_rdata,
	input  logic [10:0] roadline_addr, input logic roadline_wel, input logic roadline_weh, output logic [15:0] roadline_rdata,
	// object RAM: CPU requests on clk (ms32_cpu_sys's crossing), the RAM in SDRAM
	input  logic        obj_wq_valid, input logic [32:0] obj_wq_data, output logic obj_wq_pop, input logic [5:0] obj_wq_level,
	input  logic        obj_cpu_req,  input logic [14:0] obj_cpu_addr, output logic obj_cpu_valid, output logic [15:0] obj_cpu_rdata,
	output logic        obj_sd_rreq,  output logic [12:0] obj_sd_raddr, input logic obj_sd_rvalid, input logic [63:0] obj_sd_rdata,
	output logic        obj_sd_wreq,  output logic [15:0] obj_sd_waddr, output logic obj_sd_we16, output logic [15:0] obj_sd_wdata,
	input  logic        obj_sd_wbusy,
	input  logic [15:0] palram_addr,  input logic palram_wel,  input logic palram_weh,  output logic [15:0] palram_rdata,
	input  logic [12:0] priram_addr,  input logic priram_we,                             output logic [7:0]  priram_rdata,

	// tile ROMs, region-local byte addresses, 8-byte granules
	output logic        tx_rom_req,  output logic [23:0] tx_rom_addr,  input logic tx_rom_valid,  input logic [63:0] tx_rom_data,
	output logic        bg_rom_req,  output logic [23:0] bg_rom_addr,  input logic bg_rom_valid,  input logic [63:0] bg_rom_data,
	output logic        roz_rom_req, output logic [23:0] roz_rom_addr, input logic roz_rom_valid, input logic [63:0] roz_rom_data,
	output logic        gfx5_rom_req, output logic [23:0] gfx5_rom_addr, input logic gfx5_rom_valid, input logic [63:0] gfx5_rom_data,
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
	input  logic        dis_tx, dis_bg, dis_roz, dis_spr, dis_road,

	// debug
	output logic        tx_overrun, bg_overrun, roz_overrun, spr_overrun, fb_overrun, bad_primask,
	output logic        road_overrun,                            // F1SUPERB: the road line plane
	output logic [15:0] dbg_road_lines,                          // road lines drawn in the last frame
	output logic [15:0] dbg_road_pens,                           // non-zero road pens in the last frame
	output logic [12:0] dbg_spr_flipx, dbg_spr_flipy,            // flipped sprites in the last frame
	output logic [15:0] dbg_fy_attr,                             // the first flipy sprite's attribute
	output logic [11:0] dbg_fy_idx,                              // and the slot it came from
	output logic [9:0]  dbg_road_row,                            // the row the road plane last selected
	output logic [15:0] dbg_road_rowword,                        // and what vram[2 row] gave back
	output logic [15:0] dbg_road_starty,                         // road_ctrl[2], as the CPU last set it
	output logic [15:0] dbg_road_offsy,                          // road_ctrl[13]
	// A window on the video RAMs, for dumping them off a running board and
	// rendering the result with scripts/render_model.py -- the same renderer
	// that matches MAME pixel for pixel, so it says whether the RAM is right
	// and the RTL wrong, or the RAM is wrong. While dbg_mem_en is held the
	// read ports are taken over and the picture is garbage; the game is meant
	// to be paused for it.
	input  logic        dbg_mem_en,
	input  logic [2:0]  dbg_mem_reg,
	input  logic [15:0] dbg_mem_addr,
	output logic [15:0] dbg_mem_data,
	output logic [23:0] spr_frame_cycles,
	output logic [12:0] spr_drawn,
	output logic        dbg_roz_fill, dbg_roz_hit, dbg_roz_pen_nz,
	// one clk each, for the ISSP probe: a sprite frame still drawing when the next
	// copy is done, a sprite frame-buffer line read late, a ROZ line late, the copy done
	output logic        dbg_spr_ovr_ev, dbg_fb_ovr_ev, dbg_roz_ovr_ev, dbg_road_ovr_ev, dbg_copy_done
);

	// ------------------------------------------------------------ registers
	logic [15:0] tx_scroll [0:5];
	logic [15:0] bg_scroll [0:5];
	logic [15:0] roz_ctrl  [0:23];
	logic [15:0] road_ctrl [0:23];   // F1SUPERB, 0xFCE00800
	logic [15:0] spr_ctrl10;
	logic [15:0] brt0, brt1, brt2, brt3;
	logic        bgmode;
	always_ff @(posedge clk) begin
		if (reset) begin
			// MAME's video_start defaults, "tp2m32 doesn't set the brightness
			// registers so we need sensible defaults" (ms32_v.cpp 82-84): the
			// brightness pair 0xFFFF and sprite control 0x10 = 0x8000 (list
			// walked 0->tail). tp2m32 never writes either. Bank 1 starts at
			// factor 0x100 (m_brt1_* in video_start), i.e. registers 0.
			bgmode <= 1'b0; brt0 <= 16'hFFFF; brt1 <= 16'hFFFF; brt2 <= 16'h0000; brt3 <= 16'h0000;
			spr_ctrl10 <= 16'h8000;
		end else if (vreg_we) begin
			if (vreg_off[11:5] == 7'b1010_000 && vreg_off[4:2] < 3'd6) tx_scroll[vreg_off[4:2]] <= vreg_data;   // 0xA00-0xA17
			if (vreg_off[11:5] == 7'b1010_001 && vreg_off[4:2] < 3'd6) bg_scroll[vreg_off[4:2]] <= vreg_data;   // 0xA20-0xA37
			if (vreg_off == 12'hA7C) bgmode <= vreg_data[0];
			if (vreg_off[11:7] == 5'b01100 && vreg_off[6:2] < 5'd24) roz_ctrl[vreg_off[6:2]] <= vreg_data;   // 0x600-0x65F
			if (vreg_off[11:7] == 5'b10000 && vreg_off[6:2] < 5'd24) road_ctrl[vreg_off[6:2]] <= vreg_data;  // 0x800-0x85F
			if (vreg_off == 12'h210) spr_ctrl10 <= vreg_data;
			if (vreg_off == 12'h280) brt0 <= vreg_data;
			if (vreg_off == 12'h284) brt1 <= vreg_data;
			if (vreg_off == 12'h288) brt2 <= vreg_data;
			if (vreg_off == 12'h28C) brt3 <= vreg_data;
		end
	end
	wire crtc_we = vreg_we && (vreg_off[11:6] == 6'd0) && (vreg_off[5:2] <= 4'd8);

	// ------------------------------------------------------------------ CRTC
	logic [11:0] hcnt, vcnt, vcnt_next, vcnt_next2, hdisplay, vdisplay;
	logic        h_active, v_active, line_start;
`ifdef F1SUPERB
	localparam bit FIELD_LAST_ACTIVE = 1'b1;   // ms32_crtc: MAME's set_field_irq_last_active_line
`else
	localparam bit FIELD_LAST_ACTIVE = 1'b0;
`endif
	ms32_crtc #(.FIELD_LAST_ACTIVE(FIELD_LAST_ACTIVE)) u_crtc (
		.clk(clk), .reset(reset),
		.reg_we(crtc_we), .reg_off(vreg_off[5:2]), .reg_data(vreg_data),
		.ce_pix(ce_pix), .hcnt(hcnt), .vcnt(vcnt), .vcnt_next(vcnt_next), .vcnt_next2(vcnt_next2),
		.h_active(h_active), .v_active(v_active), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync),
		.line_start(line_start), .frame_odd(), .vblank_ev(vblank_ev), .field_ev(field_ev),
		.flip(), .timer_enable(timer_enable), .hdisplay_o(hdisplay), .vdisplay_o(vdisplay)
	);
	// Registered: vcnt changes at the end of a line and line_start comes at
	// hdisplay, so the compare has the whole blanking interval to settle. As
	// a wire it was the one path over clk_sys in the first build with the
	// YMF271 (-0.178 ns, r_vdisplay into ms32_roz's state register).
	logic fetch_active;
	always_ff @(posedge clk) fetch_active <= (vcnt_next2 < vdisplay);

	// ------------------------------------------------------------ tile RAMs
	logic [12:0] tx_va, bg_va;
	logic [14:0] roz_va;
	logic [10:0] roz_la;
	logic [15:0] tx_vd, bg_vd, roz_vd, roz_ld;
	dpram_dc #(.ADDR_WIDTH(13)) u_txram (.clk_a(cpu_clk), .a_addr(txram_addr), .a_wel(txram_wel), .a_weh(txram_weh), .a_wdata(cpu_wdata), .a_rdata(txram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[12:0] : tx_va), .b_re(1'b1), .b_rdata(tx_vd));
	dpram_dc #(.ADDR_WIDTH(13)) u_bgram (.clk_a(cpu_clk), .a_addr(bgram_addr), .a_wel(bgram_wel), .a_weh(bgram_weh), .a_wdata(cpu_wdata), .a_rdata(bgram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[12:0] : bg_va), .b_re(1'b1), .b_rdata(bg_vd));
	dpram_dc #(.ADDR_WIDTH(15)) u_rozram (.clk_a(cpu_clk), .a_addr(rozram_addr), .a_wel(rozram_wel), .a_weh(rozram_weh), .a_wdata(cpu_wdata), .a_rdata(rozram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? {dbg_mem_addr[14:0]} : roz_va), .b_re(1'b1), .b_rdata(roz_vd));
	// How many of a frame's lines the road plane actually draws: vram[2 row]
	// zero leaves a line transparent, so an all-blank road reads as 0 here and
	// says the fault is upstream of the plane, not in it.
	assign dbg_road_starty = road_ctrl[2];
	assign dbg_road_offsy  = road_ctrl[13];

	logic road_line_drawn, road_pen_nz;
	logic [15:0] road_lines_n, road_pens_n;
	always_ff @(posedge clk) begin
		if (line_start && vcnt_next2 == 12'd0) begin
			dbg_road_lines <= road_lines_n;
			dbg_road_pens  <= road_pens_n;
			road_lines_n   <= 16'd0;
			road_pens_n    <= 16'd0;
		end else begin
			if (road_line_drawn && road_lines_n != 16'hFFFF) road_lines_n <= road_lines_n + 16'd1;
			if (road_pen_nz    && road_pens_n  != 16'hFFFF) road_pens_n  <= road_pens_n  + 16'd1;
		end
	end

	// Declared here rather than beside the line planes below: the road RAMs
	// are instantiated first, and vlog rejects a net used before its
	// declaration even where Quartus and verilator infer it.
	logic [10:0] road_va, road_la, rozf1_va;
	logic [15:0] road_vd, road_ld;
`ifdef F1SUPERB
	// The game writes 448 words of the map and 2,048 of the line RAM, where
	// MAME declares 32,768 of each; the decode wraps rather than the address
	// widening, and ms32_core counts a write that reaches past the end.
	dpram_dc #(.ADDR_WIDTH(10)) u_roadvram (.clk_a(cpu_clk), .a_addr(roadvram_addr), .a_wel(roadvram_wel), .a_weh(roadvram_weh), .a_wdata(cpu_wdata), .a_rdata(roadvram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[9:0] : road_va[9:0]), .b_re(1'b1), .b_rdata(road_vd));
	dpram_dc #(.ADDR_WIDTH(11)) u_roadline (.clk_a(cpu_clk), .a_addr(roadline_addr), .a_wel(roadline_wel), .a_weh(roadline_weh), .a_wdata(cpu_wdata), .a_rdata(roadline_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[10:0] : road_la), .b_re(1'b1), .b_rdata(road_ld));
`else
	assign roadvram_rdata = 16'd0;
	assign roadline_rdata = 16'd0;
	assign road_vd = 16'd0;
	assign road_ld = 16'd0;
`endif
	dpram_dc #(.ADDR_WIDTH(11)) u_lineram (.clk_a(cpu_clk), .a_addr(lineram_addr), .a_wel(lineram_wel), .a_weh(lineram_weh), .a_wdata(cpu_wdata), .a_rdata(lineram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[10:0] : roz_la), .b_re(1'b1), .b_rdata(roz_ld));

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
	// F-1 Super Battle draws both of its rotating planes as line planes; every
	// other set has the rotating tilemap. The ROZ ROM port serves whichever
	// reads roztiles, and gfx5 is the road's alone.
	logic [7:0]  road_pen;
	logic [3:0]  road_col;
	logic        road_op;
	logic [15:0] roz_line_colour, road_line_colour;

`ifdef F1SUPERB
	ms32_lineplane #(.WRAP(1'b0)) u_rozplane (      // roztiles, clipped
		.clk(clk), .reset(reset),
		.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
		.startx({roz_ctrl[1][1:0], roz_ctrl[0]}), .starty({roz_ctrl[3][1:0], roz_ctrl[2]}),
		.offsx(roz_ctrl[12]), .offsy(roz_ctrl[13]), .offsx_hi(roz_ctrl[14][0]), .offsy_hi(roz_ctrl[15][0]),
		.line_addr(roz_la), .line_data(roz_ld),
		.vram_addr(rozf1_va), .vram_data(roz_vd),
		.rom_req(roz_rom_req), .rom_addr(roz_rom_addr), .rom_valid(roz_rom_valid), .rom_data(roz_rom_data),
		.pen(roz_pen), .colour(roz_col), .opaque(roz_op), .line_colour(roz_line_colour),
		.fetch_overrun(roz_overrun), .overrun_ev(dbg_roz_ovr_ev),
		.line_done(), .line_cycles(), .line_misses(), .line_drawn(), .pen_nz(), .dbg_row(), .dbg_rowword()
	);
	assign roz_va = {4'd0, rozf1_va};   // the line plane's map is 1,024 rows
	ms32_lineplane #(.WRAP(1'b1)) u_roadplane (     // gfx5, wrapped
		.clk(clk), .reset(reset),
		.line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active), .hdisplay(hdisplay),
		.startx({road_ctrl[1][1:0], road_ctrl[0]}), .starty({road_ctrl[3][1:0], road_ctrl[2]}),
		// dbg: what the CPU side last delivered for the two registers the row
		// comes from. The register path is a CDC mailbox with no back-pressure.
		.offsx(road_ctrl[12]), .offsy(road_ctrl[13]), .offsx_hi(road_ctrl[14][0]), .offsy_hi(road_ctrl[15][0]),
		.line_addr(road_la), .line_data(road_ld),
		.vram_addr(road_va), .vram_data(road_vd),
		.rom_req(gfx5_rom_req), .rom_addr(gfx5_rom_addr), .rom_valid(gfx5_rom_valid), .rom_data(gfx5_rom_data),
		.pen(road_pen), .colour(road_col), .opaque(road_op), .line_colour(road_line_colour),
		.fetch_overrun(road_overrun), .overrun_ev(dbg_road_ovr_ev), .line_done(), .line_cycles(), .line_misses(),
		.line_drawn(road_line_drawn), .pen_nz(road_pen_nz),
		.dbg_row(dbg_road_row), .dbg_rowword(dbg_road_rowword)
	);
`else
	assign road_overrun = 1'b0;
	assign dbg_road_ovr_ev = 1'b0;
	assign road_pen = 8'd0;
	assign road_col = 4'd0;
	assign road_op  = 1'b0;
	assign roz_line_colour = 16'd0;
	assign road_line_colour = 16'd0;
	assign road_va = 11'd0;
	assign road_la = 11'd0;
	assign gfx5_rom_req = 1'b0;
	assign gfx5_rom_addr = 24'd0;
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
		.pen(roz_pen), .colour(roz_col), .opaque(roz_op), .fetch_overrun(roz_overrun), .overrun_ev(dbg_roz_ovr_ev),
		.line_done(), .line_cycles(), .line_misses(),
		.dbg_fill(dbg_roz_fill), .dbg_hit(dbg_roz_hit), .dbg_pen_nz(dbg_roz_pen_nz)
	);
`endif

	// --------------------------------------------------------------- sprites
	logic        copy_done, obj_ready, obj_rd, spr_busy;
	assign dbg_spr_ovr_ev = copy_done && spr_busy;   // the engine's frame_start while busy
	assign dbg_copy_done  = copy_done;
	logic [14:0] obj_addr;
	logic [15:0] obj_data;
	logic        j_req, j_we, j_beat, j_done;
	logic [27:3] j_addr;
	logic [63:0] j_din, j_dout;
	ms32_objram u_objram (
		.clk(clk), .reset(reset),
		.wq_valid(obj_wq_valid), .wq_data(obj_wq_data), .wq_pop(obj_wq_pop), .wq_level(obj_wq_level),
		.cpu_req(obj_cpu_req), .cpu_addr(obj_cpu_addr), .cpu_valid(obj_cpu_valid), .cpu_rdata(obj_cpu_rdata),
		.sd_rreq(obj_sd_rreq), .sd_raddr(obj_sd_raddr), .sd_rvalid(obj_sd_rvalid), .sd_rdata(obj_sd_rdata),
		.sd_wreq(obj_sd_wreq), .sd_waddr(obj_sd_waddr), .sd_we16(obj_sd_we16), .sd_wdata(obj_sd_wdata), .sd_wbusy(obj_sd_wbusy),
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
		.busy(spr_busy), .frame_done(spr_done), .frame_overrun(spr_overrun), .frame_cycles(spr_frame_cycles), .sprites_drawn(spr_drawn),
		.drawn_flipx(dbg_spr_flipx), .drawn_flipy(dbg_spr_flipy),
		.first_fy_attr(dbg_fy_attr), .first_fy_idx(dbg_fy_idx)
	);
	ms32_sprite_fb u_fb (
		.clk(clk), .reset(reset),
		.frame_start(vblank_ev), .line_start(line_start), .hcnt(hcnt), .vcnt_next2(vcnt_next2), .fetch_line_active(fetch_active),
		.fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_data(fb_data), .fb_ready(fb_ready), .flush(spr_done),
		.pix(spr_pix),
		.j_req(j_req), .j_we(j_we), .j_addr(j_addr), .j_din(j_din), .j_beat(j_beat), .j_dout(j_dout), .j_done(j_done),
		.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
		.rd_overrun(fb_overrun), .rd_overrun_ev(dbg_fb_ovr_ev), .wr_stall_cycles()
	);

	// ---------------------------------------------------- palette, priority
	// palette: 0x8000 entries x 2 u16; entry i is u16 words 2i (RG) and 2i+1 (B)
	logic [14:0] pal_addr;
	logic [15:0] pal_w0, pal_w1;
	logic [15:0] pal_r0, pal_r1;
	logic        pal_odd_q;
	dpram_dc #(.ADDR_WIDTH(15)) u_pal0 (.clk_a(cpu_clk), .a_addr(palram_addr[15:1]), .a_wel(palram_wel && !palram_addr[0]), .a_weh(palram_weh && !palram_addr[0]), .a_wdata(cpu_wdata), .a_rdata(pal_r0),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[14:0] : pal_addr), .b_re(1'b1), .b_rdata(pal_w0));
	dpram_dc #(.ADDR_WIDTH(15)) u_pal1 (.clk_a(cpu_clk), .a_addr(palram_addr[15:1]), .a_wel(palram_wel &&  palram_addr[0]), .a_weh(palram_weh &&  palram_addr[0]), .a_wdata(cpu_wdata), .a_rdata(pal_r1),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[14:0] : pal_addr), .b_re(1'b1), .b_rdata(pal_w1));
	always_ff @(posedge cpu_clk) pal_odd_q <= palram_addr[0];
	assign palram_rdata = pal_odd_q ? pal_r1 : pal_r0;
	logic [12:0] pri_addr;
	logic [7:0]  pri_data;
	dpram_dc #(.ADDR_WIDTH(13), .DATA_WIDTH(8)) u_priram (.clk_a(cpu_clk), .a_addr(priram_addr), .a_wel(priram_we), .a_weh(1'b0), .a_wdata(cpu_wdata[7:0]), .a_rdata(priram_rdata),
		.clk_b(clk), .b_addr(dbg_mem_en ? dbg_mem_addr[12:0] : pri_addr), .b_re(1'b1), .b_rdata(pri_data));

	// the JTAG window's read side (MS32.sv):
	// 0 road map, 1 road line RAM, 2 road_ctrl, 3 priority RAM, 4 ROZ map,
	// 5 ROZ line RAM, 6 TX map, 7 palette (even words in the low half of the
	// pair, odd in the high -- both halves come back at once).
	// Combinational, not registered: the RAM outputs are already one clock
	// behind their address, and the upload path needs the byte ready in that
	// same clock, exactly as the NVRAM read does.
	always_comb begin
		case (dbg_mem_reg)
			3'd0: dbg_mem_data = road_vd;
			3'd1: dbg_mem_data = road_ld;
			3'd2: dbg_mem_data = road_ctrl[dbg_mem_addr[4:0] < 5'd24 ? dbg_mem_addr[4:0] : 5'd0];
			3'd3: dbg_mem_data = {8'd0, pri_data};
			3'd4: dbg_mem_data = roz_vd;
			3'd5: dbg_mem_data = roz_ld;
			3'd6: dbg_mem_data = tx_vd;
			3'd7: dbg_mem_data = dbg_mem_addr[15] ? pal_w1 : pal_w0;
		endcase
	end

	assign bad_primask = 1'b0;      // the priority-RAM mixer has no unhandled case
`ifdef F1SUPERB
	localparam bit MIX_F1 = 1'b1;
`else
	localparam bit MIX_F1 = 1'b0;
`endif
	ms32_mixer #(.F1(MIX_F1)) u_mix (
		.clk(clk), .reset(reset),
		.tx_pen(tx_pen), .tx_col(tx_col), .tx_op(tx_op),
		.bg_pen(bg_pen), .bg_col(bg_col), .bg_op(bg_op),
		.roz_pen(roz_pen), .roz_col(roz_col), .roz_op(roz_op),
		.road_pen(road_pen), .road_col(road_col), .road_op(road_op),
		.roz_line(roz_line_colour), .road_line(road_line_colour),
		.spr(spr_pix),
		.pri_addr(pri_addr), .pri_data(pri_data),
		.pal_addr(pal_addr), .pal_w0(pal_w0), .pal_w1(pal_w1),
		.brt0(brt0), .brt1(brt1), .brt2(brt2), .brt3(brt3),
		.dis_tx(dis_tx), .dis_bg(dis_bg), .dis_roz(dis_roz), .dis_spr(dis_spr), .dis_road(dis_road),
		.r(r), .g(g), .b(b)
	);

endmodule
