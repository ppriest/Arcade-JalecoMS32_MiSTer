// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Sprite bench: ms32_sprite rendering one frame from a capture's vblank
//  copy of object RAM (debug/<CAP>/<GAME>_sprram_vbl.bin, or _sprram.bin
//  when the capture predates the copy-moment dump) and the sprite ROM
//  (roms/<GAME>/sprite.bin) into a plain frame-buffer memory, then writing
//  every pixel's palette index (colour*256 + pen, 0xFFFF where nothing was
//  drawn) for scripts/compare_sim_layer.py against model_sprites.u16.
//
//  Run from the repository root, normally through scripts/sim_layer_check.py:
//      scripts/run_sim.sh sprite_tb +CAP=tetrisp-title +GAME=tetrisp +LAT=12 +OUT=simout/tetrisp-title
//
//  VDEFS=+define+SPR_DDR builds the engine with DDR=1 (F-1 Super Battle's
//  sprite ROM from DDR3) behind an ms32_ddr_reader and a DDR3 model: reads
//  taken a clock apart unless busy, answered in order DLAT clocks later.
//  +DLAT=<n> (default 60), +DBUSY=1: busy on a random quarter of the clocks.
`timescale 1ns/1ps

module tb_sprite;

reg clk = 0;
always #5.208 clk = ~clk;   // 96 MHz
reg reset = 1;

string CAP, GAME, OUTDIR;
integer LAT;

reg [7:0]  rom [0:(1 << 25) - 1];   // 32 MB: f1superb's sprite ROM is the whole of it
integer    rom_mask;
reg [15:0] objram [0:32767];
reg [31:0] sprctrl [0:31];
reg [15:0] fb [0:320*224-1];

// where the frame's clocks go: per engine state, and pixel steps
integer st_cnt [0:15];
integer px_steps = 0, rom_fetches = 0;
initial for (int j = 0; j < 16; j++) st_cnt[j] = 0;
always @(posedge clk) if (u_spr.busy) begin
	st_cnt[u_spr.state] = st_cnt[u_spr.state] + 1;
	if (u_spr.state == 4'd6 && !u_spr.drawy[8]) px_steps = px_steps + 1;   // S_PIX
	if (u_spr.rom_req && !u_spr.rom_req_r) ;                                  // (req is held; count in S_WR)
end
// ------------------------------------------------------------- engine
reg         frame_start = 0;
wire [14:0] obj_addr;
reg  [15:0] obj_data;
always @(posedge clk) obj_data <= objram[obj_addr];

wire        rom_req, rom_valid;
wire [27:0] rom_addr;
reg  [63:0] rom_data;
wire        fb_we;
wire [8:0]  fb_x;
wire [7:0]  fb_y;
wire [15:0] fb_data;
wire        busy, done, overrun;
wire [23:0] cycles;
wire [12:0] drawn;

`ifdef SPR_DDR
localparam bit SDDR = 1'b1;
`else
localparam bit SDDR = 1'b0;
`endif
wire        s_rq_valid, s_rq_ready, s_rs_valid, s_rs_pop, s_flush;
wire [24:0] s_rq_gran;
wire [63:0] s_rs_data;
ms32_sprite #(.DDR(SDDR), .GW(25)) u_spr (
	.clk(clk), .reset(reset),
	.frame_start(frame_start), .reverse(~sprctrl[4][15]), .hdisplay(12'd320), .vdisplay(12'd224),
	.obj_addr(obj_addr), .obj_data(obj_data), .obj_ready(1'b1), .obj_rd(),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
	.fb_we(fb_we), .fb_x(fb_x), .fb_y(fb_y), .fb_data(fb_data), .fb_ready(1'b1),
	.busy(busy), .frame_done(done), .frame_overrun(overrun), .frame_cycles(cycles), .sprites_drawn(drawn),
	.rq_valid(s_rq_valid), .rq_gran(s_rq_gran), .rq_ready(s_rq_ready),
	.rs_valid(s_rs_valid), .rs_data(s_rs_data), .rs_pop(s_rs_pop), .flush(s_flush)
);

// DDR=1: ms32_ddr_reader and a DDR3 model in front of the same ROM image
wire        g_rd, g_ack, g_dout_ready;
wire [28:0] g_addr;
reg  [63:0] g_dout_r; reg g_dout_ready_r = 0;
assign g_dout_ready = g_dout_ready_r;
ms32_ddr_reader #(.BASE(28'h0), .GW(25)) u_rd (
	.clk(clk), .reset(reset), .flush(s_flush),
	.rq_valid(s_rq_valid), .rq_gran(s_rq_gran), .rq_ready(s_rq_ready),
	.rs_valid(s_rs_valid), .rs_data(s_rs_data), .rs_pop(s_rs_pop),
	.g_rd(g_rd), .g_addr(g_addr), .g_ack(g_ack), .g_dout(g_dout_r), .g_dout_ready(g_dout_ready)
);
integer DLAT, DBUSY;
reg ddr_busy = 0;
always @(posedge clk) ddr_busy <= DBUSY && (($urandom % 4) == 0);
assign g_ack = g_rd && !ddr_busy;
reg  [63:0] dq_data [0:255];
integer     dq_due [0:255];
integer     dq_wp = 0, dq_rp = 0, dcyc = 0, j2;
always @(posedge clk) begin
	dcyc <= dcyc + 1;
	g_dout_ready_r <= 0;
	if (g_ack) begin
		for (j2 = 0; j2 < 8; j2 = j2 + 1)
			dq_data[dq_wp % 256][8*j2 +: 8] <= rom[({g_addr[24:0], 3'b000} + j2) & rom_mask];
		dq_due[dq_wp % 256] <= dcyc + DLAT;
		dq_wp <= dq_wp + 1;
	end
	if (dq_rp != dq_wp && dq_due[dq_rp % 256] <= dcyc) begin
		g_dout_r <= dq_data[dq_rp % 256];
		g_dout_ready_r <= 1;
		dq_rp <= dq_rp + 1;
	end
end

// ROM model: LAT clocks, byte i at data[8*i +: 8]
reg        rom_valid_r = 0;
integer    rom_cnt = 0, i;
reg [27:0] la;
assign rom_valid = rom_valid_r;
always @(posedge clk) begin
	rom_valid_r <= 0;
	if (rom_cnt == 0) begin
		if (rom_req) begin la <= rom_addr; rom_cnt <= LAT; end
	end else if (rom_cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) rom_data[8*i +: 8] <= rom[(la + i) & rom_mask];
		rom_valid_r <= 1; rom_cnt <= 0;
	end else rom_cnt <= rom_cnt - 1;
end

// frame buffer: overwrite
integer writes = 0;
always @(posedge clk) if (fb_we) begin
	if (fb_x < 320 && fb_y < 224) fb[fb_y * 320 + fb_x] <= fb_data;
	writes <= writes + 1;
end

// ------------------------------------------------------------- run
reg [7:0] tmp [0:131071];
integer n, k, fd;
initial begin
	if (!$value$plusargs("CAP=%s", CAP))   CAP = "tetrisp-title";
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 12;
	if (!$value$plusargs("DLAT=%d", DLAT)) DLAT = 60;
	if (!$value$plusargs("DBUSY=%d", DBUSY)) DBUSY = 0;
	if (!$value$plusargs("OUT=%s", OUTDIR)) OUTDIR = {"simout/", CAP};

	fd = $fopen({"roms/", GAME, "/sprite.bin"}, "rb"); if (!fd) begin $display("FATAL no sprite.bin"); $finish; end
	n = $fread(rom, fd); $fclose(fd); rom_mask = n - 1;
	// p47aces has a 14 MB sprite ROM: not a power of two, the model wraps with %.
	// Nothing in its captured frames reaches the top, so a power-of-two mask
	// above the size is safe here; the SDRAM map settles it for real.
	if ((n & (n - 1)) != 0) rom_mask = (1 << $clog2(n)) - 1;

	fd = $fopen({"debug/", CAP, "/", GAME, "_sprram_vbl.bin"}, "rb");
	if (!fd) fd = $fopen({"debug/", CAP, "/", GAME, "_sprram.bin"}, "rb");
	if (!fd) begin $display("FATAL no sprram"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32768; k = k + 1) objram[k] = {tmp[4*k+1], tmp[4*k]};
	fd = $fopen({"debug/", CAP, "/", GAME, "_sprctrl.bin"}, "rb"); if (!fd) begin $display("FATAL no sprctrl"); $finish; end
	n = $fread(tmp, fd); $fclose(fd);
	for (k = 0; k < 32; k = k + 1) sprctrl[k] = {tmp[4*k+3], tmp[4*k+2], tmp[4*k+1], tmp[4*k]};
	for (k = 0; k < 320*224; k = k + 1) fb[k] = 16'hFFFF;
	#1;
	$display("%s: sprite ROM %0d bytes, ctrl[0x10] %04x (%s walk), LAT %0d", CAP, rom_mask + 1,
	         sprctrl[4][15:0], sprctrl[4][15] ? "tail->0" : "0->tail", LAT);

	repeat (10) @(posedge clk);
	reset = 0;
	repeat (10) @(posedge clk);
	frame_start = 1; @(posedge clk); frame_start = 0;
	wait (done);
	@(posedge clk);

	fd = $fopen({OUTDIR, "/sim_sprites.txt"}, "w"); if (!fd) begin $display("FATAL cannot write to %s", OUTDIR); $finish; end
	for (k = 0; k < 320*224; k = k + 1) $fwrite(fd, "%04x\n", fb[k] == 16'hFFFF ? 16'hFFFF : {4'd0, fb[k][11:0]});
	$fclose(fd);
	$display("clocks per state: READ %0d SETUP %0d MUL %0d CLIP %0d ROW %0d PIX %0d ROM %0d WR %0d NEXT %0d; S_PIX visits %0d",
	         st_cnt[1], st_cnt[2], st_cnt[3], st_cnt[4], st_cnt[5], st_cnt[6], st_cnt[7], st_cnt[8], st_cnt[9], px_steps);
	$display("frame written to %s: %0d sprites drawn, %0d pixel writes, %0d clk (%0d%% of a 1,615,872-clk frame), overrun=%0d",
	         OUTDIR, drawn, writes, cycles, cycles * 100 / 1615872, overrun);
	$finish;
end

endmodule
