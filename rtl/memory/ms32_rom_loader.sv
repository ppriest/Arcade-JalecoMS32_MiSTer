// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fast ROM load. An .mra whose <rom index="0"> carries address="0x30000000"
// makes the HPS write the whole ROM image straight into DDR3, and the core
// sees ioctl_download assert and drop with no ioctl_wr at all. This module
// then replays that image, byte by byte, into ms32_sdram_top's ordinary
// download port -- ioctl_wr pulses with ioctl_addr, paced by ioctl_wait --
// so the tile decryption, sdram_download's byte pairing and the SDRAM write
// path are exactly the ones the byte-streamed download uses and
// sim/sdram_dl_tb checks. The HPS no longer waits on the FPGA for every byte;
// the FPGA does the waiting instead, at its own rate.
//
// After Seta's rom_loader.sv (from Fuuki, from Psikyo, the mechanism from
// srg320/Arcade-PsikyoSH2_MiSTer). The difference is where the bytes go: that
// loader writes SDRAM words through a transform hook, and MS32's decryption
// moves single bytes to scattered addresses, which the download stage already
// handles.
//
// Granules come from ddram_phy (8 bytes, byte i at rdata[8*i +: 8]).
module ms32_rom_loader #(
	parameter logic [27:0] LENGTH = 28'h1BC_0000    // the end of ms32_sdram_top's map
) (
	input  logic         clk,
	input  logic         reset,

	input  logic         start,       // pulse
	output logic         active,      // copying: hold the core, feed the download port

	output logic         ddr_req,     // ddram_phy: pulse while !busy
	output logic [27:0]  ddr_addr,
	input  logic         ddr_busy,
	input  logic         ddr_valid,
	input  logic [63:0]  ddr_rdata,

	output logic         l_wr,        // one clock per byte
	output logic [26:0]  l_addr,
	output logic [7:0]   l_dout,
	input  logic         l_wait       // ms32_sdram_top's ioctl_wait
);

	typedef enum logic [2:0] {L_IDLE, L_RD, L_RDWAIT, L_BYTE, L_HOLD, L_WAIT} lst_t;
	lst_t st;
	logic [27:0] base;
	logic [63:0] gran;
	logic [2:0]  k;

	assign active   = (st != L_IDLE);
	assign ddr_req  = (st == L_RD) && !ddr_busy;
	assign ddr_addr = base;

	always_ff @(posedge clk) begin
		l_wr <= 1'b0;
		if (reset) begin
			st <= L_IDLE;
		end else case (st)
			L_IDLE: if (start) begin base <= 28'd0; st <= L_RD; end
			L_RD:     if (!ddr_busy) st <= L_RDWAIT;
			L_RDWAIT: if (ddr_valid) begin gran <= ddr_rdata; k <= 3'd0; st <= L_BYTE; end
			L_BYTE: begin
				l_addr <= base[26:0] + {24'd0, k};
				l_dout <= gran[{k, 3'b000} +: 8];
				l_wr   <= 1'b1;
				st     <= L_HOLD;
			end
			L_HOLD: st <= L_WAIT;                 // ioctl_wait follows the pulse a clock later
			L_WAIT: if (!l_wait) begin
				if (k != 3'd7) begin
					k  <= k + 3'd1;
					st <= L_BYTE;
				end else if (base + 28'd8 >= LENGTH) begin
					st <= L_IDLE;
				end else begin
					base <= base + 28'd8;
					st   <= L_RD;
				end
			end
			default: st <= L_IDLE;
		endcase
	end

endmodule
