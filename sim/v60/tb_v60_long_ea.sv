//============================================================================
//  V60 long effective-address regression.
//
//  A legal F1 MOVW with two double-displacement operands is 20 bytes long.
//  Its second operand's second displacement starts at fetch-buffer byte 16.
//  This catches both:
//    * truncating disp_of's fetch-buffer offset to four bits; and
//    * truncating total_len to four bits before advancing PC.
//============================================================================
`timescale 1ns/1ps

module tb_v60_long_ea;

reg clk = 0, rst = 1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire  [1:0] c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire  [1:0] m_be;

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

reg [15:0] ram [0:32767];
reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;

always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
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

task aw32(input [31:0] w);
begin
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
end
endtask

integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;

    // R0 = pointer-table source base, R1 = pointer-table destination base.
    ab(8'h2d); ab(8'h20); ab(8'hf4); aw32(32'h0000_1000);
    ab(8'h2d); ab(8'h21); ab(8'hf4); aw32(32'h0000_1010);

    // MOVW [[R0 + disp32(0)] + disp32(0)],
    //      [[R1 + disp32(0)] + disp32(0)]
    // F1 flags E0 select modm=1 for both operands. Each mode is nine bytes,
    // so the instruction spans bytes 14..33 and its final displacement starts
    // at fetch-buffer offset 16.
    ab(8'h2d); ab(8'he0);
    // modtop=2 selects 32-bit displacements; low five bits select R0/R1.
    ab(8'h40); aw32(32'h0000_0000); aw32(32'h0000_0000);
    ab(8'h41); aw32(32'h0000_0000); aw32(32'h0000_0000);
    ab(8'h00); // HALT at byte 34; a four-bit total_len lands at byte 18.

    // Double-indirection tables and source/destination values.
    ram[16'h1000 >> 1]       = 16'h2000;
    ram[(16'h1000 >> 1) + 1] = 16'h0000;
    ram[16'h1010 >> 1]       = 16'h3000;
    ram[(16'h1010 >> 1) + 1] = 16'h0000;
    ram[16'h2000 >> 1]       = 16'h5678;
    ram[(16'h2000 >> 1) + 1] = 16'h1234;
    ram[16'h3000 >> 1]       = 16'hdead;
    ram[(16'h3000 >> 1) + 1] = 16'hbeef;

    repeat (8) @(posedge clk);
    rst = 0;
    repeat (12000) @(posedge clk);

    if (cpu.halted && cpu.pc == 32'd34 &&
        ram[16'h3000 >> 1] == 16'h5678 &&
        ram[(16'h3000 >> 1) + 1] == 16'h1234)
        $display("LONG EA PASS");
    else begin
        $display("LONG EA FAIL halted=%0d pc=%08x dest=%04x_%04x total_len=%0d",
                 cpu.halted, cpu.pc,
                 ram[(16'h3000 >> 1) + 1], ram[16'h3000 >> 1], cpu.total_len);
    end
    $finish;
end

endmodule
