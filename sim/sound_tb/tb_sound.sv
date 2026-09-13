// SPDX-License-Identifier: GPL-3.0-or-later
//
//  The sound board (ms32_sound: T80, RAM, banks, latches and the YMF271)
//  running the set's own audiocpu and ymf ROMs,
//  driven by the V70's side of MAME's sound trace at MAME's times.
//
//      python scripts/mame_sound_trace.py tetrisp --frames 600
//      scripts/run_sim.sh sound_tb +GAME=tetrisp +MS=4000
//      python scripts/compare_sound_trace.py tetrisp
//
//  The bench replays the trace's cmd (latch write) and srst (sysctrl sound
//  reset, bit 0) lines, and writes simout/sound-<GAME>/rtl_sound.trace in the
//  trace's own format from what the Z80 does: zw for its writes to
//  0x3F00-0x3FFF except 0x3F70 (3F10 is to_main), zr for its reads of
//  0x3F00-0x3F1F with repeats collapsed.
//
//  Time is clocks / (8 MHz x CEN_DIV). -gCEN_DIV=N (default 12, the core's
//  96 MHz / 12) trades fidelity to the core's clocking for run time; the
//  YMF271 tick follows it. Under ModelSim (scripts/run_sim.sh defines
//  MS32_SIM_NO_YMF271) the chip is sim/sound_tb/ms32_ymf271_timers.sv's
//  timers-only stand-in; the chip itself is sim/ymf_tb's.
//
//  +GAME     set (default tetrisp)
//  +MS       emulated milliseconds to run (default 4000)
//  +LAT      granule latency behind the bridge, in clocks (default 12)
`timescale 1ns/1ps

module tb_sound #(
	parameter int CEN_DIV = 12
);

reg clk = 0;
always #5 clk = ~clk;
reg reset = 1;
longint clocks = 0;

string  GAME, OUTDIR;
integer MS, LAT;
real    HZ;

// ------------------------------------------------------------- DUT
reg         snd_reset = 0, cmd_we = 0;
reg  [7:0]  cmd_data = 0;
wire        to_main_we, rom_req;
wire [7:0]  to_main_data;
wire [17:0] rom_addr;
wire        rom_valid;
wire [7:0]  rom_data;
wire        pcm_req;
reg         pcm_ack = 0;
wire [21:0] pcm_addr;
reg  [63:0] pcm_data;
wire signed [15:0] audio_l, audio_r;

ms32_sound #(.CEN_DIV(CEN_DIV), .CLK_HZ_X3(29'(24000000 * CEN_DIV))) dut (
	.clk(clk), .reset(reset),
	.snd_reset(snd_reset), .cmd_we(cmd_we), .cmd_data(cmd_data),
	.to_main_we(to_main_we), .to_main_data(to_main_data),
	.rom_req(rom_req), .rom_addr(rom_addr), .rom_valid(rom_valid), .rom_data(rom_data),
	.pcm_req(pcm_req), .pcm_addr(pcm_addr), .pcm_ack(pcm_ack), .pcm_data(pcm_data),
	.audio_l(audio_l), .audio_r(audio_r)
);

// YMF271 sample memory: toggle handshake, LAT clocks
reg [7:0] pcm [0:(1 << 22) - 1];
integer   pcm_cnt = 0, pi;
always @(posedge clk) begin
	if (pcm_cnt == 0) begin
		if (pcm_req != pcm_ack) pcm_cnt <= LAT;
	end else if (pcm_cnt == 1) begin
		for (pi = 0; pi < 8; pi = pi + 1) pcm_data[8*pi +: 8] <= pcm[(pcm_addr + pi) & 22'h3F_FFFF];
		pcm_ack <= pcm_req; pcm_cnt <= 0;
	end else pcm_cnt <= pcm_cnt - 1;
end
integer fa = 0;
`ifndef MS32_SIM_NO_YMF271
always @(posedge clk) if (fa != 0 && dut.u_ymf.sample_tick)
	$fwrite(fa, "%c%c%c%c", audio_l[7:0], audio_l[15:8], audio_r[7:0], audio_r[15:8]);
