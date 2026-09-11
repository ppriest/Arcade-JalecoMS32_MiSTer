//============================================================================
// V60 directed SEARCH test.  Golden Axe uses SKPCUH while building sprite
// buckets and depends on the real CPU's unusual Z convention:
//   found/non-matching element -> Z=0; exhausted range -> Z=1.
// Also verifies the architectural result registers R27 (index) and R28
// (element address).  Exact GA2 instruction bytes cover normal F7b decode;
// direct state-seeded cases isolate SCHCUH and zero-length semantics.
//============================================================================
`timescale 1ns/1ps

module tb_v60_search;

reg clk = 1'b0;
reg rst = 1'b1;
always #10 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0]  m_be;

s32_v60 #(.START_PC(32'h00000000)) cpu (
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
    if (rst)
        ack_r <= 1'b0;
    else begin
        ack_r <= m_req && !ack_r;
        if (m_req && m_we && !ack_r) begin
            if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
        end
    end
end

integer errors = 0;
integer i;

task automatic check(input condition, input [255:0] name);
begin
    if (condition !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL: %0s", name);
    end
end
endtask

task automatic launch_search(
    input [4:0] search_subop,
    input [31:0] source,
    input [15:0] value,
    input [31:0] count
);
begin
    @(negedge clk);
    rst = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    cpu.st = cpu.S_STR_RD;
    cpu.cur_op = 8'h5a;             // halfword SEARCH family
    cpu.subop = {3'b000, search_subop};
    cpu.str_src = source;
    cpu.str_dst = {16'h0000, value};
    cpu.str_len1 = count;
    cpu.str_cnt = count;
    cpu.dbus_req = 1'b0;
    cpu.dbus_we = 1'b0;
    cpu.f_z = 1'b0;
    cpu.r[27] = 32'hdeadbeef;
    cpu.r[28] = 32'hdeadbeef;
    rst = 1'b0;
end
endtask

task automatic wait_search_done;
integer watchdog;
begin
    watchdog = 0;
    while ((cpu.st !== cpu.S_NEXT) && (watchdog < 200)) begin
        @(posedge clk);
        #1;
        watchdog = watchdog + 1;
    end
    check(watchdog < 200, "SEARCH completes");
end
endtask

task automatic put_byte(input integer address, input [7:0] value);
begin
    if (address[0]) ram[address >> 1][15:8] = value;
    else            ram[address >> 1][7:0]  = value;
end
endtask

task automatic load_ga2_search_program;
integer k;
reg [7:0] p [0:19];
begin
    // MOVW #$2000,R15; MOVW #3,R14;
    // SKPCU.H [R15],R14,#0; HALT.  The five SEARCH bytes are the exact
    // encoding used by GA2's sprite-bucket builder at PC 0x132983.
    p[0]=8'h2d; p[1]=8'h2f; p[2]=8'hf4; p[3]=8'h00;
    p[4]=8'h20; p[5]=8'h00; p[6]=8'h00;
    p[7]=8'h2d; p[8]=8'h2e; p[9]=8'hf4; p[10]=8'h03;
    p[11]=8'h00; p[12]=8'h00; p[13]=8'h00;
    p[14]=8'h5a; p[15]=8'h9a; p[16]=8'h6f; p[17]=8'h8e;
    p[18]=8'he0; p[19]=8'h00;
    for (k = 0; k < 20; k = k + 1) put_byte(k, p[k]);
end
endtask

task automatic run_encoded_skpcuh(input [15:0] third_value, input expect_found);
integer watchdog;
begin
    ram[16'h1000] = 16'h0000;
    ram[16'h1001] = 16'h0000;
    ram[16'h1002] = third_value;
    @(negedge clk);
    rst = 1'b1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    watchdog = 0;
    while (!cpu.halted && (watchdog < 2000)) begin
        @(posedge clk);
        #1;
        watchdog = watchdog + 1;
    end
    check(watchdog < 2000, "encoded GA2 SKPCUH halts");
    check(cpu.f_z === !expect_found, "encoded GA2 SKPCUH Z result");
    check(cpu.r[27] === (expect_found ? 32'd2 : 32'd3),
          "encoded GA2 SKPCUH R27");
    check(cpu.r[28] === (expect_found ? 32'h00002004 : 32'h00002006),
          "encoded GA2 SKPCUH R28");
end
endtask

initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;
    load_ga2_search_program();
    repeat (4) @(posedge clk);

    run_encoded_skpcuh(16'h1234, 1'b1);
    run_encoded_skpcuh(16'h0000, 1'b0);

    // SKPCUH skips equal entries and stops on the first non-match.
    ram[16'h0800] = 16'h03c0;
    ram[16'h0801] = 16'h03c0;
    ram[16'h0802] = 16'h1234;
    launch_search(5'h1a, 32'h00001000, 16'h03c0, 32'd3);
    wait_search_done();
    check(cpu.f_z === 1'b0, "SKPCUH found sets Z=0");
    check(cpu.r[27] === 32'd2, "SKPCUH found R27 index");
    check(cpu.r[28] === 32'h00001004, "SKPCUH found R28 address");

    // All entries match the skipped value: no non-match is found.
    ram[16'h0802] = 16'h03c0;
    launch_search(5'h1a, 32'h00001000, 16'h03c0, 32'd3);
    wait_search_done();
    check(cpu.f_z === 1'b1, "SKPCUH exhausted sets Z=1");
    check(cpu.r[27] === 32'd3, "SKPCUH exhausted R27 count");
    check(cpu.r[28] === 32'h00001006, "SKPCUH exhausted R28 end address");

    // SCHCUH stops on equality and uses the same found/exhausted Z sense.
    ram[16'h0800] = 16'h1111;
    ram[16'h0801] = 16'h2222;
    ram[16'h0802] = 16'h3333;
    launch_search(5'h18, 32'h00001000, 16'h2222, 32'd3);
    wait_search_done();
    check(cpu.f_z === 1'b0, "SCHCUH found sets Z=0");
    check(cpu.r[27] === 32'd1, "SCHCUH found R27 index");
    check(cpu.r[28] === 32'h00001002, "SCHCUH found R28 address");

    launch_search(5'h1a, 32'h00001000, 16'h03c0, 32'd0);
    wait_search_done();
    check(cpu.f_z === 1'b1, "zero-length SEARCH sets Z=1");
    check(cpu.r[27] === 32'd0, "zero-length SEARCH R27");
    check(cpu.r[28] === 32'h00001000, "zero-length SEARCH R28");

    if (errors == 0) $display("V60 SEARCH PASS");
    else             $display("V60 SEARCH FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #200000;
    $display("V60 SEARCH FAIL (timeout)");
    $finish;
end

endmodule
