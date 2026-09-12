// SPDX-License-Identifier: GPL-3.0-or-later
//
// Object RAM (0x10000 bytes, 16-bit behind umask32, 4,096 sprite records)
// and its vblank copy. ms32_v.cpp screen_vblank() copies the whole RAM
// into m_sprram_buffer at the START of vblank and draw_sprites renders
// from the copy; the game rewrites the live RAM during that same vblank.
// A bank swap is not a copy (LESSONS_LEARNED, and the capture tooling
// found the same thing): the game keeps writing to the same RAM it wrote
// last frame, so the copy has to be a copy.
//
// 32,768 u16 words at one per clock take 32,768 clocks, 5.3 of the 39
// default vblank lines; copy_done pulses when the copy is complete and is
// what starts ms32_sprite. The engine reads the copy through obj_addr.
module ms32_objram (
	input  logic        clk,
	input  logic        reset,

	// CPU port, u16 index
	input  logic [14:0] cpu_addr,
	input  logic        cpu_wel,
	input  logic        cpu_weh,
	input  logic [15:0] cpu_wdata,
	output logic [15:0] cpu_rdata,

	input  logic        frame_start,        // vblank start
	output logic        copy_done,          // one clk
	output logic        copying,

	// sprite engine port into the copy
	input  logic [14:0] obj_addr,
	output logic [15:0] obj_data
);

	logic [14:0] ci;
	logic [15:0] live_q;
	logic        cp_we;
	logic [14:0] cp_addr;

	// live RAM: port A the CPU, port B the copier
	dpram #(.ADDR_WIDTH(15), .DATA_WIDTH(16)) u_live (
		.clk(clk),
		.a_addr(cpu_addr), .a_wel(cpu_wel), .a_weh(cpu_weh), .a_wdata(cpu_wdata), .a_rdata(cpu_rdata),
		.b_addr(ci), .b_re(1'b1), .b_rdata(live_q)
	);

	// the copy: port A the copier writes, port B the sprite engine reads
	dpram #(.ADDR_WIDTH(15), .DATA_WIDTH(16)) u_copy (
		.clk(clk),
		.a_addr(cp_addr), .a_wel(cp_we), .a_weh(cp_we), .a_wdata(live_q), .a_rdata(),
		.b_addr(obj_addr), .b_re(1'b1), .b_rdata(obj_data)
	);

	// read address ci leads the write by one cycle (the RAM's read latency)
	always_ff @(posedge clk) begin
		if (reset) begin
			copying   <= 1'b0;
			copy_done <= 1'b0;
			cp_we     <= 1'b0;
			ci        <= 15'd0;
		end else begin
			copy_done <= 1'b0;
			cp_we     <= copying;
			cp_addr   <= ci;
			if (frame_start) begin
				copying <= 1'b1;
				ci      <= 15'd0;
			end else if (copying) begin
				ci <= ci + 15'd1;
				if (ci == 15'h7FFF) begin
					copying   <= 1'b0;
					copy_done <= 1'b1;
				end
			end
		end
	end

endmodule
