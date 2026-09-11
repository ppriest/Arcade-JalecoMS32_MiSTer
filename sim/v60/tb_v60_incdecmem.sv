//============================================================================
//  V60 INC.H / DEC.H MEMORY read-modify-write directed test.
//
//  The register-direct INC/DEC flag cases live in tb_v60_flags; the differential
//  harness favours word ops, so the *halfword memory RMW* path (S_RMW_RD ->
//  S_RMW_EX -> S_WB_MEM at rmw_dim=1) was under-covered.  This path is exactly
//  spidman's camera page-advance timer: `dec.h 34[R25]` (reload 0x708) whose
//  Z flag gates a `bne`.  A byte-width Z bug would expire the timer whenever the
//  low byte hit 0 (every 0x100 counts) instead of at the true halfword zero,
//  racing the page counter and firing camera-gated events far too early.
//
//  Oracle: pinned MAME op12.hxx opDEC/opINC + SetSZPF at the operand width.
//    DEC: CY(borrow)=(operand==0); OV = was-negative & now-nonnegative.
//    INC: CY(carry)=(result==0);   OV = was-nonnegative & now-negative.
//  PSW low nibble = {CY,OV,S,Z} = psw[3:0] (bit3=CY,2=OV,1=S,0=Z).
//
//  Encoding: DEC.H [Rn] = 0xD2, mode 0x60|n (modm=0 -> register indirect =
//  memory);  INC.H [Rn] = 0xDA, mode 0x60|n.  GETPSW Rn = 0xF7,0x60|n.
//============================================================================
`timescale 1ns/1ps

module tb_v60_incdecmem;

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
task movw_imm(input [4:0] rn, input [31:0] imm); // MOVW #imm, Rn
    ab(8'h2D); ab(8'h20 | rn); ab(8'hF4); aw32(imm);
endtask
task getpsw(input [4:0] rn);                     // GETPSW Rn (reg-direct)
    ab(8'hF7); ab(8'h60 | rn);
endtask
task dech_mem(input [4:0] rn);                   // DEC.H [Rn]
    ab(8'hD2); ab(8'h60 | rn);
endtask
task inch_mem(input [4:0] rn);                   // INC.H [Rn]
    ab(8'hDA); ab(8'h60 | rn);
endtask

integer pass = 0, fail = 0;
task chk(input cond, input [255:0] name);
    if (cond) begin pass = pass + 1; $display("  ok   %0s", name); end
    else      begin fail = fail + 1; $display("  FAIL %0s", name); end
endtask

// Data addresses (halfword-aligned, above the program) and their word indices.
localparam A1=32'h2000, A2=32'h2002, A3=32'h2004, A4=32'h2006,
           A5=32'h2008, A6=32'h200A, A7=32'h200C;
function [15:0] wi(input [31:0] a); wi = a[16:1]; endfunction

integer i;
initial begin
    for (i = 0; i < 65536; i = i + 1) ram[i] = 16'h0000;
    pc_a = 0;
    movw_imm(5'd31, 32'h0000_8000);              // SP (unused, harmless)

    // 1: dec.h 0x0708 -> 0x0707, Z=0 S=0 OV=0 CY=0   (normal timer tick)
    movw_imm(5'd5, A1); dech_mem(5'd5); getpsw(5'd6);
    // 2: dec.h 0x0001 -> 0x0000, Z=1                 (true expiry: reload gate)
    movw_imm(5'd5, A2); dech_mem(5'd5); getpsw(5'd7);
    // 3: dec.h 0x0000 -> 0xFFFF, Z=0 S=1 CY=1(borrow)
    movw_imm(5'd5, A3); dech_mem(5'd5); getpsw(5'd8);
    // 4: dec.h 0x0701 -> 0x0700, Z=0                 (DISCRIMINATING: low byte 0
    //    but halfword nonzero -> must NOT expire; a byte-Z bug gives Z=1)
    movw_imm(5'd5, A4); dech_mem(5'd5); getpsw(5'd9);
    // 5: inc.h 0xFFFF -> 0x0000, Z=1 CY=1
    movw_imm(5'd5, A5); inch_mem(5'd5); getpsw(5'd10);
    // 6: inc.h 0x7FFF -> 0x8000, OV=1 S=1
    movw_imm(5'd5, A6); inch_mem(5'd5); getpsw(5'd11);
    // 7: inc.h 0x00FF -> 0x0100, Z=0 (byte->halfword carry must propagate)
    movw_imm(5'd5, A7); inch_mem(5'd5); getpsw(5'd12);

    ab(8'h00);                                   // HALT

    // Seed the memory operands (after the program is laid down).
    ram[wi(A1)] = 16'h0708;
    ram[wi(A2)] = 16'h0001;
    ram[wi(A3)] = 16'h0000;
    ram[wi(A4)] = 16'h0701;
    ram[wi(A5)] = 16'hFFFF;
    ram[wi(A6)] = 16'h7FFF;
    ram[wi(A7)] = 16'h00FF;

    repeat (8) @(posedge clk);
    rst = 0;
    for (i = 0; i < 4000 && !cpu.halted; i = i + 1) @(posedge clk);

    $display("mem: A1=%04x A2=%04x A3=%04x A4=%04x A5=%04x A6=%04x A7=%04x",
        ram[wi(A1)], ram[wi(A2)], ram[wi(A3)], ram[wi(A4)], ram[wi(A5)], ram[wi(A6)], ram[wi(A7)]);
    $display("psw: P6=%01x P7=%01x P8=%01x P9=%01x P10=%01x P11=%01x P12=%01x",
        cpu.r[6]&4'hf, cpu.r[7]&4'hf, cpu.r[8]&4'hf, cpu.r[9]&4'hf,
        cpu.r[10]&4'hf, cpu.r[11]&4'hf, cpu.r[12]&4'hf);

    chk(cpu.halted, "HALT reached");
    // value checks (halfword RMW writeback)
    chk(ram[wi(A1)] == 16'h0707, "DEC.H 0708 value");
    chk(ram[wi(A2)] == 16'h0000, "DEC.H 0001 value");
    chk(ram[wi(A3)] == 16'hFFFF, "DEC.H 0000 value (underflow)");
    chk(ram[wi(A4)] == 16'h0700, "DEC.H 0701 value");
    chk(ram[wi(A5)] == 16'h0000, "INC.H FFFF value (wrap)");
    chk(ram[wi(A6)] == 16'h8000, "INC.H 7FFF value");
    chk(ram[wi(A7)] == 16'h0100, "INC.H 00FF value (byte->half carry)");
    // flag checks {CY,OV,S,Z}
    chk((cpu.r[6]  & 4'hf) == 4'h0, "DEC.H 0708 flags Z=0");
    chk((cpu.r[7]  & 4'hf) == 4'h1, "DEC.H 0001 flags Z=1 (expiry)");
    chk((cpu.r[8]  & 4'hf) == 4'hA, "DEC.H 0000 flags CY=1 S=1 (borrow)");
    chk((cpu.r[9]  & 4'h1) == 4'h0, "DEC.H 0701->0700 Z=0 (halfword, not byte)");
    chk((cpu.r[10] & 4'hf) == 4'h9, "INC.H FFFF flags Z=1 CY=1");
    chk((cpu.r[11] & 4'hf) == 4'h6, "INC.H 7FFF flags OV=1 S=1");
    chk((cpu.r[12] & 4'h1) == 4'h0, "INC.H 00FF->0100 Z=0");

    if (fail == 0) $display("V60 INCDECMEM PASS (%0d checks)", pass);
    else           $display("V60 INCDECMEM FAIL (%0d/%0d failed)", fail, pass+fail);
    $finish;
end

initial begin
    #300000;
    $display("V60 INCDECMEM FAIL (timeout)");
    $finish;
end
endmodule
