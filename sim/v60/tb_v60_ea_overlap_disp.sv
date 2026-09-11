// Directed test for the Stage B EA_OVERLAP displacement fast-path
// (rtl/cpu/v60/s32_v60.sv, "eaf_disp_direct").  The random cosim generator
// (verif/cosim/gen_diff_program.py) only emits register-direct AM operands
// (modtop==3), so it never exercises this code path -- this test is that
// coverage.  Also serves as the plan's "EA base hazard" directed test
// (docs/v60-pipelining-plan.md Section 5): MOV R2<-imm; MOV ...,[R2+disp]
// back-to-back, proving the fast path reads R2's freshly-written value, not
// a stale one, since it shares the same register file port semantics as the
// existing a/b ports.
`timescale 1ns/1ps

module tb_v60_ea_overlap_disp;
reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0] c_size;
wire m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0] m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .fast_ifetch(1'b0),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1)
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:65535];
reg ack_r;
assign m_rdata = ram[m_addr[16:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[16:1]][15:8] <= m_wdata[15:8];
    end
end

integer ap;
task ab(input [7:0] b);
    begin
        if (ap[0]) ram[ap>>1][15:8] = b;
        else       ram[ap>>1][7:0] = b;
        ap = ap + 1;
    end
endtask
task aw16(input [15:0] w); begin ab(w[7:0]); ab(w[15:8]); end endtask
task aw32(input [31:0] w); begin ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); end endtask
task movw_imm(input [4:0] rn, input [31:0] v);
    begin ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(v); end
endtask
task halt; begin ab(8'h00); end endtask

integer errors = 0;
integer sim_cycles = 0;
integer last_run_cycles = 0;
always @(posedge clk) sim_cycles = sim_cycles + 1;
task check16(input [15:0] got, input [15:0] want, input [255:0] label);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %0s: got=%04x want=%04x", label, got, want);
    end
    else $display("  ok   %0s: %04x", label, got);
endtask

task run_one(input [255:0] label, input integer settle_cycles);
    integer start_cycle;
    begin
        rst = 1; repeat (8) @(posedge clk); rst = 0;
        start_cycle = sim_cycles;
        while (!cpu.halted && (sim_cycles - start_cycle) < settle_cycles)
            @(posedge clk);
        last_run_cycles = sim_cycles - start_cycle;
        $display("  timing %0s: %0d clocks", label, last_run_cycles);
        if (!cpu.halted) begin
            errors = errors + 1;
            $display("  FAIL %0s: did not halt within %0d clocks",
                     label, settle_cycles);
        end
        repeat (4) @(posedge clk);
    end
endtask

`ifdef __ICARUS__
// Reproduce the state-history dependency from Spider-Man: a previous string
// operation left S_STR_OP2 in st_after_ea.  Icarus permits the deliberate
// internal-state deposit used here; the ordinary functional cases remain in
// the Verilator suite.  Each D=1 value-read overlap must replace this token
// before launching S_EA_VAL.
task run_one_poisoned(input [255:0] label, input integer settle_cycles);
    integer start_cycle;
    begin
        rst = 1; repeat (8) @(posedge clk); rst = 0;
        cpu.st_after_ea = cpu.S_STR_OP2;
        start_cycle = sim_cycles;
        while (!cpu.halted && (sim_cycles - start_cycle) < settle_cycles)
            @(posedge clk);
        last_run_cycles = sim_cycles - start_cycle;
        $display("  timing %0s: %0d clocks", label, last_run_cycles);
        if (!cpu.halted) begin
            errors = errors + 1;
            $display("  FAIL %0s: stale EA continuation escaped", label);
        end
        repeat (4) @(posedge clk);
    end
