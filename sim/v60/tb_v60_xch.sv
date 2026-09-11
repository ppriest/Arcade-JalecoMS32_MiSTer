//============================================================================
//  V60 XCH.B/H/W directed test — regression lock for the F2 D=0 decode bug.
//
//  `xch.w R19,R20` (encoding 45 53 74) decodes as F2 D=0 (instflags[7]=0,
//  instflags[5]=0, op1 = packed register). The generic F2 D=0 path treated op1
//  as a register VALUE (flag1=0), so XCH's exec fell into the register<->memory
//  branch and WROTE R[op1] into a bogus address instead of swapping the two
//  registers. On ga2 this corrupted the PLAYER SELECT object spawn
//  (0x063BEB/0x063BF1) so the on-scale character never rendered.
//
//  Fix: XCH op1 in F2 D=0 is a register LVALUE (flag1=1). This test proves the
//  reg<->reg swap is clean (and does NOT touch memory), that the genuine
//  reg<->memory XCH form still works, and that memory<->memory reads both
//  operands before cross-writing them.
//============================================================================
`timescale 1ns/1ps

module tb_v60_xch;

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
task movw_imm(input [4:0] rn, input [31:0] v);   // MOVW #v, Rn
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(v);
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

    // R19 = AAAA1111, R20 = 00008000 (points at a memory sentinel)
    movw_imm(5'd19, 32'hAAAA_1111);
    movw_imm(5'd20, 32'h0000_8000);
    // XCH.W R19, R20  (45 53 74) — the F2 D=0 reg<->reg case that was broken
    ab(8'h45); ab(8'h53); ab(8'h74);

    // reg<->memory form: R21 = 1234ABCD, XCH.W R21, $9000
    movw_imm(5'd21, 32'h1234_ABCD);
    // 45 <iflags=op1 reg 21=0x15> F3 <addr32=0x9000>
    ab(8'h45); ab(8'h15); ab(8'hF3); aw32(32'h0000_9000);

    // F1 memory/memory forms: iflags=0x80, then direct-address F3 modes.
    // Cover byte, halfword and word lane assembly independently.
    ab(8'h41); ab(8'h80); ab(8'hF3); aw32(32'h0000_A000);
    ab(8'hF3); aw32(32'h0000_A002);
    ab(8'h43); ab(8'h80); ab(8'hF3); aw32(32'h0000_A010);
    ab(8'hF3); aw32(32'h0000_A012);
    ab(8'h45); ab(8'h80); ab(8'hF3); aw32(32'h0000_A020);
    ab(8'hF3); aw32(32'h0000_A024);

    ab(8'h00);  // HALT

    // sentinels: mem[0x8000]=0x5A5A must survive the reg-reg swap (proves no
    // spurious memory write); mem[0x9000]=0x00007777 is the reg-mem partner.
    ram[32'h8000>>1] = 16'h5A5A;
    ram[32'h9000>>1] = 16'h7777;
    ram[(32'h9000>>1)+1] = 16'h0000;
    ram[32'hA000>>1] = 16'h12A1;
    ram[32'hA002>>1] = 16'h34B2;
    ram[32'hA010>>1] = 16'h1122;
    ram[(32'hA010>>1)+1] = 16'h0000;
    ram[32'hA012>>1] = 16'h3344;
    ram[32'hA020>>1] = 16'h5566;
    ram[(32'hA020>>1)+1] = 16'h7788;
    ram[32'hA024>>1] = 16'h99AA;
    ram[(32'hA024>>1)+1] = 16'hBBCC;

    repeat (8) @(posedge clk);
    rst = 0;
    wait (cpu.halted);
    repeat (4) @(posedge clk);

    $display("R19=%08x R20=%08x R21=%08x mem8000=%04x mem9000=%08x",
        cpu.r[19], cpu.r[20], cpu.r[21], ram[32'h8000>>1],
        {ram[(32'h9000>>1)+1], ram[32'h9000>>1]});

    // reg<->reg swap correct
    chk(cpu.r[19] == 32'h0000_8000, "XCH.W reg-reg: R19 got R20");
    chk(cpu.r[20] == 32'hAAAA_1111, "XCH.W reg-reg: R20 got R19");
    // and NO memory corruption (the original bug wrote R19 into [R20]=0x8000)
    chk(ram[32'h8000>>1] == 16'h5A5A, "XCH.W reg-reg did NOT write memory");
    // reg<->memory swap correct
    chk(cpu.r[21] == 32'h0000_7777, "XCH.W reg-mem: R21 got mem");
    chk({ram[(32'h9000>>1)+1], ram[32'h9000>>1]} == 32'h1234_ABCD,
        "XCH.W reg-mem: mem got R21");
    chk((ram[32'hA000>>1] & 16'h00ff) == 16'h00b2 &&
        (ram[32'hA002>>1] & 16'h00ff) == 16'h00a1,
        "XCH.B mem-mem: bytes swapped");
    chk(ram[32'hA010>>1] == 16'h3344 && ram[32'hA012>>1] == 16'h1122,
        "XCH.H mem-mem: halfwords swapped");
    chk(ram[32'hA020>>1] == 16'h99AA && ram[(32'hA020>>1)+1] == 16'hBBCC &&
        ram[32'hA024>>1] == 16'h5566 && ram[(32'hA024>>1)+1] == 16'h7788,
        "XCH.W mem-mem: words swapped");

    if (fail == 0) $display("V60 XCH PASS (%0d checks)", pass);
    else           $display("V60 XCH FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

endmodule
