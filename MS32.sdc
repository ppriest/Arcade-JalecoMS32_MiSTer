derive_pll_clocks
derive_clock_uncertainty

# clk_cpu (general[1], 20 MHz, the V70's domain) and clk_sys (general[0],
# 96 MHz) share the VCO but no usable edge relationship: every signal that
# crosses goes through rtl/cpu/ms32_cdc.sv, so the two are asynchronous.
set clk_sys_pll [get_clocks {*pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_cpu_pll [get_clocks {*pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_clock_groups -asynchronous -group $clk_cpu_pll -group $clk_sys_pll

# SDRAM: the MT48LC16M16 on the daughterboard, clocked by the PLL's third
# output (clk_sys shifted 180 degrees). Constraints carried over from the
# Seta core, which took them from Psikyo, where they were proven on hardware.
set sdram_tAC   6.0    ;# memory CLK -> data valid, max
set sdram_tOH   2.7    ;# memory CLK -> data hold, min
set sdram_tDS   1.5    ;# memory input setup
set sdram_tDH   0.8    ;# memory input hold
set sdram_board 0.5    ;# trace + pin, max, each direction
set sdram_board_min 0.1
create_generated_clock -name sdram_clk_pin -source [get_pins -compatibility_mode {*pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] [get_ports {SDRAM_CLK}]
set_input_delay -clock sdram_clk_pin -max [expr {$sdram_tAC + $sdram_board}]     [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock sdram_clk_pin -min [expr {$sdram_tOH + $sdram_board_min}] [get_ports {SDRAM_DQ[*]}]
set sdram_dq_regs [get_registers {*sdram:u_sdram|dq_in[*]}]
set_multicycle_path -setup 2 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set_multicycle_path -hold  1 -from [get_clocks {sdram_clk_pin}] -to $sdram_dq_regs
set sdram_outs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_nCS SDRAM_CKE}]
set_output_delay -clock sdram_clk_pin -max [expr {$sdram_tDS + $sdram_board}]      $sdram_outs
set_output_delay -clock sdram_clk_pin -min [expr {-$sdram_tDH + $sdram_board_min}] $sdram_outs

# T80 (the sound Z80) internal paths: multicycle 4, as the Psikyo and Fuuki
# cores constrain the same core. Audit here: no falling_edge in rtl/cpu/t80/;
# T80se.vhd, T80.vhd and T80_Reg.vhd update under CEN/ClkEn except T80.vhd's
# NMI edge detector (OldNMI_n -> NMI_s, one gate of logic, every clock) and
# the DIRSet branch, which T80se ties off. ms32_sound's clock enable comes at
# least 6 clocks apart (12, or 6 when repaying a wait), so a CEN-gated
# register's output is stable for 6. Only T80 -> T80: the glue in ms32_sound
# samples the bus pins every clock and keeps full-clock timing.
set t80 [get_registers {*|ms32_sound:u_sound|T80se:u_cpu|*}]
if {[get_collection_size $t80] > 0} {
    set_multicycle_path -setup -end 4 -from $t80 -to $t80
    set_multicycle_path -hold  -end 3 -from $t80 -to $t80
} else {
    post_message -type critical_warning "MS32.sdc: no T80se registers matched -- sound CPU multicycle NOT applied"
}
