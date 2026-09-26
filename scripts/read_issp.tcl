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
# "poll <n>" samples instance V <n> times in this one JTAG session and prints a
# compact line each time. Starting quartus_stp costs about fifteen seconds, so a
# time series is only affordable from inside a single session -- which is what it
# takes to catch a moment in an attract loop.
set npoll 0
set pi [lsearch -exact $argv poll]
if {$pi >= 0} { set npoll [lindex $argv [expr {$pi + 1}]] }
if {$npoll > 0} {
    set fi -1
    foreach inst $insts { if {[lindex $inst 3] eq "F"} { set fi [lindex $inst 0] } }
    foreach inst $insts {
        set ii [lindex $inst 0]
        if {[lindex $inst 3] ne "V"} { continue }
        set p [read_probe_data -instance_index $ii]
        if {[string length $p] != 441} {
            puts "WIDTH MISMATCH: instance V is [string length $p] bits, this tree'srtl/debug expects 441. Refusing to poll -- the board is running a different build."
            end_insystem_source_probe
            exit 1
        }
        puts "sample frames roadlines roadpens sprdrawn | fpu0: starts irqs reads writes | fpu1: starts irqs reads writes | pass: lines min-max writes | flagwr fields | fpu0 writes while busy"
        for {set k 0} {$k < $npoll} {incr k} {
            set p [read_probe_data -instance_index $ii]
            # not through expr: it would read the bit string as a number
            if {$fi >= 0} { set f [read_probe_data -instance_index $fi] } else { set f [string repeat 0 256] }
            puts [format "%d %d %d %d %d | %d %d %d %d | %d %d %d %d | %d-%d %d | %d %d | %d" $k                 [bits_to_int $p 103 118] [bits_to_int $p 284 299] [bits_to_int $p 300 315]                 [bits_to_int $p 342 354]                 [bits_to_int $f 96 111] [bits_to_int $f 64 79] [bits_to_int $f 0 15] [bits_to_int $f 16 31]                 [bits_to_int $f 112 127] [bits_to_int $f 80 95] [bits_to_int $f 32 47] [bits_to_int $f 48 63]                 [bits_to_int $f 128 135] [bits_to_int $f 136 143] [bits_to_int $f 144 159] [bits_to_int $f 160 175] [bits_to_int $f 176 191] [bits_to_int $f 192 207]]
            after 700
        }
    }
    end_insystem_source_probe
    exit 0
}

