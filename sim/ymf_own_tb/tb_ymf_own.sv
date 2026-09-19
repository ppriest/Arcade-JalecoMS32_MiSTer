// SPDX-License-Identifier: GPL-3.0-or-later
//
//  sim/ymf_tb with the YMF271 on its own 56.47 MHz clock (960 MHz / 17),
//  enabled every clock -- the clocking proposed for P-47 Aces' overruns.
//  Plusargs as sim/ymf_tb; +LAT counts the chip's clocks.
//
//      python scripts/run_verilator.py ymf_own_tb +GAME=p47aces +MS=24000 +LAT=54 +OUT=simout/ymf-own
`timescale 1ns/1ps
module tb_ymf_own;
	tb_ymf #(.OWN(1'b1)) u_tb ();
endmodule
