//============================================================================
//  V60 differential bench (DESIGN.md §11.2)
//  Loads a $readmemh program image (from gen_diff_program.py), runs s32_v60
//  to HALT, prints the final register file + scratch memory in the exact
//  format run_diff.sh compares against the reference model's .expected file.
//============================================================================
`timescale 1ns/1ps

module tb_v60_diff;

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

reg [1023:0] hexfile;
integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    if (!$value$plusargs("hex=%s", hexfile)) begin
        $display("no +hex="); $finish;
    end
    $readmemh(hexfile, ram);

    repeat (6) @(posedge clk);
    rst = 0;

    // run to HALT or timeout
    for (i = 0; i < 200000; i = i + 1) begin
        @(posedge clk);
        if (cpu.halted) i = 200000;
    end

    for (i = 0; i < 8; i = i + 1)
        $display("R%0d=%08x", i, cpu.r[i]);
    for (i = 0; i < 8; i = i + 1)
        $display("M%0d=%04x%04x", i, ram[(16'h8000>>1)+2*i+1], ram[(16'h8000>>1)+2*i]);
    $finish;
end

endmodule