endtask
`endif

initial begin
    // ---------------------------------------------------------------------
    // Case 1: ADDW R1, [R2+0x10] (byte displacement, F2 D=0, op2 = AM).
    // R2 = 0x300 (base, points into RAM as a byte address >>1 word index).
    // R1 = 5.  Memory word at (0x300+0x10)/2 = word 0x188 pre-set to 7.
    // Expect: word 0x188 becomes 7+5=12 after ADDW commits.
    // ---------------------------------------------------------------------
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0188] = 16'd7;
    ap = 0;
    movw_imm(5'd2, 32'h0000_0300);   // R2 = base
    movw_imm(5'd1, 32'd5);           // R1 = 5
    // ADDW R1,[R2+0x10]: opcode 0x84 (ADDW, F12 group), instflags = D=0,
    // ea_modm=0, reg=R1 (0x01) -> byte = 0x00|0x01 = 0x01 (bit5=D=0,
    // bit6=ea_modm=0).  Mode byte: modtop=0 (byte disp), modreg=R2 (0x02)
    // -> 0x02.  Displacement byte: 0x10.
    ab(8'h84); ab(8'h01); ab(8'h02); ab(8'h10);
    halt();
    run_one("case1", 300);
    check16(ram[16'h0188], 16'd12, "ADDW R1,[R2+byte_disp]");
    if (last_run_cycles > 105) begin errors = errors + 1; $display("  FAIL case1 throughput"); end

    // ---------------------------------------------------------------------
    // Case 2: half-word displacement, same shape, negative offset check via
    // a larger positive displacement (V60 disp is signed; use a value that
    // requires the half-word encoding, 0x0140, to force modtop==1).
    // R2 = 0x1000, disp=0x140 -> target byte addr 0x1140, word idx 0x8A0.
    // ---------------------------------------------------------------------
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h08a0] = 16'd100;
    ap = 0;
    movw_imm(5'd2, 32'h0000_1000);
    movw_imm(5'd1, 32'd23);
    // modtop=1 (half disp): mode byte = 0x20 | R2(0x02) = 0x22.
    ab(8'h84); ab(8'h01); ab(8'h22); aw16(16'h0140);
    halt();
    run_one("case2", 300);
    check16(ram[16'h08a0], 16'd123, "ADDW R1,[R2+half_disp]");
    if (last_run_cycles > 115) begin errors = errors + 1; $display("  FAIL case2 throughput"); end

    // ---------------------------------------------------------------------
    // Case 3: EA base hazard.  MOV R2<-new_base; ADDW R1,[R2+4] immediately
    // after, back to back with no intervening instruction.  Proves the fast
    // path reads R2's value as committed by the immediately preceding
    // instruction, not a stale pre-write value -- the scenario the plan's
    // hazard test set explicitly calls out.
    // ---------------------------------------------------------------------
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0102] = 16'd1;   // (0x200+4)/2 = 0x102
    ram[16'h0182] = 16'hDEAD; // (0x300+4)/2, must NOT be touched (stale base)
    ap = 0;
    movw_imm(5'd1, 32'd9);
    movw_imm(5'd2, 32'h0000_0300);   // R2 = 0x300 (stale value, if bug present)
    movw_imm(5'd2, 32'h0000_0200);   // R2 <- 0x200 (fresh value, immediately before use)
    ab(8'h84); ab(8'h01); ab(8'h02); ab(8'h04);  // ADDW R1,[R2+4]
    halt();
    run_one("case3", 300);
    check16(ram[16'h0102], 16'd10, "ADDW R1,[R2+4] uses FRESH R2 (0x200)");
    check16(ram[16'h0182], 16'hDEAD, "stale-base target must be untouched");
    if (last_run_cycles > 131) begin errors = errors + 1; $display("  FAIL case3 throughput"); end

    // ---------------------------------------------------------------------
    // Case 4: common F2 D=1 memory source. ADDW [R2+4],R1 must launch the
    // physical read directly from S_IF2 while preserving the same result.
    // ---------------------------------------------------------------------
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0102] = 16'd7;
    ap = 0;
    movw_imm(5'd1, 32'd5);
    movw_imm(5'd2, 32'h0000_0200);
    ab(8'h84); ab(8'h21); ab(8'h02); ab(8'h04);  // ADDW [R2+4],R1
    halt();
    run_one("case4", 300);
    check16(cpu.r[1][15:0], 16'd12, "ADDW [R2+4],R1 memory-source overlap");
    if (last_run_cycles > 105) begin
        errors = errors + 1;
        $display("  FAIL case4 throughput: %0d clocks want<=105", last_run_cycles);
    end

    // Case 5: register-indirect source is the zero-displacement companion.
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0100] = 16'd9;
    ap = 0;
    movw_imm(5'd1, 32'd4);
    movw_imm(5'd2, 32'h0000_0200);
    ab(8'h84); ab(8'h21); ab(8'h62);              // ADDW [R2],R1
    halt();
    run_one("case5", 300);
    check16(cpu.r[1][15:0], 16'd13, "ADDW [R2],R1 indirect-source overlap");
    if (last_run_cycles > 105) begin
        errors = errors + 1;
        $display("  FAIL case5 throughput: %0d clocks want<=105", last_run_cycles);
    end

`ifdef __ICARUS__
    // Case 6: the same register-indirect source with a deliberately stale
    // non-S_EXEC continuation.  Before the fix this enters the string states,
    // over-consumes one instruction byte and fails to halt at the successor.
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0100] = 16'd9;
    ap = 0;
    movw_imm(5'd1, 32'd4);
    movw_imm(5'd2, 32'h0000_0200);
    ab(8'h84); ab(8'h21); ab(8'h62);              // ADDW [R2],R1
    halt();
    run_one_poisoned("case6-stale-continuation", 300);
    check16(cpu.r[1][15:0], 16'd13, "D=1 overlap replaces stale continuation");

    // Case 7: displacement companion, independently guarding the other direct
    // S_EA_VAL launch fixed by this change.
    for (ap = 0; ap < 65536; ap = ap + 1) ram[ap] = 16'h0000;
    ram[16'h0102] = 16'd9;
    ap = 0;
    movw_imm(5'd1, 32'd4);
    movw_imm(5'd2, 32'h0000_0200);
    ab(8'h84); ab(8'h21); ab(8'h02); ab(8'h04);  // ADDW [R2+4],R1
    halt();
    run_one_poisoned("case7-stale-disp-continuation", 300);
    check16(cpu.r[1][15:0], 16'd13, "D=1 displacement replaces stale continuation");
`endif

    if (errors == 0)
        $display("V60 EA_OVERLAP DISP PASS");
    else
        $display("V60 EA_OVERLAP DISP FAIL errors=%0d", errors);
    $finish;
end

initial begin
    #200000;
    $display("V60 EA_OVERLAP DISP FAIL timeout");
    $finish;
end
endmodule
