//============================================================================
//  V60 CMPC (compare characters) directed test (audit R20 V60-13).  MAME
//  opCMPSTR: on the first difference S = (source > dest); on an equal common
//  prefix S/Z come from the length compare; R28 = len1+i, R27 = len2+i (not the
//  raw addresses); zero-length still sets flags.  White-box state seeding, like
//  the SEARCH test, avoids hand-assembling the F7a operand encoding.
//============================================================================
`timescale 1ns/1ps

module tb_v60_cmpc;

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

reg [15:0] ram [0:32767];
reg ack_r = 1'b0;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    if (rst) ack_r <= 1'b0;
    else begin
        ack_r <= m_req && !ack_r;
        if (m_req && m_we && !ack_r) begin
            if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
        end
    end
end

integer errors = 0, i;
task automatic check(input condition, input [255:0] name);
    if (condition !== 1'b1) begin errors = errors + 1; $display("  FAIL: %0s", name); end
endtask
task automatic put_byte(input integer a, input [7:0] v);
    if (a[0]) ram[a >> 1][15:8] = v; else ram[a >> 1][7:0] = v;
endtask

// Seed two strings and run a byte CMPC (subop 0), then wait for completion.
task automatic run_cmpc(input [31:0] saddr, input [31:0] daddr,
                        input [31:0] l1, input [31:0] l2);
integer wd;
begin
    @(negedge clk);
    rst = 1'b1; repeat (3) @(posedge clk); @(negedge clk);
    cpu.st = cpu.S_STR_RD;
    cpu.cur_op = 8'h58;              // byte string family
    cpu.subop  = 8'h00;             // CMPC
    cpu.str_src = saddr;
    cpu.str_dst = daddr;
    cpu.str_len1 = l1;
    cpu.str_len2 = l2;
    cpu.str_cnt  = (l1 < l2) ? l1 : l2;
    cpu.dbus_req = 1'b0; cpu.dbus_we = 1'b0;
    cpu.f_z = 1'bx; cpu.f_s = 1'bx;
    cpu.r[27] = 32'hdeadbeef; cpu.r[28] = 32'hdeadbeef;
    rst = 1'b0;
    wd = 0;
    while ((cpu.st !== cpu.S_NEXT) && (wd < 400)) begin @(posedge clk); #1; wd = wd + 1; end
    check(wd < 400, "CMPC completes");
end
endtask

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    // source @ 0x1000, dest @ 0x2000
    put_byte(16'h1000,"A"); put_byte(16'h1001,"B"); put_byte(16'h1002,"C"); put_byte(16'h1003,"D");
    put_byte(16'h2000,"A"); put_byte(16'h2001,"B"); put_byte(16'h2002,"C"); put_byte(16'h2003,"E");

    // 1: ABCD vs ABCE -> differ at i=3, source 'D' < dest 'E' -> S=0, Z=0, R28=7 R27=7
    run_cmpc(32'h1000, 32'h2000, 4, 4);
    check(cpu.f_s === 1'b0, "src<dest -> S=0");
    check(cpu.f_z === 1'b0, "differ -> Z=0");
    check(cpu.r[28] === 32'd7, "R28 = len1+i (7)");
    check(cpu.r[27] === 32'd7, "R27 = len2+i (7)");

    // 2: ABCF vs ABCE -> differ at i=3, source 'F' > dest 'E' -> S=1
    put_byte(16'h1003,"F");
    run_cmpc(32'h1000, 32'h2000, 4, 4);
    check(cpu.f_s === 1'b1, "src>dest -> S=1");
    check(cpu.f_z === 1'b0, "differ -> Z=0 (2)");

    // 3: ABCD vs ABCD equal, same length -> Z=1, S=0, R28=8 R27=8
    put_byte(16'h1003,"D"); put_byte(16'h2003,"D");
    run_cmpc(32'h1000, 32'h2000, 4, 4);
    check(cpu.f_z === 1'b1, "equal same-length -> Z=1");
    check(cpu.f_s === 1'b0, "equal -> S=0");
    check(cpu.r[28] === 32'd8, "R28 = len1+min (8)");
    check(cpu.r[27] === 32'd8, "R27 = len2+min (8)");

    // 4: ABC (len3) vs ABCD (len4) equal prefix, len1<len2 -> S=0, Z=0, R28=6 R27=7
    run_cmpc(32'h1000, 32'h2000, 3, 4);
    check(cpu.f_s === 1'b0, "shorter source -> S=0");
    check(cpu.f_z === 1'b0, "unequal length -> Z=0");
    check(cpu.r[28] === 32'd6, "R28 = len1+min (6)");
    check(cpu.r[27] === 32'd7, "R27 = len2+min (7)");

    // 5: zero-length equal -> Z=1, R28=0 R27=0
    run_cmpc(32'h1000, 32'h2000, 0, 0);
    check(cpu.f_z === 1'b1, "zero-length equal -> Z=1");
    check(cpu.r[28] === 32'd0, "zero-length R28=0");
    check(cpu.r[27] === 32'd0, "zero-length R27=0");

    if (errors == 0) $display("V60 CMPC PASS");
    else             $display("V60 CMPC FAIL (%0d errors)", errors);
    $finish;
end

initial begin #500000; $display("V60 CMPC FAIL (timeout)"); $finish; end
endmodule
