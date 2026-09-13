// SPDX-License-Identifier: GPL-3.0-or-later
//
// Dual-clock RAM: port A (clk_a) reads and writes with byte-lane enables,
// port B (clk_b) reads. The CPU port of every video RAM, with the video
// engines on port B in clk_sys. Depth 2**ADDR_WIDTH. Reads are synchronous,
// one cycle, on each port's own clock.
//
// SYNTHESIS INSTANTIATES altsyncram. Inferred from behavioural code (port A
// read/write in one block, port B read in another) Quartus 17 built every
// one of these as TWO simple-dual-port copies, one per read port -- the
// first Phase 2 fit needed 6.8 Mbit of block memory against the device's
// 5.66, 2.45 Mbit of it duplicates (LESSONS_LEARNED, "Driving a dual-port
// RAM's second read port can silently REPLICATE the array"). A
// BIDIR_DUAL_PORT altsyncram with two clocks and byte enables is one M10K
// array. The behavioural model below is what every simulator runs (Quartus
// synthesis defines ALTERA_RESERVED_QIS).
//
// b_re gates port B's address register (clocken1). With b_re tied high, as
// every user of this module has, that is the behavioural model exactly.
module dpram_dc #(
	parameter int ADDR_WIDTH = 13,
	parameter int DATA_WIDTH = 16
) (
	input  logic                   clk_a,
	input  logic [ADDR_WIDTH-1:0] a_addr,
	input  logic                   a_wel,    // write a_wdata[7:0]
	input  logic                   a_weh,    // write a_wdata[DATA_WIDTH-1:8]
	input  logic [DATA_WIDTH-1:0] a_wdata,
	output logic [DATA_WIDTH-1:0] a_rdata,

	input  logic                   clk_b,
	input  logic [ADDR_WIDTH-1:0] b_addr,
	input  logic                   b_re,
	output logic [DATA_WIDTH-1:0] b_rdata
);

`ifndef ALTERA_RESERVED_QIS
	logic [DATA_WIDTH-1:0] mem [0:(1 << ADDR_WIDTH) - 1];

	localparam int HI = (DATA_WIDTH > 8) ? DATA_WIDTH - 1 : 8;
	always_ff @(posedge clk_a) begin
		a_rdata <= mem[a_addr];
		if (a_wel) mem[a_addr][7:0] <= a_wdata[7:0];
		if (DATA_WIDTH > 8 && a_weh) mem[a_addr][HI:8] <= a_wdata[HI:8];
	end

	always_ff @(posedge clk_b) begin
		if (b_re) b_rdata <= mem[b_addr];
	end
`else
	localparam int NBE = (DATA_WIDTH + 7) / 8;
	wire [NBE-1:0] be = (NBE == 1) ? a_wel : {{(NBE-1){a_weh}}, a_wel};

	altsyncram #(
		.operation_mode("BIDIR_DUAL_PORT"),
		.ram_block_type("M10K"),
		.intended_device_family("Cyclone V"),
		.lpm_type("altsyncram"),
		.numwords_a(1 << ADDR_WIDTH), .widthad_a(ADDR_WIDTH), .width_a(DATA_WIDTH),
		.numwords_b(1 << ADDR_WIDTH), .widthad_b(ADDR_WIDTH), .width_b(DATA_WIDTH),
		.width_byteena_a(NBE), .byte_size(8),
		.width_byteena_b(1),
		.outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
		.address_reg_b("CLOCK1"), .indata_reg_b("CLOCK1"), .wrcontrol_wraddress_reg_b("CLOCK1"),
		.clock_enable_input_a("BYPASS"), .clock_enable_output_a("BYPASS"),
		.clock_enable_input_b("NORMAL"), .clock_enable_output_b("BYPASS"),
		.outdata_aclr_a("NONE"), .outdata_aclr_b("NONE"),
		.read_during_write_mode_mixed_ports("DONT_CARE"),
		.read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
		.read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
		.power_up_uninitialized("FALSE")
	) u_ram (
		.clock0(clk_a), .address_a(a_addr), .data_a(a_wdata), .wren_a(a_wel | a_weh), .byteena_a(be), .q_a(a_rdata),
		.clock1(clk_b), .clocken1(b_re), .address_b(b_addr), .data_b({DATA_WIDTH{1'b0}}), .wren_b(1'b0), .q_b(b_rdata),
		.aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0), .addressstall_b(1'b0), .byteena_b(1'b1),
		.clocken0(1'b1), .clocken2(1'b1), .clocken3(1'b1), .rden_a(1'b1), .rden_b(1'b1), .eccstatus()
	);
`endif

endmodule
