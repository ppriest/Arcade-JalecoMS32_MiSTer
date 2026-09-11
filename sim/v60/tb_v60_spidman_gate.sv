//============================================================================
//  Spider-Man scroll-gated enemy activation regression.
//
//  Executes the literal instruction forms used by the waiting-object manager:
//    1B 60 39 B0 02 06 00   mov.h 6[2B0[R25]], R0
//    BA 20 14 3C            cmp.h 3C[R20], R0
//
//  R25+0x2B0 holds a pointer to the 32-bit fixed-point camera block.  The
//  manager admits an object only when both camera halves are inside the signed
//  windows at R20+{38,3A,3C,3E}.  This is the path shared by the early Venom,
//  Scorpion, and fat-enemy symptom.
//============================================================================
`timescale 1ns/1ps

module tb_v60_spidman_gate;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
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

// The real addresses are 0x20xxxx.  Mirroring on the low 16 address bits keeps
// this directed model small while preserving the addresses seen by the CPU.
reg [15:0] ram [0:32767];
reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;

integer ptr_lo_reads, ptr_hi_reads, cam_x_reads, cam_y_reads;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && !m_we && !ack_r) begin
        case ({m_addr, 1'b0})
            24'h2082b0: ptr_lo_reads = ptr_lo_reads + 1;
            24'h2082b2: ptr_hi_reads = ptr_hi_reads + 1;
            24'h208344: cam_x_reads  = cam_x_reads + 1;
            24'h208346: cam_y_reads  = cam_y_reads + 1;
            default: ;
        endcase
    end
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
begin
    if (pc_a[0]) ram[pc_a >> 1][15:8] = b;
    else         ram[pc_a >> 1][7:0]  = b;
    pc_a = pc_a + 1;
end
endtask

task patchb(input integer addr, input [7:0] b);
begin
    if (addr[0]) ram[addr >> 1][15:8] = b;
    else         ram[addr >> 1][7:0]  = b;
end
endtask

task aw32(input [31:0] w);
begin
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
end
endtask

task movw_imm(input [4:0] rn, input [31:0] imm);
begin
    ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(imm);
end
endtask

integer br_y_hi, br_y_lo, br_x_hi, br_x_lo, fail_pc;
task build_program;
begin
    pc_a = 0;
    movw_imm(5'd25, 32'h0020_8000); // R25: global work-RAM base
    movw_imm(5'd20, 32'h0020_9000); // R20: waiting-object record

    // Literal 0x087A99 camera-Y fetch and window compare.
    ab(8'h1b); ab(8'h60); ab(8'h39); ab(8'hb0); ab(8'h02); ab(8'h06); ab(8'h00);
    ab(8'hba); ab(8'h20); ab(8'h14); ab(8'h3c);
    br_y_hi = pc_a; ab(8'h6f); ab(8'h00); // bgt fail
    ab(8'hba); ab(8'h20); ab(8'h14); ab(8'h3e);
    br_y_lo = pc_a; ab(8'h6c); ab(8'h00); // blt fail

    // Literal 0x087AAC camera-X fetch and window compare.
    ab(8'h1b); ab(8'h60); ab(8'h39); ab(8'hb0); ab(8'h02); ab(8'h04); ab(8'h00);
    ab(8'hba); ab(8'h20); ab(8'h14); ab(8'h38);
    br_x_hi = pc_a; ab(8'h6f); ab(8'h00); // bgt fail
    ab(8'hba); ab(8'h20); ab(8'h14); ab(8'h3a);
    br_x_lo = pc_a; ab(8'h6c); ab(8'h00); // blt fail

    movw_imm(5'd10, 32'hc0de_c0de);
    ab(8'h00); // HALT: admitted

    fail_pc = pc_a;
    movw_imm(5'd10, 32'hdead_f00d);
    ab(8'h00); // HALT: rejected

    // V60 short Bcc displacement is relative to the branch opcode address.
    patchb(br_y_hi + 1, fail_pc - br_y_hi);
    patchb(br_y_lo + 1, fail_pc - br_y_lo);
    patchb(br_x_hi + 1, fail_pc - br_x_hi);
    patchb(br_x_lo + 1, fail_pc - br_x_lo);
end
endtask

integer pass = 0, fail = 0, cycles;
task run_case(
    input [15:0] cam_x,
    input [15:0] cam_y,
    input [15:0] x_upper,
    input [15:0] x_lower,
    input [15:0] y_upper,
    input [15:0] y_lower,
    input        admit,
    input [255:0] name
);
begin
    // Pointer at 0x2082B0 -> 0x208340 (little-endian 32-bit).
    ram[16'h82b0 >> 1] = 16'h8340;
    ram[16'h82b2 >> 1] = 16'h0020;
    ram[16'h8344 >> 1] = cam_x;
    ram[16'h8346 >> 1] = cam_y;
    ram[16'h9038 >> 1] = x_upper;
    ram[16'h903a >> 1] = x_lower;
    ram[16'h903c >> 1] = y_upper;
    ram[16'h903e >> 1] = y_lower;

    ptr_lo_reads = 0; ptr_hi_reads = 0;
    cam_x_reads = 0; cam_y_reads = 0;
    rst = 1;
    repeat (8) @(posedge clk);
    rst = 0;
    for (cycles = 0; cycles < 4000 && !cpu.halted; cycles = cycles + 1)
        @(posedge clk);

    if (cpu.halted &&
        cpu.r[10] == (admit ? 32'hc0de_c0de : 32'hdead_f00d) &&
        ptr_lo_reads >= 1 && ptr_hi_reads >= 1 && cam_y_reads >= 1 &&
        (!admit || cam_x_reads >= 1)) begin
        pass = pass + 1;
        $display("  ok   %0s r0=%04x reads ptr=%0d/%0d cam=%0d/%0d",
                 name, cpu.r[0][15:0], ptr_lo_reads, ptr_hi_reads,
                 cam_x_reads, cam_y_reads);
    end
    else begin
        fail = fail + 1;
        $display("  FAIL %0s halted=%0d pc=%08x r0=%08x r10=%08x reads ptr=%0d/%0d cam=%0d/%0d",
                 name, cpu.halted, cpu.pc, cpu.r[0], cpu.r[10],
                 ptr_lo_reads, ptr_hi_reads, cam_x_reads, cam_y_reads);
    end
end
endtask

integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    build_program();

    run_case(16'h0240, 16'h0260, 16'h0300, 16'h0200, 16'h0300, 16'h0200,
             1'b1, "both camera coordinates inside window");
    run_case(16'h0240, 16'h0400, 16'h0300, 16'h0200, 16'h0300, 16'h0200,
             1'b0, "camera Y above upper bound (BGT)");
    run_case(16'h0240, 16'h0100, 16'h0300, 16'h0200, 16'h0300, 16'h0200,
             1'b0, "camera Y below lower bound (BLT)");
    run_case(16'h0400, 16'h0260, 16'h0300, 16'h0200, 16'h0300, 16'h0200,
             1'b0, "camera X above upper bound (BGT)");
    run_case(16'h0100, 16'h0260, 16'h0300, 16'h0200, 16'h0300, 16'h0200,
             1'b0, "camera X below lower bound (BLT)");
    run_case(16'hff00, 16'hff20, 16'hff40, 16'hfec0, 16'hff40, 16'hfec0,
             1'b1, "signed-negative camera window");

    if (fail == 0) $display("SPIDMAN GATE PASS (%0d cases)", pass);
    else           $display("SPIDMAN GATE FAIL (%0d/%0d failed)", fail, pass + fail);
    $finish;
end

initial begin
    #1000000;
    $display("SPIDMAN GATE FAIL (timeout)");
    $finish;
end

endmodule
