//============================================================================
//  V60 directed test: 0x59 decimal group (V60-10) — F7c format
//   ADDDC:  packed-BCD byte add with carry chain (Rad Mobile timer)
//   SUBDC:  BCD subtract (dst - src - CY), register destination
//   SUBRDC: BCD reverse subtract (src - dst - CY) with borrow
//   CVTDPZ: packed byte -> zoned halfword with pattern
//   CVTDZP: zoned halfword -> packed byte
//  PASS requires all memory/register results exact.
//============================================================================
`timescale 1ns/1ps

module tb_v60_decimal;

reg clk = 0, rst = 1;
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
reg ack_r;
assign m_rdata = ram[m_addr[15:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[15:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[15:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) ram[pc_a>>1][15:8]=b; else ram[pc_a>>1][7:0]=b; pc_a=pc_a+1;
endtask
task aw32(input [31:0] w); ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]); endtask
task movw_imm_reg(input [31:0] v, input [4:0] rn);
    ab(8'h2D); ab(8'h20|rn); ab(8'hF4); aw32(v);
endtask
task movb_reg_abs(input [4:0] rn, input [31:0] a);
    ab(8'h09); ab(8'h00|rn); ab(8'hF3); aw32(a);
endtask

// F7c decimal op: [59] [sub | m1<<6 | m2<<5] [op1 AM...] [op2 AM...] [ext]
// op1 = immediate byte (F4 v), op2 = absolute (F3 addr32)
task dec_imm_abs(input [4:0] sub, input [7:0] v, input [31:0] a, input [7:0] pat);
    ab(8'h59); ab({2'b00, 1'b0, sub}); ab(8'hF4); ab(v);
    ab(8'hF3); aw32(a); ab(pat);
endtask
// op1 = immediate byte, op2 = register direct (mode byte 0x60|reg, modm=1)
task dec_imm_reg(input [4:0] sub, input [7:0] v, input [4:0] rn, input [7:0] pat);
    ab(8'h59); ab({2'b00, 1'b1, sub} | 8'h20); ab(8'hF4); ab(v);
    ab(8'h60 | {3'b0, rn}); ab(pat);
endtask

integer errors = 0;
task check8(input [7:0] got, input [7:0] want, input [63:0] name);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %s got=%02x want=%02x", name, got, want);
    end
endtask
task check16(input [15:0] got, input [15:0] want, input [63:0] name);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %s got=%04x want=%04x", name, got, want);
    end
endtask

function automatic [7:0] ref_bin2bcd(input [6:0] v);
    integer q, r;
    begin
        q = v / 10;
        r = v % 10;
        ref_bin2bcd = {q[3:0], r[3:0]};
    end
endfunction

integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;

    // Exhaust the helper's complete seven-bit input space.  The optimized
    // implementation shares one /10 quotient and derives the remainder.
    for (i = 0; i < 128; i = i + 1) begin
        if (cpu.bin2bcd(i[6:0]) !== ref_bin2bcd(i[6:0])) begin
            errors = errors + 1;
            $display("  FAIL bin2bcd(%0d) got=%02x want=%02x",
                     i, cpu.bin2bcd(i[6:0]), ref_bin2bcd(i[6:0]));
        end
    end

    pc_a = 0;
    movw_imm_reg(32'h0000_F000, 5'd31);              // SP

    // seed dest byte 0x25 at 0x2040
    movw_imm_reg(32'h0000_0025, 5'd0);
    movb_reg_abs(5'd0, 32'h0000_2040);

    // A: ADDDC chain on memory dest (CY known 0 after MOVs? force via
    // ADDW #0,r1 which clears CY)
    movw_imm_reg(32'h0000_0000, 5'd1);               // r1=0 (flags: Z set, CY 0)
    dec_imm_abs(5'd0, 8'h37, 32'h0000_2040, 8'h00);  // 37+25   = 62, CY=0
    dec_imm_abs(5'd0, 8'h70, 32'h0000_2040, 8'h00);  // 70+62   =132 -> 32, CY=1
    dec_imm_abs(5'd0, 8'h05, 32'h0000_2040, 8'h00);  // 05+32+1 = 38, CY=0

    // B: SUBDC on register dest (upper bytes preserved)
    movw_imm_reg(32'hAAAA_0041, 5'd5);
    dec_imm_reg(5'd1, 8'h29, 5'd5, 8'h00);           // 41-29-0 = 12

    // C: SUBRDC with borrow
    movw_imm_reg(32'h0000_0005, 5'd6);
    dec_imm_reg(5'd2, 8'h03, 5'd6, 8'h00);           // 03-05 -> -2 +100 = 98, CY=1
    dec_imm_reg(5'd2, 8'h99, 5'd6, 8'h00);           // 99-98-CY(1) = 0, CY=0

    // D: CVTDPZ packed 0x25 -> zoned halfword with pattern 0x30 = "25"
    dec_imm_abs(5'h10, 8'h25, 32'h0000_2050, 8'h30); // -> 0x3532 (le: 32 35)

    // E: CVTDZP zoned 0x3532 -> packed byte 0x25 into r7
    movw_imm_reg(32'h0000_0000, 5'd7);
    ab(8'h59); ab(8'h38);                            // sub 0x18, m2=1 (reg)
    ab(8'hF4); ab(8'h32); ab(8'h35);                 // op1 imm halfword 0x3532
    ab(8'h60 | 8'd7);                                // op2 = r7
    ab(8'h30);                                       // pattern 0x30

    ab(8'h00);                                       // HALT

    repeat (6) @(posedge clk);
    rst = 0;
    repeat (60000) @(posedge clk);

    check8(ram[16'h2040>>1][7:0],  8'h38,   "ADDDC-chain");
    check16(cpu.r[5][15:0], 16'h0012, "SUBDC-reg-low");
    check16(cpu.r[5][31:16], 16'hAAAA, "SUBDC-reg-high");
    check8(cpu.r[6][7:0],  8'h00,   "SUBRDC-final");
    check16(ram[16'h2050>>1], 16'h3532, "CVTDPZ");
    check8(cpu.r[7][7:0],  8'h25,   "CVTDZP");
    if (cpu.halted !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL cpu not halted (pc=%08x)", cpu.pc);
    end

    if (errors == 0) $display("DECIMAL PASS");
    else             $display("DECIMAL FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #4000000;
    $display("DECIMAL FAIL (timeout, pc=%08x)", cpu.pc);
    $finish;
end

endmodule
