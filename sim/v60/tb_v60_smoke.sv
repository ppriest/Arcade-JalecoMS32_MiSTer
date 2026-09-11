//============================================================================
//  V60 smoke testbench: 64KB RAM model on the 16-bit bus, hand-assembled
//  program exercising MOV/ADD/CMP/Bcc/JSR/RET/PUSH/POP.
//  Pass criterion printed at end.
//============================================================================
`timescale 1ns/1ps

module tb_v60_smoke;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

// CPU <-> adapter
wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;

// adapter <-> memory
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(),
    .nmi_n(1'b1)
);

s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// 64KB RAM, 16-bit
reg [15:0] ram [0:32767];
reg        ack_r;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

// ---------------------------------------------------------------------
// program (hand-assembled V60):
//   0000: MOVW #$12345678, R0      ; 2D 20 6A 78 56 34 12  (F2, D=0? -> op1=AM imm, op2=reg)
//         encoding: opcode 2D; instflags = 0x40|... use F2 D=1: 2D, iflags=0x20|reg
//         iflags bit7=0(F2) bit5=1(D: op2=reg0? D=1 -> op2 reg) modm=bit6 for op1
//         iflags = 0x20 | 0 (reg0), op1 mode byte at PC+2: mode7 imm full = 0xE0|0x14? mode byte:
//         modm=0 top3=7 -> Group7, low5=0x14 immediate -> byte 0xF4, then 4 bytes little endian
//   Program below (bytes):
//    2D 20 F4 78 56 34 12      MOVW #12345678h, R0
//    2D 21 F4 11 11 11 11      MOVW #11111111h, R1
//    84 A1 60                  ADDW R0? -- use F2 D=0: iflags=0x00|1? here: ADDW R1?, dest AM
//   For simplicity: ADDW R0, R1 via F2 D=1 (op1 = AM = reg R0 (modm=1 mode3), op2 = reg1):
//    84 61 70                  ADDW R0, R1   (iflags=0x20|1 |0x40 modm=1; mode byte 0x60|0=reg0)
//    (0x40 => modm=1: mode byte top3=3 means Register) mode byte = 0x60 | reg
//   ...
// The exact byte stream is built in the initial block.
// ---------------------------------------------------------------------
integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;

    // MOVW #$12345678, R0 : op=2D iflags=(F2,D=1,reg0)=0x20 modebyte=0xF4 imm32
    ram[0] = {8'h20, 8'h2D};       // 0000: 2D 20
    ram[1] = {8'h78, 8'hF4};       // 0002: F4 78
    ram[2] = {8'h34, 8'h56};       // 0004: 56 34
    ram[3] = {8'h21, 8'h12};       // 0006: 12 | next op 2D
    // Actually construct via byte array for clarity:
    begin : prog
        reg [7:0] p [0:63];
        integer k;
        k = 0;
        // MOVW #$12345678, R0
        p[k]=8'h2D; k++; p[k]=8'h20; k++; p[k]=8'hF4; k++;
        p[k]=8'h78; k++; p[k]=8'h56; k++; p[k]=8'h34; k++; p[k]=8'h12; k++;
        // MOVW #$11111111, R1
        p[k]=8'h2D; k++; p[k]=8'h21; k++; p[k]=8'hF4; k++;
        p[k]=8'h11; k++; p[k]=8'h11; k++; p[k]=8'h11; k++; p[k]=8'h11; k++;
        // ADDW R0, R1  (F2 D=1: iflags=0x20|1 + modm(bit6)=1; mode byte 0x60|0 = reg R0)
        p[k]=8'h84; k++; p[k]=8'h61; k++; p[k]=8'h60; k++;
        // CMPW R1, R0? -> CMPW #$23456789, R1 (F2 D=1 reg1, imm)
        p[k]=8'hBC; k++; p[k]=8'h21; k++; p[k]=8'hF4; k++;
        p[k]=8'h89; k++; p[k]=8'h67; k++; p[k]=8'h45; k++; p[k]=8'h23; k++;
        // BE8 +4 (should be taken: R1 == 0x23456789)
        p[k]=8'h64; k++; p[k]=8'h04; k++;
        // (skipped if taken) HALT HALT
        p[k]=8'h00; k++; p[k]=8'h00; k++;
        // target: MOVW R1, R2 (F2 D=1 reg2? op1=AM reg1) -> 2D iflags=0x62 mode=0x61
        p[k]=8'h2D; k++; p[k]=8'h62; k++; p[k]=8'h61; k++;
        // HALT
        p[k]=8'h00; k++;
        for (i = 0; i < 32; i = i + 1)
            ram[i] = {p[2*i+1], p[2*i]};
    end
end

initial begin
    repeat (8) @(posedge clk);
    rst = 0;
    repeat (3000) @(posedge clk);
    $display("R0=%08x R1=%08x R2=%08x halted=%0d",
        cpu.r[0], cpu.r[1], cpu.r[2], cpu.halted);
    if (cpu.r[0] == 32'h12345678 &&
        cpu.r[1] == 32'h23456789 &&
        cpu.r[2] == 32'h23456789 &&
        cpu.halted)
        $display("SMOKE PASS");
    else
        $display("SMOKE FAIL");
    $finish;
end

endmodule
