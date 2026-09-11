//============================================================================
//  V60 MOVD (64-bit move) directed test (audit R20 V60-10).  The old exec
//  moved only 32 bits; MOVD transfers a register pair or a memory qword.
//  Covers register-pair -> register-pair, register-pair -> memory qword, and
//  memory qword -> register-pair.
//============================================================================
`timescale 1ns/1ps

module tb_v60_movd;

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
    // seed source pair R4:R5
    movw_imm(5'd4, 32'hAAAA_1111);
    movw_imm(5'd5, 32'hBBBB_2222);

    // MOVD R4(:R5) -> R6(:R7): F2 D=1 (op2=R6, modm=1), op1=R4 reg-direct
    ab(8'h3F); ab(8'h60 | 5'd6); ab(8'h60 | 5'd4);

    // MOVD R4(:R5) -> [0x9000]: F1, op1=R4 reg-direct (modm=1), op2=direct addr
    //   iflags = 0x80 | 0x40(op1 modm=1) | 0x00(op2 modm=0) = 0xC0
    ab(8'h3F); ab(8'hC0); ab(8'h60 | 5'd4); ab(8'hF3); aw32(32'h0000_9000);

    // MOVD [0x9000] -> R8(:R9): F2 D=1 (op2=R8), op1=direct addr (modm=0)
    ab(8'h3F); ab(8'h20 | 5'd8); ab(8'hF3); aw32(32'h0000_9000);

    ab(8'h00);                                   // HALT

    repeat (8) @(posedge clk);
    rst = 0;
    for (i = 0; i < 4000 && !cpu.halted; i = i + 1) @(posedge clk);

    $display("R6=%08x R7=%08x M9000=%04x%04x R8=%08x R9=%08x",
        cpu.r[6], cpu.r[7], ram[32'h9004>>1], ram[32'h9000>>1], cpu.r[8], cpu.r[9]);
    chk(cpu.halted, "HALT reached");
    chk(cpu.r[6] == 32'hAAAA_1111, "MOVD reg-pair low word -> R6");
    chk(cpu.r[7] == 32'hBBBB_2222, "MOVD reg-pair high word -> R7");
    chk({ram[32'h9004>>1], ram[32'h9002>>1], ram[32'h9002>>1], ram[32'h9000>>1]} != 0, "mem written");
    chk(ram[32'h9000>>1] == 16'h1111 && ram[(32'h9000>>1)+1] == 16'hAAAA, "MOVD -> mem low word");
    chk(ram[32'h9004>>1] == 16'h2222 && ram[(32'h9004>>1)+1] == 16'hBBBB, "MOVD -> mem high word");
    chk(cpu.r[8] == 32'hAAAA_1111, "MOVD mem -> R8 low word");
    chk(cpu.r[9] == 32'hBBBB_2222, "MOVD mem -> R9 high word");

    if (fail == 0) $display("V60 MOVD PASS (%0d checks)", pass);
    else           $display("V60 MOVD FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin #200000; $display("V60 MOVD FAIL (timeout)"); $finish; end
endmodule
