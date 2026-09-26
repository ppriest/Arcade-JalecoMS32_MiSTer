// SPDX-License-Identifier: GPL-3.0-or-later
//
// Jaleco "FPU" maths coprocessor (F-1 Super Battle). Two of them sit on the
// V70's bus, at 0xfd100000 and 0xfd140000, each with its own program and data
// RAM, and interrupt the host when a routine ends.
//
// TRANSCRIBED FROM MAME's src/devices/cpu/jalfpu/jalfpu.cpp (BSD-3-Clause,
// copyright Andrea Bogazzi), from mamedev/mame PR 16135. The instruction set
// there was reverse-engineered from the program the V70 uploads and validated
// against the game's own self-test; this is that behaviour in RTL, opcode by
// opcode, so the two can be diffed instruction by instruction. Where MAME says
// a thing is unverified or unimplemented, so is this: unknown function codes
// do nothing, memory selector 0 uses base 0, and the control words other than
// halt are markers.
//
// THE MULTIPLY AND THE DIVIDE ARE REAL HERE. docs/WORKFLOW.md §13 forbids both
// in new RTL; this chip is a maths unit whose instruction set has a 16x16
// multiply and a 32/16 divide, so it is the stated exception. The multiply is
// one DSP block; the divide is a 16-step restoring divider, not a `/`.
//
// 20-bit instructions: 4-bit opcode, 16-bit argument. 16 registers s0-sf, two
// loop counters c6/c7, flags Z N C V, a 4-deep call stack, one delay slot, and
// a 16-bit "sign" register saying which registers a multiply treats as
// unsigned. Register results land in s[b], the multiply and divide also in sd.
//
// The real chip's clock is unknown -- MAME guesses 48 MHz / 8 and runs one
// instruction per cycle. CE_DIV divides the clock this runs on to about that
// rate. An instruction takes two ticks here (fetch, execute), a load three and
// a divide nineteen; the host cannot see the difference, since it starts a
// routine and waits for the interrupt.
module jalfpu #(
	parameter int CE_DIV = 2        // clk_cpu 20 MHz / 2, two ticks an instruction: ~5 MIPS
) (
	input  logic        clk,
	input  logic        rst,

	// Host window (32-bit bus, same clock), the map jalfpu.cpp's host_map
	// gives: 0x0000-0x23ff data RAM (one u16 per 32-bit slot), 0x2400-0x24ff
	// registers, 0x4000-0x5fff program RAM (a word's argument and opcode in
	// separate longs). h_req is held until h_valid, which answers once.
	input  logic        h_req,
	input  logic        h_we,
	input  logic [14:0] h_addr,     // byte address inside the window
	input  logic [15:0] h_wdata,
	output logic [15:0] h_rdata,
	output logic        h_valid,

	output logic        irq,        // level: set by a halt, cleared by the host
	output logic        busy,       // a routine is running: host PC write to halt

	// For sim/jalfpu_tb, which diffs these against MAME's own trace after every
	// instruction. dbg_stall freezes the sequencer between instructions so the
	// bench can apply the host writes where the trace has them; the core ties it
	// low and leaves the outputs unconnected, and the fitter strips the lot.
	input  logic        dbg_stall,
	output logic        dbg_retire, // one clock, the cycle after an instruction completes
	output logic [9:0]  dbg_ppc,
	output logic [19:0] dbg_op,
	output logic [255:0] dbg_s,     // s0 in [15:0], sf in [255:240]
	output logic [15:0] dbg_c6, dbg_c7, dbg_sign,
	output logic [3:0]  dbg_flags,
	output logic [2:0]  dbg_sp,

	// A JTAG window on the data RAM (MS32.sv, DEBUG_ISSP): while dbg_ren is
	// high port B reads dbg_raddr instead of the host's address, so a host read
	// in that time gets the wrong word -- the game should be paused.
	input  logic        dbg_ren,
	input  logic [11:0] dbg_raddr,
	output logic [15:0] dbg_rdata
);

	// ------------------------------------------------------------ clock enable
	localparam int CEW = (CE_DIV <= 2) ? 1 : $clog2(CE_DIV);
	logic [CEW-1:0] ce_cnt;
	wire ce = (ce_cnt == CEW'(CE_DIV - 1));
	always_ff @(posedge clk) begin
		if (rst)     ce_cnt <= '0;
		else if (ce) ce_cnt <= '0;
		else         ce_cnt <= ce_cnt + 1'b1;
	end

	// ------------------------------------------------------------ state
	localparam int F_Z = 0, F_N = 1, F_C = 2, F_V = 3;
	logic [9:0]  pc, ppc, delay_target;
	logic [15:0] s [0:15];
	logic [15:0] c6, c7, sign, ctrl;
	logic [3:0]  flags;             // {V, C, N, Z}
	logic [9:0]  stack [0:3];
	logic [2:0]  sp;
	logic        running, delay, in_delay;
	assign busy = running;
	logic [15:0] hostreg [0:63];    // the registers this chip does not decode

	// ------------------------------------------------------------ memories
	// program: 1,024 x 20, written by the host (port A), fetched by the core (B)
	logic        p_we;
	logic [9:0]  p_addr, p_raddr;
	logic [19:0] p_wdata, p_hrdata, op_word;
	dpram #(.ADDR_WIDTH(10), .DATA_WIDTH(20)) u_prg (
		.clk(clk),
		.a_addr(p_addr), .a_wel(p_we), .a_weh(p_we), .a_wdata(p_wdata), .a_rdata(p_hrdata),
		.b_addr(p_raddr), .b_re(1'b1), .b_rdata(op_word)
	);

	// data: the map declares 0x900 words, so 4,096 deep. Port A is the core's
	// (load, store) and the host's writes, which stall the core for a tick;
	// port B is the host's read.
	logic        d_we;
	logic [11:0] d_addr, d_haddr;
	logic [15:0] d_wdata, d_rdata, d_hrdata;
	dpram #(.ADDR_WIDTH(12), .DATA_WIDTH(16)) u_data (
		.clk(clk),
		.a_addr(d_addr), .a_wel(d_we), .a_weh(d_we), .a_wdata(d_wdata), .a_rdata(d_rdata),
		.b_addr(dbg_ren ? dbg_raddr : d_haddr), .b_re(1'b1), .b_rdata(d_hrdata)
	);
	assign dbg_rdata = d_hrdata;

	// ------------------------------------------------------------ host port
	// Two cycles: latch the request and present the RAM address, then answer
	// (and, for a write, write). A program write is read-modify-write, since
	// the host writes the argument and the opcode nibble separately.
	typedef enum logic [1:0] {H_IDLE, H_ADDR, H_WAIT, H_DONE} hst_t;
	hst_t hst;
	logic        h_we_l;
	logic [14:0] h_addr_l;
	logic [15:0] h_wdata_l;
	wire         h_is_data = (h_addr_l < 15'h2400);
	wire         h_is_reg  = (h_addr_l >= 15'h2400) && (h_addr_l < 15'h2500);
	wire         h_is_prg  = (h_addr_l >= 15'h4000) && (h_addr_l < 15'h6000);
	wire  [11:0] h_dword   = h_addr_l[13:2];        // data RAM word
	wire   [5:0] h_reg     = h_addr_l[7:2];         // register index
	wire   [9:0] h_pw      = h_addr_l[12:3];        // program word
	wire         h_plow    = h_addr_l[2];           // the argument half, else the opcode nibble
	// the host's data RAM write takes port A for one cycle
	wire         h_dwrite  = (hst == H_WAIT) && h_we_l && h_is_data;
	// a program write is read-modify-write, so the core must not fetch from the
	// program RAM's port A in that cycle -- it does not: the core fetches on B

	// ------------------------------------------------------------ decode
	wire [3:0]  opc = op_word[19:16];
	wire [15:0] arg = op_word[15:0];
	wire [5:0]  fn  = arg[15:10];
	wire [3:0]  ra  = arg[9:6];
	wire [3:0]  rb  = arg[3:0];
	wire [15:0] sa  = s[ra];
	wire [15:0] sb  = s[rb];
	wire [3:0]  cc  = fn[3:0];      // branch condition
	wire        csense = fn[4];
	wire        cdelay = fn[5];

	// jalfpu.cpp's LOAD_SEL, GROUP_REG and MODE_BASE tables
	function automatic logic [3:0] load_sel(input logic [3:0] o);
		case (o)
			4'd0:    load_sel = 4'h3;
			4'd1:    load_sel = 4'h7;
			4'd2:    load_sel = 4'hb;
			4'd3:    load_sel = 4'hd;
			4'd4:    load_sel = 4'he;
			default: load_sel = 4'hf;
		endcase
	endfunction
	function automatic logic [15:0] mode_base(input logic [2:0] sel);
		case (sel)
			3'd2:       mode_base = 16'h100;
			3'd3:       mode_base = 16'h200;
			3'd5, 3'd6: mode_base = 16'h300;
			3'd7:       mode_base = 16'h600;
			default:    mode_base = 16'h000;   // selector 0 unverified, as in MAME
		endcase
	endfunction

	// The data RAM effective address, declared here because opcode 0xc uses it
	// and vlog rejects a net used before its declaration.
	wire [15:0] d_ea = sa + mode_base(fn[4:2]);
	// Hoisted out of the lvalue s[...]: Questa crashes on a function call used
	// as an array index there (vgenexpr.c internal error). group_reg's six
	// answers become one vector for the same reason, indexed by the loop.
	wire [3:0]  ld_sel = load_sel(opc);
	localparam logic [23:0] GROUP_REGS = {4'h0, 4'h1, 4'h2, 4'h4, 4'h5, 4'h6};   // i = 5 down to 0

	localparam logic [15:0] CTL_HALT = 16'h4080;

	// Z and N from a result, C and V kept
	function automatic logic [3:0] nz(input logic [15:0] v, input logic [3:0] f);
		nz = {f[F_V], f[F_C], v[15], (v == 16'd0)};
	endfunction

	function automatic logic condition(input logic [3:0] code);
		case (code)
			4'h0:    condition = 1'b1;
			4'h2,
			4'h3:    condition = (c6 != 16'd0);
			4'h4,
			4'h5:    condition = (c7 != 16'd0);
			4'h8:    condition = flags[F_Z];
			4'h9:    condition = (flags[F_N] != flags[F_V]);                    // signed <
			4'ha:    condition = (flags[F_N] == flags[F_V]) && !flags[F_Z];     // signed >
			4'hd:    condition = flags[F_C];
			4'he:    condition = flags[F_N];
			4'hf:    condition = flags[F_V];
			default: condition = 1'b0;         // unknown condition: never taken, as MAME
		endcase
	endfunction

	// ------------------------------------------------------------ ALU (opcode 8)
	wire [16:0] alu_add = {1'b0, sb} + {1'b0, sa} + {16'd0, (fn == 6'h0f) && flags[F_C]};
	wire [16:0] alu_sub = {1'b0, sb} - {1'b0, sa} - {16'd0, (fn == 6'h1f) && flags[F_C]};
	wire [15:0] alu_and = sb & sa;
	wire [15:0] alu_or  = sb | sa;
	wire [15:0] alu_xor = sb ^ sa;
	wire        add_v   = (sb[15] ^ alu_add[15]) & (sa[15] ^ alu_add[15]);
	wire        sub_v   = (sb[15] ^ sa[15]) & (sb[15] ^ alu_sub[15]);

	// ------------------------------------------------------------ multiply (opcode 9)
	// one DSP: 17x17 signed covers both forms -- s16 x s16 (fn 0x17), and
	// s16 x u16 for the sign-register variants, negated when the sign bit is 0
	wire signed [16:0] mul_a = (fn == 6'h17) ? {sa[15], sa} : {1'b0, sa};
	wire signed [16:0] mul_b = {sb[15], sb};
	wire signed [33:0] mul_r = mul_a * mul_b;
	wire        [31:0] mul_p = ((fn != 6'h17) && !sign[ra]) ? -mul_r[31:0] : mul_r[31:0];

	// ------------------------------------------------------------ divide (opcode 9)
	// 16-step restoring divide on magnitudes. The quotient overflows 16 bits
	// exactly when the dividend's high half already reaches the divisor, which
	// also catches division by zero; jalfpu.cpp saturates rather than trapping.
	logic [16:0] dv_rem;            // working remainder
	logic [15:0] dv_low;            // the dividend bits still to be shifted in
	logic [15:0] dv_q, dv_d;
	logic [4:0]  dv_step;
	logic        dv_signed, dv_neg_q, dv_neg_r, dv_ovf;
	logic [3:0]  dv_rb;
	wire [16:0]  dv_shift = {dv_rem[15:0], dv_low[15]};
	wire [17:0]  dv_diff  = {1'b0, dv_shift} - {2'b00, dv_d};
	wire         dv_fits  = !dv_diff[17];

	// ------------------------------------------------------------ sequencer
	typedef enum logic [2:0] {T_IDLE, T_FETCH, T_EXEC, T_LOAD, T_LOAD2, T_DIV, T_DIVEND, T_LOADA} st_t;
	st_t st;
	logic [3:0] ld_rb;              // the register a pending load writes
	logic [11:0] ld_ea;             // and its address, to present again after a host write

	// A host write to the data RAM (port A) or to a register lands in H_WAIT.
	// The routine sits that cycle out: its own port A access or register write
	// in the same cycle would override the host's. MAME has no such overlap
	// -- the V70 never writes while a routine runs there -- but this FPU is
	// slower than MAME's, so on the board it can. A load caught by it presents
	// its address again (T_LOADA), since the host's write moved port A.
	wire         h_wr_now  = (hst == H_WAIT) && h_we_l && (h_is_data || h_is_reg);

	// the bench's view (Quartus 17 wants the block named and one assign apiece)
	genvar gi;
	generate
		for (gi = 0; gi < 16; gi = gi + 1) begin : g_dbg_s
			assign dbg_s[16*gi +: 16] = s[gi];
		end
	endgenerate
	assign dbg_c6    = c6;
	assign dbg_c7    = c7;
	assign dbg_sign  = sign;
	assign dbg_flags = flags;
	assign dbg_sp    = sp;
	assign dbg_ppc   = ppc;
	assign dbg_op    = op_word;

	integer i;
	always_ff @(posedge clk) begin
		p_we    <= 1'b0;
		dbg_retire <= 1'b0;
		d_we    <= 1'b0;
		h_valid <= 1'b0;

		if (rst) begin
			st <= T_IDLE; hst <= H_IDLE; dbg_retire <= 1'b0;
			running <= 1'b0; delay <= 1'b0; in_delay <= 1'b0; irq <= 1'b0;
			pc <= 10'd0; ppc <= 10'd0; sp <= 3'd0;
			flags <= 4'd0; sign <= 16'd0; ctrl <= 16'd0; c6 <= 16'd0; c7 <= 16'd0;
			for (i = 0; i < 16; i = i + 1) s[i] <= 16'd0;
		end else begin

			// ---------------------------------------------- host window
			case (hst)
				H_IDLE: if (h_req) begin
					h_addr_l  <= h_addr;
					h_we_l    <= h_we;
					h_wdata_l <= h_wdata;
					d_haddr   <= h_addr[13:2];        // present both RAM addresses
					p_addr    <= h_addr[12:3];
					hst       <= H_ADDR;
				end

				H_ADDR: hst <= H_WAIT;                // the RAMs are reading

				H_WAIT: begin                         // the RAMs have answered
					h_valid <= 1'b1;
					hst     <= H_DONE;
					if (h_is_prg) begin
						h_rdata <= h_plow ? p_hrdata[15:0] : {12'd0, p_hrdata[19:16]};
						if (h_we_l) begin
							p_wdata <= h_plow ? {p_hrdata[19:16], h_wdata_l}
							                  : {h_wdata_l[3:0], p_hrdata[15:0]};
							p_we    <= 1'b1;
						end
					end else if (h_is_data) begin
						h_rdata <= d_hrdata;
						if (h_we_l) begin             // takes port A for this cycle
							d_addr  <= h_dword;
							d_wdata <= h_wdata_l;
							d_we    <= 1'b1;
						end
					end else if (h_is_reg) begin
						if (h_reg < 6'h10) begin
							h_rdata <= s[h_reg[3:0]];
							if (h_we_l) s[h_reg[3:0]] <= h_wdata_l;
						end else if (h_reg == 6'h30) begin
							h_rdata <= {6'd0, pc};
							if (h_we_l) begin         // writing the PC starts a routine
								pc      <= h_wdata_l[9:0];
								delay   <= 1'b0;
								running <= 1'b1;
							end
						end else if (h_reg == 6'h32) begin
							h_rdata <= ctrl;
							if (h_we_l) begin
								ctrl <= h_wdata_l;
								if (|(h_wdata_l & 16'h0006)) irq <= 1'b0;
							end
						end else begin
							h_rdata <= hostreg[h_reg];
							if (h_we_l) hostreg[h_reg] <= h_wdata_l;
						end
					end else begin
						h_rdata <= 16'd0;
					end
				end

				default: if (!h_req) hst <= H_IDLE;   // one answer per request
			endcase

			// ---------------------------------------------- core
			if (h_wr_now) begin
				if (st == T_LOAD || st == T_LOAD2) st <= T_LOADA;
			end else if (!dbg_stall) case (st)
				T_IDLE: if (running && !h_dwrite) begin
					p_raddr <= pc;
					st      <= T_FETCH;
				end

				T_FETCH: if (ce) begin                // op_word is the instruction at p_raddr
					ppc      <= p_raddr;
					pc       <= p_raddr + 10'd1;
					in_delay <= delay;
					delay    <= 1'b0;
					st       <= T_EXEC;
				end

				T_EXEC: begin
					st <= T_IDLE;                     // most instructions are one tick
					dbg_retire <= 1'b1;               // cleared below if it needs more
					if (in_delay) begin               // the branch that took the slot lands now
						pc       <= delay_target;
						in_delay <= 1'b0;
					end
					unique case (opc)
						4'h0, 4'h1, 4'h2, 4'h3, 4'h4, 4'h5: s[ld_sel] <= arg;
						4'h6: c6 <= arg;
						4'h7: c7 <= arg;

						4'h8: case (fn)               // add, subtract, compare, and, or, xor
							6'h07, 6'h0f: begin
								s[rb] <= alu_add[15:0];
								flags <= {add_v, alu_add[16], alu_add[15], (alu_add[15:0] == 16'd0)};
							end
							6'h17, 6'h1f, 6'h27: begin
								if (fn != 6'h27) s[rb] <= alu_sub[15:0];   // 0x27 is compare
								flags <= {sub_v, alu_sub[16], alu_sub[15], (alu_sub[15:0] == 16'd0)};
							end
							6'h2f: begin s[rb] <= alu_and; flags <= {2'b00, alu_and[15], (alu_and == 16'd0)}; end
							6'h37: begin s[rb] <= alu_or;  flags <= {2'b00, alu_or[15],  (alu_or  == 16'd0)}; end
							6'h3f: begin s[rb] <= alu_xor; flags <= {2'b00, alu_xor[15], (alu_xor == 16'd0)}; end
							default: ;                // unimplemented, as MAME logs it
						endcase

						4'h9: case (fn)               // multiply, divide, test
							6'h1c, 6'h1d, 6'h1e, 6'h17: begin
								s[rb]   <= mul_p[31:16];
								s[4'hd] <= mul_p[15:0];
								flags   <= nz(mul_p[31:16], flags);
							end
							6'h07: flags <= nz(sb, flags);
							6'h27, 6'h2f: begin       // unsigned and signed divide
								dv_signed <= (fn == 6'h2f);
								dv_neg_q  <= (fn == 6'h2f) && (sb[15] ^ sa[15]);
								dv_neg_r  <= (fn == 6'h2f) && sb[15];
								dv_d      <= ((fn == 6'h2f) && sa[15]) ? (~sa + 16'd1) : sa;
								// the dividend is {s[b], sd}; take its magnitude for a signed divide
								if ((fn == 6'h2f) && sb[15]) begin
									dv_rem <= {1'b0, (s[4'hd] == 16'd0) ? (~sb + 16'd1) : ~sb};
									dv_low <= ~s[4'hd] + 16'd1;
								end else begin
									dv_rem <= {1'b0, sb};
									dv_low <= s[4'hd];
								end
								dv_q    <= 16'd0;
								dv_step <= 5'd0;
								dv_rb   <= rb;
								st      <= T_DIV;
								dbg_retire <= 1'b0;
							end
							default: ;
						endcase

						4'ha: case (fn)               // move, increment, decrement, negate, absolute, not
							6'h3c, 6'h3d, 6'h3e, 6'h3f: begin s[rb] <= sa; flags <= nz(sa, flags); end
							6'h07: begin
								s[rb] <= sa + 16'd1;
								flags <= {(sa == 16'h7fff), (sa == 16'hffff), (sa + 16'd1) == 16'd0 ? 1'b0 : (sa + 16'd1) >= 16'h8000, ((sa + 16'd1) == 16'd0)};
							end
							6'h0f: begin
								s[rb] <= sa - 16'd1;
								flags <= {(sa == 16'h8000), (sa == 16'd0), (sa - 16'd1) >= 16'h8000, ((sa - 16'd1) == 16'd0)};
							end
							6'h17: begin s[rb] <= ~sa + 16'd1; flags <= nz(~sa + 16'd1, flags); end
							6'h1f: begin                      // absolute value
								s[rb] <= sa[15] ? (~sa + 16'd1) : sa;
								// N says the input was positive: the host ROM's projected Y table needs that
								flags <= {flags[F_V], flags[F_C], (!sa[15] && (sa != 16'd0)),
								          ((sa[15] ? (~sa + 16'd1) : sa) == 16'd0)};
							end
							6'h27: begin s[rb] <= ~sa; flags <= nz(~sa, flags); end
							default: ;
						endcase

						4'hb: case (fn)               // shifts and rotates
							6'h07: begin s[rb] <= {sa[14:0], 1'b0};       flags <= {flags[F_V], sa[15], sa[14], (sa[14:0] == 15'd0)}; end
							6'h0f: begin s[rb] <= {1'b0, sa[15:1]};       flags <= {flags[F_V], sa[0], 1'b0, (sa[15:1] == 15'd0)}; end
							6'h1f: begin s[rb] <= {sa[15], sa[15:1]};     flags <= {flags[F_V], sa[0], sa[15], ({sa[15], sa[15:1]} == 16'd0)}; end
							6'h37: begin s[rb] <= {sa[14:0], flags[F_C]}; flags <= {flags[F_V], sa[15], sa[14], ({sa[14:0], flags[F_C]} == 16'd0)}; end
							6'h3f: begin s[rb] <= {flags[F_C], sa[15:1]}; flags <= {flags[F_V], sa[0], flags[F_C], ({flags[F_C], sa[15:1]} == 16'd0)}; end
							default: ;
						endcase

						4'hc: begin                   // data RAM load and store
							d_addr <= d_ea[11:0];
							ld_ea  <= d_ea[11:0];
							if (fn[1]) s[ra] <= fn[0] ? (sa - 16'd1) : (sa + 16'd1);
							if (fn[5]) begin
								ld_rb <= rb;
								st    <= T_LOAD;      // port A answers next cycle
								dbg_retire <= 1'b0;
							end else begin
								d_wdata <= sb;
								d_we    <= 1'b1;
							end
						end

						4'hd: for (i = 0; i < 6; i = i + 1)   // register group operations
							if (arg[4 + i]) case (fn)
								6'h1e, 6'h1f: sign[GROUP_REGS[4*i +: 4]] <= 1'b0;
								6'h2d:        sign[GROUP_REGS[4*i +: 4]] <= flags[F_N];
								6'h3a:        if (flags[F_C]) s[GROUP_REGS[4*i +: 4]] <= 16'hffff;
								default: ;
							endcase

						4'he: if (arg == CTL_HALT) begin      // end of routine
							running <= 1'b0;
							irq     <= 1'b1;
						end

						4'hf: begin                   // branch, call, return
							// c6/c7 post-decrement on the counted conditions, taken or not
							if (cc == 4'h3) c6 <= c6 - 16'd1;
							if (cc == 4'h5) c7 <= c7 - 16'd1;
							if (cc == 4'h7) begin
								if (csense) begin                        // call
									if (sp < 3'd4) begin
										stack[sp[1:0]] <= ppc + (cdelay ? 10'd2 : 10'd1);
										sp <= sp + 3'd1;
									end
									if (cdelay) begin delay <= 1'b1; delay_target <= arg[9:0]; end
									else pc <= arg[9:0];
								end else if (sp != 3'd0) begin           // return
									sp <= sp - 3'd1;
									if (cdelay) begin delay <= 1'b1; delay_target <= stack[sp[1:0] - 2'd1]; end
									else pc <= stack[sp[1:0] - 2'd1];
								end
							end else if (condition(cc) == csense) begin
								if (cdelay) begin delay <= 1'b1; delay_target <= arg[9:0]; end
								else pc <= arg[9:0];
							end
						end

						default: ;
					endcase
				end

				T_LOAD: st <= T_LOAD2;            // the RAM is reading

				T_LOADA: begin                    // a host write moved port A: again
					d_addr <= ld_ea;
					st     <= T_LOAD;
				end

				T_LOAD2: begin
					s[ld_rb]   <= d_rdata;
					st         <= T_IDLE;
					dbg_retire <= 1'b1;
				end

				T_DIV: if (ce) begin
					if (dv_step == 5'd0 && (dv_d == 16'd0 || dv_rem[15:0] >= dv_d)) begin
						dv_ovf <= 1'b1;               // the quotient cannot fit 16 bits
						st     <= T_DIVEND;
					end else begin
						dv_ovf  <= 1'b0;
						dv_rem  <= dv_fits ? dv_diff[16:0] : dv_shift;
						dv_low  <= {dv_low[14:0], 1'b0};
						dv_q    <= {dv_q[14:0], dv_fits};
						dv_step <= dv_step + 5'd1;
						if (dv_step == 5'd15) st <= T_DIVEND;
					end
				end

				T_DIVEND: begin
					if (dv_ovf) begin                 // saturate, as jalfpu.cpp does
						s[4'hd] <= dv_signed ? (dv_neg_q ? 16'h8000 : 16'h7fff) : 16'hffff;
						flags   <= {1'b1, flags[F_C],
						            dv_signed ? dv_neg_q : 1'b1,
						            1'b0};
					end else begin
						s[4'hd]  <= dv_neg_q ? (~dv_q + 16'd1) : dv_q;
						s[dv_rb] <= dv_neg_r ? (~dv_rem[15:0] + 16'd1) : dv_rem[15:0];
						flags    <= nz(dv_neg_q ? (~dv_q + 16'd1) : dv_q, flags);
					end
					st         <= T_IDLE;
					dbg_retire <= 1'b1;
				end

				default: st <= T_IDLE;
			endcase
		end
	end

	// the effective address of a data RAM access, before any post-increment

endmodule
