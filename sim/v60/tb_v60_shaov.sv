//============================================================================
// V60 SHA (arithmetic shift) left-shift OVERFLOW directed test.
//
// The 50-seed differential harness (tb_v60_diff) does NOT model SHA's OV flag,
// so the audit V60 Finding-1 fix (sha_left_ov masking exactly `count` top bits,
// not count+1) and its count==width sub-fix had no automated coverage.  This
// test locks both down against the pinned MAME oracle.
//
// Oracle: pinned MAME mame-master-20260719, src/devices/cpu/v60/op12.hxx
//   #define SHIFTLEFT_OV(val,count,bitsize):
//       tmp  = (count==32) ? 0xFFFFFFFF : ((1<<count)-1);
//       tmp <<= (bitsize - count);            // mask = top `count` bits, in place
//       OV = sign ? ((val & tmp) != tmp)      // negative: OV unless top bits all-1
//                 : ((val & tmp) != 0);       // positive: OV unless top bits all-0
//   (well-defined for 1 <= count <= bitsize; count>bitsize is UB there.)
//   opSHAB/H/W: count==0 -> CY=OV=0, result unchanged; count<0 -> right shift,
//   OV always 0.  Result is val<<count truncated to width (0 if count>=bitsize).
//
// Encoding matches tb_v60_rotate: F2 D=1, op1 = count AM (immediate), op2 = R0
// register-direct (mode byte 0x20).  SHAB=0xb9, SHAH=0xbb, SHAW=0xbd.  Each
// case checks the written result R0 and the OV flag (cpu.f_ov).
//============================================================================
`timescale 1ns/1ps

module tb_v60_shaov;

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

// Load R0, run one SHA at the opcode's width, HALT; check result R0 and OV.
task automatic run_case(
    input [8*40-1:0] name,
    input [7:0] opcode,
    input signed [8:0] count,
    input [31:0] initial_value,
    input [31:0] expected_value,
    input expected_ov
);
    integer i;
    integer cycles;
    begin
        rst = 1'b1;
        repeat (3) @(posedge clk);
        for (i = 0; i < 256; i = i + 1) ram[i] = 16'h0000;
        emit_pc = 0;

        mov_imm(5'd0, initial_value);
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
            $display("FAIL %-40s timeout pc=%08x", name, cpu.pc);
            errors = errors + 1;
        end
        else if (cpu.r[0] !== expected_value || cpu.f_ov !== expected_ov) begin
            $display("FAIL %-40s value=%08x ov=%b expected=%08x/ov=%b",
                     name, cpu.r[0], cpu.f_ov, expected_value, expected_ov);
            errors = errors + 1;
        end
        else
            $display("PASS %-40s value=%08x ov=%b", name, cpu.r[0], cpu.f_ov);
    end
endtask

initial begin
    // --- SHA.B (byte, bitsize=8, opcode 0xb9) ---
    // In-range (1<=count<width): the Finding-1 fix (mask exactly `count` bits).
    run_case("SHAB #1,0x40 pos no-ov (Finding-1)", 8'hb9,  1, 32'h0000_0040, 32'h0000_0080, 1'b0);
    run_case("SHAB #2,0x60 pos ov",                8'hb9,  2, 32'h0000_0060, 32'h0000_0080, 1'b1);
    run_case("SHAB #1,0xC0 neg no-ov",             8'hb9,  1, 32'h0000_00C0, 32'h0000_0080, 1'b0);
    run_case("SHAB #2,0xA0 neg ov",                8'hb9,  2, 32'h0000_00A0, 32'h0000_0080, 1'b1);
    // count==width edge (the sub-fix folding c==w into the exact mask):
    run_case("SHAB #8,0xFF eq -1 no-ov (sub-fix)", 8'hb9,  8, 32'h0000_00FF, 32'h0000_0000, 1'b0);
    run_case("SHAB #8,0x80 eq neg ov",             8'hb9,  8, 32'h0000_0080, 32'h0000_0000, 1'b1);
    run_case("SHAB #8,0x01 eq pos ov",             8'hb9,  8, 32'h0000_0001, 32'h0000_0000, 1'b1);
    run_case("SHAB #8,0x00 eq zero no-ov",         8'hb9,  8, 32'h0000_0000, 32'h0000_0000, 1'b0);
    // count==0 -> CY=OV=0, result unchanged; negative count -> right shift, OV=0.
    run_case("SHAB #0,0x55 zero-count no-ov",       8'hb9,  0, 32'h0000_0055, 32'h0000_0055, 1'b0);
    run_case("SHAB #-1,0x81 right-shift no-ov",     8'hb9, -1, 32'h0000_0081, 32'h0000_00C0, 1'b0);

    // --- SHA.H (half, bitsize=16, opcode 0xbb) ---
    run_case("SHAH #1,0x4000 pos no-ov",           8'hbb,  1, 32'h0000_4000, 32'h0000_8000, 1'b0);
    run_case("SHAH #2,0x6000 pos ov",              8'hbb,  2, 32'h0000_6000, 32'h0000_8000, 1'b1);
    run_case("SHAH #16,0xFFFF eq -1 no-ov",        8'hbb, 16, 32'h0000_FFFF, 32'h0000_0000, 1'b0);

    // --- SHA.W (word, bitsize=32, opcode 0xbd) ---
    run_case("SHAW #1,0x40000000 pos no-ov",       8'hbd,  1, 32'h4000_0000, 32'h8000_0000, 1'b0);
    run_case("SHAW #2,0x60000000 pos ov",          8'hbd,  2, 32'h6000_0000, 32'h8000_0000, 1'b1);
    // count==32 uses MAME's (count==32) special mask; RTL else-branch computes
    // ((32'd1<<32)-1)=0xFFFFFFFF -> confirms ModelSim's 1<<32==0 semantics.
    run_case("SHAW #32,0xFFFFFFFF eq -1 no-ov",    8'hbd, 32, 32'hFFFF_FFFF, 32'h0000_0000, 1'b0);
    run_case("SHAW #32,0x00000001 eq pos ov",      8'hbd, 32, 32'h0000_0001, 32'h0000_0000, 1'b1);
    run_case("SHAW #32,0x80000000 eq neg ov",      8'hbd, 32, 32'h8000_0000, 32'h0000_0000, 1'b1);

    if (errors == 0)
        $display("V60 SHAOV PASS");
    else
        $fatal(1, "V60 SHAOV FAIL (%0d cases)", errors);
    $finish;
end

initial begin
    #500000;
    $display("V60 SHAOV FAIL (timeout)");
    $fatal(1, "V60 SHAOV FAIL (global timeout)");
end

endmodule
