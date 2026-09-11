//============================================================================
//  V60 down-direction character search (SCHC*D / SKPC*D) directed test
//  (audit R20 V60-15).  MAME opSEARCHDB/opSEARCHDH: the down form scans the
//  range in descending order from MAME's start index — byte reads op1+len1 down
//  to op1 (len1+1 reads; the first is one past the buffer), half reads
//  op1+(len1-1)*2 down to op1 (len1 reads).  On break the element index i is
//  reported in R27 and its address in R28; Z follows MAME's post-loop test
//  (i==len1), so it is set only when a byte down-search matches its one-past-
//  the-top read, and cleared on an exhausted scan (i falls to -1).
//
//  White-box seeding at S_STR_OP2 (as the CMPC/MOVCD tests do) exercises the
//  down-start bias and the descending completion without hand-assembling the
//  F7b operand encoding.  The up-direction / MOVC / CMPC paths are gated off by
//  subop[0] and are covered by the differential + directed CPU tiers.
//============================================================================
`timescale 1ns/1ps

module tb_v60_schd;

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
task automatic put_half(input integer a, input [15:0] v);
    ram[a >> 1] = v;                     // a is even
endtask

// Seed S_STR_OP2 for a down-direction search and run to completion.
//   op  = 8'h58 (byte) / 8'h5a (half)
//   sub = 8'h19 (SCHC down) / 8'h1b (SKPC down)
//   base= op1 (range base), sval = search value, l1 = len1
task automatic run_schd(input [7:0] op, input [7:0] sub,
                        input [31:0] base, input [31:0] sval, input [31:0] l1);
integer wd;
begin
    @(negedge clk);
    rst = 1'b1; repeat (3) @(posedge clk); @(negedge clk);
    cpu.st      = cpu.S_STR_OP2;
    cpu.cur_op  = op;
    cpu.subop   = sub;
    cpu.str_src = base;          // S_STR_OP1 leaves op1 here; S_STR_OP2 biases it
    cpu.op2     = sval;          // becomes str_dst (the search value)
    cpu.str_len1 = l1;
    cpu.str_len2 = 32'd0;
    cpu.len1 = 0; cpu.len2 = 0;
    cpu.dbus_req = 1'b0; cpu.dbus_we = 1'b0;
    cpu.f_z = 1'bx;
    cpu.r[27] = 32'hdead_beef; cpu.r[28] = 32'hdead_beef;
    rst = 1'b0;
    wd = 0;
    while ((cpu.st !== cpu.S_NEXT) && (wd < 400)) begin @(posedge clk); #1; wd = wd + 1; end
    check(wd < 400, "SCHD completes");
end
endtask

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;

    // 1: byte SCHC-down, match mid-range. Range 0x1000..0x1003 = A B C D, OOB
    //    read at 0x1004 = 0x00. Search 'C'. Descending: i=4(00),3(D),2(C=hit).
    //    -> Z=0 (i!=len1), R27=i=2, R28=0x1002.
    put_byte(16'h1000, "A"); put_byte(16'h1001, "B");
    put_byte(16'h1002, "C"); put_byte(16'h1003, "D"); put_byte(16'h1004, 8'h00);
    run_schd(8'h58, 8'h19, 32'h1000, "C", 4);
    check(cpu.f_z === 1'b0,        "byte SCHC-dn hit: Z=0");
    check(cpu.r[27] === 32'd2,     "byte SCHC-dn hit: R27=i=2");
    check(cpu.r[28] === 32'h1002,  "byte SCHC-dn hit: R28=0x1002");

    // 2: byte SCHC-down, no match. Search 'Z'. Scan i=4..0 misses, i falls to
    //    -1 -> Z=0, R27=0xFFFFFFFF, R28=op1-1=0x0FFF.
    run_schd(8'h58, 8'h19, 32'h1000, "Z", 4);
    check(cpu.f_z === 1'b0,               "byte SCHC-dn miss: Z=0");
    check(cpu.r[27] === 32'hffff_ffff,    "byte SCHC-dn miss: R27=-1");
    check(cpu.r[28] === 32'h0fff,         "byte SCHC-dn miss: R28=op1-1");

    // 3: byte SCHC-down, match at the one-past-the-top read (i==len1). Put the
    //    value only at 0x1004. MAME sets Z=1 here (post-loop i==len1).
    put_byte(16'h1004, 8'h99);
    run_schd(8'h58, 8'h19, 32'h1000, 32'h99, 4);
    check(cpu.f_z === 1'b1,        "byte SCHC-dn top: Z=1 (i==len1)");
    check(cpu.r[27] === 32'd4,     "byte SCHC-dn top: R27=len1=4");
    check(cpu.r[28] === 32'h1004,  "byte SCHC-dn top: R28=0x1004");
    put_byte(16'h1004, 8'h00);     // restore

    // 4: half SCHC-down, len1=3. Reads i=2(0x2004),1(0x2002),0(0x2000). Words
    //    3333/2222/1111. Search 0x2222 -> hit at i=1: Z=0, R27=1, R28=0x2002.
    put_half(16'h2000, 16'h1111); put_half(16'h2002, 16'h2222);
    put_half(16'h2004, 16'h3333);
    run_schd(8'h5a, 8'h19, 32'h2000, 32'h2222, 3);
    check(cpu.f_z === 1'b0,        "half SCHC-dn hit: Z=0");
    check(cpu.r[27] === 32'd1,     "half SCHC-dn hit: R27=i=1");
    check(cpu.r[28] === 32'h2002,  "half SCHC-dn hit: R28=0x2002");

    // 5: byte SKPC-down (break on first NON-match going down). Range A A B A,
    //    OOB 0x1004=A. Search 'A'. Descending skips A's, breaks at 0x1002 'B'.
    //    -> Z=0, R27=i=2, R28=0x1002.
    put_byte(16'h1000, "A"); put_byte(16'h1001, "A");
    put_byte(16'h1002, "B"); put_byte(16'h1003, "A"); put_byte(16'h1004, "A");
    run_schd(8'h58, 8'h1b, 32'h1000, "A", 4);
    check(cpu.f_z === 1'b0,        "byte SKPC-dn: Z=0");
    check(cpu.r[27] === 32'd2,     "byte SKPC-dn: R27=i=2");
    check(cpu.r[28] === 32'h1002,  "byte SKPC-dn: R28=0x1002");

    if (errors == 0) $display("V60 SCHD PASS");
    else             $display("V60 SCHD FAIL (%0d errors)", errors);
    $finish;
end

initial begin #500000; $display("V60 SCHD FAIL (timeout)"); $finish; end
endmodule
