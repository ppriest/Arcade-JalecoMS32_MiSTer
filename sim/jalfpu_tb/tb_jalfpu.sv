// SPDX-License-Identifier: GPL-3.0-or-later
//
// rtl/cpu/jalfpu/jalfpu.sv against MAME's own execution of the same program.
//
//     python scripts/run_verilator.py jalfpu_tb +TRACE=simout/f1-trace/fpu0_exec.txt
//
// The trace is one ordered event stream, written by the patched MAME in the
// F-1 Super Battle worktree (docs/ROADMAP.md, "F-1 Super Battle"):
//
//   H <p|d|r> <offset> <data>   a host write: program RAM, data RAM, register
//   S <pc> <s0..sf> <c6> <c7> <flags> <sign> <sp>     a routine start
//   I <ppc> <op> <s0..sf> <c6> <c7> <flags> <sign> <sp>   after one instruction
//
// The bench applies each host write with the core frozen, then releases it for
// exactly one instruction per I line and diffs the whole register file. The
// first difference is printed with both sides and the run stops, since
// everything after it is a consequence.
`timescale 1ns/1ps

module tb_jalfpu;

	logic clk = 0, rst = 1;
	always #5 clk = ~clk;

	logic        h_req = 0, h_we = 0;
	logic [14:0] h_addr = 0;
	logic [15:0] h_wdata = 0, h_rdata;
	logic        h_valid, irq;
	logic        stall = 1, retire;
	logic [9:0]  ppc;
	logic [19:0] op;
	logic [255:0] sregs;
	logic [15:0] c6, c7, sign;
	logic [3:0]  flags;
	logic [2:0]  sp;

	jalfpu #(.CE_DIV(1)) dut (
		.clk(clk), .rst(rst),
		.h_req(h_req), .h_we(h_we), .h_addr(h_addr), .h_wdata(h_wdata),
		.h_rdata(h_rdata), .h_valid(h_valid), .irq(irq),
		.dbg_stall(stall), .dbg_retire(retire), .dbg_ppc(ppc), .dbg_op(op),
		.dbg_s(sregs), .dbg_c6(c6), .dbg_c7(c7), .dbg_sign(sign),
		.dbg_flags(flags), .dbg_sp(sp),
		.dbg_ren(1'b0), .dbg_raddr(12'd0), .dbg_rdata()
	);

	// ------------------------------------------------------------ host access
	task automatic host_write(input logic [14:0] addr, input logic [15:0] data);
		begin
			@(posedge clk);
			h_req <= 1'b1; h_we <= 1'b1; h_addr <= addr; h_wdata <= data;
			@(posedge clk);
			while (!h_valid) @(posedge clk);
			h_req <= 1'b0; h_we <= 1'b0;
			@(posedge clk);
		end
	endtask

	// ------------------------------------------------------------ the trace
	string  trace_path;
	integer fd, n, nins, nhost, nstart, bad;
	string  tok, kind;
	integer off, val, t_ppc, t_op, i;
	logic [15:0] t_s [0:15];
	integer t_c6, t_c7, t_flags, t_sign, t_sp;
	integer MAX;

	task automatic read_state();
		begin
			for (i = 0; i < 16; i = i + 1) begin
				n = $fscanf(fd, "%h", val);
				t_s[i] = val[15:0];
			end
			n = $fscanf(fd, "%h %h %h %h %d", t_c6, t_c7, t_flags, t_sign, t_sp);
		end
	endtask

	task automatic show_state(input string who);
		begin
			$display("  %-4s s0-s7 %04h %04h %04h %04h %04h %04h %04h %04h", who,
			         t_s[0], t_s[1], t_s[2], t_s[3], t_s[4], t_s[5], t_s[6], t_s[7]);
			$display("       s8-sf %04h %04h %04h %04h %04h %04h %04h %04h",
			         t_s[8], t_s[9], t_s[10], t_s[11], t_s[12], t_s[13], t_s[14], t_s[15]);
			$display("       c6 %04h c7 %04h flags %h sign %04h sp %0d",
			         t_c6[15:0], t_c7[15:0], t_flags[3:0], t_sign[15:0], t_sp);
		end
	endtask

	function automatic logic state_matches();
		logic ok;
		begin
			ok = 1'b1;
			for (i = 0; i < 16; i = i + 1)
				if (sregs[16*i +: 16] !== t_s[i]) ok = 1'b0;
			if (c6 !== t_c6[15:0] || c7 !== t_c7[15:0]) ok = 1'b0;
			if (flags !== t_flags[3:0] || sign !== t_sign[15:0]) ok = 1'b0;
			if (sp !== t_sp[2:0]) ok = 1'b0;
			state_matches = ok;
		end
	endfunction

	task automatic report_mismatch(input string what);
		begin
			$display("MISMATCH at instruction %0d (%s), fpu pc %03h op %05h", nins, what, ppc, op);
			show_state("mame");
			for (i = 0; i < 16; i = i + 1) t_s[i] = sregs[16*i +: 16];
			t_c6 = c6; t_c7 = c7; t_flags = flags; t_sign = sign; t_sp = sp;
			show_state("rtl");
		end
	endtask

	initial begin
		if (!$value$plusargs("TRACE=%s", trace_path)) trace_path = "simout/f1-trace/fpu0_exec.txt";
		if (!$value$plusargs("MAX=%d", MAX)) MAX = 0;         // 0: the whole trace
		fd = $fopen(trace_path, "r");
		if (fd == 0) begin $display("FATAL: no %s", trace_path); $finish; end

		repeat (4) @(posedge clk);
		rst = 0;
		repeat (4) @(posedge clk);

		nins = 0; nhost = 0; nstart = 0; bad = 0;
		while (!$feof(fd) && bad == 0 && (MAX == 0 || nins < MAX)) begin
			n = $fscanf(fd, "%s", tok);
			if (n != 1) begin
				// end of file
			end else if (tok == "H") begin
				n = $fscanf(fd, "%s %h %h", kind, off, val);
				nhost = nhost + 1;
				if (kind == "p")      host_write(15'h4000 + off[12:0] * 4, val[15:0]);
				else if (kind == "d") host_write(off[12:0] * 4, val[15:0]);
				else                  host_write(15'h2400 + off[5:0] * 4, val[15:0]);
			end else if (tok == "S") begin
				n = $fscanf(fd, "%h", t_ppc);
				read_state();
				nstart = nstart + 1;
				if (!state_matches()) begin
					$display("MISMATCH at routine start %0d (pc %03h)", nstart, t_ppc[9:0]);
					show_state("mame");
					for (i = 0; i < 16; i = i + 1) t_s[i] = sregs[16*i +: 16];
					t_c6 = c6; t_c7 = c7; t_flags = flags; t_sign = sign; t_sp = sp;
					show_state("rtl");
					bad = 1;
				end
			end else if (tok == "I") begin
				n = $fscanf(fd, "%h %h", t_ppc, t_op);
				read_state();
				// let exactly one instruction run
				stall = 0;
				@(posedge clk);
				while (!retire) @(posedge clk);
				stall = 1;
				@(posedge clk);
				nins = nins + 1;
				if (ppc !== t_ppc[9:0] || op !== t_op[19:0]) begin
					$display("MISMATCH at instruction %0d: mame pc %03h op %05h, rtl pc %03h op %05h",
					         nins, t_ppc[9:0], t_op[19:0], ppc, op);
					bad = 1;
				end else if (!state_matches()) begin
					report_mismatch("state after the instruction");
					bad = 1;
				end
			end
		end

		$display("JALFPU: %0d instructions, %0d host writes, %0d routine starts, %0d mismatch",
		         nins, nhost, nstart, bad);
		$fclose(fd);
		$finish;
	end

	// a stuck core should not hang the run
	initial begin
		#500_000_000;
		$display("TIMEOUT after %0d instructions", nins);
		$finish;
	end

endmodule
