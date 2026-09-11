// Golden Axe boss-meter arithmetic regression.
// MAME PC 0x1341c7..0x1341e1 scales damage by 1.5 with SHL.W #-1,
// subtracts it from a halfword meter, clamps negative results, and stores it.
`timescale 1ns/1ps

module tb_v60_ga2_bossbar;
reg clk = 0;
reg rst = 1;
always #5 clk = ~clk;
integer cediv = 1;
integer cecnt = 0;
reg ce = 1'b1;
initial if (!$value$plusargs("CEDIV=%d", cediv)) cediv = 1;
always @(posedge clk) begin
    if (cecnt >= cediv-1) begin cecnt <= 0; ce <= 1'b1; end
    else begin cecnt <= cecnt + 1; ce <= 1'b0; end
end

wire c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0] c_size;
wire m_req, m_we, m_ack;
wire [23:1] m_addr;
wire [15:0] m_wdata, m_rdata;
wire [1:0] m_be;

s32_v60 #(.START_PC(32'h0)) cpu (
    .clk(clk), .ce(ce), .rst(rst),
    .fast_ifetch(1'b0),
    .if_req(), .if_addr(), .if_data(64'd0), .if_ack(1'b0),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(1'b1), .irq_vector(8'd0), .irq_ack(), .nmi_n(1'b1)
);
s32_v60_bus bus_adapter (
    .clk(clk), .ce(ce), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

reg [15:0] ram [0:511];
reg ack_r;
assign m_rdata = ram[m_addr[9:1]];
assign m_ack = ack_r;
always @(posedge clk) begin
    if (rst) ack_r <= 1'b0;
    else begin
        ack_r <= m_req & ~ack_r;
        if (m_req && m_we && !ack_r) begin
            if (m_be[0]) ram[m_addr[9:1]][7:0] <= m_wdata[7:0];
            if (m_be[1]) ram[m_addr[9:1]][15:8] <= m_wdata[15:8];
        end
    end
end

integer emit_pc;
integer errors = 0;
task automatic emit8(input [7:0] v);
begin
    if (emit_pc[0]) ram[emit_pc >> 1][15:8] = v;
    else ram[emit_pc >> 1][7:0] = v;
    emit_pc = emit_pc + 1;
end
endtask
task automatic emit32(input [31:0] v);
begin emit8(v[7:0]); emit8(v[15:8]); emit8(v[23:16]); emit8(v[31:24]); end
endtask
task automatic mov_imm(input [4:0] rn, input [31:0] v);
begin emit8(8'h2d); emit8(8'h20 | rn); emit8(8'hf4); emit32(v); end
endtask

task automatic run_case(
    input [15:0] initial_meter,
    input [31:0] base_damage,
    input [15:0] expected_meter,
    input use_indexed_scale
);
integer i, cycles;
begin
    rst = 1;
    repeat (3) @(posedge clk);
    for (i = 0; i < 512; i = i + 1) ram[i] = 0;
    emit_pc = 0;
    mov_imm(5'd20, 32'h0000_0100);
    mov_imm(5'd2, base_damage);
    if (use_indexed_scale) begin
        // Exact 2-player cabinet path at 0x1341b4:
        // MOVEA.H [R2](R2),R2 = base R2 + halfword-scaled index R2*2.
        emit8(8'h42); emit8(8'h62); emit8(8'hc2); emit8(8'h62);
    end else begin
        // Exact alternate cabinet path at 0x1341c7..0x1341d1.
        emit8(8'h2d); emit8(8'h42); emit8(8'h61);             // mov.w R2,R1
        emit8(8'had); emit8(8'h21); emit8(8'hf4); emit8(8'hff); // shl.w #-1,R1
        emit8(8'h84); emit8(8'h41); emit8(8'h62);             // add.w R1,R2
    end
    emit8(8'h1d); emit8(8'h20); emit8(8'h14); emit8(8'h6c); // movz.hw 6c[R20],R0
    emit8(8'haa); emit8(8'h42); emit8(8'h60);             // sub.h R2,R0
    emit8(8'h63); emit8(8'h05);                           // bnl store
    emit8(8'hb2); emit8(8'h40); emit8(8'h60);             // xor.h R0,R0
    emit8(8'h1b); emit8(8'h00); emit8(8'h14); emit8(8'h6c); // mov.h R0,6c[R20]
    emit8(8'h00);
    ram[16'h016c >> 1] = initial_meter;
    repeat (2) @(posedge clk);
    rst = 0;
    cycles = 0;
    while (!cpu.halted && cycles < 4000) begin
        @(posedge clk);
        cycles = cycles + 1;
    end
    if (!cpu.halted || ram[16'h016c >> 1] !== expected_meter) begin
        $display("FAIL initial=%04x damage=%08x got=%04x expected=%04x R1=%08x R2=%08x",
                 initial_meter, base_damage, ram[16'h016c >> 1],
                 expected_meter, cpu.r[1], cpu.r[2]);
        errors = errors + 1;
    end else begin
        $display("PASS initial=%04x damage=%08x result=%04x scaled=%08x",
                 initial_meter, base_damage, ram[16'h016c >> 1], cpu.r[2]);
    end
end
endtask

task automatic run_draw_case(
    input [15:0] current_hp,
    input [15:0] max_hp,
    input [31:0] expected_width
);
integer i, cycles;
reg [31:0] div_result, mul_result, div_op, div_acc, mul_op, mul_acc;
begin
    rst = 1;
    repeat (3) @(posedge clk);
    for (i = 0; i < 512; i = i + 1) ram[i] = 0;
    emit_pc = 0;
    div_result = 32'hdead_dead;
    mul_result = 32'hdead_dead;
    div_op = 32'hdead_dead;
    div_acc = 32'hdead_dead;
    mul_op = 32'hdead_dead;
    mul_acc = 32'hdead_dead;
    mov_imm(5'd20, 32'h0000_0100);
    mov_imm(5'd2, 32'h0000_c000);
    // Exact GA2 bytes at 0x13403e..0x13404b.
    emit8(8'hb3); emit8(8'h22); emit8(8'h34); emit8(8'h0c); emit8(8'h01);
    emit8(8'h93); emit8(8'h22); emit8(8'h14); emit8(8'h6c);
    emit8(8'hab); emit8(8'h22); emit8(8'hf4); emit8(8'hf8);
    emit8(8'h00);
    ram[16'h016c >> 1] = current_hp;
    ram[16'h020c >> 1] = max_hp;
    repeat (2) @(posedge clk);
    rst = 0;
    cycles = 0;
    while (!cpu.halted && cycles < 8000) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cpu.pc == 32'd14 && cpu.mdcnt == 32) begin
            div_op = cpu.mdop;
            div_acc = cpu.mdacc[31:0];
        end
        if (cpu.pc == 32'd19) div_result = cpu.r[2];
        if (cpu.pc == 32'd19 && cpu.mdcnt == 16) begin
            mul_op = cpu.mdop;
            mul_acc = cpu.mdacc[31:0];
        end
        if (cpu.pc == 32'd23) mul_result = cpu.r[2];
    end
    if (!cpu.halted || cpu.r[2] !== expected_width || mul_op === 32'hdead_dead) begin
        $display("FAIL draw current=%0d max=%0d width=%08x expected=%08x div=%08x mul=%08x",
                 current_hp, max_hp, cpu.r[2], expected_width, div_result, mul_result);
        $display("     div operands op=%08x acc=%08x; mul op=%08x acc=%08x",
                 div_op, div_acc, mul_op, mul_acc);
        errors = errors + 1;
    end else begin
        $display("PASS draw current=%0d max=%0d width=%0d",
                 current_hp, max_hp, cpu.r[2]);
    end
end
endtask

initial begin
    run_case(16'h00f0, 32'd4, 16'h00e4, 1'b1);
    run_case(16'h00e4, 32'd4, 16'h00d8, 1'b1);
    run_case(16'h000a, 32'd4, 16'h0000, 1'b1);
    run_case(16'h0120, 32'd8, 16'h0108, 1'b1);
    run_case(16'h00f0, 32'd8, 16'h00e4, 1'b0);
    run_draw_case(16'd300, 16'd300, 32'd191);
    run_draw_case(16'd288, 16'd300, 32'd183);
    run_draw_case(16'd228, 16'd300, 32'd145);
    run_draw_case(16'd192, 16'd300, 32'd122);
    run_draw_case(16'd90,  16'd300, 32'd57);
    if (errors == 0) $display("V60 GA2 BOSSBAR PASS");
    else $fatal(1, "V60 GA2 BOSSBAR FAIL (%0d)", errors);
    $finish;
end

initial begin
    #500000;
    $fatal(1, "V60 GA2 BOSSBAR FAIL (timeout)");
end
endmodule
