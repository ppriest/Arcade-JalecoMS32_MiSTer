// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-System Sources and Probes for the video engines' time, read over JTAG
// with scripts/read_issp.py (MS32_stp revision only, DEBUG_ISSP). What it
// answers on the board, where the DDR3 behind the sprite frame buffer and the
// object RAM copy has a latency no bench models: did an engine run out of
// time, how often, and by how much was the margin smallest.
//
// Instance "V":
//   [6:0]    sticky overrun flags: TX, BG, ROZ, sprites, frame-buffer read, unhandled priority mask, rotation FIFO
//   [22:7]   sprite frames still drawing when the next object RAM copy finished
//   [38:23]  sprite frame-buffer lines read late
//   [54:39]  ROZ lines not finished before display
//   [78:55]  longest sprite frame, clocks
//   [102:79] latest object RAM copy finish after vblank start, clocks
//   [118:103] frames (vblank starts)
//   [134:119] frame count at the last late ROZ line
//   [150:135] resets seen (rises of the core's composite reset)
//   [174:151] length of the last reset, clocks (saturating)
//   [190:175] OSD reset (status[0]) rises
//   [206:191] V70 reset rises as ms32_cpu_sys sees it (clk_sys copy of its reset)
//   [222:207] V70 32-bit reads of the DIP switches   [238:223] of them not the switch register
//   [270:239] the last such value   (these three from clk_cpu: sampled, not synchronised)
//   [286:271] YMF271 passes that missed their tick (since reset)
//   [302:287] longest YMF271 sample fetch wait for SDRAM, clocks (since reset)
//   [318:303] longest V70 instruction fetch wait for SDRAM, clocks (since reset)
// Source bit 0 clears the counts and maxima (the sticky flags clear with the core's reset).
module issp_video_probe #(
	parameter [7:0] INSTANCE_ID = "V"
) (
	input logic        clk,
	input logic [6:0]  flags,
	input logic        vblank_ev,
	input logic        spr_ovr_ev,
	input logic        fb_ovr_ev,
	input logic        roz_ovr_ev,
	input logic        copy_done,
	input logic [23:0] spr_frame_cycles,
	input logic        core_reset,
	input logic        osd_reset,
	input logic        cpu_reset,
	input logic [15:0] dsw_reads,
	input logic [15:0] dsw_bad,
	input logic [31:0] dsw_last_bad,
	input logic [15:0] ymf_overrun,
	input logic [15:0] ymf_wait_max,
	input logic [15:0] if_wait_max
);

	logic [15:0] c_spr, c_fb, c_roz, c_frames, roz_last, c_rst, c_osd, c_cpu;
	logic [23:0] rst_len, rst_cnt;
	logic        rst_d, osd_d, cpu_d;
	logic [23:0] max_spr, max_copy, since_vbl;
	logic        clear;

	function automatic logic [15:0] sat(input logic [15:0] v, input logic inc);
		sat = (inc && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction

	always_ff @(posedge clk) begin
		since_vbl <= vblank_ev ? 24'd0 : (since_vbl == 24'hFFFFFF ? since_vbl : since_vbl + 24'd1);
		rst_d <= core_reset; osd_d <= osd_reset; cpu_d <= cpu_reset;
		if (core_reset) rst_cnt <= (rst_cnt == 24'hFFFFFF) ? rst_cnt : rst_cnt + 24'd1;
		else rst_cnt <= 24'd0;
		if (clear) begin
			c_spr <= '0; c_fb <= '0; c_roz <= '0; c_frames <= '0; max_spr <= '0; max_copy <= '0;
			roz_last <= '0; c_rst <= '0; c_osd <= '0; c_cpu <= '0; rst_len <= '0;
		end else begin
			c_spr    <= sat(c_spr,    spr_ovr_ev);
			c_fb     <= sat(c_fb,     fb_ovr_ev);
			c_roz    <= sat(c_roz,    roz_ovr_ev);
			c_frames <= sat(c_frames, vblank_ev);
			if (spr_frame_cycles > max_spr) max_spr <= spr_frame_cycles;
			if (copy_done && since_vbl > max_copy) max_copy <= since_vbl;
			if (roz_ovr_ev) roz_last <= c_frames;
			c_rst <= sat(c_rst, core_reset && !rst_d);
			c_osd <= sat(c_osd, osd_reset && !osd_d);
			c_cpu <= sat(c_cpu, cpu_reset && !cpu_d);
			if (!core_reset && rst_d) rst_len <= rst_cnt;
		end
	end

	wire [318:0] probe_bus = {if_wait_max, ymf_wait_max, ymf_overrun, dsw_last_bad, dsw_bad, dsw_reads, c_cpu, c_osd, rst_len, c_rst, roz_last, c_frames, max_copy, max_spr, c_roz, c_fb, c_spr, flags};
	wire [0:0]   source_bus;
	assign clear = source_bus[0];

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(319),
		.source_width(1),
		.source_initial_value("0"),
		.enable_metastability("NO"),
		.lpm_type("altsource_probe")
	) u_issp (
		.probe(probe_bus),
		.source(source_bus),
		.source_clk(clk),
		.source_ena(1'b1)
	);

endmodule
