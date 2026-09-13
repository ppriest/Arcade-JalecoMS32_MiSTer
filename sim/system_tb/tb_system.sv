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
integer LAT, FRAME, TRACE;
reg [31:0] DSW;
reg        INV = 0, MJ = 0;

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

ms32_core u_core (
	.clk_sys(clk), .clk_cpu(clk_cpu), .sys_reset(reset), .cpu_run(cpu_run), .invert_lines(INV),
	.inputs(32'hFFFF_FFFF), .dsw(DSW), .mahjong(MJ), .mj_keys({30{1'b1}}),
	.nv_addr(13'd0), .nv_rdata(), .nv_written(),
	.snd_reset(), .snd_cmd_we(), .snd_cmd_data(), .snd_tomain_we(1'b0), .snd_tomain_data(8'h00),
	.ld_req(1'b0), .ld_addr(32'd0), .ld_be(4'd0), .ld_data(32'd0), .ld_ack(),
	.prg_req(pg_req),  .prg_addr(pg_addr), .prg_valid(pg_valid), .prg_data(pg_data),
	.tx_req(tx_req),   .tx_addr(tx_addr),  .tx_valid(tx_valid),  .tx_data(tx_data),
	.bg_req(bg_req),   .bg_addr(bg_addr),  .bg_valid(bg_valid),  .bg_data(bg_data),
	.roz_req(rz_req),  .roz_addr(rz_addr), .roz_valid(rz_valid), .roz_data(rz_data),
	.spr_req(sp_req),  .spr_addr(sp_addr), .spr_valid(sp_valid), .spr_data(sp_data),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR), .DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE),
	.ce_pix(ce_pix), .hblank(hblank), .vblank(vblank), .hsync(hsync), .vsync(vsync), .r(r), .g(g), .b(b),
	.vblank_ev(vblank_ev),
	.dis_tx(1'b0), .dis_bg(1'b0), .dis_roz(1'b0), .dis_spr(1'b0),
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
			else if (name == "sprram") v = u_core.u_video.u_objram.u_live.mem[w];
			else if (name == "palram") v = w[0] ? u_core.u_video.u_pal1.mem[w >> 1] : u_core.u_video.u_pal0.mem[w >> 1];
			else if (name == "priram") v = {8'h00, u_core.u_video.u_priram.mem[w]};
			else                      v = u_core.u_video.u_lineram.mem[w];
			$fwrite(fdd, "%c%c%c%c", v[7:0], v[15:8], 8'h00, 8'h00);
		end
		$fclose(fdd);
	end
endtask

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
	if (ftr != 0) $fclose(ftr);
	if ($test$plusargs("DUMP")) begin
		dump16("txram", 13); dump16("bgram", 13); dump16("rozram", 15); dump16("lineram", 11);
		dump16("sprram", 15); dump16("palram", 16); dump16("priram", 13);
	end
	$finish;
end

endmodule
