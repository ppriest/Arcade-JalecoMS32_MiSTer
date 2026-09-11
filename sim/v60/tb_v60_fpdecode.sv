//============================================================================
//  V60 FP group full-instruction decode test: assembles real ADDFS/MULFS
//  instructions (register and memory operand forms) and runs them end to end,
//  exercising the 0x5C decode -> operand fetch -> compute -> writeback path.
//  Expected float32 results computed by hand (RNE): 2.5+1.5=4.0, 3.0*1.5=4.5.
//============================================================================
`timescale 1ns/1ps
module tb_v60_fpdecode;
reg clk = 0, rst = 1;
always #10 clk = ~clk;
wire c_req, c_we, c_ack; wire [31:0] c_addr, c_wdata, c_rdata; wire [1:0] c_size;
wire m_req, m_we, m_ack; wire [23:1] m_addr; wire [15:0] m_wdata, m_rdata; wire [1:0] m_be;
s32_v60 #(.START_PC(32'h0)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'h00), .irq_ack(), .nmi_n(1'b1));
s32_v60_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack));
reg [15:0] ram [0:32767]; reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]]; assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end
integer i, errors = 0;
task automatic check(input condition, input [255:0] nm);
    if (condition !== 1'b1) begin errors = errors + 1; $display("  FAIL: %0s", nm); end
endtask
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    begin : prog
        reg [7:0] p [0:31]; integer k;
        k = 0;
        // ADDFS R1, R2      : 5C 78 61 62   (op1=reg1 val, op2=reg2 RMW) -> R2 = R2 + R1
        p[k]=8'h5c; k++; p[k]=8'h78; k++; p[k]=8'h61; k++; p[k]=8'h62; k++;
        // MULFS R1, [R3]    : 5C 5A 61 63   (op1=reg1 val, op2=[R3] mem RMW) -> [R3] = [R3]*R1
        p[k]=8'h5c; k++; p[k]=8'h5a; k++; p[k]=8'h61; k++; p[k]=8'h63; k++;
        // NEGFS R1, [R4]    : 5C 49 61 64   (op1=reg1 val, op2=[R4] WRITE-ONLY:
        // MAME does ReadAMAddress + store, no load — the read counter below
        // proves the destination is never read)
        p[k]=8'h5c; k++; p[k]=8'h49; k++; p[k]=8'h61; k++; p[k]=8'h64; k++;
        // HALT
        p[k]=8'h00; k++;
        for (i = 0; i < 16; i = i + 1) ram[i] = {p[2*i+1], p[2*i]};
    end
    // data: [R3=0x8000] = 3.0 (0x40400000)
    ram[16'h8000 >> 1]       = 16'h0000;   // low half of 0x40400000
    ram[(16'h8000 >> 1) + 1] = 16'h4040;   // high half
    // [R4=0x8100] = poison; NEGFS must overwrite it without reading it
    ram[16'h8100 >> 1]       = 16'hbeef;
    ram[(16'h8100 >> 1) + 1] = 16'hdead;
end
// count data reads of the NEGFS destination (0x8100-0x8103): must stay 0
integer negfs_dst_reads = 0;
always @(posedge clk)
    if (m_req && !m_we && !ack_r &&
        (m_addr == 23'(16'h8100 >> 1) || m_addr == 23'((16'h8100 >> 1) + 1)))
        negfs_dst_reads = negfs_dst_reads + 1;
initial begin
    // preload GPRs (reset preserves them): R1=1.5, R2=2.5, R3/R4=data ptrs
    cpu.r[1] = 32'h3fc00000;   // 1.5
    cpu.r[2] = 32'h40200000;   // 2.5
    cpu.r[3] = 32'h00008000;   // pointer
    cpu.r[4] = 32'h00008100;   // NEGFS dest pointer
    repeat (8) @(posedge clk);
    rst = 0;
    repeat (600) @(posedge clk);
    $display("R2=%08x  mem[0x8000]=%04x%04x  mem[0x8100]=%04x%04x  halted=%0d",
        cpu.r[2], ram[(16'h8000>>1)+1], ram[16'h8000>>1],
        ram[(16'h8100>>1)+1], ram[16'h8100>>1], cpu.halted);
    check(cpu.r[2] === 32'h40800000, "ADDFS R1,R2 -> 4.0");                        // 2.5+1.5
    check({ram[(16'h8000>>1)+1], ram[16'h8000>>1]} === 32'h40900000, "MULFS [R3] -> 4.5"); // 3.0*1.5
    check({ram[(16'h8100>>1)+1], ram[16'h8100>>1]} === 32'hbfc00000, "NEGFS [R4] -> -1.5"); // -R1
    check(negfs_dst_reads == 0, "NEGFS dest never read");
    check(cpu.halted, "halted");
    if (errors == 0) $display("V60 FPDECODE PASS");
    else             $display("V60 FPDECODE FAIL (%0d errors)", errors);
    $finish;
end
initial begin #200000; $display("V60 FPDECODE FAIL (timeout)"); $finish; end
endmodule
