# Read the debug probes over JTAG (In-System Sources and Probes).
#
#   quartus_stp -t scripts/read_issp.tcl [clear]
#
# RUN THROUGH scripts/read_issp.py, which holds the machine-wide JTAG marker
# (scripts/hwlock.py): a JTAG session concurrent with Quartus or ModelSim has
# bugchecked this PC. Layout from rtl/debug/issp_probe.sv (LSB first).

proc bits_to_int {s lo hi} {
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}
puts "device:   $dev"
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
puts "instances: $insts"
catch {end_insystem_source_probe}
if {[catch {start_insystem_source_probe -hardware_name $hw -device_name $dev} e]} {
    puts "start failed: $e"; exit 1
}
if {[lindex $argv 0] eq "clear"} {
    foreach inst $insts {
        set ii [lindex $inst 0]
        write_source_data -instance_index $ii -value 1 -value_in_hex
        after 20
        write_source_data -instance_index $ii -value 0 -value_in_hex
    }
    puts "counters cleared"
}
foreach inst $insts {
    set ii [lindex $inst 0]
    set iid [lindex $inst 3]
    set p [read_probe_data -instance_index $ii]
    puts ""
    puts "---- instance $ii ($iid) ----"
    if {$iid eq "M"} {
        puts [format "download bytes accepted   : %d" [bits_to_int $p 0 15]]
        puts [format "download writes issued    : %d" [bits_to_int $p 16 31]]
        puts [format "download writes completed : %d" [bits_to_int $p 32 47]]
        puts [format "ROM granule reads done    : %d" [bits_to_int $p 48 63]]
        puts [format "ioctl_wait seen high      : %d" [bits_to_int $p 64 64]]
        puts [format "ioctl_download seen       : %d" [bits_to_int $p 65 65]]
        puts [format "pll_locked now            : %d" [bits_to_int $p 66 66]]
        puts [format "ioctl_wait now            : %d" [bits_to_int $p 67 67]]
        puts [format "ROZ cache fills           : %d" [bits_to_int $p 68 83]]
        puts [format "ROZ cache hits            : %d" [bits_to_int $p 84 99]]
        puts [format "last download addr (low)  : %04X" [bits_to_int $p 100 115]]
        puts [format "ROZ non-zero pens written : %d" [bits_to_int $p 116 131]]
    } else {
        puts "raw: $p"
    }
}
end_insystem_source_probe