foreach inst $insts {
    set ii [lindex $inst 0]
    set iid [lindex $inst 3]
    set p [read_probe_data -instance_index $ii]
    puts ""
    puts "---- instance $ii ($iid) ----"
    # "raw" prints the bit string as well as the decode: the field offsets below
    # belong to the RTL in this working tree, so a board running an older
    # bitstream has to be decoded by hand against that build's own header.
    if {[lsearch -exact $argv raw] >= 0} { puts "raw ([string length $p] bits): $p" }
    # The field offsets below belong to the RTL in this working tree. A board
    # running an older bitstream decodes into plausible nonsense unless the
    # width is checked -- that has already happened once here.
    set want 0
    if {$iid eq "M"} { set want 132 } elseif {$iid eq "V"} { set want 441 } elseif {$iid eq "F"} { set want 256 }
    if {$want && [string length $p] != $want} {
        puts "WIDTH MISMATCH: instance $iid is [string length $p] bits, this tree'srtl/debug expects $want. The board is running a different build; the numbersbelow would be nonsense, so they are not printed. Deploy this tree's bitstream,or read it with \"raw\" and decode against that build's own header."
        continue
    }
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
    } elseif {$iid eq "V"} {
        set fl [bits_to_int $p 0 6]
        set names {TX BG ROZ sprites fb-read priority-mask rotation}
        set on {}
        for {set b 0} {$b < 7} {incr b} { if {($fl >> $b) & 1} { lappend on [lindex $names $b] } }
        puts [format "overrun flags set         : %s" [expr {[llength $on] ? [join $on {, }] : "none"}]]
        puts [format "sprite frames overrun     : %d" [bits_to_int $p 7 22]]
        puts [format "frame-buffer lines late   : %d" [bits_to_int $p 23 38]]
        puts [format "ROZ lines late            : %d" [bits_to_int $p 39 54]]
        set ms [bits_to_int $p 55 78]
        puts [format "longest sprite frame      : %d clocks (%.0f%% of a frame)" $ms [expr {100.0 * $ms / (6144 * 263)}]]
        set mc [bits_to_int $p 79 102]
        puts [format "latest copy finish        : %d clocks after vblank (%d lines)" $mc [expr {$mc / 6144}]]
        puts [format "frames                    : %d" [bits_to_int $p 103 118]]
        puts [format "frame of last late ROZ    : %d" [bits_to_int $p 119 134]]
        puts [format "YMF271 passes overrun     : %d" [bits_to_int $p 135 150]]
        puts [format "YMF271 fetch wait, max    : %d clocks" [bits_to_int $p 151 166]]
        puts [format "V70 ifetch wait, max      : %d clocks" [bits_to_int $p 167 182]]
        puts [format "road writes past the RAMs : %d" [bits_to_int $p 183 198]]
        puts [format "road plane overrun        : %s" [expr {[string index $p [expr {[string length $p] - 1 - 199}]] eq "1" ? "yes" : "no"}]]
        puts [format "road lines late           : %d" [bits_to_int $p 200 215]]
        puts [format "longest FPU routine       : %d clocks (%.1f%% of a frame)" [bits_to_int $p 216 235] [expr {100.0 * [bits_to_int $p 216 235] / 333333}]]
        puts [format "FPU routines started      : %d" [bits_to_int $p 236 251]]
        puts [format "road map writes           : %d" [bits_to_int $p 252 267]]
        puts [format "road line RAM writes      : %d" [bits_to_int $p 268 283]]
        puts [format "road lines drawn, last fr : %d" [bits_to_int $p 284 299]]
        puts [format "road pens non-zero, last  : %d" [bits_to_int $p 300 315]]
        puts [format "sprites drawn / fx / fy   : %d / %d / %d" [bits_to_int $p 342 354] [bits_to_int $p 316 328] [bits_to_int $p 329 341]]
        puts [format "first flipy sprite        : attr %04X at slot %d" [bits_to_int $p 355 370] [bits_to_int $p 371 382]]
        puts [format "road row / vram\[2 row\]    : %d / %04X" [bits_to_int $p 383 392] [bits_to_int $p 393 408]]
        puts [format "road starty / offsy       : %04X / %04X" [bits_to_int $p 409 424] [bits_to_int $p 425 440]]
    } elseif {$iid eq "F"} {
        puts [format "FPU0 starts/irqs/rd/wr    : %d / %d / %d / %d" [bits_to_int $p 96 111] [bits_to_int $p 64 79] [bits_to_int $p 0 15] [bits_to_int $p 16 31]]
        puts [format "FPU1 starts/irqs/rd/wr    : %d / %d / %d / %d" [bits_to_int $p 112 127] [bits_to_int $p 80 95] [bits_to_int $p 32 47] [bits_to_int $p 48 63]]
        puts [format "last pass road lines      : %d-%d, %d writes" [bits_to_int $p 128 135] [bits_to_int $p 136 143] [bits_to_int $p 144 159]]
        puts [format "FEE10000 writes / fields  : %d / %d" [bits_to_int $p 160 175] [bits_to_int $p 176 191]]
        puts [format "FPU0 writes while busy    : %d" [bits_to_int $p 192 207]]
        puts [format "FPU0 chains started       : %d" [bits_to_int $p 208 223]]
        puts [format "FPU0 writes before chain 0: %d, hash %04x" [bits_to_int $p 240 255] [bits_to_int $p 224 239]]
    } else {
        puts "raw: $p"
    }
}
end_insystem_source_probe
