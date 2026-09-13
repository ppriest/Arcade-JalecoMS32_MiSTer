// SPDX-License-Identifier: GPL-3.0-or-later
//
//  The YMF271 on its own: every Z80 write to 0x3F00-0x3F0F in MAME's sound
//  trace replayed at MAME's time into rtl/sound/ymf271, at clk_sys 96 MHz
//  with the chip on a clock enable every other clock as ms32_sound runs it,
//  with the set's sample ROM behind a toggle-handshake memory model. The
//  chip's output is written once per 44.1 kHz tick as 16-bit stereo, for
//  scripts/compare_ymf_audio.py against MAME's -wavwrite of the same run.
//
//      python scripts/mame_sound_trace.py tetrisp --frames 1800 --wav
//      python scripts/run_verilator.py ymf_tb +GAME=tetrisp +MS=20000
//      python scripts/compare_ymf_audio.py tetrisp
//
//  +GAME   set (default tetrisp)
//  +MS     emulated milliseconds (default 10000)
//  +LAT    sample memory latency in clocks (default 16)
//  +DUMP0=ms +DUMP1=ms  per-slot envelope state and phase at every sample tick
//          in that window, to <OUT>/rtl_slots.txt (the format of the
//          temporary MAME dump used to compare against)
`timescale 1ns/1ps

module tb_ymf;

localparam real HZ = 96.0e6;
reg clk = 0;
always #5.208 clk = ~clk;
reg reset = 1;
longint clocks = 0;
always @(posedge clk) clocks <= clocks + 1;

string  GAME, OUTDIR;
integer MS, LAT;

// ------------------------------------------------------------- DUT
reg        wr = 0;
reg  [3:0] addr = 0;
reg  [7:0] din = 0;
wire [7:0] dout;
wire [25:0] sdr_addr;
reg  [63:0] sdr_dout;
wire        sdr_req;
reg         sdr_ack = 0;
wire [15:0] audio_l, audio_r, dbg_overrun, dbg_active;

ssbus_if ss_regs(), ss_par(), ss_st(), ss_fb();
assign ss_regs.select = 8'hFF; assign ss_regs.query = 1'b0; assign ss_regs.read = 1'b0; assign ss_regs.write = 1'b0;
assign ss_regs.data = 64'd0;   assign ss_regs.addr = 32'd0;
assign ss_par.select  = 8'hFF; assign ss_par.query  = 1'b0; assign ss_par.read  = 1'b0; assign ss_par.write  = 1'b0;
assign ss_par.data  = 64'd0;   assign ss_par.addr  = 32'd0;
assign ss_st.select   = 8'hFF; assign ss_st.query   = 1'b0; assign ss_st.read   = 1'b0; assign ss_st.write   = 1'b0;
assign ss_st.data   = 64'd0;   assign ss_st.addr   = 32'd0;
assign ss_fb.select   = 8'hFF; assign ss_fb.query   = 1'b0; assign ss_fb.read   = 1'b0; assign ss_fb.write   = 1'b0;
assign ss_fb.data   = 64'd0;   assign ss_fb.addr   = 32'd0;

// as ms32_sound drives it: a clock enable every other clock, 48 MHz
reg ce = 0;
always @(posedge clk) ce <= reset ? 1'b0 : ~ce;
ymf271 #(.CLK_HZ_X3(29'd144000000)) u_ymf (
	.clk(clk), .ce(ce), .reset(reset), .pause(1'b0),
	.ssbus_regs(ss_regs), .ssbus_par(ss_par), .ssbus_st(ss_st), .ssbus_fb(ss_fb),
	.stereo(1'b1), .pcm_25mb(1'b1), .ymf_16384(1'b0),
	.addr(addr), .din(din), .dout(dout), .wr(wr), .rd(1'b0), .irq(),
	.sdr_addr(sdr_addr), .sdr_dout(sdr_dout), .sdr_req(sdr_req), .sdr_ack(sdr_ack),
	.ext_wr(), .ext_wd(), .ext_a(), .ext_ovr(1'b0), .ext_ovr_data(8'h00), .mem_dirty(1'b0),
	.audio_l(audio_l), .audio_r(audio_r), .dbg_overrun(dbg_overrun), .dbg_active(dbg_active)
);

// ------------------------------------------------------------- sample memory
reg [7:0] pcm [0:(1 << 22) - 1];
integer   cnt = 0, i;
reg       req_d = 0;
always @(posedge clk) begin
	req_d <= sdr_req;
	if (cnt == 0) begin
		if (sdr_req != sdr_ack && sdr_req != req_d) cnt <= LAT;
		else if (sdr_req != sdr_ack && cnt == 0) cnt <= LAT;
	end else if (cnt == 1) begin
		for (i = 0; i < 8; i = i + 1) sdr_dout[8*i +: 8] <= pcm[(sdr_addr + i) & 26'h3F_FFFF];
		sdr_ack <= sdr_req; cnt <= 0;
	end else cnt <= cnt - 1;
end

// ------------------------------------------------------------- audio out
integer fa, n_samp = 0, max_over = 0;
always @(posedge clk) if (ce && u_ymf.sample_tick && fa != 0) begin
	$fwrite(fa, "%c%c%c%c", audio_l[7:0], audio_l[15:8], audio_r[7:0], audio_r[15:8]);
	n_samp = n_samp + 1;
	if (dbg_overrun > max_over) max_over = dbg_overrun;
end

// ------------------------------------------------------------- slot dump
integer fd = 0, d0 = -1, d1 = -1, sn;
reg [127:0] st;
always @(posedge clk) if (ce && u_ymf.sample_tick && fd != 0) begin
	if (clocks / 96000 >= d0 && clocks / 96000 < d1)
		for (sn = 0; sn < 48; sn = sn + 1) begin
			st = u_ymf.synth.st_mem[sn];
			if (st[46:44] != 3'd4)
				$fdisplay(fd, "%.6f %0d st%0d att%0d ph%08x", clocks / HZ, sn, st[46:44], st[56:47], st[127:96]);
		end
end

// ------------------------------------------------------------- stimulus
integer fi, r, data, a16, n_wr = 0;
string  line, kind;
real    t;
longint due;
initial begin
	fa = 0;
	if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
	if (!$value$plusargs("MS=%d", MS))     MS = 10000;
	if (!$value$plusargs("LAT=%d", LAT))   LAT = 16;
	OUTDIR = {"simout/ymf-", GAME};
	if ($value$plusargs("DUMP0=%d", d0) && $value$plusargs("DUMP1=%d", d1)) fd = $fopen({OUTDIR, "/rtl_slots.txt"}, "w");
	fi = $fopen({"roms/", GAME, "/ymf.bin"}, "rb");
	if (fi == 0) begin $display("FATAL no roms/%s/ymf.bin", GAME); $finish; end
	r = $fread(pcm, fi); $fclose(fi);
	fa = $fopen({OUTDIR, "/rtl_audio.raw"}, "wb");
	if (fa == 0) begin $display("FATAL cannot write %s (create it)", OUTDIR); $finish; end
	fi = $fopen({"debug/", GAME, "-sound/", GAME, "_sound.trace"}, "r");
	if (fi == 0) begin $display("FATAL no sound trace"); $finish; end
	$display("%s: %0d sample bytes, %0d ms, LAT %0d", GAME, r, MS, LAT);
	repeat (20) @(posedge clk);
	reset = 0;
	while (!$feof(fi)) begin
		r = $fgets(line, fi);
		if (r == 0 || line.len() == 0 || line.getc(0) == "#") continue;
		r = $sscanf(line, "%f %s %h %h", t, kind, a16, data);
		if (r < 4 || kind != "zw" || a16 < 32'h3F00 || a16 > 32'h3F0F) continue;
		if (t * 1000 >= MS) break;
		due = longint'(t * HZ);
		while (clocks < due) @(posedge clk);
		addr <= a16[3:0]; din <= data[7:0]; wr <= 1; @(posedge clk); @(posedge clk); wr <= 0;   // spans a ce
		n_wr = n_wr + 1;
	end
	while (clocks < longint'(MS * HZ / 1000)) @(posedge clk);
	$fclose(fa); fa = 0;
	$display("YMF: %0d ms, %0d writes, %0d samples, worst dbg_overrun %0d -> %s/rtl_audio.raw",
	         MS, n_wr, n_samp, max_over, OUTDIR);
	$finish;
end

endmodule
