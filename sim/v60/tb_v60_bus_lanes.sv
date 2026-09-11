//============================================================================
// V60 16-bit external-bus lane/alignment regression.
// Covers every V60 logical size at even and odd byte addresses, including
// the 3-cycle odd-address dword case used by MAME's *_unaligned accesses.
//============================================================================
`timescale 1ns/1ps

module tb_v60_bus_lanes;

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

reg         c_req = 0;
reg         c_we = 0;
reg  [31:0] c_addr = 0;
reg   [1:0] c_size = 0;
reg  [31:0] c_wdata = 0;
wire [31:0] c_rdata;
wire        c_ack;
wire        m_req, m_we;
wire [23:1] m_addr;
wire [15:0] m_wdata;
wire  [1:0] m_be;
wire [15:0] m_rdata;
wire        m_ack;

s32_v60_bus dut (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [7:0] mem [0:63];
reg ack_r;
integer accepted_cycles;
integer errors = 0;
wire [23:0] byte_addr = {m_addr, 1'b0};

assign m_rdata = {mem[byte_addr + 1], mem[byte_addr]};
assign m_ack = ack_r;

always @(posedge clk) begin
    if (rst) begin
        ack_r <= 1'b0;
        accepted_cycles <= 0;
    end
    else begin
        ack_r <= m_req & ~ack_r;
        if (m_req && !ack_r) begin
            accepted_cycles <= accepted_cycles + 1;
            if (m_we) begin
                if (m_be[0]) mem[byte_addr]     <= m_wdata[7:0];
                if (m_be[1]) mem[byte_addr + 1] <= m_wdata[15:8];
            end
        end
    end
end

task automatic transact(
    input we,
    input [31:0] addr,
    input [1:0] size,
    input [31:0] wdata,
    input integer expected_cycles,
    output [31:0] rdata
);
    integer before_cycles;
    begin
        before_cycles = accepted_cycles;
        @(negedge clk);
        c_we = we; c_addr = addr; c_size = size; c_wdata = wdata; c_req = 1'b1;
        wait (c_ack);
        rdata = c_rdata;
        @(negedge clk);
        c_req = 1'b0;
        repeat (2) @(posedge clk);
        if (accepted_cycles - before_cycles != expected_cycles) begin
            $display("FAIL cycles addr=%0d size=%0d got=%0d expected=%0d",
                     addr, size, accepted_cycles - before_cycles, expected_cycles);
            errors = errors + 1;
        end
    end
endtask

task automatic check_byte(input integer addr, input [7:0] expected);
    if (mem[addr] !== expected) begin
        $display("FAIL mem[%0d]=%02x expected=%02x", addr, mem[addr], expected);
        errors = errors + 1;
    end
endtask

task automatic check_read(
    input [31:0] got,
    input [31:0] expected,
    input [8*32-1:0] name
);
    if (got !== expected) begin
        $display("FAIL %-32s got=%08x expected=%08x", name, got, expected);
        errors = errors + 1;
    end
endtask

integer i;
reg [31:0] rd;
initial begin
    for (i = 0; i < 64; i = i + 1) mem[i] = i[7:0];
    repeat (4) @(posedge clk);
    rst = 1'b0;

    transact(1, 32'd3,  2'd0, 32'h000000aa, 1, rd);
    check_byte(3, 8'haa);
    transact(1, 32'd4,  2'd1, 32'h0000beef, 1, rd);
    check_byte(4, 8'hef); check_byte(5, 8'hbe);
    transact(1, 32'd7,  2'd1, 32'h00001234, 2, rd);
    check_byte(7, 8'h34); check_byte(8, 8'h12);
    transact(1, 32'd10, 2'd2, 32'h89abcdef, 2, rd);
    check_byte(10, 8'hef); check_byte(11, 8'hcd);
    check_byte(12, 8'hab); check_byte(13, 8'h89);
    transact(1, 32'd15, 2'd2, 32'h01234567, 3, rd);
    check_byte(15, 8'h67); check_byte(16, 8'h45);
    check_byte(17, 8'h23); check_byte(18, 8'h01);

    transact(0, 32'd3,  2'd0, 32'd0, 1, rd); check_read(rd, 32'h000000aa, "odd byte read");
    transact(0, 32'd4,  2'd1, 32'd0, 1, rd); check_read(rd, 32'h0000beef, "even halfword read");
    transact(0, 32'd7,  2'd1, 32'd0, 2, rd); check_read(rd, 32'h00001234, "odd halfword read");
    transact(0, 32'd10, 2'd2, 32'd0, 2, rd); check_read(rd, 32'h89abcdef, "even dword read");
    transact(0, 32'd15, 2'd2, 32'd0, 3, rd); check_read(rd, 32'h01234567, "odd dword read");

    // Reset is an epoch boundary even when a CPU request is held and a
    // physical cycle is outstanding. No stale request/ACK may escape it.
    @(negedge clk); c_req = 1'b1; c_addr = 32'd20; c_size = 2'd1;
    wait(m_req); @(negedge clk); rst = 1'b1;
    @(posedge clk); #1;
    if (m_req !== 1'b0 || c_ack !== 1'b0) begin
        $display("FAIL reset retained stale bus request/ack m_req=%b c_ack=%b",m_req,c_ack);
        errors = errors + 1;
    end
    @(negedge clk); c_req = 1'b0; rst = 1'b0;
    repeat(2) @(posedge clk);

    if (errors == 0)
        $display("V60 BUS LANES PASS");
    else
        $fatal(1, "V60 BUS LANES FAIL (%0d checks)", errors);
    $finish;
end

endmodule
