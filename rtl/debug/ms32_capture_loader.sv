// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capture blob loader: ioctl index 2 (the OSD's F2 slot, or rom index 2 of an
// .mra) carries a stream of little-endian u16 words in the order
// scripts/build_capture_blob.py writes them. Each word becomes one bus write
// at the CPU address MAME's ms32_map gives it, issued into ms32_cpu_sys's
// loader port while the V70 is held in reset -- so playback goes through the
// same decode, RAM ports and register mailbox as the game's own writes.
// ioctl_wait holds the HPS off from the byte that completes a word until
// that write has been acknowledged across the clock domains.
//
// The download holds the core reset, and the writes arrive during it:
// sys_reset is the core reset with the capture download taken out, and both
// ms32_video and ms32_cpu_sys's bus side must run from it or every write is
// dropped (sim/capload_tb drives this module the way hps_io does).
module ms32_capture_loader (
	input  logic        clk,
	input  logic        reset,            // the core's composite reset (includes ioctl_download)
	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,
	output logic        ioctl_wait,

	output logic        sys_reset,

	output logic        ld_req,           // held until ld_ack
	output logic [31:0] ld_addr,
	output logic [3:0]  ld_be,
	output logic [31:0] ld_data,
	input  logic        ld_ack
);

	localparam int W_TXRAM   = 0;                      // 0x2000 words
	localparam int W_BGRAM   = W_TXRAM   + 'h2000;     // 0x2000
	localparam int W_ROZRAM  = W_BGRAM   + 'h2000;     // 0x8000
	localparam int W_LINERAM = W_ROZRAM  + 'h8000;     // 0x800
	localparam int W_OBJRAM  = W_LINERAM + 'h800;      // 0x8000
	localparam int W_PALRAM  = W_OBJRAM  + 'h8000;     // 0x10000
	localparam int W_PRIRAM  = W_PALRAM  + 'h10000;    // 0x2000 (u8 in the low byte)
	localparam int W_VREGS   = W_PRIRAM  + 'h2000;     // 0x400 words: register byte offset = 4 * k
	localparam int W_END     = W_VREGS   + 'h400;

	wire ld_capture = ioctl_download && (ioctl_index[5:0] == 6'd2);
	assign sys_reset = reset & ~ld_capture;

	// region base address and u16 index for word w
	function automatic logic [35:0] place(input logic [17:0] w);   // {be, addr}
		logic [31:0] base;
		logic [17:0] rel;
		logic [3:0]  be;
		be = 4'b0011;
		if      (w < W_BGRAM)   begin base = 32'hC2C0_0000; rel = w - 18'(W_TXRAM);   end
		else if (w < W_ROZRAM)  begin base = 32'hC2C0_8000; rel = w - 18'(W_BGRAM);   end
		else if (w < W_LINERAM) begin base = 32'hC200_0000; rel = w - 18'(W_ROZRAM);  end
		else if (w < W_OBJRAM)  begin base = 32'hC220_0000; rel = w - 18'(W_LINERAM); end
		else if (w < W_PALRAM)  begin base = 32'hC280_0000; rel = w - 18'(W_OBJRAM);  end
		else if (w < W_PRIRAM)  begin base = 32'hC140_0000; rel = w - 18'(W_PALRAM);  end
		else if (w < W_VREGS)   begin base = 32'hC118_0000; rel = w - 18'(W_PRIRAM); be = 4'b0001; end
		else                    begin base = 32'hFCE0_0000; rel = w - 18'(W_VREGS);   end
		place = {be, base + {12'd0, rel, 2'b00}};
	endfunction

	logic [7:0] lo;
	always_ff @(posedge clk) begin
		if (reset && !ld_capture) begin
			ld_req <= 1'b0;
		end else begin
			if (ld_ack) ld_req <= 1'b0;
			if (ld_capture && ioctl_wr) begin
				if (!ioctl_addr[0]) lo <= ioctl_dout;
				else if (ioctl_addr[18:1] < W_END) begin
					{ld_be, ld_addr} <= place(ioctl_addr[18:1]);
					ld_data <= {16'd0, ioctl_dout, lo};
					ld_req  <= 1'b1;
				end
			end
		end
	end

	assign ioctl_wait = ld_req || (ld_capture && ioctl_wr && ioctl_addr[0]);

endmodule
