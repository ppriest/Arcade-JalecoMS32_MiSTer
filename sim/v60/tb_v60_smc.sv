//============================================================================
//  V60 self-modifying-code / fetch-window coherency regression.
//
//  Audit gap (V60-19, s32_v60.sv:2909-2920): a completing data write that
//  overlaps the live (or retained) fetch window must invalidate it so the CPU
//  executes the NEW bytes, not stale prefetched ones.  No existing test covers
//  this, and it is the #1 correctness risk for an instruction prefetcher (which
//  keeps MORE bytes ahead of PC, making the overlap window larger).  This test
//  locks the current behavior BEFORE the prefetch redesign.
//
//  Program stores a fresh imm32 over the immediate of an instruction that is
//  only a few bytes ahead of PC (guaranteed inside the fetch window at store
//  time), then executes it and checks the register got the NEW value.
//============================================================================
`timescale 1ns/1ps

module tb_v60_smc;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

// +CEDIV=<n>: gate ce every n-th clock (default 1 = every clock). The unit
// suite runs ce=1; gated ce (e.g. /3, the production V60 cadence) exercises the
// ack-sampling / wait-state paths the audit flagged as untested.
integer cediv = 1;
integer cecnt = 0;
reg ce = 1'b1;
initial if (!$value$plusargs("CEDIV=%d", cediv)) cediv = 1;
always @(posedge clk) begin
    if (cecnt >= cediv-1) begin cecnt <= 0; ce <= 1'b1; end
    else begin cecnt <= cecnt + 1; ce <= 1'b0; end
end

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(ce), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1)
);

s32_v60_bus adapter (
    .clk(clk), .ce(ce), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:32767];
reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    // honour byte-enables so the SMC store lands in RAM (same unified memory
    // the fetch reads back)
    if (!rst && m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

integer i;
initial begin : init_program
    reg [7:0] p [0:31];
    integer k;
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    for (i = 0; i < 32; i = i + 1) p[i] = 8'h00;
    k = 0;
    // 0: MOVW #$0000BEEF, R0    (2D 20 F4 EF BE 00 00) - the replacement value
    p[0]=8'h2D; p[1]=8'h20; p[2]=8'hF4; p[3]=8'hEF; p[4]=8'hBE; p[5]=8'h00; p[6]=8'h00;
    // 7: MOVW R0, [$14]         (2D 00 F3 14 00 00 00) - store R0 over target imm32 at byte 20
    p[7]=8'h2D; p[8]=8'h00; p[9]=8'hF3; p[10]=8'h14; p[11]=8'h00; p[12]=8'h00; p[13]=8'h00;
    // 14..16: NOP NOP NOP       (CD) - keep target inside the fetch window, let store retire
    p[14]=8'hCD; p[15]=8'hCD; p[16]=8'hCD;
    // 17: MOVW #$11111111, R1   (2D 21 F4 11 11 11 11) - imm at bytes 20..23 gets overwritten
    p[17]=8'h2D; p[18]=8'h21; p[19]=8'hF4; p[20]=8'h11; p[21]=8'h11; p[22]=8'h11; p[23]=8'h11;
    // 24: HALT
    p[24]=8'h00;
    for (i = 0; i < 16; i = i + 1) ram[i] = {p[2*i+1], p[2*i]};
end

integer cycles = 0;
initial begin
    repeat (8) @(posedge clk);
    rst = 0;
    while (!cpu.halted && cycles < 20000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end
    $display("V60 SMC: halted=%0d r0=%08x r1=%08x cycles=%0d",
        cpu.halted, cpu.r[0], cpu.r[1], cycles);
    if (cpu.halted && cpu.r[0] == 32'h0000_BEEF && cpu.r[1] == 32'h0000_BEEF)
        $display("V60 SMC PASS");
    else begin
        if (cpu.r[1] == 32'h1111_1111)
            $display("  FAIL: executed STALE fetch-window bytes (r1=11111111)");
        else
            $display("  FAIL: r1=%08x expected 0000BEEF", cpu.r[1]);
        $display("V60 SMC FAIL");
    end
    $finish;
end

endmodule
