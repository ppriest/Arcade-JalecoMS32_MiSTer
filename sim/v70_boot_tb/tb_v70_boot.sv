// SPDX-License-Identifier: GPL-3.0-or-later
//
//  V70 boot bench: the vendored s32_v60 core (IS_V70=1) behind ms32_v70_bus,
//  running a real game's program ROM against a model of the MS32 memory map,
//  logging every physical bus access in the same format as MAME's tap trace
//  so scripts/compare_boot_trace.py can diff the two.
//
//  Run from the repository root (readmemh paths are CWD-relative):
//      scripts/run_sim.sh v70_boot_tb +GAME=tetrisp +N=20000
//
//  WHAT IS MODELLED, AND WHAT IS REPLAYED
//  --------------------------------------
//  Every RAM in ms32_map is backed at its full physical size and with its
//  mirrors, because the boot exercises them before anything is visible
//  (LESSONS_LEARNED: "An unbacked RAM region does not read as garbage, it
//  reads as a failed power-on memory test"). The 8- and 16-bit regions sit
//  behind umask32 the way MAME has them: one meaningful byte or halfword per
//  32-bit word, the rest reading zero.
//
//  I/O reads are NOT modelled. They are REPLAYED from the MAME trace: the
//  bench loads MAME's own recorded (address, data) pairs for every read that
//  is not ROM or RAM, and answers each such read with the next unconsumed
//  value MAME saw at that address. That makes inputs, DIPs and the sound
//  latch return exactly what MAME's did, in MAME's order, without a model of
//  any of them -- which is the point of a CPU trace diff: the only thing
//  under test is the CPU and its bus.
//
//  Address decode: every region in ms32_map has a .mirror() covering address
//  bits 29:26 (the 0xC/0xD/0xE/0xF aliases) plus region-specific low bits.
//  The decode below masks 29:26 off and matches on 25:16 the way MAME's
//  handlers resolve, then indexes with the bits the mirror leaves live.
`timescale 1ns/1ps

module tb_v70_boot;

reg clk = 0, rst = 1;
always #5 clk = ~clk;        // 100 MHz; ce=1, so the CPU runs at full clock

// ---------------------------------------------------------------- CPU + bus
wire        c_req, c_we, c_ack;
wire [31:0] c_addr, c_wdata, c_rdata;
wire [1:0]  c_size;
wire        m_req, m_we;
wire [31:2] m_addr;
wire [31:0] m_wdata;
wire [3:0]  m_be;
reg  [31:0] m_rdata;
reg         m_ack;

wire       irq_n;
wire [7:0] irq_vector;
wire       irq_ack;
wire        if_req;
wire [31:0] if_addr;
reg  [63:0] if_data = 64'd0;
reg         if_ack = 1'b0;
reg fastif = 0;

s32_v60 #(.START_PC(32'hFFFF_FFF0), .IS_V70(1'b1), .FAST_IFETCH(1'b1),
          // the whole 2 MB ROM, mirror bits 29:26 ignored, both ranges
          .IF_ROM0_MASK(32'hC3E0_0000), .IF_ROM0_MATCH(32'hC3E0_0000),
          .IF_ROM1_MASK(32'hC3E0_0000), .IF_ROM1_MATCH(32'hC3E0_0000)) cpu (
    .clk(clk), .ce(1'b1), .rst(rst), .fast_ifetch(fastif),
    .if_req(if_req), .if_addr(if_addr), .if_data(if_data), .if_ack(if_ack),
    .bus_req(c_req), .bus_we(c_we), .bus_addr(c_addr), .bus_size(c_size),
    .bus_wdata(c_wdata), .bus_rdata(c_rdata), .bus_ack(c_ack),
    .irq_n(irq_n), .irq_vector(irq_vector), .irq_ack(irq_ack), .nmi_n(1'b1)
);

ms32_v70_bus adapter (
    .clk(clk), .ce(1'b1), .rst(rst),
    .c_req(c_req), .c_we(c_we), .c_addr(c_addr), .c_size(c_size),
    .c_wdata(c_wdata), .c_rdata(c_rdata), .c_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
    .m_be(m_be), .m_rdata(m_rdata), .m_ack(m_ack)
);

// ---------------------------------------------------------------- memories
// Byte arrays, so the ROM image loads with no byte-order assumption and the
// byte-enable writes are literal.
reg [7:0] rom     [0:2097151];   // 0xFFE00000, 2 MB, mirror 0x3c000000
reg [7:0] scratch [0:131071];    // 0xC2E00000, 128 KB 32-bit, mirror 0x3c0e0000
reg [7:0] nvram   [0:8191];      // 0xC0000000,   8 KB  8-bit, mirror 0x3c1f8000
reg [7:0] priram  [0:8191];      // 0xC1180000,   8 KB  8-bit, mirror 0x3c038000
reg [7:0] palram  [0:131071];    // 0xC1400000, 128 KB 16-bit, mirror 0x3c1c0000
reg [7:0] rozram  [0:65535];     // 0xC2000000,  64 KB 16-bit, mirror 0x3c1e0000
reg [7:0] lineram [0:4095];      // 0xC2200000,   4 KB 16-bit, mirror 0x3c1fe000
reg [7:0] sprram  [0:65535];     // 0xC2800000,  64 KB 16-bit, mirror 0x3c1e0000
reg [7:0] txram   [0:16383];     // 0xC2C00000,  16 KB 16-bit, mirror 0x3c1f0000
reg [7:0] bgram   [0:16383];     // 0xC2C08000,  16 KB 16-bit, mirror 0x3c1f0000
reg [7:0] ioram   [0:4095];      // 0xFCE00000..0xFCE00FFF: sysctrl/sprite/roz/scroll regs, kept as RAM

// ---------------------------------------------------------------- decode
wire [31:0] a    = {m_addr, 2'b00};
wire [31:0] am   = a & 32'hC3FF_FFFF;      // bits 29:26 are mirror bits everywhere
wire        is_rom     = (am[31:21] == 11'b1100_0011_111);          // c3e00000-c3ffffff
wire        is_scratch = (am[31:20] == 12'hc2e);                    // c2e00000 +0x3c0e0000
wire        is_nvram   = (am[31:21] == 11'b1100_0000_000);          // c0000000-c01fffff
wire        is_priram  = (am[31:18] == 14'b1100_0001_0001_10);      // c1180000-c11bffff
wire        is_palram  = (am[31:21] == 11'b1100_0001_010);          // c1400000-c15fffff
wire        is_rozram  = (am[31:21] == 11'b1100_0010_000);          // c2000000-c21fffff
wire        is_lineram = (am[31:21] == 11'b1100_0010_001);          // c2200000-c23fffff
wire        is_sprram  = (am[31:21] == 11'b1100_0010_100);          // c2800000-c29fffff
wire        is_txbg    = (am[31:21] == 11'b1100_0010_110);          // c2c00000-c2dfffff
wire        is_bg      = is_txbg && am[15];
wire        is_ioregs  = (a[31:12] == 20'hfce00);
wire        is_io      = !(is_rom | is_scratch | is_nvram | is_priram | is_palram |
                           is_rozram | is_lineram | is_sprram | is_txbg | is_ioregs);

// Word read from a byte array at a byte offset (little-endian), with the
// umask32 rule applied by the caller.
function [31:0] rd_rom(input [20:0] o);     rd_rom     = {rom[o+3],     rom[o+2],     rom[o+1],     rom[o]};     endfunction
function [31:0] rd_scratch(input [16:0] o); rd_scratch = {scratch[o+3], scratch[o+2], scratch[o+1], scratch[o]}; endfunction

// ---------------------------------------------------------------- instruction port
// +FASTIF=1 serves the core's dedicated 8-byte instruction port from the ROM
// array with one clock of latency -- what an on-chip instruction cache hit
// looks like -- instead of routing prefetch through the 32-bit data adapter.
// It is the A/B for how much of the CPI is fetch (LESSONS/ROADMAP: 73% of
// cycles in S_FILL on real code through the adapter).
initial if ($value$plusargs("FASTIF=%d", fastif)) ;
// the core wants the line already aligned so byte 0 is the frontier byte
always @(posedge clk) begin
    if_ack <= if_req;
    if (if_req) if_data <= (is_rom_a(if_addr)) ?
        {rom[if_addr[20:0]+7], rom[if_addr[20:0]+6], rom[if_addr[20:0]+5], rom[if_addr[20:0]+4],
         rom[if_addr[20:0]+3], rom[if_addr[20:0]+2], rom[if_addr[20:0]+1], rom[if_addr[20:0]]} : 64'd0;
end
function is_rom_a(input [31:0] x); is_rom_a = ((x & 32'hC3FF_FFFF) >> 21) == 11'b1100_0011_111; endfunction

// ---------------------------------------------------------------- I/O replay
// MAME's reads of non-ROM/RAM addresses, in order. Loaded from a file the
// compare script writes: one "addr data" pair per line, hex.
integer NREPLAY = 0;
reg [31:0] rp_addr [0:65535];
reg [31:0] rp_data [0:65535];
integer rp_next = 0;         // next unconsumed replay entry
integer rp_miss = 0;

function [31:0] io_replay(input [31:0] addr);
    integer k; reg found;
    begin
        found = 0; io_replay = 32'h0;
        // scan forward from the next unconsumed entry for this address; the
        // window is bounded so a CPU that diverged does not walk the table
        for (k = rp_next; k < NREPLAY && k < rp_next + 64 && !found; k = k + 1)
            if (rp_addr[k] == addr) begin io_replay = rp_data[k]; rp_next = k + 1; found = 1; end
        if (!found) rp_miss = rp_miss + 1;
    end
endfunction

// ---------------------------------------------------------------- interrupts
// MAME's interrupt entries, replayed by POSITION (compare_boot_trace.py irqs):
// once the bench has seen the occurrence-th write of addr=data it is ARMED,
// and it asserts `level` on irq_n/irq_vector when the core's PC reaches the
// PC MAME pushed for that entry, holding it until the core consumes the
// vector (irq_ack). The write alone was not enough: MAME's vblank is a time
// event and rose during a DBcc that made no write, so the write is a lower
// bound and the PC is the exact point. Occurrences are counted per
// (addr,data) over every write the RTL makes, as the script counted MAME's.
integer NIRQ = 0;
reg [7:0]  iq_level [0:4095];
reg [31:0] iq_addr  [0:4095];
reg [31:0] iq_data  [0:4095];
integer    iq_occ   [0:4095];
reg [31:0] iq_pc    [0:4095];
reg [31:0] iq_psw   [0:4095];   // the PSW MAME pushed: picks the loop iteration at iq_pc
integer    iq_nrd   [0:4095];   // data reads MAME made between the trigger write and the entry
integer iq_next = 0;
integer rd_since = 0;           // data reads since the pending trigger's write
reg     iq_armed = 0;        // trigger write seen; fire when the core's PC reaches iq_pc
// Occurrences are counted GLOBALLY per (addr,data), from reset, exactly as
// the script counted MAME's -- a key's first occurrence can precede an
// earlier interrupt, and a count restarted at each ack never reaches it
// (frame 5, FE80D954=0 occurrence 2, was never taken that way).
integer wcount [longint];    // associative: {addr,data} -> writes so far
integer irq_taken = 0;

task automatic note_write(input [31:0] adr, input [31:0] d);
    longint key;
    begin
        key = {adr, d};
        if (!wcount.exists(key)) wcount[key] = 0;
        wcount[key] = wcount[key] + 1;
        if (iq_next < NIRQ && !iq_armed && adr == iq_addr[iq_next] && d == iq_data[iq_next]
            && wcount[key] == iq_occ[iq_next]) iq_armed <= 1'b1;
    end
endtask
// the pending trigger's count so far, for the live-arm term below
function automatic integer pending_count();
    longint key;
    begin
        key = {iq_addr[iq_next], iq_data[iq_next]};
        pending_count = wcount.exists(key) ? wcount[key] : 0;
    end
endfunction

// Fire when armed and the core is at MAME's entry PC. COMBINATIONAL, not
// registered: with SEQ_DISPATCH the successor's S_DECODE is the very clock
// after pc changes, and a registered irq_n was sampled one instruction late
// (return PC FFE0EC4C where MAME had FFE0EC49). Held by pc==target until the
// entry itself moves pc; iq_armed drops on irq_ack.
// ...and armed COMBINATIONALLY from the write while it is still on the bus,
// not from its acknowledge: the core posts a store and dispatches the
// successor before the ack, so pc can reach the target in the same clock the
// write is requested -- frame 5 was never taken with a registered arm.
// trig_count counts acknowledged occurrences; the live term is the pending one.
wire trig_live = m_req && m_we && !m_ack && iq_next < NIRQ && !iq_armed
                 && a == iq_addr[iq_next] && m_wdata == iq_data[iq_next]
                 && (pending_count() + 1) == iq_occ[iq_next];
// The PSW the core would push is its live psw; MAME's v60_do_irq pushes it
// before touching IE/EL, so the two compare directly. A loop can pass the
// entry PC several times between the trigger write and MAME's entry, and the
// flags are what separate the iterations (seen: 01040001 vs 01040002).
// A polling loop has the same PC and PSW every iteration; what separates the
// iteration MAME's timer landed on is how many data reads it had made since
// the trigger write. rd_since counts non-ROM reads after arming.
assign irq_n      = ~((iq_armed || trig_live) && cpu.pc == iq_pc[iq_next] && cpu.psw == iq_psw[iq_next]
                      && rd_since == iq_nrd[iq_next]);
assign irq_vector = iq_level[iq_next];
always @(posedge clk) if (irq_ack) begin
    irq_taken <= irq_taken + 1;
    iq_next <= iq_next + 1;
    iq_armed <= 1'b0;
    rd_since <= 0;
end

// ---------------------------------------------------------------- bus model
// Registered read, one-cycle ack; byte-enabled writes. 16-bit regions keep
// their data in the low halfword of each 32-bit slot (umask32 0x0000ffff), the
// 8-bit ones in the low byte (0x000000ff) -- what the CPU sees is what MAME's
// handlers return.
integer n_acc = 0;
integer N = 20000;
string  GAME = "tetrisp";
integer flog;

task automatic do_write(input [31:0] adr, input [3:0] be, input [31:0] d);
    integer i;
    begin
        for (i = 0; i < 4; i = i + 1) if (be[i]) begin
            if      (is_scratch) scratch[adr[16:0] + i] = d[8*i +: 8];
            else if (is_nvram   && i == 0) nvram  [adr[14:2]]         = d[7:0];
            else if (is_priram  && i == 0) priram [adr[14:2]]         = d[7:0];
            else if (is_palram  && i <  2) palram [{adr[17:2], i[0]}] = d[8*i +: 8];
            else if (is_rozram  && i <  2) rozram [{adr[16:2], i[0]}] = d[8*i +: 8];
            else if (is_lineram && i <  2) lineram[{adr[12:2], i[0]}] = d[8*i +: 8];
            else if (is_sprram  && i <  2) sprram [{adr[16:2], i[0]}] = d[8*i +: 8];
            else if (is_txbg && !is_bg && i < 2) txram[{adr[14:2], i[0]}] = d[8*i +: 8];
            else if (is_txbg &&  is_bg && i < 2) bgram[{adr[14:2], i[0]}] = d[8*i +: 8];
            else if (is_ioregs) ioram[adr[11:0] + i] = d[8*i +: 8];
        end
    end
endtask

function [31:0] do_read(input [31:0] adr);
    begin
        if      (is_rom)     do_read = rd_rom(adr[20:0]);
        else if (is_scratch) do_read = rd_scratch(adr[16:0]);
        else if (is_nvram)   do_read = {24'b0, nvram[adr[14:2]]};
        else if (is_priram)  do_read = {24'b0, priram[adr[14:2]]};
        else if (is_palram)  do_read = {16'b0, palram[{adr[17:2],1'b1}],  palram[{adr[17:2],1'b0}]};
        else if (is_rozram)  do_read = {16'b0, rozram[{adr[16:2],1'b1}],  rozram[{adr[16:2],1'b0}]};
        else if (is_lineram) do_read = {16'b0, lineram[{adr[12:2],1'b1}], lineram[{adr[12:2],1'b0}]};
        else if (is_sprram)  do_read = {16'b0, sprram[{adr[16:2],1'b1}],  sprram[{adr[16:2],1'b0}]};
        else if (is_txbg && !is_bg) do_read = {16'b0, txram[{adr[14:2],1'b1}], txram[{adr[14:2],1'b0}]};
        else if (is_txbg &&  is_bg) do_read = {16'b0, bgram[{adr[14:2],1'b1}], bgram[{adr[14:2],1'b0}]};
        else if (is_ioregs)  do_read = {ioram[adr[11:0]+3], ioram[adr[11:0]+2], ioram[adr[11:0]+1], ioram[adr[11:0]]};
        else                 do_read = io_replay(adr);
    end
endfunction

reg [31:0] mask_of_be, rd_now;
always @* mask_of_be = {{8{m_be[3]}}, {8{m_be[2]}}, {8{m_be[1]}}, {8{m_be[0]}}};

always @(posedge clk) begin
    m_ack <= 1'b0;
    if (m_req && !m_ack) begin
        m_ack <= 1'b1;
        if (m_we) begin
            do_write(a, m_be, m_wdata);
            note_write(a, m_wdata);
            $fdisplay(flog, "%0d\tw\t%08X\t%08X\t%08X", n_acc + 1, a, mask_of_be, m_wdata);
        end
        else begin
            if (iq_armed && !is_rom) rd_since <= rd_since + 1;
            // one call only: io_replay() consumes an entry each time it runs
            rd_now = do_read(a);
            m_rdata <= rd_now;
            $fdisplay(flog, "%0d\tr\t%08X\t%08X\t%08X", n_acc + 1, a, mask_of_be, rd_now);
        end
        n_acc <= n_acc + 1;
    end
end

// ---------------------------------------------------------------- decode monitor
// First decodes: what the window held when the core looked at it. Diagnostic
// for a boot that halts or wanders; costs nothing when it does not.
// ---------------------------------------------------------------- CPI
// Instructions retired = S_DECODE entries (every instruction passes through
// it once; an exception adds one). Bus-busy = cycles with a physical request
// outstanding, whoever owns it. This is the Phase 0 criterion-3 number.
longint cpi_cycles = 0, cpi_instr = 0, cpi_busbusy = 0, cpi_pfwait = 0;
// FP-group census: does this game execute 0x5C/0x5F at all? Decides whether
// the FP tail (the core's Fmax-limiting path) has to be carried.
longint cpi_fp = 0;
reg st_dec_d = 0;
always @(posedge clk) if (!rst) begin
    cpi_cycles <= cpi_cycles + 1;
    st_dec_d   <= (cpu.st == 3);
    if (cpu.st == 3 && !st_dec_d) begin
        cpi_instr <= cpi_instr + 1;
        if (cpu.fb[0] == 8'h5c || cpu.fb[0] == 8'h5f) cpi_fp <= cpi_fp + 1;
    end
    if (m_req) cpi_busbusy <= cpi_busbusy + 1;
    if (cpu.st == 1 /* S_FILL */) cpi_pfwait <= cpi_pfwait + 1;
end
integer ncyc = 0;
always @(posedge clk) if (!rst && ncyc < 60) begin
    ncyc = ncyc + 1;
    $display("CYC %0d st=%0d pc=%08x fb_base=%08x fb_valid=%0d fb_wr=%0d fb_need=%0d pf_busy=%0d pf_addr=%08x m_req=%0d m_ack=%0d",
             ncyc, cpu.st, cpu.pc, cpu.fb_base, cpu.fb_valid, cpu.fb_wr, cpu.fb_need, cpu.pf_busy, cpu.pf_addr, m_req, m_ack);
end
integer ndec = 0;
always @(posedge clk) if (!rst && cpu.st == 3 /* S_DECODE */ && ndec < 12) begin
    ndec = ndec + 1;
    $display("DECODE #%0d pc=%08x fb_base=%08x fb_valid=%0d fb_wr=%0d fb[0..7]=%02x %02x %02x %02x %02x %02x %02x %02x",
             ndec, cpu.pc, cpu.fb_base, cpu.fb_valid, cpu.fb_wr,
             cpu.fb[0], cpu.fb[1], cpu.fb[2], cpu.fb[3], cpu.fb[4], cpu.fb[5], cpu.fb[6], cpu.fb[7]);
end

// ---------------------------------------------------------------- run
integer i, f;
string  s, hexpath, rppath, outpath;
reg [31:0] ra, rd;
initial begin
    if (!$value$plusargs("GAME=%s", GAME)) GAME = "tetrisp";
    if (!$value$plusargs("N=%d", N)) N = 20000;
    hexpath = {"roms/", GAME, "/maincpu.hex"};
    rppath  = {"debug/", GAME, "-boot/", GAME, "_io_replay.txt"};
    // +TRACE=<name> picks the output file, so a Verilator run and a ModelSim
    // run of the same game can proceed side by side without clobbering.
    begin : pick_out
        string tracename;
        if (!$value$plusargs("TRACE=%s", tracename)) tracename = "rtl_boot.trace";
        outpath = {"debug/", GAME, "-boot/", tracename};
    end

    for (i = 0; i < 2097152; i = i + 1) rom[i] = 8'hCD;
    $readmemh(hexpath, rom);
    $display("ROM %s: bytes at FFFFFFF0 = %02x %02x %02x %02x", hexpath,
             rom[21'h1FFFF0], rom[21'h1FFFF1], rom[21'h1FFFF2], rom[21'h1FFFF3]);

    f = $fopen(rppath, "r");
    if (f) begin
        while (!$feof(f) && NREPLAY < 65536) begin
            if ($fscanf(f, "%h %h\n", ra, rd) == 2) begin
                rp_addr[NREPLAY] = ra; rp_data[NREPLAY] = rd; NREPLAY = NREPLAY + 1;
            end
        end
        $fclose(f);
    end
    $display("I/O replay: %0d entries from %s", NREPLAY, rppath);

    begin : load_irqs
        string irqpath; integer lv, occ, nrd; reg [31:0] ia, id, ipc, ipsw;
        irqpath = {"debug/", GAME, "-boot/", GAME, "_irqs.txt"};
        f = $fopen(irqpath, "r");
        if (f) begin
            void'($fgets(s, f));   // header line
            while (!$feof(f) && NIRQ < 4096)
                if ($fscanf(f, "%d %h %h %d %h %h %d\n", lv, ia, id, occ, ipc, ipsw, nrd) == 7) begin
                    iq_level[NIRQ] = lv[7:0]; iq_addr[NIRQ] = ia; iq_data[NIRQ] = id; iq_occ[NIRQ] = occ; iq_pc[NIRQ] = ipc; iq_psw[NIRQ] = ipsw; iq_nrd[NIRQ] = nrd;
                    NIRQ = NIRQ + 1;
                end
            $fclose(f);
        end
        $display("IRQ replay: %0d entries from %s", NIRQ, irqpath);
    end

    flog = $fopen(outpath, "w");
    $fdisplay(flog, "# RTL bus accesses from reset, in order (%s).", GAME);
    $fdisplay(flog, "# seq\trw\taddr\tmask\tdata");

    repeat (5) @(posedge clk);
    rst = 0;
    // run until N accesses, or a hang
    begin : run
        integer idle;
        idle = 0;
        while (n_acc < N) begin
            @(posedge clk);
            if (m_req) idle = 0; else idle = idle + 1;
            if (idle > 100000) begin
                $display("HANG: no bus activity for 100000 clocks after %0d accesses, PC=%08x", n_acc, cpu.pc);
                $display("      st=%0d fb_base=%08x fb_valid=%0d fb_wr=%0d frontier=%08x pf_busy=%0d pf_req=%0d pf_addr=%08x bus_owner=%0d dbus_req=%0d halted=%0d",
                         cpu.st, cpu.fb_base, cpu.fb_valid, cpu.fb_wr, cpu.fetch_frontier, cpu.pf_busy, cpu.pf_req, cpu.pf_addr, cpu.bus_owner, cpu.dbus_req, cpu.halted);
                disable run;
            end
        end
    end
    $fdisplay(flog, "# %0d accesses, %0d I/O replay misses, %0d of %0d interrupts taken, PC=%08x", n_acc, rp_miss, irq_taken, NIRQ, cpu.pc);
    $display("V70 IRQ: %0d of %0d replayed interrupts taken", irq_taken, NIRQ);
    $fclose(flog);
    $display("V70 BOOT: %0d accesses logged to %s, %0d I/O replay misses, PC=%08x", n_acc, outpath, rp_miss, cpu.pc);
    $display("V70 CPI: %0d instructions in %0d cycles = %0d.%02d cycles/instr; bus busy %0d cycles (%0d%%), in S_FILL %0d cycles (%0d%%); FP-group instructions %0d",
             cpi_instr, cpi_cycles, cpi_cycles / (cpi_instr ? cpi_instr : 1),
             (100 * cpi_cycles / (cpi_instr ? cpi_instr : 1)) % 100,
             cpi_busbusy, 100 * cpi_busbusy / (cpi_cycles ? cpi_cycles : 1),
             cpi_pfwait, 100 * cpi_pfwait / (cpi_cycles ? cpi_cycles : 1), cpi_fp);
    $finish;
end

endmodule
