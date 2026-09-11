//============================================================================
//  V60 MULX/DIVX with a MEMORY operand (audit R20 V60-9).  The old exec stored
//  no result for MULX/MULUX and skipped DIVX/DIVUX entirely when op2 was in
//  memory; register-pair forms were correct.  This checks the qword store and
//  the memory-dividend divide with quotient/remainder writeback.
//============================================================================
`timescale 1ns/1ps

module tb_v60_divxmem;

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

reg [15:0] ram [0:65535];
reg ack_r;
assign m_rdata = ram[m_addr[16:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[16:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) ram[pc_a>>1][15:8] = b;
    else         ram[pc_a>>1][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w); ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); endtask
task movw_imm(input [4:0] rn, input [31:0] imm);
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm);
endtask
task st_abs(input [4:0] rn, input [31:0] addr);   // MOVW Rn, [addr]
    ab(8'h2D); ab(8'h00 | rn); ab(8'hF3); aw32(addr);
endtask

function [31:0] rd32(input [31:0] a); rd32 = {ram[(a>>1)+1], ram[a>>1]}; endfunction

integer pass = 0, fail = 0;
task chk(input cond, input [255:0] name);
    if (cond) begin pass = pass + 1; $display("  ok   %0s", name); end
    else      begin fail = fail + 1; $display("  FAIL %0s", name); end
endtask

integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;
    movw_imm(5'd31, 32'h0001_0000);              // SP

    // MULX R2 * [0x9000] -> [0x9000] qword (0x10000*0x10000 = 0x1_00000000)
    movw_imm(5'd5, 32'h0001_0000);  st_abs(5'd5, 32'h0000_9000);
    movw_imm(5'd2, 32'h0001_0000);
    ab(8'h86); ab(8'hC0); ab(8'h60 | 5'd2); ab(8'hF3); aw32(32'h0000_9000); // MULX R2,[0x9000]

    // DIVX [0x9008](=100) / R3(=7) -> q=14 @ [0x9008], r=2 @ [0x900C]
    movw_imm(5'd5, 32'd100); st_abs(5'd5, 32'h0000_9008);
    movw_imm(5'd5, 32'd0);   st_abs(5'd5, 32'h0000_900C);
    movw_imm(5'd3, 32'd7);
    ab(8'hA6); ab(8'hC0); ab(8'h60 | 5'd3); ab(8'hF3); aw32(32'h0000_9008); // DIVX R3,[0x9008]

    ab(8'h00);                                   // HALT

    repeat (8) @(posedge clk);
    rst = 0;
    for (i = 0; i < 6000 && !cpu.halted; i = i + 1) @(posedge clk);

    $display("MULX[9000]=%08x_%08x  DIVX q[9008]=%08x r[900C]=%08x",
        rd32(32'h9004), rd32(32'h9000), rd32(32'h9008), rd32(32'h900C));
    chk(cpu.halted, "HALT reached");
    chk(rd32(32'h9000) == 32'h0000_0000, "MULX mem low 32 = 0");
    chk(rd32(32'h9004) == 32'h0000_0001, "MULX mem high 32 = 1");
    chk(rd32(32'h9008) == 32'd14, "DIVX mem quotient = 14");
    chk(rd32(32'h900C) == 32'd2,  "DIVX mem remainder = 2");

    if (fail == 0) $display("V60 DIVXMEM PASS (%0d checks)", pass);
    else           $display("V60 DIVXMEM FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin #300000; $display("V60 DIVXMEM FAIL (timeout)"); $finish; end
endmodule
