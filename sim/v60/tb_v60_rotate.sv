//============================================================================
// V60 ROT/ROTC normal-decode regression.
//
// Oracle: pinned MAME a8c5e5346, src/devices/cpu/v60/op12.hxx opROT[B/H/W]
// and opROTC[B/H/W].  In particular, positive ROT reports the result LSB in
// CY, negative ROT reports the result MSB, a zero count clears CY, and ROTC
// inserts carry at the active operand width (bit 7/15/31).
//============================================================================
`timescale 1ns/1ps

module tb_v60_rotate;

reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;

wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire  [1:0] c_size;
wire        m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire  [1:0] m_be;

s32_v60 #(.START_PC(32'h0000_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'd0), .irq_ack(), .nmi_n(1'b1)
);

s32_v60_bus bus_adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:255];
reg ack_r;
assign m_rdata = ram[m_addr[8:1]];
assign m_ack = ack_r;

always @(posedge clk) begin
    if (rst)
        ack_r <= 1'b0;
    else begin
        ack_r <= m_req & ~ack_r;
        if (m_req && m_we && !ack_r) begin
            if (m_be[0]) ram[m_addr[8:1]][7:0]  <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[8:1]][15:8] <= m_wdata[15:8];
        end
    end
end

integer emit_pc;
integer errors = 0;

task automatic emit8(input [7:0] value);
    begin
        if (emit_pc[0]) ram[emit_pc >> 1][15:8] = value;
        else            ram[emit_pc >> 1][7:0]  = value;
        emit_pc = emit_pc + 1;
    end
endtask

task automatic emit32(input [31:0] value);
    begin
        emit8(value[7:0]); emit8(value[15:8]);
        emit8(value[23:16]); emit8(value[31:24]);
    end
endtask

task automatic mov_imm(input [4:0] rn, input [31:0] value);
    begin
        emit8(8'h2d); emit8(8'h20 | rn); emit8(8'hf4); emit32(value);
    end
endtask

task automatic emit_count(input signed [8:0] count);
    begin
        if (count >= 0 && count <= 15)
            emit8(8'he0 | count[3:0]);       // immediate quick
        else begin
            emit8(8'hf4);                    // full byte immediate
            emit8(count[7:0]);
        end
    end
endtask

task automatic run_case(
    input [8*32-1:0] name,
    input [7:0] opcode,
    input signed [8:0] count,
    input [31:0] initial_value,
    input preset_carry,
    input [31:0] expected_value,
    input expected_carry
);
    integer i;
    integer cycles;
    begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        for (i = 0; i < 256; i = i + 1) ram[i] = 16'h0000;
        emit_pc = 0;

        mov_imm(5'd0, initial_value);
        if (preset_carry) begin
            mov_imm(5'd1, 32'd0);
            // SUBB #1,R1 => 0-1 sets CY, without altering R0.
            emit8(8'ha8); emit8(8'h21); emit8(8'he1);
        end
        // F2 D=1: operand 1 is the count AM, operand 2 is register R0.
        emit8(opcode); emit8(8'h20); emit_count(count);
        emit8(8'h00);                         // HALT

        repeat (2) @(posedge clk);
        rst = 1'b0;
        cycles = 0;
        while (!cpu.halted && cycles < 4000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!cpu.halted) begin
            $display("FAIL %-32s timeout pc=%08x", name, cpu.pc);
            errors = errors + 1;
        end
        else if (cpu.r[0] !== expected_value || cpu.f_cy !== expected_carry) begin
            $display("FAIL %-32s value=%08x cy=%b expected=%08x/%b",
                     name, cpu.r[0], cpu.f_cy, expected_value, expected_carry);
            errors = errors + 1;
        end
        else
            $display("PASS %-32s value=%08x cy=%b", name, cpu.r[0], cpu.f_cy);
    end
endtask

initial begin
    run_case("ROTB +1 wrap carry", 8'h89,  1, 32'h00000081, 0, 32'h00000003, 1);
    run_case("ROTB -1 wrap carry", 8'h89, -1, 32'h00000081, 0, 32'h000000c0, 1);
    run_case("ROTB zero clears carry", 8'h89, 0, 32'h00000080, 1, 32'h00000080, 0);
    run_case("ROTH +1 wrap carry", 8'h8b,  1, 32'h00008001, 0, 32'h00000003, 1);

    run_case("ROTCB +1 uses carry", 8'h99,  1, 32'h00000080, 1, 32'h00000001, 1);
    run_case("ROTCB -1 inserts bit7", 8'h99, -1, 32'h00000002, 1, 32'h00000081, 0);
    run_case("ROTCH -1 inserts bit15", 8'h9b, -1, 32'h00000002, 1, 32'h00008001, 0);
    run_case("ROTCB zero clears carry", 8'h99, 0, 32'h0000005a, 1, 32'h0000005a, 0);

    if (errors == 0)
        $display("V60 ROTATE PASS");
    else
        $fatal(1, "V60 ROTATE FAIL (%0d cases)", errors);
    $finish;
end

endmodule
