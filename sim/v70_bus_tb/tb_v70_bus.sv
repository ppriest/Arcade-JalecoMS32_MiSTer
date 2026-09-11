// SPDX-License-Identifier: GPL-3.0-or-later
//
//  ms32_v70_bus unit bench: every (size, alignment) read and write against a
//  32-bit RAM model, checked for value and for physical cycle count.
//  Run from the repository root:  scripts/run_sim.sh v70_bus_tb
//  Pass marker: "V70 BUS PASS"
//
//  The CPU side is driven the way s32_v60 drives it: c_req held until c_ack,
//  then dropped for at least one clock (the four-phase re-arm the adapter
//  insists on). The RAM model acks one clock after seeing m_req, with data
//  valid on the ack -- a registered read, as LESSONS_LEARNED asks for.
`timescale 1ns/1ps

module tb_v70_bus;

reg clk = 0, rst = 1;
always #5 clk = ~clk;

reg         c_req = 0, c_we = 0;
reg  [31:0] c_addr = 0, c_wdata = 0;
reg  [1:0]  c_size = 0;
wire [31:0] c_rdata;
wire        c_ack;

wire        m_req, m_we, m_ack;
wire [31:2] m_addr;
wire [31:0] m_wdata, m_rdata;
wire [3:0]  m_be;

ms32_v70_bus dut (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// 256-byte RAM, 32-bit words, registered read, byte-enabled write
reg [31:0] ram [0:63];
reg        ack_r = 0;
reg [31:0] rdata_r;
assign m_ack   = ack_r;
assign m_rdata = rdata_r;
integer mcycles = 0;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && !ack_r) begin
        mcycles <= mcycles + 1;
        rdata_r <= ram[m_addr[7:2]];
        if (m_we) begin
            if (m_be[0]) ram[m_addr[7:2]][7:0]   <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[7:2]][15:8]  <= m_wdata[15:8];
            if (m_be[2]) ram[m_addr[7:2]][23:16] <= m_wdata[23:16];
            if (m_be[3]) ram[m_addr[7:2]][31:24] <= m_wdata[31:24];
        end
    end
end

// byte view of the RAM, for the reference model
function [7:0] rb(input [7:0] a);
    rb = ram[a[7:2]] >> (a[1:0] * 8);
endfunction

integer fails = 0, checks = 0;
task check(input string what, input ok);
    begin
        checks = checks + 1;
        if (!ok) begin fails = fails + 1; $display("  FAIL %s", what); end
    end
endtask

task xfer(input we, input [31:0] a, input [1:0] sz, input [31:0] wd, output [31:0] rd, output integer cyc);
    integer m0;
    begin
        m0 = mcycles;
        @(posedge clk);
        c_req <= 1; c_we <= we; c_addr <= a; c_size <= sz; c_wdata <= wd;
        do @(posedge clk); while (!c_ack);
        rd = c_rdata;
        c_req <= 0;
        @(posedge clk); @(posedge clk);
        cyc = mcycles - m0;
    end
endtask

integer i, sz, al, cyc, want_cyc;
reg [31:0] rd, want, wd;
reg [7:0]  a;
string what;

initial begin
    for (i = 0; i < 64; i = i + 1) ram[i] = {8'(4*i+3), 8'(4*i+2), 8'(4*i+1), 8'(4*i)};
    repeat (3) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);

    // ---- reads: every size at every alignment, value from the byte view
    for (sz = 0; sz < 3; sz = sz + 1)
      for (al = 0; al < 4; al = al + 1) begin
        a = 8'h10 + al;
        xfer(0, {24'h0, a}, sz[1:0], 32'h0, rd, cyc);
        case (sz)
            0: begin want = rb(a); want_cyc = 1; end
            1: begin want = {rb(a+1), rb(a)}; want_cyc = (al == 3) ? 2 : 1; end
            default: begin want = {rb(a+3), rb(a+2), rb(a+1), rb(a)}; want_cyc = (al == 0) ? 1 : 2; end
        endcase
        $sformat(what, "read sz=%0d al=%0d got %08x want %08x cyc %0d want %0d", sz, al, rd, want, cyc, want_cyc);
        check(what, rd == want && cyc == want_cyc);
      end

    // ---- writes: pattern, then read back through the byte view; neighbours untouched
    for (sz = 0; sz < 3; sz = sz + 1)
      for (al = 0; al < 4; al = al + 1) begin
        a = 8'h40 + 8*(4*sz+al) + al;   // every case in its own 8-byte area, so the
                                       // neighbour check never sees a previous write
        wd = 32'hA1B2C3D4 + sz*32'h01010101 + al;
        xfer(1, {24'h0, a}, sz[1:0], wd, rd, cyc);
        case (sz)
            0: begin want = wd[7:0];  want_cyc = 1; end
            1: begin want = wd[15:0]; want_cyc = (al == 3) ? 2 : 1; end
            default: begin want = wd; want_cyc = (al == 0) ? 1 : 2; end
        endcase
        case (sz)
            0: rd = rb(a);
            1: rd = {rb(a+1), rb(a)};
            default: rd = {rb(a+3), rb(a+2), rb(a+1), rb(a)};
        endcase
        $sformat(what, "write sz=%0d al=%0d readback %08x want %08x cyc %0d want %0d", sz, al, rd, want, cyc, want_cyc);
        check(what, rd == want && cyc == want_cyc);
        // the byte below and the byte above the access must be the RAM's init pattern
        $sformat(what, "write sz=%0d al=%0d neighbours intact", sz, al);
        check(what, rb(a-1) == a-1 && rb(a + (1<<sz)) == a + (1<<sz));
      end

    $display("%0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("V70 BUS PASS"); else $display("V70 BUS FAIL");
    $finish;
end

endmodule
