// SPDX-License-Identifier: GPL-3.0-or-later
//
//  The whole board running a game: ms32_core (V70 and memory map on
//  clk_cpu, video on clk_sys) with the program, tile and sprite ROMs behind
//  latency models and the sprite frame buffer behind the DDRAM model. No
//  replay: interrupts come from the CRTC and the system controller, inputs
//  and DIPs are constants (MAME's defaults for the set).
//
//      python scripts/run_verilator.py system_tb +GAME=tetrisp +FRAME=1200 +OUT=simout/system-tetrisp
//
//  +FRAME=N   write frame N (counted from reset, as MAME's frame numbers
//             are) to <OUT>/sim_rgb.txt for scripts/compare_sim_rgb.py
//  +TRACE=N   log the first N bus accesses to debug/<GAME>-boot/rtl_sys.trace
//             in the MAME tap format, for scripts/compare_boot_trace.py
//  +DSW=hex   the DIP word (default FF7FFFFF, what MAME's tetrisp read)
//  +LAT=N     ROM model latency in clk_sys clocks (default 12)
//  +INV       ms32_invert_lines, as the mod byte sets it for tp2m32
//  +MJ        mahjong inputs (mod byte bit 5), no key pressed
//  +DUMP      with the frame, write the video RAMs to <OUT>/<ram>.bin in
//             mame_capture.py's layout (one little-endian dword per u16)
`timescale 1ns/1ps

module tb_system;

reg clk = 0;
always #5.208 clk = ~clk;       // clk_sys, 96 MHz
reg clk_cpu = 0;
always #25 clk_cpu = ~clk_cpu;  // clk_cpu, 20 MHz
reg reset = 1, cpu_run = 0;

string  GAME, OUTDIR;
integer LAT, FRAME, TRACE, PAUSE_AT, PAUSE_LEN;
reg [31:0] DSW;
reg        INV = 0, MJ = 0, PAUSE = 0;

// ------------------------------------------------------------- ROMs
reg [7:0]  prgrom [0:(1 << 21) - 1];
reg [7:0]  txrom  [0:(1 << 19) - 1];
reg [7:0]  bgrom  [0:(1 << 22) - 1];
reg [7:0]  rozrom [0:(1 << 22) - 1];
reg [7:0]  sprrom [0:(1 << 24) - 1];
integer    txrom_mask, bgrom_mask, rozrom_mask, sprrom_mask;

wire        pg_req, tx_req, bg_req, rz_req, sp_req;
wire [17:0] pg_addr;
wire [23:0] tx_addr, bg_addr, rz_addr;
wire [27:0] sp_addr;
reg         pg_valid = 0, tx_valid = 0, bg_valid = 0, rz_valid = 0, sp_valid = 0;
reg  [63:0] pg_data, tx_data, bg_data, rz_data, sp_data;

wire        DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY;
wire [7:0]  DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DIN, DDRAM_DOUT;

wire        ce_pix, hblank, vblank, hsync, vsync, vblank_ev;
wire [7:0]  r, g, b;
wire        tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm;
wire [31:0] pc;

// object RAM in SDRAM (ms32_objram behind ms32_sdram_top)
wire        ob_rreq, ob_rvalid, ob_wreq, ob_we16, ob_wbusy;
wire [12:0] ob_raddr;
wire [15:0] ob_waddr, ob_wdata;
wire [63:0] ob_rdata;
objram_sdram_model u_objsd (
	.clk(clk), .rreq(ob_rreq), .raddr(ob_raddr), .rvalid(ob_rvalid), .rdata(ob_rdata),
	.wreq(ob_wreq), .waddr(ob_waddr), .we16(ob_we16), .wdata(ob_wdata), .wbusy(ob_wbusy)
);

ms32_core u_core (
	.clk_sys(clk), .clk_cpu(clk_cpu), .sys_reset(reset), .cpu_run(cpu_run), .pause(PAUSE), .invert_lines(INV),
	.inputs(32'hFFFF_FFFF), .dsw(DSW), .mahjong(MJ), .mj_keys({30{1'b1}}),
	.nv_addr(13'd0), .nv_rdata(), .nv_written(),
	.snd_reset(), .snd_cmd_we(), .snd_cmd_data(), .snd_tomain_we(1'b0), .snd_tomain_data(8'h00),
	.ld_req(1'b0), .ld_addr(32'd0), .ld_be(4'd0), .ld_data(32'd0), .ld_ack(),
	.prg_req(pg_req),  .prg_addr(pg_addr), .prg_valid(pg_valid), .prg_data(pg_data),
	.tx_req(tx_req),   .tx_addr(tx_addr),  .tx_valid(tx_valid),  .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),  .bg_valid(bg_valid),  .bg_data(bg_data),
	.roz_req(rz_req),  .roz_addr(rz_addr), .roz_valid(rz_valid), .roz_data(rz_data),
	.spr_req(sp_req),  .spr_addr(sp_addr), .spr_valid(sp_valid), .spr_data(sp_data),
	.obj_rreq(ob_rreq), .obj_raddr(ob_raddr), .obj_rvalid(ob_rvalid), .obj_rdata(ob_rdata),
	.obj_wreq(ob_wreq), .obj_waddr(ob_waddr), .obj_we16(ob_we16), .obj_wdata(ob_wdata), .obj_wbusy(ob_wbusy),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(vblank_ev),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0), .dis_road(1'b0),
	.dbg_mem_en(1'b0), .dbg_mem_reg(4'd0), .dbg_mem_addr(16'd0), .dbg_mem_data(),
	.tx_overrun(tx_ovr), .bg_overrun(bg_ovr), .roz_overrun(roz_ovr), .spr_overrun(spr_ovr), .fb_overrun(fb_ovr), .bad_primask(bad_pm),
	.dbg_roz_fill(), .dbg_roz_hit(), .dbg_roz_pen_nz(), .dbg_pc(pc)
);

// ------------------------------------------------------------ ROM models
// LAT clocks from req to valid, one request at a time per port. The program
// ROM port's address is a granule index (x8 bytes).
integer pg_cnt = 0, tx_cnt = 0, bg_cnt = 0, rz_cnt = 0, sp_cnt = 0, i;
reg [27:0] pg_la, tx_la, bg_la, rz_la, sp_la;
always @(posedge clk) begin
	pg_valid <= 0;
	if (pg_cnt == 0) begin if (pg_req) begin pg_la <= {7'd0, pg_addr, 3'd0}; pg_cnt <= LAT; end end
	else if (pg_cnt == 1) begin for (i = 0; i < 8; i = i + 1) pg_data[8*i +: 8] <= prgrom[pg_la[20:0] + i]; pg_valid <= 1; pg_cnt <= 0; end
	else pg_cnt <= pg_cnt - 1;
	tx_valid <= 0;
	if (tx_cnt == 0) begin if (tx_req) begin tx_la <= {4'd0, tx_addr}; tx_cnt <= LAT; end end
	else if (tx_cnt == 1) begin for (i = 0; i < 8; i = i + 1) tx_data[8*i +: 8] <= txrom[(tx_la + i) & txrom_mask]; tx_valid <= 1; tx_cnt <= 0; end
	else tx_cnt <= tx_cnt - 1;
	bg_valid <= 0;
	if (bg_cnt == 0) begin if (bg_req) begin bg_la <= {4'd0, bg_addr}; bg_cnt <= LAT; end end
	else if (bg_cnt == 1) begin for (i = 0; i < 8; i = i + 1) bg_data[8*i +: 8] <= bgrom[(bg_la + i) & bgrom_mask]; bg_valid <= 1; bg_cnt <= 0; end
	else bg_cnt <= bg_cnt - 1;
	rz_valid <= 0;
	if (rz_cnt == 0) begin if (rz_req) begin rz_la <= {4'd0, rz_addr}; rz_cnt <= LAT; end end
	else if (rz_cnt == 1) begin for (i = 0; i < 8; i = i + 1) rz_data[8*i +: 8] <= rozrom[(rz_la + i) & rozrom_mask]; rz_valid <= 1; rz_cnt <= 0; end
	else rz_cnt <= rz_cnt - 1;
	sp_valid <= 0;
	if (sp_cnt == 0) begin if (sp_req) begin sp_la <= sp_addr; sp_cnt <= LAT; end end
	else if (sp_cnt == 1) begin for (i = 0; i < 8; i = i + 1) sp_data[8*i +: 8] <= sprrom[(sp_la + i) & sprrom_mask]; sp_valid <= 1; sp_cnt <= 0; end
	else sp_cnt <= sp_cnt - 1;
end

// ------------------------------------------------------------ DDRAM model
// sim/video_tb's model with a busy time of 6 and a read latency of 20.
localparam [27:0] FB_BASE = 28'h2000000;
localparam integer DDR_BUSY = 6, DDR_LAT = 20;
reg [63:0] ddr [0:262143];   // 18-bit word index: frame buffer 0x00000-0x0FFFF, object copy 0x20000-0x21FFF (DDRAM_ADDR's low 18 bits)
reg        ddr_busy = 0;
integer    ddr_busy_cnt = 0, ddr_rd_cnt = 0, ddr_rd_left = 0, ddr_wr_left = 0, j;
reg [17:0] ddr_rd_word, ddr_wr_word;
reg        ddr_ready = 0;
reg [63:0] ddr_dout;
assign DDRAM_BUSY = ddr_busy;
assign DDRAM_DOUT_READY = ddr_ready;
assign DDRAM_DOUT = ddr_dout;
wire [17:0] ddr_word = DDRAM_ADDR[17:0];
always @(posedge clk) begin
	ddr_ready <= 0;
	if (ddr_busy_cnt > 0) begin ddr_busy_cnt <= ddr_busy_cnt - 1; if (ddr_busy_cnt == 1) ddr_busy <= 0; end
	if (ddr_rd_cnt > 0) begin
		ddr_rd_cnt <= ddr_rd_cnt - 1;
		if (ddr_rd_cnt == 1) begin
			ddr_dout <= ddr[ddr_rd_word]; ddr_ready <= 1;
			if (ddr_rd_left > 1) begin ddr_rd_left <= ddr_rd_left - 1; ddr_rd_word <= ddr_rd_word + 1; ddr_rd_cnt <= 1; end
			else begin ddr_rd_left <= 0; ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end
	end
	if (!ddr_busy) begin
		if (DDRAM_WE) begin
			if (ddr_wr_left == 0) begin ddr_wr_word = ddr_word; ddr_wr_left = {24'd0, DDRAM_BURSTCNT}; end
			for (j = 0; j < 8; j = j + 1) if (DDRAM_BE[j]) ddr[ddr_wr_word][8*j +: 8] <= DDRAM_DIN[8*j +: 8];
			ddr_wr_word = ddr_wr_word + 1;
			ddr_wr_left = ddr_wr_left - 1;
			if (ddr_wr_left == 0) begin ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY; end
		end else if (DDRAM_RD && ddr_rd_left == 0) begin
			ddr_rd_word <= ddr_word; ddr_rd_left <= {24'd0, DDRAM_BURSTCNT}; ddr_rd_cnt <= DDR_LAT;
			ddr_busy <= 1; ddr_busy_cnt <= DDR_BUSY;
		end
	end
end

// ------------------------------------------------------------- bus trace
integer ftr = 0, n_tr = 0;
wire [31:0] tr_mask = {{8{u_core.u_sys.m_be[3]}}, {8{u_core.u_sys.m_be[2]}}, {8{u_core.u_sys.m_be[1]}}, {8{u_core.u_sys.m_be[0]}}};
always @(posedge clk_cpu) begin
	if (ftr != 0 && u_core.u_sys.m_ack && !u_core.u_sys.ld_owns && n_tr < TRACE) begin
		n_tr = n_tr + 1;
		if (u_core.u_sys.m_we)
			$fdisplay(ftr, "%0d\tw\t%08X\t%08X\t%08X", n_tr, u_core.u_sys.a, tr_mask, u_core.u_sys.m_wdata);
		else
			$fdisplay(ftr, "%0d\tr\t%08X\t%08X\t%08X", n_tr, u_core.u_sys.a, tr_mask, u_core.u_sys.m_rdata);
		if (n_tr == TRACE) begin $fclose(ftr); ftr = 0; $display("trace: %0d accesses written", TRACE); end
	end
end

// ------------------------------------------------------------- sound commands
// every V70 write to the sound latch, with the time since the previous one
realtime snd_t_last = 0;
always @(posedge clk_cpu)
	if (u_core.u_sys.wr && u_core.u_sys.is_sndcmd && !u_core.u_sys.ld_owns) begin
		$display("sndcmd %02x at %.6f s (+%.1f us)", u_core.u_sys.m_wdata[7:0], $realtime / 1e9, ($realtime - snd_t_last) / 1e3);
		snd_t_last = $realtime;
	end

// ------------------------------------------------------------- frames
reg [23:0] out [0:320*224-1];
integer frame = 0, irqs = 0;
always @(posedge clk) if (vblank_ev) frame <= frame + 1;
always @(posedge clk_cpu) if (u_core.u_sys.irq_ack) irqs <= irqs + 1;
always @(posedge clk) begin
	if (ce_pix && !hblank && !vblank && frame == FRAME && u_core.u_video.hcnt < 320 && u_core.u_video.vcnt < 224)
		out[u_core.u_video.vcnt * 320 + u_core.u_video.hcnt] <= {r, g, b};
end
always @(posedge clk) if (vblank_ev && (frame % 60) == 59)
	$display("frame %0d: pc %08x, %0d accesses, %0d interrupts, cache %0d hits %0d misses, overrun tx=%0d bg=%0d roz=%0d spr=%0d fb=%0d",
	         frame + 1, pc, u_core.u_sys.dbg_accesses, irqs, u_core.u_sys.dbg_cache_hits, u_core.u_sys.dbg_cache_misses,
	         tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr);

// ------------------------------------------------------------- RAM dumps
task dump16(input string name, input integer aw);
	integer fdd, w;
	reg [15:0] v;
	begin
		fdd = $fopen({OUTDIR, "/", name, ".bin"}, "wb");
		for (w = 0; w < (1 << aw); w = w + 1) begin
			if (name == "txram")      v = u_core.u_video.u_txram.mem[w];
			else if (name == "bgram") v = u_core.u_video.u_bgram.mem[w];
			else if (name == "rozram") v = u_core.u_video.u_rozram.mem[w];
			else if (name == "sprram") v = {u_objsd.mem[2*w+1], u_objsd.mem[2*w]};   // the live RAM, in the SDRAM model
			else if (name == "palram") v = w[0] ? u_core.u_video.u_pal1.mem[w >> 1] : u_core.u_video.u_pal0.mem[w >> 1];
			else if (name == "priram") v = {8'h00, u_core.u_video.u_priram.mem[w]};
			else                      v = u_core.u_video.u_lineram.mem[w];
			$fwrite(fdd, "%c%c%c%c", v[7:0], v[15:8], 8'h00, 8'h00);
		end
		$fclose(fdd);
	end
endtask

// +PAUSE_AT=<frame> +PAUSE_LEN=<frames>: hold the pause input for that many
// frames and report the V70's bus accesses across the held part (one frame
// after the edge onwards, which must not move)
integer acc0;
initial begin
	if ($value$plusargs("PAUSE_AT=%d", PAUSE_AT) && PAUSE_AT > 0) begin
		wait (frame == PAUSE_AT);
		PAUSE = 1;
		wait (frame == PAUSE_AT + 1);
		acc0 = u_core.u_sys.dbg_accesses;
		wait (frame == PAUSE_AT + PAUSE_LEN);
		$display("pause: frames %0d-%0d, accesses %0d at +1 frame, %0d at release, pc %08x",
		         PAUSE_AT, PAUSE_AT + PAUSE_LEN, acc0, u_core.u_sys.dbg_accesses, pc);
		PAUSE = 0;
	end
end

// V70 accesses by region: per run, and the heaviest frame
integer n_wram_r = 0, n_wram_w = 0, n_obj_r = 0, n_obj_w = 0, n_rom = 0, n_all = 0;
integer f_wram = 0, f_obj = 0, f_all = 0, mx_wram = 0, mx_obj = 0, mx_all = 0, f_last = 0;
always @(posedge clk_cpu) begin
	if (u_core.u_sys.accept && !u_core.u_sys.ld_owns) begin
		n_all = n_all + 1; f_all = f_all + 1;
		if (u_core.u_sys.is_wram)   begin if (u_core.u_sys.m_we) n_wram_w = n_wram_w + 1; else n_wram_r = n_wram_r + 1; f_wram = f_wram + 1; end
		if (u_core.u_sys.is_objram) begin if (u_core.u_sys.m_we) n_obj_w = n_obj_w + 1;   else n_obj_r = n_obj_r + 1;   f_obj = f_obj + 1; end
		if (u_core.u_sys.is_rom) n_rom = n_rom + 1;
	end
	if (frame != f_last) begin
		f_last = frame;
		if (frame > 2) begin
			if (f_wram > mx_wram) mx_wram = f_wram;
			if (f_obj  > mx_obj)  mx_obj  = f_obj;
			if (f_all  > mx_all)  mx_all  = f_all;
		end
		f_wram = 0; f_obj = 0; f_all = 0;
	end
end

// +PCHIST: after frame 60, count bus accesses by V70 PC and write the top
// entries at the end (finds a game's wait-for-vblank loop).
// +IDLE_LO=hex +IDLE_HI=hex: per frame, write the clocks the PC spends outside
// that range (busy) and the work/object RAM accesses made while busy to
// <OUT>/busy.txt: "frame busy_clk wram_acc obj_acc".
int unsigned pc_hist [int unsigned];
reg [31:0] IDLE_LO = 0, IDLE_HI = 0;
integer fbusy = 0, b_clk = 0, b_wram = 0, b_obj = 0, b_last = 0;
wire in_idle = (u_core.u_sys.dbg_pc >= IDLE_LO) && (u_core.u_sys.dbg_pc <= IDLE_HI);
always @(posedge clk_cpu) begin
	if ($test$plusargs("PCHIST") && frame > 60 && u_core.u_sys.accept && !u_core.u_sys.ld_owns)
		pc_hist[u_core.u_sys.dbg_pc] = pc_hist.exists(u_core.u_sys.dbg_pc) ? pc_hist[u_core.u_sys.dbg_pc] + 1 : 1;
	if (fbusy != 0) begin
		if (!in_idle && cpu_run) begin
			b_clk = b_clk + 1;
			if (u_core.u_sys.accept && u_core.u_sys.is_wram)   b_wram = b_wram + 1;
			if (u_core.u_sys.accept && u_core.u_sys.is_objram) b_obj  = b_obj + 1;
		end
		if (frame != b_last) begin
			$fdisplay(fbusy, "%0d %0d %0d %0d", b_last, b_clk, b_wram, b_obj);
			b_last = frame; b_clk = 0; b_wram = 0; b_obj = 0;
		end
	end
end

// +PCT_LO=hex +PCT_HI=hex +PCT_AT=frame: print the first 60 bus accesses made
// with the PC in that range from that frame on
reg [31:0] PCT_LO = 0, PCT_HI = 0;
integer PCT_AT = 0, pct_n = 0;
always @(posedge clk_cpu)
	if (PCT_HI != 0 && frame >= PCT_AT && pct_n < 60 && u_core.u_sys.accept &&
	    u_core.u_sys.dbg_pc >= PCT_LO && u_core.u_sys.dbg_pc <= PCT_HI) begin
		pct_n = pct_n + 1;
		$display("pct f%0d pc %08x %s %08x be %x wdata %08x", frame, u_core.u_sys.dbg_pc, u_core.u_sys.m_we ? "W" : "R",
		         u_core.u_sys.a, u_core.u_sys.m_be, u_core.u_sys.m_wdata);
	end

// the vblank copy of object RAM (SDRAM to DDR3): the longest, in clk_sys clocks
integer cp_len = 0, cp_max = 0;
always @(posedge clk) begin
	if (u_core.u_video.u_objram.copying) cp_len = cp_len + 1;
	else begin if (cp_len > cp_max) cp_max = cp_len; cp_len = 0; end
end

// +FRAMELOG: <OUT>/frames.txt, one line per sprite frame the engine finishes:
// "frame drawn cycles obj_writes obj_writes_during_copy cpu_objram_clocks".
// The object RAM columns count clk_sys events since the previous line.
integer flog = 0, fl_w = 0, fl_wc = 0, fl_wait = 0, fl_cpstart = 0, fl_vbl = 0;
always @(posedge clk) begin   // clocks from vblank start to the sprite engine's start
	if (vblank_ev) fl_vbl = 0; else fl_vbl = fl_vbl + 1;
	if (u_core.u_video.u_objram.copy_done) fl_cpstart = fl_vbl;
end
always @(posedge clk) if (flog != 0) begin
	if (u_core.u_video.u_objram.wq_pop) begin
		fl_w = fl_w + 1;
		if (u_core.u_video.u_objram.copy_act) fl_wc = fl_wc + 1;
	end
	// the V70's bus held on object RAM: queue full, a read's drain or its request
	if (u_core.u_sys.bst inside {u_core.u_sys.B_OBJW, u_core.u_sys.B_OBJR, u_core.u_sys.B_OBJ}) fl_wait = fl_wait + 1;
	if (u_core.u_video.spr_done) begin
		$fdisplay(flog, "%0d %0d %0d %0d %0d %0d %0d %0d", frame, u_core.u_video.u_spr.sprites_drawn, u_core.u_video.u_spr.frame_cycles, fl_w, fl_wc, fl_wait,
		          u_core.u_video.u_spr.frame_overrun, fl_cpstart);
		fl_w = 0; fl_wc = 0; fl_wait = 0;
	end
end

// +RESET_AT=<frame>: the OSD reset, as MS32.sv applies it: the core's reset
// (sys_reset) and cpu_run low together for 100,000 clocks, then released
integer RESET_AT = 0;
initial begin
	if ($value$plusargs("RESET_AT=%d", RESET_AT) && RESET_AT > 0) begin
		wait (frame == RESET_AT);
		@(posedge clk); reset = 1; cpu_run = 0;
		repeat (100000) @(posedge clk);
		reset = 0;
		repeat (40) @(posedge clk);
		cpu_run = 1;
		$display("reset at frame %0d released; pc %08x", RESET_AT, pc);
	end
end

// line RAM: CPU writes during active display, and writes to the address the
// ROZ engine's port B holds within +-2 clk_sys of its read edge (the M10K's
// mixed-port read-during-write is undefined)
integer lr_w_act = 0, lr_w_vbl = 0, lr_coll = 0, lr_last_w = -100, lr_frames_coll = 0, lr_fc_last = -1;
reg [10:0] lr_w_addr;
integer tcl = 0;
always @(posedge clk) tcl = tcl + 1;
always @(posedge clk_cpu) if (u_core.u_sys.lineram_wel || u_core.u_sys.lineram_weh) begin
	lr_w_addr = u_core.u_sys.lineram_addr; lr_last_w = tcl;
	if (u_core.u_video.vcnt < 224) lr_w_act = lr_w_act + 1; else lr_w_vbl = lr_w_vbl + 1;
end
always @(posedge clk) if (tcl - lr_last_w <= 2 && u_core.u_video.roz_la == lr_w_addr && u_core.u_video.u_roz.state == 1) begin
	lr_coll = lr_coll + 1;
	if (frame != lr_fc_last) begin lr_frames_coll = lr_frames_coll + 1; lr_fc_last = frame; end
end

// ------------------------------------------------------------- run
integer n, k, fd;
initial begin
	if (!$value$plusargs("GAME=%s", GAME))  GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))    LAT = 12;
	if (!$value$plusargs("FRAME=%d", FRAME)) FRAME = 60;
	if (!$value$plusargs("TRACE=%d", TRACE)) TRACE = 0;
	if (!$value$plusargs("DSW=%h", DSW))    DSW = 32'hFF7F_FFFF;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/system-", GAME};
	INV = $test$plusargs("INV");
	MJ  = $test$plusargs("MJ");
	if (!$value$plusargs("PAUSE_AT=%d", PAUSE_AT))   PAUSE_AT = 0;
	if (!$value$plusargs("PAUSE_LEN=%d", PAUSE_LEN)) PAUSE_LEN = 0;

	for (k = 0; k < (1 << 21); k = k + 1) prgrom[k] = 8'hCD;
	fd = $fopen({"roms/", GAME, "/maincpu.bin"}, "rb"); if (fd == 0) begin $display("FATAL no maincpu.bin"); $finish; end
	n = $fread(prgrom, fd); $fclose(fd);
	fd = $fopen({"roms/", GAME, "/txtiles_dec.bin"}, "rb"); n = $fread(txrom, fd); $fclose(fd); txrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/bgtiles_dec.bin"}, "rb"); n = $fread(bgrom, fd); $fclose(fd); bgrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/roztiles.bin"}, "rb");    n = $fread(rozrom, fd); $fclose(fd); rozrom_mask = n - 1;
	fd = $fopen({"roms/", GAME, "/sprite.bin"}, "rb");      n = $fread(sprrom, fd); $fclose(fd); sprrom_mask = n - 1;
	if ((n & (n - 1)) != 0) sprrom_mask = (1 << $clog2(n)) - 1;
	for (k = 0; k < 262144; k = k + 1) ddr[k] = 64'd0;
	for (k = 0; k < 320*224; k = k + 1) out[k] = 24'h000000;
	$display("%s: reset vector bytes %02x %02x %02x %02x, frame %0d, LAT %0d, DSW %08x, INV %0d",
	         GAME, prgrom[21'h1FFFF0], prgrom[21'h1FFFF1], prgrom[21'h1FFFF2], prgrom[21'h1FFFF3], FRAME, LAT, DSW, INV);
	if (TRACE > 0) begin
		ftr = $fopen({"debug/", GAME, "-boot/rtl_sys.trace"}, "w");
		$fdisplay(ftr, "# RTL bus accesses from reset, in order (%s, system bench).", GAME);
		$fdisplay(ftr, "# seq\trw\taddr\tmask\tdata");
	end

	void'($value$plusargs("IDLE_LO=%h", IDLE_LO));
	void'($value$plusargs("PCT_LO=%h", PCT_LO)); void'($value$plusargs("PCT_HI=%h", PCT_HI)); void'($value$plusargs("PCT_AT=%d", PCT_AT));
	void'($value$plusargs("IDLE_HI=%h", IDLE_HI));
	if (IDLE_HI != 0) fbusy = $fopen({OUTDIR, "/busy.txt"}, "w");
	if ($test$plusargs("FRAMELOG")) flog = $fopen({OUTDIR, "/frames.txt"}, "w");
	repeat (40) @(posedge clk);
	reset = 0;
	repeat (40) @(posedge clk);
	cpu_run = 1;

	wait (frame == FRAME + 1);
	@(posedge clk);
	fd = $fopen({OUTDIR, "/sim_rgb.txt"}, "w"); if (fd == 0) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%06x\n", out[k]);
	$fclose(fd);
	$display("frame %0d written to %s; pc %08x, %0d accesses, %0d interrupts; overrun tx=%0d bg=%0d roz=%0d spr=%0d fb=%0d bad_primask=%0d",
	         FRAME, OUTDIR, pc, u_core.u_sys.dbg_accesses, irqs, tx_ovr, bg_ovr, roz_ovr, spr_ovr, fb_ovr, bad_pm);
	if ($test$plusargs("PCHIST")) begin : top_pcs
		int unsigned best_pc, best_n, done_pc [$];
		for (int t = 0; t < 12; t++) begin
			best_n = 0;
			foreach (pc_hist[q]) if (pc_hist[q] > best_n && !(q inside {done_pc})) begin best_n = pc_hist[q]; best_pc = q; end
			done_pc.push_back(best_pc);
			$display("pc %08x %0d", best_pc, best_n);
		end
	end
	if (fbusy != 0) $fclose(fbusy);
	if (flog != 0) $fclose(flog);
	$display("line RAM: CPU writes %0d in active display, %0d in vblank; same-address writes within 2 clocks of a ROZ read: %0d in %0d frames",
	         lr_w_act, lr_w_vbl, lr_coll, lr_frames_coll);
	$display("object RAM copy: longest %0d clocks (%0d lines of 6144)", cp_max, cp_max / 6144);
	$display("accesses: all %0d (heaviest frame %0d), work RAM r %0d w %0d (heaviest frame %0d), object RAM r %0d w %0d (heaviest frame %0d), ROM data %0d",
	         n_all, mx_all, n_wram_r, n_wram_w, mx_wram, n_obj_r, n_obj_w, mx_obj, n_rom);
	if (ftr != 0) $fclose(ftr);
	if ($test$plusargs("DUMP")) begin
		dump16("txram", 13); dump16("bgram", 13); dump16("rozram", 15); dump16("lineram", 11);
		dump16("sprram", 15); dump16("palram", 16); dump16("priram", 13);
	end
	$finish;
end

endmodule
