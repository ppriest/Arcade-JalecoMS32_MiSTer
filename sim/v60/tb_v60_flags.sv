//============================================================================
//  V60 flag-generation directed test (audit R20 V60-5 INC/DEC overflow, and
//  V60-3 GETPSW).  The 50-seed differential harness never observes PSW, so
//  these flag fixes had no direct coverage.  Each case loads an operand, runs
//  a single flag-setting instruction, and captures the PSW with GETPSW (which
//  itself exercises the R20 GETPSW decode fix).  PSW low nibble = {CY,OV,S,Z}
//  per s32_v60: psw = {psw_rest[31:4], f_cy, f_ov, f_s, f_z}.
//============================================================================
`timescale 1ns/1ps

module tb_v60_flags;

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

reg [15:0] ram [0:65535];
reg ack_r;
assign m_rdata = ram[m_addr[16:1]];
assign m_ack   = ack_r;
always @(posedge clk) begin
    ack_r <= m_req & ~ack_r;
    if (m_req && m_we && !ack_r) begin
        if (m_be[0]) ram[m_addr[16:1]][7:0]  <= m_wdata[7:0];
        if (m_be[1]) ram[m_addr[16:1]][15:8] <= m_wdata[15:8];
    end
end

integer pc_a;
task ab(input [7:0] b);
    if (pc_a[0]) ram[pc_a>>1][15:8] = b;
    else         ram[pc_a>>1][7:0]  = b;
    pc_a = pc_a + 1;
endtask
task aw32(input [31:0] w);
    ab(w[7:0]); ab(w[15:8]); ab(w[23:16]); ab(w[31:24]);
endtask
task movw_imm(input [4:0] rn, input [31:0] imm); // MOVW #imm, Rn (F2 D=1)
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm);
endtask
task getpsw(input [4:0] rn);                     // GETPSW Rn (reg-direct: modm=1)
    ab(8'hF7); ab(8'h60 | rn);
endtask

integer pass = 0, fail = 0;
task chk(input cond, input [255:0] name);
    if (cond) begin pass = pass + 1; $display("  ok   %0s", name); end
    else      begin fail = fail + 1; $display("  FAIL %0s", name); end
endtask

integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;
    movw_imm(5'd31, 32'h0001_0000);              // SP

    // Register-direct operands use the modm=1 opcode variant (LSB set):
    // INC.W=0xDD, INC.B=0xD9, DEC.W=0xD5, with mode byte 0x60|reg.
    // 1: INC.W of 0x7FFFFFFF -> 0x80000000, OV=1 S=1 Z=0 CY=0
    movw_imm(5'd6, 32'h7FFF_FFFF);
    ab(8'hDD); ab(8'h60 | 5'd6);                 // INC.W R6
    getpsw(5'd7);
    // 2: INC.W of 0xFFFFFFFF -> 0, CY=1 Z=1 OV=0
    movw_imm(5'd8, 32'hFFFF_FFFF);
    ab(8'hDD); ab(8'h60 | 5'd8);                 // INC.W R8
    getpsw(5'd9);
    // 3: DEC.W of 0x80000000 -> 0x7FFFFFFF, OV=1 S=0 Z=0 CY=0
    movw_imm(5'd10, 32'h8000_0000);
    ab(8'hD5); ab(8'h60 | 5'd10);                // DEC.W R10
    getpsw(5'd11);
    // 4: DEC.W of 0 -> 0xFFFFFFFF, CY=1(borrow) S=1 OV=0 Z=0
    movw_imm(5'd12, 32'h0000_0000);
    ab(8'hD5); ab(8'h60 | 5'd12);                // DEC.W R12
    getpsw(5'd13);
    // 5: INC.B of 0x7F -> 0x80, OV=1 (byte width)
    movw_imm(5'd14, 32'h0000_007F);
    ab(8'hD9); ab(8'h60 | 5'd14);                // INC.B R14
    getpsw(5'd15);

    // MUL.W Rdest *= Rsrc (F2 D=1 op2=dest modm=1, op1=src reg-direct):
    //   opcode 0x85, iflags 0x60|dest, mode byte 0x60|src.
    // 6: 0x10000 * 0x10000 -> low 0, high nonzero -> OV=1
    movw_imm(5'd16, 32'h0001_0000);
    movw_imm(5'd17, 32'h0001_0000);
    ab(8'h85); ab(8'h60 | 5'd17); ab(8'h60 | 5'd16); // MUL.W R17 *= R16
    getpsw(5'd18);
    // 7: signed 1 * -1 -> -1, high 32 = 0xFFFFFFFF -> OV=1 (MAME MUL.W quirk)
    movw_imm(5'd19, 32'h0000_0001);
    movw_imm(5'd20, 32'hFFFF_FFFF);
    ab(8'h85); ab(8'h60 | 5'd19); ab(8'h60 | 5'd20); // MUL.W R19 *= R20
    getpsw(5'd21);
    // 8: 2 * 3 -> 6, OV=0
    movw_imm(5'd22, 32'h0000_0002);
    movw_imm(5'd23, 32'h0000_0003);
    ab(8'h85); ab(8'h60 | 5'd23); ab(8'h60 | 5'd22); // MUL.W R23 *= R22
    getpsw(5'd24);
    // DIV.W Rdividend /= Rdivisor (opcode 0xA5):
    // 9: 0x80000000 / -1 -> signed overflow, OV=1, dest stays 0x80000000
    movw_imm(5'd25, 32'hFFFF_FFFF);              // divisor -1
    movw_imm(5'd26, 32'h8000_0000);              // dividend min
    ab(8'hA5); ab(8'h60 | 5'd26); ab(8'h60 | 5'd25); // DIV.W R26 /= R25
    getpsw(5'd27);
    // 10: 10 / 2 -> 5, OV=0
    movw_imm(5'd28, 32'h0000_0002);              // divisor
    movw_imm(5'd29, 32'h0000_000A);              // dividend
    ab(8'hA5); ab(8'h60 | 5'd29); ab(8'h60 | 5'd28); // DIV.W R29 /= R28
    getpsw(5'd30);

    // 11: Golden Axe executes SETF #4 against adjacent byte fields at
    // 0x2C7B and 0x2C7A.  SETF is byte-sized: each instruction must update
    // only its addressed byte and preserve the following coinage fields.
    movw_imm(5'd0, 32'h0000_0000);
    movw_imm(5'd1, 32'h0000_0001);
    movw_imm(5'd25, 32'h0000_0000);
    ab(8'hB8); ab(8'h40); ab(8'h60);             // CMP.B R0,R0: Z=1
    ab(8'h47); ab(8'h80); ab(8'hE4); ab(8'h39); ab(8'h7B); ab(8'h2C);
    ab(8'hB8); ab(8'h41); ab(8'h60);             // CMP.B R1,R0: Z=0
    ab(8'h47); ab(8'h80); ab(8'hE4); ab(8'h39); ab(8'h7A); ab(8'h2C);

    // 12: Arabian Fight level-entry movement uses this exact ROM sequence.
    // It first expands direction 1 to a 32-bit speed, multiplies that memory
    // destination by 0x100, then applies the resulting fixed-point velocity.
    // S_MULDIV used to skip memory writeback, leaving speed=1 and advancing
    // the player only 1/256 as far as MAME/original code intends.
    movw_imm(5'd24, 32'h0000_2000);              // player-object base
    ab(8'h1C); ab(8'h80); ab(8'h38); ab(8'h92); ab(8'h00); ab(8'h18); ab(8'h2C);
    ab(8'h85); ab(8'h80); ab(8'hF4); aw32(32'h0000_0100); ab(8'h18); ab(8'h2C);
    ab(8'h1C); ab(8'h20); ab(8'h18); ab(8'h0A);
    ab(8'h85); ab(8'h20); ab(8'h18); ab(8'h2C);
    ab(8'hBD); ab(8'h20); ab(8'hF4); ab(8'hF8);
    ab(8'h84); ab(8'h00); ab(8'h18); ab(8'h7A);

    ab(8'h00);                                   // HALT

    ram[16'h163D] = 16'hAA55;                    // 2C7A=55, 2C7B=AA
    ram[16'h163E] = 16'hCCBB;                    // 2C7C=BB, 2C7D=CC
    ram[16'h163F] = 16'hEEDD;                    // 2C7E=DD, 2C7F=EE
    ram[16'h2092 >> 1] = 16'h0001;               // object+0x92 direction
    ram[16'h200A >> 1] = 16'h0100;               // object+0x0A velocity
    ram[16'h202C >> 1] = 16'hDEAD;               // object+0x2C speed (overwritten)
    ram[16'h202E >> 1] = 16'hBEEF;
    ram[16'h207A >> 1] = 16'h0000;               // object+0x7A accumulator
    ram[16'h207C >> 1] = 16'hFFFF;

    repeat (8) @(posedge clk);
    rst = 0;

    // run to completion
    for (i = 0; i < 3000 && !cpu.halted; i = i + 1) @(posedge clk);

    $display("R6=%08x P7=%01x R8=%08x P9=%01x R10=%08x P11=%01x R12=%08x P13=%01x R14=%08x P15=%01x",
        cpu.r[6], cpu.r[7]&4'hf, cpu.r[8], cpu.r[9]&4'hf, cpu.r[10], cpu.r[11]&4'hf,
        cpu.r[12], cpu.r[13]&4'hf, cpu.r[14], cpu.r[15]&4'hf);

    chk(cpu.halted, "HALT reached");
    // {CY,OV,S,Z} = psw[3:0]
    chk(cpu.r[6]  == 32'h8000_0000, "INC.W 7FFFFFFF result");
    chk((cpu.r[7]  & 4'hf) == 4'h6,  "INC.W 7FFFFFFF flags OV=1 S=1 Z=0 CY=0");
    chk(cpu.r[8]  == 32'h0000_0000, "INC.W FFFFFFFF result");
    chk((cpu.r[9]  & 4'hf) == 4'h9,  "INC.W FFFFFFFF flags Z=1 CY=1 OV=0");
    chk(cpu.r[10] == 32'h7FFF_FFFF, "DEC.W 80000000 result");
    chk((cpu.r[11] & 4'hf) == 4'h4,  "DEC.W 80000000 flags OV=1 S=0 Z=0 CY=0");
    chk(cpu.r[12] == 32'hFFFF_FFFF, "DEC.W 0 result");
    chk((cpu.r[13] & 4'hf) == 4'hA,  "DEC.W 0 flags CY=1 S=1 OV=0");
    chk(cpu.r[14][7:0] == 8'h80,     "INC.B 7F byte result");
    chk((cpu.r[15] & 4'h4) == 4'h4,  "INC.B 7F byte overflow OV=1");

    $display("R17=%08x P18=%01x R19=%08x P21=%01x R23=%08x P24=%01x R26=%08x P27=%01x R29=%08x P30=%01x",
        cpu.r[17], cpu.r[18]&4'hf, cpu.r[19], cpu.r[21]&4'hf, cpu.r[23], cpu.r[24]&4'hf,
        cpu.r[26], cpu.r[27]&4'hf, cpu.r[29], cpu.r[30]&4'hf);
    chk(cpu.r[17] == 32'h0000_0000, "MUL.W 10000*10000 low result");
    chk((cpu.r[18] & 4'h4) == 4'h4,  "MUL.W 10000*10000 OV=1");
    chk(cpu.r[19] == 32'hFFFF_FFFF, "MUL.W 1*-1 result");
    chk((cpu.r[21] & 4'h4) == 4'h4,  "MUL.W 1*-1 OV=1 (high half nonzero)");
    chk(cpu.r[23] == 32'h0000_0006, "MUL.W 2*3 result");
    chk((cpu.r[24] & 4'h4) == 4'h0,  "MUL.W 2*3 OV=0");
    chk((cpu.r[27] & 4'h4) == 4'h4,  "DIV.W min/-1 overflow OV=1");
    chk(cpu.r[29] == 32'h0000_0005, "DIV.W 10/2 result");
    chk((cpu.r[30] & 4'h4) == 4'h0,  "DIV.W 10/2 OV=0");
    chk(ram[16'h163D] == 16'h0100, "SETF.B updates only 2C7A/2C7B bytes");
    chk((ram[16'h163E] == 16'hCCBB) && (ram[16'h163F] == 16'hEEDD),
        "SETF.B preserves adjacent coinage bytes 2C7C-2C7F");
    $display("ARAB speed=%04x%04x accumulator=%04x%04x R0=%08x",
        ram[16'h202E >> 1], ram[16'h202C >> 1],
        ram[16'h207C >> 1], ram[16'h207A >> 1], cpu.r[0]);
    chk({ram[16'h202E >> 1], ram[16'h202C >> 1]} == 32'h0000_0100,
        "Arabian Fight MUL.W immediate writes memory speed 00000100");
    chk({ram[16'h207C >> 1], ram[16'h207A >> 1]} == 32'hFFFF_0100,
        "Arabian Fight fixed-point accumulator advances by 00000100");

    if (fail == 0) $display("V60 FLAGS PASS (%0d checks)", pass);
    else           $display("V60 FLAGS FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin
    #200000;
    $display("V60 FLAGS FAIL (timeout)");
    $finish;
end
endmodule
