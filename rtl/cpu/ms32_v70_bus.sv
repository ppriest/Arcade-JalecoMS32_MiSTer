// SPDX-License-Identifier: GPL-3.0-or-later
//
// Arcade-JalecoMS32_MiSTer - Copyright (C) 2026 Paul Priest
//
//============================================================================
//  V70 logical-bus adapter: 32-bit external data bus.
//
//  The vendored s32_v60 core (rtl/cpu/v60/) issues LOGICAL accesses -- any
//  address, size 1/2/4 bytes -- on its bus_* port and expects the adapter to
//  turn them into aligned physical cycles. Upstream's s32_v60_bus does that
//  for the V60's 16-bit bus (1..3 cycles on m_addr[23:1]) and declares an
//  IS_V70 parameter it never acts on. This is the V70 version: 1..2 aligned
//  32-bit cycles on a 32-bit address, with byte enables.
//
//  The CPU-side handshake is copied from s32_v60_bus and must stay identical,
//  because the core was written against it: c_req is held until c_ack, the
//  adapter observes the request-low re-arm on EVERY clock edge (the
//  microsequencer may advance between bus enables) and holds c_ack until it
//  is seen. See the "Four-phase CPU-side handshake" note upstream.
//
//  Physical side contract (the MS32 memory map behind it, rtl/ms32_*):
//    m_req   held high until m_ack; a new request always shows a 0->1 edge
//    m_addr  word address, m_addr = c_addr[31:2] for cycle 0, +1 for cycle 1
//    m_be    byte lanes, little-endian: be[0] is the byte at m_addr*4+0
//    m_ack   one clock; m_rdata must be valid on it (registered or not).
//            Ack is sampled only while ce is high, so a source in a faster
//            clock domain must HOLD it (LESSONS_LEARNED, "DTACK/ready must
//            be a held level").
//
//  Cycle counts, from the low address bits and the size:
//    byte            1
//    half  a[1:0]!=3 1     a[1:0]==3  2   (bytes at +3 and +4)
//    word  a[1:0]==0 1     otherwise  2
//  Unaligned halves and words are legal on a V70 and MAME's core issues them
//  (read_dword_unaligned throughout v60.cpp); the trace shows the CPU doing
//  exactly that on tetrisp's boot.
//============================================================================

module ms32_v70_bus (
    input             clk,
    input             ce,
    input             rst,

    // CPU side (logical) -- identical to s32_v60_bus
    input             c_req,
    input             c_we,
    input      [31:0] c_addr,
    input       [1:0] c_size,      // 0=B 1=H 2=W
    input      [31:0] c_wdata,
    output reg [31:0] c_rdata,
    output reg        c_ack,

    // system side: 32-bit bus
    output reg        m_req,
    output reg        m_we,
    output reg [31:2] m_addr,
    output reg [31:0] m_wdata,
    output reg  [3:0] m_be,
    input      [31:0] m_rdata,
    input             m_ack
);

typedef enum logic [1:0] { I_IDLE, I_CYC, I_WAIT } bst_t;
bst_t bst;

reg        cyc, cycs;          // current / total cycles - 1 (0 or 1)
reg [31:0] addr_r, wdata_r;
reg [1:0]  size_r;
reg        we_r;
reg        c_req_armed;
reg [31:0] acc;                // read assembly

// Byte lanes and write data for one physical cycle. Cycle 0 starts at lane
// a[1:0]; cycle 1 (only for an access that crosses the word) starts at lane 0
// and carries whatever bytes were left over.
//   nbytes = 1 << size ; first cycle carries min(nbytes, 4 - a[1:0]) bytes.
function automatic [3:0] lanes(input [1:0] a, input [1:0] size, input c);
    reg [2:0] nb, first, rest;
    begin
        nb    = 3'd1 << size;
        first = (nb <= (3'd4 - {1'b0, a})) ? nb : (3'd4 - {1'b0, a});
        rest  = nb - first;
        if (!c) lanes = (4'b1111 >> (3'd4 - first)) << a;
        else    lanes = (4'b1111 >> (3'd4 - rest));
    end
endfunction

// Data shifted into place for cycle c: cycle 0 shifts up by a[1:0] bytes,
// cycle 1 shifts down by the bytes cycle 0 carried.
function automatic [31:0] wshift(input [31:0] d, input [1:0] a, input c);
    reg [2:0] first;
    begin
        first = 3'd4 - {1'b0, a};
        if (!c) wshift = d << ({3'b0, a} * 8);
        else    wshift = d >> ({2'b0, first} * 8);
    end
endfunction

// cycle-0 read word shifted down so the addressed byte is at [7:0]; the byte
// count cycle 0 carried, which is where cycle 1's bytes start
wire [31:0] rd_sh    = m_rdata >> ({3'b0, addr_r[1:0]} * 8);
wire [2:0]  rd_first = 3'd4 - {1'b0, addr_r[1:0]};

always @(posedge clk) begin
    if (rst) begin
        bst <= I_IDLE; m_req <= 0; c_ack <= 0; c_req_armed <= 1;
        cyc <= 0; cycs <= 0;
    end
    else begin
        if (!c_req) begin
            c_ack <= 1'b0;
            c_req_armed <= 1'b1;
        end

        if (ce) begin
            case (bst)
            I_IDLE: if (c_req && c_req_armed && !c_ack) begin
                c_req_armed <= 1'b0;
                addr_r  <= c_addr;
                wdata_r <= c_wdata;
                size_r  <= c_size;
                we_r    <= c_we;
                cyc     <= 1'b0;
                case (c_size)
                    2'd0:    cycs <= 1'b0;
                    2'd1:    cycs <= (c_addr[1:0] == 2'd3);
                    default: cycs <= (c_addr[1:0] != 2'd0);
                endcase
                bst <= I_CYC;
            end
            I_CYC: begin
                m_req   <= 1'b1;
                m_we    <= we_r;
                m_addr  <= addr_r[31:2] + {29'b0, cyc};
                m_be    <= lanes(addr_r[1:0], size_r, cyc);
                m_wdata <= wshift(wdata_r, addr_r[1:0], cyc);
                bst     <= I_WAIT;
            end
            I_WAIT: if (m_ack) begin
                m_req <= 1'b0;
                if (cyc == cycs) begin
                    bst <= I_IDLE;
                    if (c_req) c_ack <= 1'b1;
                end
                else begin
                    cyc <= 1'b1;
                    bst <= I_CYC;
                end
            end
            default: bst <= I_IDLE;
            endcase

            // Read assembly. Cycle 0's bytes land at [7:0] upward after
            // shifting the word down by a[1:0] bytes; cycle 1's bytes, if any,
            // go above them. Unused high bytes are zero -- the core masks by
            // size itself, but a clean value is cheaper to read in a trace.
            if (bst == I_WAIT && m_ack && !we_r) begin
                if (cyc == 1'b0) begin
                    acc <= rd_sh;
                    case (size_r)
                        2'd0:    c_rdata <= rd_sh & 32'h0000_00ff;
                        2'd1:    c_rdata <= rd_sh & 32'h0000_ffff;
                        default: c_rdata <= rd_sh;
                    endcase
                end
                else begin
                    // second cycle: m_rdata's low bytes go above cycle 0's
                    case (size_r)
                        2'd1:    c_rdata <= {16'b0, m_rdata[7:0], acc[7:0]};
                        default: c_rdata <= (m_rdata << (rd_first * 8)) | acc;
                    endcase
                end
            end
        end
    end
end

endmodule
