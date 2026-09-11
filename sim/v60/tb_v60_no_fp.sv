//============================================================================
// Golden Axe V60 no-FP profile: valid 0x5C and 0x5F sub-opcodes must take the
// architectural reserved-instruction vector when S32_V60_NO_FP is defined.
//============================================================================
`timescale 1ns/1ps

module tb_v60_no_fp;

`ifndef S32_V60_NO_FP
initial begin
    $display("V60 NO-FP FAIL (S32_V60_NO_FP is not defined)");
    $finish;
end
`endif

reg clk = 1'b0;
reg rst = 1'b1;
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

reg [15:0] ram [0:32767];
reg ack_r = 1'b0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;

always @(posedge clk) begin
    if (rst) ack_r <= 1'b0;
    else begin
        ack_r <= m_req & ~ack_r;
        if (m_req && m_we && !ack_r) begin
            if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
        end
    end
end

integer i;
integer errors = 0;

task automatic check_reserved(input [7:0] op, input [7:0] extension);
    integer cycles;
begin
    rst = 1'b1;
    repeat (4) @(posedge clk);
    for (i = 0; i < 256; i = i + 1) ram[i] = 16'h0000;

    // A valid FP sub-opcode sits in the extension byte. Vector 8 at 0x20
    // points to a HALT handler at 0x100.
    ram[0]   = {extension, op};
    ram[16]  = 16'h0100;
    ram[17]  = 16'h0000;
    ram[128] = 16'h0000;
    ram[16'h3ffc] = 16'hdead;
    ram[16'h3ffd] = 16'hbeef;
    cpu.r[31] = 32'h0000_8000;

    rst = 1'b0;
    cycles = 0;
    while (!cpu.halted && cycles < 2000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    if (!cpu.halted || cpu.pc !== 32'h0000_0100 ||
        cpu.r[31] !== 32'h0000_7ff8 ||
        {ram[16'h3ffd], ram[16'h3ffc]} !== 32'h0000_0000) begin
        errors = errors + 1;
        $display("NO-FP RESERVED %02x FAIL halt=%0d pc=%08x sp=%08x saved_pc=%08x",
                 op, cpu.halted, cpu.pc, cpu.r[31],
                 {ram[16'h3ffd], ram[16'h3ffc]});
    end
    else $display("NO-FP RESERVED %02x PASS cycles=%0d", op, cycles);
end
endtask

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    check_reserved(8'h5c, 8'h78); // valid ADDFS group encoding
    check_reserved(8'h5f, 8'h60); // valid CVTWS group encoding

    if (errors == 0) $display("V60 NO-FP PASS");
    else             $display("V60 NO-FP FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #200000;
    $display("V60 NO-FP FAIL (timeout)");
    $finish;
end

endmodule
