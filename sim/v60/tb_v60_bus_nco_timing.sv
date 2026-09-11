//============================================================================
// V60 external-bus timing and CPU-side re-arm regression.
//
// The production System 32 clock enable is a 21848/65536 fractional NCO.  It
// normally leaves three clk_sys edges between V60 bus enables, but carries can
// very rarely leave only two.  Sweep every accumulator phase and require the
// logical-bus adapter to retain the documented three-enable minimum even when
// the system-side target acknowledges with zero additional wait states.
//
// "Three enables" is counted inclusively: logical address/setup acceptance,
// m_req launch, and m_ack/c_ack completion.  An aligned dword needs two 16-bit
// physical cycles and therefore takes five enables in this zero-wait model.
//============================================================================
`timescale 1ns/1ps

module tb_v60_bus_nco_timing;

localparam [15:0] V60_CE_INC = s32_pkg::PCB_V60_CE_INC;
localparam integer PHASES = 65536;
localparam integer ALIGNED_ACCESSES_PER_PHASE = 8;
localparam integer BACK_TO_BACK_ACCESSES_PER_PHASE = 2;
localparam integer EXPECTED_ACKS =
    PHASES * (ALIGNED_ACCESSES_PER_PHASE + BACK_TO_BACK_ACCESSES_PER_PHASE);

reg clk = 1'b0;
reg rst = 1'b1;
always #5 clk = ~clk;

// Exact production NCO recurrence, with a seed input used only to exhaustively
// sweep the possible phase alignments.  ce_bus is registered just as ce_cpu is
// in Arcade-SegaSystem32.sv.
reg [15:0] phase_seed = 16'd0;
reg [15:0] ce_acc = 16'd0;
reg        ce_bus = 1'b0;
reg [16:0] ce_sum;
always @(posedge clk) begin
    if (rst) begin
        ce_acc  <= phase_seed;
        ce_bus <= 1'b0;
    end
    else begin
        ce_sum = {1'b0, ce_acc} + {1'b0, V60_CE_INC};
        ce_acc <= ce_sum[15:0];
        ce_bus <= ce_sum[16];
    end
end

reg         c_req = 1'b0;
reg         c_we = 1'b0;
reg  [31:0] c_addr = 32'd0;
reg   [1:0] c_size = 2'd0;
reg  [31:0] c_wdata = 32'd0;
wire [31:0] c_rdata;
wire        c_ack;
wire        m_req;
wire        m_we;
wire [23:1] m_addr;
wire [15:0] m_wdata;
wire  [1:0] m_be;
wire [15:0] m_rdata;
wire        m_ack;

s32_v60_bus dut (
    .clk(clk), .ce(ce_bus), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// Fastest legal target response: no target-added wait enable.  This makes the
// adapter, rather than the memory model, solely responsible for the minimum.
assign m_ack = m_req;
assign m_rdata = 16'h5aa5;

integer raw_clock = 0;
integer ce_clock = 0;
integer last_ce_raw = 0;
integer last_ce_valid = 0;
integer accepted = 0;
integer completed = 0;
integer active = 0;
integer accept_ce = 0;
integer min_ce_span = 32'h7fff_ffff;
integer max_ce_span = 0;
integer saw_gap2 = 0;
integer saw_gap3 = 0;
integer saw_gap2_during_access = 0;
integer saw_gap3_during_access = 0;
integer errors = 0;
integer gap;
integer span;
reg c_ack_q = 1'b0;

task automatic record_error;
    input integer code;
    input integer detail;
    begin
        errors = errors + 1;
        if (errors <= 20)
            $display("FAIL code=%0d detail=%0d phase=%04x raw=%0d ce=%0d",
                     code, detail, phase_seed, raw_clock, ce_clock);
    end
endtask

// Score only signals as sampled by the DUT at posedge clk.  c_ack is observed
// one raw edge after its nonblocking assignment; the NCO cannot emit adjacent
// enables, so ce_clock still names the completing enable at that observation.
always @(posedge clk) begin
    raw_clock = raw_clock + 1;
    if (rst) begin
        ce_clock = 0;
        last_ce_valid = 0;
        active = 0;
        c_ack_q = 1'b0;
    end
    else begin
        if (ce_bus) begin
            ce_clock = ce_clock + 1;
            if (last_ce_valid) begin
                gap = raw_clock - last_ce_raw;
                if (gap == 2) begin
                    saw_gap2 = 1;
                    if (active) saw_gap2_during_access = 1;
                end
                else if (gap == 3) begin
                    saw_gap3 = 1;
                    if (active) saw_gap3_during_access = 1;
                end
                else begin
                    record_error(1, gap);
                end
            end
            last_ce_raw = raw_clock;
            last_ce_valid = 1;

            // I_IDLE is encoded as zero.  Qualifying with !c_ack prevents an
            // ACK-held request from being mistaken for a new transaction.
            if ((dut.bst == 2'd0) && c_req && !c_ack) begin
                if (active)
                    record_error(2, ce_clock);
                active = 1;
                accept_ce = ce_clock;
                accepted = accepted + 1;
            end
        end

        if (c_ack && !c_ack_q) begin
            if (!active) begin
                record_error(3, ce_clock);
            end
            else begin
                span = ce_clock - accept_ce + 1;
                if (span < 3)
                    record_error(4, span);
                if (span < min_ce_span) min_ce_span = span;
                if (span > max_ce_span) max_ce_span = span;
                completed = completed + 1;
                active = 0;
            end
        end
        c_ack_q = c_ack;
    end
end

task automatic reset_at_phase;
    input integer seed;
    begin
        @(negedge clk);
        rst = 1'b1;
        c_req = 1'b0;
        c_we = 1'b0;
        c_addr = 32'd0;
        c_size = 2'd0;
        c_wdata = 32'd0;
        phase_seed = seed[15:0];
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
    end
endtask

task automatic wait_for_ack;
    input integer case_id;
    output integer ok;
    integer timeout;
    begin
        timeout = 0;
        while ((c_ack !== 1'b1) && timeout < 96) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (c_ack !== 1'b1) begin
            record_error(100 + case_id, timeout);
            ok = 0;
        end
        else begin
            ok = 1;
        end
    end
endtask

task automatic aligned_access;
    input integer case_id;
    input         we;
    input  [31:0] addr;
    input   [1:0] size;
    input  [31:0] wdata;
    integer ok;
    begin
        @(negedge clk);
        c_we = we;
        c_addr = addr;
        c_size = size;
        c_wdata = wdata;
        c_req = 1'b1;
        wait_for_ack(case_id, ok);
        c_req = 1'b0;
        // Let the raw-clock request-low path clear ACK and re-arm before the
        // next reset/phase case.
        @(posedge clk);
        @(negedge clk);
        if (c_ack !== 1'b0)
            record_error(200 + case_id, c_ack);
    end
endtask

task automatic back_to_back_accesses;
    integer ok;
    begin
        @(negedge clk);
        c_we = 1'b1;
        c_addr = 32'h0000_2000;
        c_size = 2'd1;
        c_wdata = 32'h0000_1357;
        c_req = 1'b1;
        wait_for_ack(20, ok);
        if (ok) begin
            // Exactly one raw clk_sys edge low.  This edge is intentionally
            // not aligned to ce_bus; every NCO phase must still re-arm.
            c_req = 1'b0;
            @(posedge clk);
            @(negedge clk);
            if (c_ack !== 1'b0)
                record_error(220, c_ack);

            c_addr = 32'h0000_2002;
            c_wdata = 32'h0000_2468;
            c_req = 1'b1;
            wait_for_ack(21, ok);
            c_req = 1'b0;
            @(posedge clk);
            @(negedge clk);
            if (c_ack !== 1'b0)
                record_error(221, c_ack);
        end
        else begin
            c_req = 1'b0;
        end
    end
endtask

integer phase;
initial begin
    // Each phase gets naturally aligned B/H/W reads and writes.  Bytes use
    // both external lanes; halfwords are even and dwords are 4-byte aligned.
    for (phase = 0; phase < PHASES; phase = phase + 1) begin
        if ((phase & 16'h1fff) == 0)
            $display("[aligned] phase %04x", phase);

        reset_at_phase(phase);
        aligned_access(0, 1'b0, 32'h0000_1000, 2'd0, 32'd0);
        reset_at_phase(phase);
        aligned_access(1, 1'b1, 32'h0000_1000, 2'd0, 32'h0000_00a1);
        reset_at_phase(phase);
        aligned_access(2, 1'b0, 32'h0000_1001, 2'd0, 32'd0);
        reset_at_phase(phase);
        aligned_access(3, 1'b1, 32'h0000_1001, 2'd0, 32'h0000_00b2);
        reset_at_phase(phase);
        aligned_access(4, 1'b0, 32'h0000_1002, 2'd1, 32'd0);
        reset_at_phase(phase);
        aligned_access(5, 1'b1, 32'h0000_1002, 2'd1, 32'h0000_c3d4);
        reset_at_phase(phase);
        aligned_access(6, 1'b0, 32'h0000_1004, 2'd2, 32'd0);
        reset_at_phase(phase);
        aligned_access(7, 1'b1, 32'h0000_1004, 2'd2, 32'he5f6_0718);
    end

    // Independently sweep the one-raw-clock request-low/re-arm sequence.  A
    // CE-only edge detector fails this sweep whenever the low pulse falls
    // between two fractional enables.
    for (phase = 0; phase < PHASES; phase = phase + 1) begin
        if ((phase & 16'h1fff) == 0)
            $display("[re-arm]  phase %04x", phase);
        reset_at_phase(phase);
        back_to_back_accesses();
    end

    repeat (2) @(posedge clk);

    if (accepted != EXPECTED_ACKS)
        record_error(300, accepted);
    if (completed != EXPECTED_ACKS)
        record_error(301, completed);
    if (!saw_gap2)
        record_error(302, saw_gap2);
    if (!saw_gap3)
        record_error(303, saw_gap3);
    if (!saw_gap2_during_access)
        record_error(304, saw_gap2_during_access);
    if (!saw_gap3_during_access)
        record_error(305, saw_gap3_during_access);

    $display("V60 BUS NCO SUMMARY phases=%0d accepted=%0d completed=%0d min_ce=%0d max_ce=%0d gap2=%0d gap3=%0d",
             PHASES, accepted, completed, min_ce_span, max_ce_span,
             saw_gap2_during_access, saw_gap3_during_access);
    if (errors == 0)
        $display("V60 BUS NCO TIMING PASS");
    else
        $fatal(1, "V60 BUS NCO TIMING FAIL (%0d errors)", errors);
    $finish;
end

initial begin
    #1000000000;
    $fatal(1, "V60 BUS NCO TIMING FAIL (global timeout)");
end

endmodule
