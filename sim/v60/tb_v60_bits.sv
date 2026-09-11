//============================================================================
//  V60 directed test: 0x5B bit strings / 0x5D bit fields (V60-10)
//   EXTBFZ/EXTBFS/EXTBFL: extract bit field (zero/sign/left-justified)
//   INSBFR:               insert bit field into memory (RMW dword)
//   SCH1BSU/SCH0BSU:      scan bit string for first 1/0
//   MOVBSU:               bit-string copy (up)
//  BAM modes used: displacement8 (base reg + bit disp), register indirect.
//============================================================================
`timescale 1ns/1ps

module tb_v60_bits;

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

integer errors = 0;
task check32(input [31:0] got, input [31:0] want, input [79:0] name);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %s got=%08x want=%08x", name, got, want);
    end
endtask
task check16(input [15:0] got, input [15:0] want, input [79:0] name);
    if (got !== want) begin
        errors = errors + 1;
        $display("  FAIL %s got=%04x want=%04x", name, got, want);
    end
endtask

integer i;
initial begin
    for (i = 0; i < 32768; i = i + 1) ram[i] = 16'h0000;

    // data: dword at 0x2100 = 0xABCD1234
    ram[16'h2100>>1] = 16'h1234; ram[16'h2102>>1] = 16'hABCD;
    // scan string at 0x2110: first set bit at global index 18
    ram[16'h2110>>1] = 16'h0000; ram[16'h2112>>1] = 16'h0004;
    // all-ones byte for SCH0 not-found case at 0x2118
    ram[16'h2118>>1] = 16'h00FF;
    // MOVBSU source at 0x2120 = 0x0FB4
    ram[16'h2120>>1] = 16'h0FB4;

    pc_a = 0;
    movw_imm_reg(32'h0000_F000, 5'd31);           // SP
    movw_imm_reg(32'h0000_2100, 5'd2);            // base for bitfield data

    // EXTBFZ off=4 len=8 -> r10 = 0x23
    ab(8'h5D); ab(8'h29); ab(8'h02); ab(8'h04); ab(8'h08); ab(8'h6A);
    // EXTBFS off=12 len=8 -> 0xD1 sign-extended -> r11 = FFFFFFD1
    ab(8'h5D); ab(8'h28); ab(8'h02); ab(8'h0C); ab(8'h08); ab(8'h6B);
    // EXTBFL off=4 len=8 -> r12 = 0x23000000
    ab(8'h5D); ab(8'h2A); ab(8'h02); ab(8'h04); ab(8'h08); ab(8'h6C);

    // INSBFR #0x5A into bits 8..15 of dword at r3=0x2104 (bit disp 8)
    movw_imm_reg(32'h0000_2104, 5'd3);
    ab(8'h5D); ab(8'h18); ab(8'hF4); aw32(32'h0000_005A);
    ab(8'h03); ab(8'h08); ab(8'h08);

    // SCH1BSU from r4=0x2110 (reg indirect), len 24 -> r13 = 18, Z=0
    movw_imm_reg(32'h0000_2110, 5'd4);
    ab(8'h5B); ab(8'h22); ab(8'h64); ab(8'h18); ab(8'h6D);
    // SCH0BSU on 0xFF byte at r4=0x2118, len 8 -> not found: r14 = 8, Z=1
    movw_imm_reg(32'h0000_2118, 5'd4);
    ab(8'h5B); ab(8'h20); ab(8'h64); ab(8'h08); ab(8'h6E);

    // MOVBSU: 12 bits from 0x2120 bit4 -> 0x2128 bit0 => dst word 0x00FB
    movw_imm_reg(32'h0000_2120, 5'd5);
    movw_imm_reg(32'h0000_2128, 5'd6);
    ab(8'h5B); ab(8'h08); ab(8'h05); ab(8'h04); ab(8'h0C); ab(8'h06); ab(8'h00);

    // MOVBSD: same 12 bits copied DOWN (offsets pre-advanced by len-1,
    // byte crossings walk downward) -> same result at 0x212C
    movw_imm_reg(32'h0000_212C, 5'd6);
    ab(8'h5B); ab(8'h09); ab(8'h05); ab(8'h04); ab(8'h0C); ab(8'h06); ab(8'h00);

    ab(8'h00);                                     // HALT

    repeat (6) @(posedge clk);
    rst = 0;
    repeat (120000) @(posedge clk);

    check32(cpu.r[10], 32'h0000_0023, "EXTBFZ");
    check32(cpu.r[11], 32'hFFFF_FFD1, "EXTBFS");
    check32(cpu.r[12], 32'h2300_0000, "EXTBFL");
    check16(ram[16'h2104>>1], 16'h5A00, "INSBFR-lo");
    check16(ram[16'h2106>>1], 16'h0000, "INSBFR-hi");
    check32(cpu.r[13], 32'd18, "SCH1BSU");
    check32(cpu.r[14], 32'd8,  "SCH0BSU");
    check16(ram[16'h2128>>1], 16'h00FB, "MOVBSU");
    check16(ram[16'h212C>>1], 16'h00FB, "MOVBSD");
    if (cpu.halted !== 1'b1) begin
        errors = errors + 1;
        $display("  FAIL cpu not halted (pc=%08x)", cpu.pc);
    end

    if (errors == 0) $display("BITS PASS");
    else             $display("BITS FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #8000000;
    $display("BITS FAIL (timeout, pc=%08x)", cpu.pc);
    $finish;
end

endmodule
