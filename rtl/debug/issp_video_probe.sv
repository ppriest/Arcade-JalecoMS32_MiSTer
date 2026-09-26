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
//   [150:135] YMF271 passes that missed their tick (since reset)
//   [166:151] longest YMF271 sample fetch wait for SDRAM, clocks (since reset)
//   [182:167] longest V70 instruction fetch wait for SDRAM, clocks (since reset)
//   [198:183] F-1 Super Battle: V70 writes past the road RAMs, which alias (0 elsewhere)
//   [199]     F-1 Super Battle: the road line plane has overrun a line (sticky)
//   [215:200] road lines not finished before display
//   [235:216] F-1 Super Battle: longest FPU routine, clk_cpu clocks (a frame is 333,333)
//   [251:236] FPU routines started   (both from clk_cpu: sampled, not synchronised)
//   [267:252] road map writes   [283:268] road line RAM writes (clk_cpu, saturating)
//   [299:284] road lines the plane drew in the last frame (0 = every line blank)
//   [315:300] non-zero road pens written in the last frame (0 = the ROM gives nothing)
//   [328:316] sprites drawn, last frame
//
// Removed once they had answered their question rather than carried: the reset
// counts and lengths (c524b91, for whether the board's OSD Reset reaches the
// core -- it does) and the V70's DIP switch reads (557d2e8, for The Game
// Paradise's one-frame Japanese logo). 136 bits and their counters.
// New fields go on the TOP of the bus: the offsets above are in read_issp.tcl.
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
	input logic [15:0] ymf_overrun,
	input logic [15:0] ymf_wait_max,
	input logic [15:0] if_wait_max,
	input logic [15:0] road_over,
	input logic        road_ovr,
	input logic        road_ovr_ev,
	input logic [19:0] fpu_max,
	input logic [15:0] fpu_runs,
	input logic [15:0] road_vw,
	input logic [15:0] road_lw,
	input logic [15:0] road_lines,
	input logic [15:0] road_pens,
	input logic [12:0] spr_drawn
);

	logic [15:0] c_spr, c_fb, c_roz, c_road, c_frames, roz_last;
	logic [23:0] max_spr, max_copy, since_vbl;
	logic        clear;

	function automatic logic [15:0] sat(input logic [15:0] v, input logic inc);
		sat = (inc && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction

	always_ff @(posedge clk) begin
		since_vbl <= vblank_ev ? 24'd0 : (since_vbl == 24'hFFFFFF ? since_vbl : since_vbl + 24'd1);
		if (clear) begin
			c_spr <= '0; c_fb <= '0; c_roz <= '0; c_road <= '0; c_frames <= '0; max_spr <= '0; max_copy <= '0;
			roz_last <= '0;
		end else begin
			c_spr    <= sat(c_spr,    spr_ovr_ev);
			c_fb     <= sat(c_fb,     fb_ovr_ev);
			c_roz    <= sat(c_roz,    roz_ovr_ev);
			c_road   <= sat(c_road,   road_ovr_ev);
			c_frames <= sat(c_frames, vblank_ev);
			if (spr_frame_cycles > max_spr) max_spr <= spr_frame_cycles;
			if (copy_done && since_vbl > max_copy) max_copy <= since_vbl;
			if (roz_ovr_ev) roz_last <= c_frames;
		end
	end

	wire [328:0] probe_bus = {spr_drawn, road_pens, road_lines, road_lw, road_vw, fpu_runs, fpu_max, c_road, road_ovr, road_over, if_wait_max, ymf_wait_max, ymf_overrun, roz_last, c_frames, max_copy, max_spr, c_roz, c_fb, c_spr, flags};
	wire [0:0]   source_bus;
	assign clear = source_bus[0];

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(329),
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
