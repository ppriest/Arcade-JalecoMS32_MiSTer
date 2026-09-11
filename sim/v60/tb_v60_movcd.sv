//============================================================================
//  V60 MOVCD (down-direction character copy) directed test (audit R20 V60-14).
//  MAME opMOVSTRD copies the ascending range base..base+min-1 in descending
//  element order; the old RTL walked physically below the base and corrupted
//  memory.  Seeded at S_STR_OP2 so the down-init (top-of-range) runs.
//============================================================================
`timescale 1ns/1ps

module tb_v60_movcd;

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

integer errors = 0, i, wd;
task automatic check(input condition, input [255:0] name);
    if (condition !== 1'b1) begin errors = errors + 1; $display("  FAIL: %0s", name); end
endtask
task automatic put_byte(input integer a, input [7:0] v);
    if (a[0]) ram[a >> 1][15:8] = v; else ram[a >> 1][7:0] = v;
endtask
function [7:0] get_byte(input integer a);
    get_byte = a[0] ? ram[a >> 1][15:8] : ram[a >> 1][7:0];
endfunction

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    // source "WXYZ" at 0x1000; dest zeroed at 0x2000; below-base sentinels
    put_byte(16'h1000,"W"); put_byte(16'h1001,"X"); put_byte(16'h1002,"Y"); put_byte(16'h1003,"Z");
    put_byte(16'h0FFF,8'hEE); put_byte(16'h1FFF,8'hEE);   // below source/dest bases

    @(negedge clk);
    rst = 1'b1; repeat (3) @(posedge clk); @(negedge clk);
    // Enter at S_STR_OP2 so the MOVCD down-init computes the top-of-range start.
    cpu.st = cpu.S_STR_OP2;
    cpu.cur_op = 8'h58;             // byte string family
    cpu.subop  = 8'h09;            // MOVCD (down)
    cpu.op1 = 32'h0000_1000;       // source base
    cpu.op2 = 32'h0000_2000;       // dest base
    cpu.str_len1 = 4;
    cpu.len1 = 0; cpu.len2 = 0;    // register/EA extension lengths = 0
    cpu.fb[3] = 8'd4;              // len2 byte (small immediate) at ofs 3+0+0
    cpu.dbus_req = 1'b0; cpu.dbus_we = 1'b0;
    rst = 1'b0;

    wd = 0;
    while ((cpu.st !== cpu.S_NEXT) && (wd < 600)) begin @(posedge clk); #1; wd = wd + 1; end
    check(wd < 600, "MOVCD completes");

    $display("dest = %s%s%s%s   below[0FFF]=%02x below[1FFF]=%02x",
        get_byte(16'h2000), get_byte(16'h2001), get_byte(16'h2002), get_byte(16'h2003),
        get_byte(16'h0FFF), get_byte(16'h1FFF));
    check(get_byte(16'h2000) == "W", "dest[0] = W");
    check(get_byte(16'h2001) == "X", "dest[1] = X");
    check(get_byte(16'h2002) == "Y", "dest[2] = Y");
    check(get_byte(16'h2003) == "Z", "dest[3] = Z");
    // The old bug walked below the base; these sentinels must be untouched.
    check(get_byte(16'h0FFF) == 8'hEE, "source below-base intact");
    check(get_byte(16'h1FFF) == 8'hEE, "dest below-base intact (no corruption)");

    if (errors == 0) $display("V60 MOVCD PASS");
    else             $display("V60 MOVCD FAIL (%0d errors)", errors);
    $finish;
end

initial begin #500000; $display("V60 MOVCD FAIL (timeout)"); $finish; end
endmodule
