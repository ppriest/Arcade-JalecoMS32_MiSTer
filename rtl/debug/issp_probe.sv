// SPDX-License-Identifier: GPL-3.0-or-later
//
// In-System Sources and Probes instrumentation, read over JTAG with
// scripts/read_issp.py (which holds the machine-wide JTAG marker so no
// Quartus or ModelSim run overlaps it -- scripts/hwlock.py; that overlap
// has bugchecked this PC). Built only in the MS32_stp revision
// (DEBUG_ISSP). Ported from the Psikyo core's rtl/debug/issp_probe.sv,
// where the design is explained: SignalTap is GUI-only in Quartus Prime
// Lite 17.0, and what distinguishes the causes of "nothing arrives" is a
// handful of saturating counts, not a waveform.
//
// Instance "M" -- the memory path:
//   [15:0]   download bytes accepted (ioctl_wr with index 0)
//   [31:16]  download writes issued to the SDRAM arbiter (dl_req rises)
//   [47:32]  download writes completed (dl_busy falls)
//   [63:48]  tile/sprite granule reads completed (any valid)
//   [64]     ioctl_wait seen high      [65] ioctl_download seen
//   [66]     pll_locked now            [67] ioctl_wait now
//   [83:68]  ROZ cache fills          [99:84] ROZ cache hits
//   [115:100] last ioctl_addr[15:0] accepted
//   [131:116] ROZ pens written non-zero
// Source bit 0 clears the counters.
module issp_probe #(
	parameter [7:0] INSTANCE_ID = "M"
) (
	input logic        clk,
	input logic        dl_byte,        // ioctl_wr && index 0
	input logic [15:0] dl_addr_lo,
	input logic        dl_req,
	input logic        dl_busy,
	input logic        rom_valid,      // any granule read completing
	input logic        ioctl_wait,
	input logic        ioctl_download,
	input logic        pll_locked,
	input logic        roz_fill,
	input logic        roz_hit,
	input logic        roz_pen_nz
);

	logic [15:0] c_byte, c_issued, c_done, c_reads, c_fill, c_hit, c_pen;
	logic [15:0] last_addr;
	logic        wait_seen, dl_seen, dl_req_d, dl_busy_d;
	logic        clear;

	function automatic logic [15:0] sat(input logic [15:0] v, input logic inc);
		sat = (inc && v != 16'hFFFF) ? v + 16'd1 : v;
	endfunction

	always_ff @(posedge clk) begin
		dl_req_d  <= dl_req;
		dl_busy_d <= dl_busy;
		if (clear) begin
			c_byte <= '0; c_issued <= '0; c_done <= '0; c_reads <= '0; c_fill <= '0; c_hit <= '0; c_pen <= '0;
			wait_seen <= 1'b0; dl_seen <= 1'b0; last_addr <= '0;
		end else begin
			c_byte   <= sat(c_byte,   dl_byte);
			c_issued <= sat(c_issued, dl_req && !dl_req_d);
			c_done   <= sat(c_done,   !dl_busy && dl_busy_d);
			c_reads  <= sat(c_reads,  rom_valid);
			c_fill   <= sat(c_fill,   roz_fill);
			c_hit    <= sat(c_hit,    roz_hit);
			c_pen    <= sat(c_pen,    roz_pen_nz);
			if (dl_byte) last_addr <= dl_addr_lo;
			if (ioctl_wait)     wait_seen <= 1'b1;
			if (ioctl_download) dl_seen   <= 1'b1;
		end
	end

	wire [131:0] probe_bus = {c_pen, last_addr, c_hit, c_fill,
	                          ioctl_wait, pll_locked, dl_seen, wait_seen,
	                          c_reads, c_done, c_issued, c_byte};
	wire [0:0] source_bus;
	assign clear = source_bus[0];

	altsource_probe #(
		.sld_auto_instance_index("YES"),
		.instance_id(INSTANCE_ID),
		.probe_width(132),
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
