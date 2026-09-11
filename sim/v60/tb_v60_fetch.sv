//============================================================================
//  V60 fetch-loop performance regression.
//
//  Models the short backward branch pattern seen in svf's boot delay loop:
//  an immediate MOVW loop body followed by DBR.  Functional correctness alone is
//  not enough here; repeatedly refilling the full 20-byte fetch window makes
//  branch-heavy game code several times slower than the real V60.
//============================================================================
`timescale 1ns/1ps

module tb_v60_fetch;

localparam integer ITERATIONS = 256;
`ifdef V60_NO_LOOP_RESTORE
localparam integer CYCLE_BUDGET = 2800;
`else
localparam integer CYCLE_BUDGET = 2200;
`endif

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

reg [15:0] ram [0:32767];
reg ack_r = 0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;

integer read_txns = 0;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (!rst && m_req && !m_we && !ack_r) read_txns = read_txns + 1;
end

integer i;
initial begin : init_program
    reg [7:0] p [0:31];
    integer k;
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    for (i = 0; i < 32; i = i + 1) p[i] = 8'h00;
    k = 0;

    // MOVW #ITERATIONS, R0
    p[k]=8'h2D; k=k+1; p[k]=8'h20; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=ITERATIONS[7:0]; k=k+1; p[k]=ITERATIONS[15:8]; k=k+1;
    p[k]=8'h00; k=k+1; p[k]=8'h00; k=k+1;

    // loop: MOVW #$12345678,R1; DBR R0, loop (-7 from DBR); HALT
    p[k]=8'h2D; k=k+1; p[k]=8'h21; k=k+1; p[k]=8'hF4; k=k+1;
    p[k]=8'h78; k=k+1; p[k]=8'h56; k=k+1;
    p[k]=8'h34; k=k+1; p[k]=8'h12; k=k+1;
    p[k]=8'hC6; k=k+1; p[k]=8'hA0; k=k+1;
    p[k]=8'hF9; k=k+1; p[k]=8'hFF; k=k+1;
    p[k]=8'h00;

    for (i = 0; i < 16; i = i + 1)
        ram[i] = {p[2*i+1], p[2*i]};
end

integer cycles = 0;
initial begin
    repeat (8) @(posedge clk);
    rst = 0;
    while (!cpu.halted && cycles < 100000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end

    $display("FETCH PERF: iterations=%0d cycles=%0d reads=%0d r0=%0d halted=%0d",
        ITERATIONS, cycles, read_txns, cpu.r[0], cpu.halted);
    if (cpu.halted && cpu.r[0] == 0 && cpu.r[1] == 32'h1234_5678 &&
        cycles <= CYCLE_BUDGET && read_txns <= 16)
        $display("FETCH PERF PASS");
    else begin
        if (cycles > CYCLE_BUDGET)
            $display("  cycle budget exceeded: %0d > %0d", cycles, CYCLE_BUDGET);
        if (read_txns > 16)
            $display("  read budget exceeded: %0d > 16", read_txns);
        $display("FETCH PERF FAIL");
    end
    $finish;
end

endmodule
