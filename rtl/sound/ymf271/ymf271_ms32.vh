// SPDX-License-Identifier: GPL-3.0-or-later
//
// What ymf271_synth.sv takes from SeibuSPI's spi_defs.vh, for MS32: the
// sample region's base in the address the engine emits. 0, because
// ms32_sdram_top adds BASE_YMF when it routes the fetch.
localparam [25:0] SDR_PCM_BASE = 26'h000_0000;
