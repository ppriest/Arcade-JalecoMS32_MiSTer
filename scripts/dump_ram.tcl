# Dump a video RAM region off a running board through the "D" source/probe
# window (MS32.sv, DEBUG_ISSP). Driven by scripts/dump_ram.py, which holds the
# machine-wide JTAG marker.
#
#   quartus_stp -t scripts/dump_ram.tcl <region> <count> <outfile>
#   quartus_stp -t scripts/dump_ram.tcl trigger
#
# region: 0 road map, 1 road line RAM, 2 road_ctrl, 3 priority RAM,
#         4 ROZ map, 5 ROZ line RAM, 6 TX map, 7 palette
# trigger: pulse source bit 21, which has the core ask the HPS to upload the
#         NVRAM slot and all eight regions to the .mra's .nvm file (MS32.sv)
set region [lindex $argv 0]
set count  [lindex $argv 1]
set out    [lindex $argv 2]

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSE*" $d] || $dev eq ""} { set dev $d }
}
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
set ii -1
foreach inst $insts { if {[lindex $inst 3] eq "D"} { set ii [lindex $inst 0] } }
if {$ii < 0} {
    puts "NO 'D' INSTANCE -- the board is running a build without the RAM window."
    puts "instances: $insts"
    exit 1
}
catch {end_insystem_source_probe}
start_insystem_source_probe -hardware_name $hw -device_name $dev

# write_source_data takes a binary string, MSB first, source-width long
proc bits {n} {
    set s ""
    for {set i 21} {$i >= 0} {incr i -1} { append s [expr {($n >> $i) & 1}] }
    return $s
}

if {$region eq "trigger"} {
    write_source_data -instance_index $ii -value [bits [expr {1 << 21}]]
    after 100
    write_source_data -instance_index $ii -value [bits 0]
    end_insystem_source_probe
    puts "dump requested"
    exit 0
}

set fh [open $out w]
for {set a 0} {$a < $count} {incr a} {
    # {dump, enable, region[3:0], address[15:0]}
    set src [expr {(1 << 20) | ($region << 16) | $a}]
    write_source_data -instance_index $ii -value [bits $src]
    set v [read_probe_data -instance_index $ii]
    # binary string, MSB first
    set n 0
    foreach c [split $v ""] { set n [expr {$n * 2 + ($c eq "1" ? 1 : 0)}] }
    puts $fh [format "%04x" $n]
}
close $fh
write_source_data -instance_index $ii -value [bits 0]
end_insystem_source_probe
puts "wrote $count words of region $region to $out"
