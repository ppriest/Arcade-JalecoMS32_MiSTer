//============================================================================
//  Spider-Man waiting-enemy trigger-window constructor regression.
//
//  Runs the literal 0x087E9B..0x087EEB instruction stream. Reversed endpoint
//  pairs exercise XCH.H R0,R1 before the game expands them into camera bounds.
//============================================================================
`timescale 1ns/1ps

module tb_v60_spidman_window;

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
reg ack_r = 0;
assign m_rdata = ram[m_addr[16:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[16:1]][15:8] <= m_wdata[15:8];
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
task movw_imm(input [4:0] rn, input [31:0] v);
begin
    ab(8'h2d); ab(8'h20 | rn); ab(8'hf4); aw32(v);
end
endtask

integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;
    movw_imm(5'd20, 32'h0000_8000);

    // Literal game code 0x087E9B..0x087EEB, then HALT in place of RSR.
    ab(8'h1b); ab(8'h20); ab(8'h14); ab(8'h20);
    ab(8'h1b); ab(8'h21); ab(8'h14); ab(8'h24);
    ab(8'hba); ab(8'h40); ab(8'h61);
    ab(8'h6d); ab(8'h05);
    ab(8'h43); ab(8'h40); ab(8'h61);
    ab(8'h1b); ab(8'h00); ab(8'h14); ab(8'h32);
    ab(8'h1b); ab(8'h01); ab(8'h14); ab(8'h30);
    ab(8'haa); ab(8'h20); ab(8'hf4); ab(8'h40); ab(8'h06);
    ab(8'h82); ab(8'h21); ab(8'hf4); ab(8'h40); ab(8'h01);
    ab(8'h1b); ab(8'h00); ab(8'h14); ab(8'h3a);
    ab(8'h1b); ab(8'h01); ab(8'h14); ab(8'h38);
    ab(8'h1b); ab(8'h20); ab(8'h14); ab(8'h22);
    ab(8'h1b); ab(8'h21); ab(8'h14); ab(8'h26);
    ab(8'hba); ab(8'h40); ab(8'h61);
    ab(8'h6d); ab(8'h05);
    ab(8'h43); ab(8'h40); ab(8'h61);
    ab(8'h1b); ab(8'h00); ab(8'h14); ab(8'h36);
    ab(8'h1b); ab(8'h01); ab(8'h14); ab(8'h34);
    ab(8'haa); ab(8'h20); ab(8'hf4); ab(8'hc0); ab(8'h04);
    ab(8'h82); ab(8'h21); ab(8'hf4); ab(8'h40); ab(8'h01);
    ab(8'h1b); ab(8'h00); ab(8'h14); ab(8'h3e);
    ab(8'h1b); ab(8'h01); ab(8'h14); ab(8'h3c);
    ab(8'h00);

    // Both endpoint pairs are deliberately reversed and must be exchanged.
    ram[16'h8020 >> 1] = 16'h0200;
    ram[16'h8024 >> 1] = 16'h0100;
    ram[16'h8022 >> 1] = 16'h0700;
    ram[16'h8026 >> 1] = 16'h0300;

    repeat (8) @(posedge clk);
    rst = 0;
    wait (cpu.halted);
    repeat (4) @(posedge clk);

    if (ram[16'h8032 >> 1] == 16'h0100 &&
        ram[16'h8030 >> 1] == 16'h0200 &&
        ram[16'h803a >> 1] == 16'hfac0 &&
        ram[16'h8038 >> 1] == 16'h0340 &&
        ram[16'h8036 >> 1] == 16'h0300 &&
        ram[16'h8034 >> 1] == 16'h0700 &&
        ram[16'h803e >> 1] == 16'hfe40 &&
        ram[16'h803c >> 1] == 16'h0840)
        $display("SPIDMAN WINDOW PASS x=%04x..%04x y=%04x..%04x",
                 ram[16'h803a >> 1], ram[16'h8038 >> 1],
                 ram[16'h803e >> 1], ram[16'h803c >> 1]);
    else
        $display("SPIDMAN WINDOW FAIL endpoints=%04x/%04x,%04x/%04x windows=%04x..%04x,%04x..%04x",
                 ram[16'h8032 >> 1], ram[16'h8030 >> 1],
                 ram[16'h8036 >> 1], ram[16'h8034 >> 1],
                 ram[16'h803a >> 1], ram[16'h8038 >> 1],
                 ram[16'h803e >> 1], ram[16'h803c >> 1]);
    $finish;
end

initial begin
    #2000000;
    $display("SPIDMAN WINDOW FAIL (timeout)");
    $finish;
end

endmodule