`endif

// ------------------------------------------------------------- ROM model
// The core's path: sdram_narrow_bridge (its one-granule cache answers a hit
// in two clocks) in front of a granule store with LAT clocks of latency.
reg  [7:0]  rom [0:262143];
wire        g_req;
wire [25:0] g_addr;
reg         g_valid = 0;
reg  [63:0] g_data;
integer     g_cnt = 0, gi;
reg  [17:0] g_la;
sdram_narrow_bridge #(.WORD_BYTES(1)) u_bridge (
	.clk(clk), .reset(reset), .inval(1'b0),
	.req(rom_req), .addr({8'd0, rom_addr}), .valid(rom_valid), .data(rom_data),
	.g_req(g_req), .g_addr(g_addr), .g_valid(g_valid), .g_data(g_data)
);
always @(posedge clk) begin
	g_valid <= 0;
	if (g_cnt == 0) begin
		// g_req is still high the clock after valid, until the bridge leaves B_WAIT
		if (g_req && !g_valid) begin g_la <= g_addr[17:0]; g_cnt <= LAT; end
	end else if (g_cnt == 1) begin
		for (gi = 0; gi < 8; gi = gi + 1) g_data[8*gi +: 8] <= rom[(g_la + gi) & 18'h3FFFF];
		g_valid <= 1; g_cnt <= 0;
	end else g_cnt <= g_cnt - 1;
end

// every byte the Z80 is handed checked against the ROM at the address it asked for
reg  [17:0] chk_addr;
integer     n_bad = 0;
always @(posedge clk) begin
	if (rom_req) chk_addr <= rom_addr;
	if (rom_valid && rom_data !== rom[rom_req ? rom_addr : chk_addr]) begin
		n_bad = n_bad + 1;
		if (n_bad <= 5) $display("ROM BAD at %0d: addr %05x got %02x want %02x", clocks, chk_addr, rom_data, rom[chk_addr]);
	end
end

// ------------------------------------------------------------- clock count
always @(posedge clk) clocks <= clocks + 1;
function real now();
	now = clocks / HZ;
endfunction

// ------------------------------------------------------------- trace out
integer fo;
integer n_zw = 0, n_zr = 0, n_tomain = 0, n_fetch = 0;
reg [15:0] zr_a;  reg [7:0] zr_d;  integer zr_rep = 0;  real zr_t;
reg [7:0]  di_last;
reg [15:0] a_last;
reg        mem_rd_d = 0, m1_d = 0;
wire       mem_rd = !dut.mreq_n && !dut.rd_n;

task flush_zr();
	if (zr_rep > 0) begin
		$fdisplay(fo, "%.9f\tzr\t%04X\t%02X\tx%0d", zr_t, zr_a, zr_d, zr_rep);
		zr_rep = 0;
	end
endtask

always @(posedge clk) begin
	mem_rd_d <= mem_rd;
	if (mem_rd) begin di_last <= dut.di; a_last <= dut.a; end
	if (!dut.m1_n && mem_rd && !m1_d) n_fetch = n_fetch + 1;
	m1_d <= !dut.m1_n && mem_rd;
	// a read ends: log it as the Z80 latched it
	if (mem_rd_d && !mem_rd && a_last[15:5] == 11'h1F8) begin
		n_zr = n_zr + 1;
		if (zr_rep > 0 && zr_a == a_last && zr_d == di_last) zr_rep = zr_rep + 1;
		else begin flush_zr(); zr_a = a_last; zr_d = di_last; zr_rep = 1; zr_t = now(); end
	end
	if (dut.wr_end && dut.wa[15:8] == 8'h3F && dut.wa != 16'h3F70) begin
		flush_zr();
		n_zw = n_zw + 1;
		$fdisplay(fo, "%.9f\tzw\t%04X\t%02X", now(), dut.wa, dut.wd);
	end
	if (to_main_we) n_tomain = n_tomain + 1;
end

// ------------------------------------------------------------- stimulus
integer fi, r;
string  line, kind;
real    t;
integer data;
longint due;

initial begin
	if (!$value$plusargs("GAME=%s", GAME))       GAME = "tetrisp";
	if (!$value$plusargs("MS=%d", MS))           MS = 4000;
	if (!$value$plusargs("LAT=%d", LAT))         LAT = 12;
	HZ = 8.0e6 * CEN_DIV;
	OUTDIR = {"simout/sound-", GAME};

	fi = $fopen({"roms/", GAME, "/audiocpu.bin"}, "rb");
	if (fi == 0) begin $display("FATAL no roms/%s/audiocpu.bin", GAME); $finish; end
	r = $fread(rom, fi); $fclose(fi);
	fi = $fopen({"roms/", GAME, "/ymf.bin"}, "rb");
	if (fi == 0) begin $display("FATAL no roms/%s/ymf.bin", GAME); $finish; end
	r = $fread(pcm, fi); $fclose(fi);
	fi = $fopen({"roms/", GAME, "/audiocpu.bin"}, "rb"); r = $fread(rom, fi); $fclose(fi);
	fa = $fopen({OUTDIR, "/rtl_audio.raw"}, "wb");
	fo = $fopen({OUTDIR, "/rtl_sound.trace"}, "w");
	if (fo == 0) begin $display("FATAL cannot write %s (create it)", OUTDIR); $finish; end
	$fdisplay(fo, "# t\tkind\t[addr]\tdata   (RTL, CEN_DIV %0d)", CEN_DIV);
	fi = $fopen({"debug/", GAME, "-sound/", GAME, "_sound.trace"}, "r");
	if (fi == 0) begin $display("FATAL no debug/%s-sound/%s_sound.trace", GAME, GAME); $finish; end
	$display("%s: audiocpu %0d bytes, %0d ms, CEN_DIV %0d, LAT %0d", GAME, r, MS, CEN_DIV, LAT);

	repeat (20) @(posedge clk);
	reset = 0;

	while (!$feof(fi)) begin
		r = $fgets(line, fi);
		if (r == 0 || line.len() == 0 || line.getc(0) == "#") continue;
		r = $sscanf(line, "%f %s %h", t, kind, data);
		if (r < 3 || !(kind == "cmd" || kind == "srst")) continue;
		if (t * 1000 >= MS) break;
		due = longint'(t * HZ);
		while (clocks < due) @(posedge clk);
		if (kind == "cmd") begin
			cmd_data <= data[7:0]; cmd_we <= 1; @(posedge clk); cmd_we <= 0;
			$display("%.6f cmd %02x", now(), data[7:0]);
		end else if (data[0]) begin
			snd_reset <= 1; @(posedge clk); snd_reset <= 0;
			$display("%.6f sound reset", now());
		end
	end
	while (clocks < longint'(MS * HZ / 1000)) @(posedge clk);
	flush_zr();
	$fclose(fo);
	$fclose(fa); fa = 0;
	$display("SOUND: %0d ms, %0d opcode fetches, %0d bad ROM bytes, %0d zw, %0d zr, %0d to_main -> %s/rtl_sound.trace",
	         MS, n_fetch, n_bad, n_zw, n_zr, n_tomain, OUTDIR);
	$finish;
end

endmodule
