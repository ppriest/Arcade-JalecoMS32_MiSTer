project_open v70_probe -revision v70_probe
create_timing_netlist
set_operating_conditions 7_slow_1100mv_100c
read_sdc
update_timing_netlist
report_timing -setup -npaths 12 -detail summary -file worst_summary.rpt
report_timing -setup -npaths 1 -detail full_path -file worst_full.rpt
project_close
