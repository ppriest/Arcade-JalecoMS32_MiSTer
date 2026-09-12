// SPDX-License-Identifier: GPL-3.0-or-later
//
// Capture blob loader: ioctl index 2 (the OSD's F2 slot, or rom index 2 of an
// .mra) carries a stream of little-endian u16 words in the order
// scripts/build_capture_blob.py writes them; the word index selects the
// destination RAM or register block of ms32_video.
//
// The download holds the core reset, and the register writes arrive during
// it: video_reset is the core reset with the capture download taken out, and
// ms32_video must be driven from it or every register write is dropped.
// sim/capload_tb drives this module the way hps_io does.
module ms32_capture_loader (
	input  logic        clk,
	input  logic        reset,            // the core's composite reset (includes ioctl_download)
	input  logic        ioctl_download,
	input  logic [15:0] ioctl_index,
	input  logic        ioctl_wr,
	input  logic [26:0] ioctl_addr,
	input  logic  [7:0] ioctl_dout,

	output logic        video_reset,
	output logic        ld_tx, ld_bg, ld_roz, ld_line, ld_obj, ld_pal, ld_pri, ld_vreg,
	output logic [17:0] ld_rel,
	output logic [15:0] ld_data
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
	assign video_reset = reset & ~ld_capture;

	logic  [7:0] ld_lo;
	logic        ld_we = 1'b0;
	logic [17:0] ld_word;
	always_ff @(posedge clk) begin
		ld_we <= 1'b0;
		if (ld_capture && ioctl_wr) begin
			if (!ioctl_addr[0]) ld_lo <= ioctl_dout;
			else begin
				ld_we   <= 1'b1;
				ld_word <= ioctl_addr[18:1];
				ld_data <= {ioctl_dout, ld_lo};
			end
		end
	end

	assign ld_tx   = ld_we && (ld_word >= W_TXRAM)   && (ld_word < W_BGRAM);
	assign ld_bg   = ld_we && (ld_word >= W_BGRAM)   && (ld_word < W_ROZRAM);
	assign ld_roz  = ld_we && (ld_word >= W_ROZRAM)  && (ld_word < W_LINERAM);
	assign ld_line = ld_we && (ld_word >= W_LINERAM) && (ld_word < W_OBJRAM);
	assign ld_obj  = ld_we && (ld_word >= W_OBJRAM)  && (ld_word < W_PALRAM);
	assign ld_pal  = ld_we && (ld_word >= W_PALRAM)  && (ld_word < W_PRIRAM);
	assign ld_pri  = ld_we && (ld_word >= W_PRIRAM)  && (ld_word < W_VREGS);
	assign ld_vreg = ld_we && (ld_word >= W_VREGS)   && (ld_word < W_END);
	assign ld_rel  = ld_word - (ld_tx ? 18'(W_TXRAM) : ld_bg ? 18'(W_BGRAM) : ld_roz ? 18'(W_ROZRAM) : ld_line ? 18'(W_LINERAM) :
	                            ld_obj ? 18'(W_OBJRAM) : ld_pal ? 18'(W_PALRAM) : ld_pri ? 18'(W_PRIRAM) : 18'(W_VREGS));

endmodule
