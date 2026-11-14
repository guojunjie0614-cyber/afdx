# ModelSim batch entry for the synthesizable VLID application stream top.
# Run from the repository root: do sim/run_app.do [stimulus] [vl_config] [run_name]
# The judge edits stimulus.txt; tb/lib/afdx_sys_config.v owns configuration.
# Original VLID bytes are injected without conversion to a transmit index.
onerror {resume}
onbreak {}

namespace eval app_entry {
    variable cfg
    variable msgs
    variable folder ""
    variable root ""
}

proc app_entry::fail {message} {error "APP ENTRY FAIL: $message"}

proc app_entry::read_text {path} {
    if {![file isfile $path]} {fail "missing input file $path"}
    set f [open $path r]
    fconfigure $f -encoding ascii
    set text [read $f]
    close $f
    return $text
}

proc app_entry::strip {line} {
    set hash [string first "#" $line]
    if {$hash >= 0} {set line [string range $line 0 [expr {$hash-1}]]}
    return [string trim $line]
}

# vl_config.txt: one "<VLID hex> <BAG us> <Lmax bytes> <sport> <dport>" line per transmit VL.
proc app_entry::read_config {path} {
    variable cfg
    set cfg [dict create order {} item {} index {}]
    set position 0
    foreach raw [split [read_text $path] "\n"] {
        set line [strip $raw]
        if {$line eq ""} {continue}
        if {![regexp {^([0-9A-Fa-fx]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)$} \
                $line -> vl_hex bag lmax sport dport]} {
            fail "vl_config line: '$line'"
        }
        if {[scan $vl_hex %x vlid] != 1} {fail "vl_config bad VLID '$vl_hex'"}
        set vlid [expr {$vlid & 0xFFFF}]
        if {$bag < 1 || $bag > 1000000} {fail "vl_config BAG outside 1..1000000 us for VLID [format %04X $vlid]"}
        if {$lmax < 1 || $lmax > 1471} {fail "vl_config Lmax outside 1..1471 for VLID [format %04X $vlid]"}
        if {$sport > 65535 || $dport > 65535} {fail "vl_config port outside 0..65535"}
        if {[dict exists $cfg index $vlid]} {fail "vl_config duplicate VLID [format %04X $vlid]"}
        if {$position >= 128} {fail "vl_config has more than 128 transmit VLs"}
        dict lappend cfg order $vlid
        dict set cfg index $vlid $position
        dict set cfg item $position [list $vlid $bag $lmax $sport $dport]
        incr position
    }
    if {$position == 0} {fail "vl_config has no VL"}
    return $cfg
}

# stimulus.txt: one "<time us> <VLID hex> <payload hex>" line per message.
proc app_entry::read_stimulus {path cfg} {
    set msgs {}
    set number 0
    foreach raw [split [read_text $path] "\n"] {
        set line [strip $raw]
        if {$line eq ""} {continue}
        incr number
        if {![regexp {^([0-9]+(?:\.[0-9]+)?)\s+([0-9A-Fa-f]{1,4})\s+([0-9A-Fa-f]+)$} \
                $line -> time_us vl_hex payload]} {
            fail "stimulus line $number: '$line'"
        }
        if {[string length $payload] % 2} {fail "stimulus line $number: odd number of hex digits"}
        set length [expr {[string length $payload]/2}]
        if {$length < 1 || $length > 8192} {fail "stimulus line $number: payload $length bytes outside 1..8192"}
        if {[scan $vl_hex %x vlid] != 1} {fail "stimulus line $number: bad VLID '$vl_hex'"}
        set vlid [expr {$vlid & 0xFFFF}]
        if {![dict exists $cfg index $vlid]} {
            fail "stimulus line $number: VLID [format %04X $vlid] is not in the VL config"
        }
        set due [expr {int(round($time_us*125.0))}]
        lappend msgs [list $due [dict get $cfg index $vlid] $length [string tolower $payload] $vlid]
    }
    if {![llength $msgs]} {fail "stimulus is empty"}
    return $msgs
}

proc app_entry::write_vectors {folder msgs cfg stimulus} {
    variable root
    file mkdir [file join $folder vectors]
    foreach sub {es1_tx es1_rx es2_tx es2_rx es1_gmii_tx es1_gmii_rx es2_gmii_tx es2_gmii_rx} {
        file mkdir [file join $folder $sub]
    }
    set payload [open [file join $folder vectors sys_payload.hex] w]
    set schedule [open [file join $folder vectors app_schedule.txt] w]
    set count [open [file join $folder vectors sys_payload.count] w]
    fconfigure $payload -translation crlf -encoding ascii
    fconfigure $schedule -translation crlf -encoding ascii
    fconfigure $count -translation crlf -encoding ascii
    set offset 0
    puts $schedule [llength $msgs]
    foreach message $msgs {
        lassign $message due index length hex vlid
        puts $payload [join [regexp -all -inline {..} $hex] "\n"]
        puts $schedule [format "%d %d %d %d" $due $vlid $length $offset]
        incr offset $length
    }
    puts $count $offset
    close $payload
    close $schedule
    close $count
    # Optional window file: <stimulus root>.window, or window.txt for the default stimulus.
    # Two times in us; without it throughput is reported but not judged.
    set window_path [file rootname $stimulus].window
    if {![file isfile $window_path] && $stimulus eq [file join $root sim vectors app stimulus.txt]} {
        set window_path [file join $root sim vectors app window.txt]
    }
    set begin 0; set end 0
    if {[file isfile $window_path]} {
        set text [string trim [read_text $window_path]]
        if {![regexp {^(\S+)\s+(\S+)$} $text -> begin end]} {
            fail "window.txt must contain two times in us"
        }
        if {![string is double -strict $begin] || ![string is double -strict $end] || $end <= $begin} {
            fail "window.txt must contain two increasing times in us"
        }
        set begin [expr {int(round($begin*125.0))}]
        set end [expr {int(round($end*125.0))}]
    }
    set window [open [file join $folder vectors app_window.txt] w]
    fconfigure $window -translation crlf -encoding ascii
    puts $window "$begin $end"
    close $window
    return [list $begin $end]
}

proc app_entry::tool_dir {} {
    if {[info exists ::env(MODEL_TECH)] && [file isfile [file join $::env(MODEL_TECH) vlog.exe]]} {
        return $::env(MODEL_TECH)
    }
    return [file dirname [info nameofexecutable]]
}

# Compile and simulate with the external batch tools; -batch avoids the local
# vsim/vish RPC transport, which is broken on some hosts (WinError 10013).
proc app_entry::compile {folder} {
    variable root
    cd $folder
    file delete -force work
    catch {vlib work}
    if {[info exists ::env(MODELSIM)]} {unset ::env(MODELSIM)}
    source [file join $root sim modelsim_compat.tcl]
    set sources [concat [afdx_modelsim_rtl $root $folder] \
        [lsort [glob [file join $root tb lib *.v]]] [list [file join $root tb tb_app_entry.v]]]
    if {![file isfile [file join $root tb lib afdx_sys_config.v]]} {
        fail "missing non-top system configuration module"
    }
    set ce_div 2
    if {[info exists ::env(AFDX_CE_DIV)]} {set ce_div $::env(AFDX_CE_DIV)}
    if {$ce_div ni {1 2}} {fail "AFDX_CE_DIV must be 1 or 2"}
    set log [file join $folder compile.log]
    set command [list [file join [tool_dir] vlog.exe] -vlog01compat +define+AFDX_CE_DIV=$ce_div \
        +incdir+[file join $root tb lib]]
    set failed [catch {exec {*}$command {*}$sources > $log 2>@1} message]
    puts "APP CE_DIV=$ce_div"
    set report [read_text $log]
    if {[regexp {(\*\* (Error|Fatal)|.*\mFAIL\M)} $report]} {fail "compile reported an error; see $log"}
    if {$failed} {fail "compile failed: $message; see $log"}
    set warnings [regexp -all -line {^[ \t]*(#[ \t]*)?\*\* Warning([ \t]+\([^)]*\))?:} $report]
    puts "APP COMPILE PASS warnings=$warnings"
    return 1
}

proc app_entry::simulate {folder} {
    variable root
    cd $folder
    set log [file join $folder simulation.log]
    set command [list [file join [tool_dir] vsim.exe] -batch -quiet -t 1ps -onfinish stop \
        -wlf simulation.wlf tb_app_entry -do "run -all; quit -f"]
    set failed [catch {exec {*}$command > $log 2>@1} message]
    set report [read_text $log]
    if {[string first "RAMCOLL" $report] >= 0 || [regexp {(\*\* (Error|Fatal)|.*\mFAIL\M)} $report]} {
        fail "simulation reported RAMCOLL, Error, Fatal or FAIL; see $log"
    }
    if {$failed} {fail "simulation failed: $message; see $log"}
    if {![regexp {\[RESULT\] tb_app_entry PASS checks=([0-9]+) errors=0} $report -> checks]} {
        fail "testbench did not pass; see $log"
    }
    set warnings [regexp -all -line {^[ \t]*(#[\t ]*)?\*\* Warning([ \t]+\([^)]*\))?:} $report]
    return [list $checks $warnings]
}

# Delivery rows are matched per receive index; each accepted message must arrive once.
proc app_entry::read_deliveries {folder msgs cfg} {
    set expected [dict create]
    foreach message $msgs {
        lassign $message due index length hex vlid
        dict lappend expected $index [list $length $hex]
    }
    set received [dict create]
    set order {}
    set duplicate 0
    set rm_drop 0
    set good 0
    set path [file join $folder es2_rx events.txt]
    foreach line [split [read_text $path] "\n"] {
        if {[regexp {^D (\d+) ([AB]) (\d+) [0-9a-f]+ [0-9a-f]+ (\d+) ([0-9a-f]+)(?: \d+ \d+)?$} \
                $line -> start net index length payload]} {
            set position 0
            if {[dict exists $received $index]} {set position [dict get $received $index]}
            if {![dict exists $expected $index] || $position >= [llength [dict get $expected $index]]} {
                fail "unexpected delivery for receive index $index"
            }
            lassign [lindex [dict get $expected $index] $position] want_length want_hex
            if {$length != $want_length || $payload ne $want_hex} {
                fail "delivery $position of index $index does not match the stimulus"
            }
            dict set received $index [expr {$position+1}]
            lappend order [list $start [expr {$start+$length-1}] $index $payload]
        } elseif {[regexp {^E \d+ rm_drop$} $line]} {
            incr rm_drop
        } elseif {[regexp {^E \d+ [ab]_good$} $line]} {
            incr good
        }
    }
    set total 0
    dict for {index items} $expected {
        set got 0
        if {[dict exists $received $index]} {set got [dict get $received $index]}
        if {$got != [llength $items]} {fail "receive index $index delivered $got of [llength $items] messages"}
        incr total [llength $items]
    }
    if {[llength $order] != $total} {fail "delivered [llength $order] messages for $total stimulus lines"}
    if {$rm_drop != $total} {fail "redundancy rejection count $rm_drop is not $total"}
    if {$good != 2*$total} {fail "good frame count $good is not [expr {2*$total}] (A and B copies)"}
    if {$duplicate != 0} {fail "duplicate delivery detected"}
    return [list $order $total $rm_drop $good]
}

proc app_entry::analyse {folder msgs cfg window} {
    variable root
    lassign [read_deliveries $folder $msgs $cfg] order total rm_drop good
    set rx [open [file join $folder rx.txt] r]
    set raw_rows [split [string trim [read $rx]] "\n"]
    if {[llength $raw_rows]!=$total} {fail "raw rx.txt message count"}
    set raw_expected [dict create]
    foreach message $msgs {
        lassign $message due index length hex vlid
        dict lappend raw_expected $vlid $hex
    }
    set cursor [dict create]
    foreach line $raw_rows {
        lassign $line first last id payload
        scan $id %x id
        set n 0;if {[dict exists $cursor $id]} {set n [dict get $cursor $id]}
        if {![dict exists $raw_expected $id] || $payload ne [lindex [dict get $raw_expected $id] $n]} {fail "raw VLID/payload mismatch"}
        dict set cursor $id [expr {$n+1}]
    }
    close $rx
    source [file join $root sim r97_measure.tcl]
    set results [r97::measure $folder app]
    set p app/es1_to_es2/accepted/all
    set inject [dict get $results $p/inject/mbps]
    set e2e [dict get $results $p/L_entry_last/max]
    set first [dict get $results $p/L_entry_first/max]
    set jitter [dict get $results $p/jitter_r119/jitter]
    set jvl [dict get $results $p/jitter_r119/vl]
    set jlen [dict get $results $p/jitter_r119/len]
    set stalls [dict get $results $p/inject/stall_cycles]
    set stallmax [dict get $results $p/inject/stall_maxrun]
    set lag [dict get $results $p/inject/lag_max]
    set dropped [dict get $results $p/integrity/dropped]
    set duplicate [dict get $results $p/integrity/duplicate]
    set overflow [dict get $results $p/integrity/overflow]
    set epoch 0
    foreach line [split [read_text [file join $folder sys_events.txt]] "\n"] {
        if {[regexp {^G \d+ STIMULUS_EPOCH (\d+)$} $line -> offset]} {set epoch $offset}
    }
    set begin [expr {[lindex $window 0]+$epoch}]; set end [expr {[lindex $window 1]+$epoch}]
    set has_window [expr {$end > $begin}]
    set meets [expr {$has_window && $inject >= 100.0 && $e2e <= 250000 && $jitter <= 6250 &&
        $dropped == 0 && $overflow == 0 && $duplicate == 0 && ($lag eq "NA" || $lag <= 1471)}]
    set judgement [expr {$has_window ? ($meets ? "PASS" : "FAIL") : "REPORT"}]
    set summary [open [file join $folder summary.txt] w]
    fconfigure $summary -translation crlf -encoding ascii
    puts $summary [format "APP SUMMARY run=%s messages=%d vls=%d window_begin=%d window_end=%d" \
        [file tail $folder] $total [llength [dict get $cfg order]] $begin $end]
    puts $summary [format "APP METRIC inject_mbps=%.3f max_e2e_us=%.3f max_e2e_first_us=%.3f jitter_r119_us=%.3f jitter_vl=%s jitter_len=%s stall_cycles=%d stall_maxrun=%d lag_max_cycles=%s dropped=%d duplicate=%d overflow=%d delivered=%d redundancy_rejections=%d good_frames=%d" \
        $inject [expr {$e2e*0.008}] [expr {$first*0.008}] [expr {$jitter*0.008}] $jvl $jlen \
        $stalls $stallmax $lag $dropped $duplicate $overflow $total $rm_drop $good]
    puts $summary [format "APP REQUIREMENT %s min_mbps=100 max_e2e_us=2000 max_jitter_us=50" $judgement]
    puts $summary [format "APP CHECK PASS messages=%d delivered=%d payload=match redundancy=once" $total $total]
    close $summary
    if {[file size [file join $folder rx.txt]] == 0} {fail "rx.txt is empty"}
    if {!$meets && $has_window} {
        fail "summary requirement not met: inject=[format %.3f $inject] Mbps max_e2e=[format %.3f [expr {$e2e*0.008}]] us jitter=[format %.3f [expr {$jitter*0.008}]] us"
    }
    return [format "APP ENTRY PASS run=%s messages=%d vls=%d inject_mbps=%.3f max_e2e_us=%.3f jitter_us=%.3f output=out/app/%s" \
        [file tail $folder] $total [llength [dict get $cfg order]] $inject [expr {$e2e*0.008}] \
        [expr {$jitter*0.008}] [file tail $folder]]
}

# Long-datagram path uses the public-port fragmentation harness. Legacy R97
# assumes one wire frame per message; its short-only path remains unchanged.
proc app_entry::run_fragmented {folder cfg msgs} {
    variable root
    set frag [file join $folder fragmentation]
    file mkdir $frag
    set py python
    if {[info exists ::env(AFDX_PYTHON)]} {set py $::env(AFDX_PYTHON)}
    set helper [file join $root tools fragment_integration.py]
    set failed [catch {exec $py $helper app-prepare $frag \
        [file join $folder vectors vl_config.txt] [file join $folder vectors app_schedule.txt] \
        [file join $folder vectors sys_payload.hex] [file join $folder vectors app_window.txt]} message]
    if {$failed} {fail "fragment vector preparation: $message"}
    set payload_count [string trim [read_text [file join $folder vectors sys_payload.count]]]
    if {![string is integer -strict $payload_count] || $payload_count < 1} {
        fail "invalid fragment payload count '$payload_count'"
    }
    set payload_capacity [expr {max(65536, $payload_count)}]
    cd $frag
    catch {vlib work}
    if {[info exists ::env(MODELSIM)]} {unset ::env(MODELSIM)}
    source [file join $root sim modelsim_compat.tcl]
    set sources [concat [afdx_modelsim_rtl $root $frag] [list [file join $root tb tb_fragmentation.v]]]
    set ce_div 2
    if {[info exists ::env(AFDX_CE_DIV)]} {set ce_div $::env(AFDX_CE_DIV)}
    if {$ce_div ni {1 2}} {fail "AFDX_CE_DIV must be 1 or 2"}
    set log [file join $frag compile.log]
    set command [list [file join [tool_dir] vlog.exe] -vlog01compat +define+AFDX_CE_DIV=$ce_div]
    set failed [catch {exec {*}$command {*}$sources > $log 2>@1} message]
    if {$failed || [regexp {\*\* (Error|Fatal)} [read_text $log]]} {fail "fragment compile failed: $message; see $log"}
    set log [file join $frag simulation.log]
    set command [list [file join [tool_dir] vsim.exe] -batch -quiet -t 1ps -onfinish stop \
        -gPAYLOAD_CAPACITY=$payload_capacity tb_fragmentation -do "run -all; quit -f"]
    set failed [catch {exec {*}$command > $log 2>@1} message]
    set report [read_text $log]
    if {$failed || ![regexp {\[RESULT\] tb_fragmentation PASS errors=0} $report] || [regexp {\*\* (Error|Fatal)} $report]} {
        fail "fragment simulation failed: $message; see $log"
    }
    set failed [catch {exec $py $helper app-check $frag} message]
    if {$failed} {fail "fragment packet/application checks: $message"}
    file copy -force [file join $frag rx.txt] [file join $folder rx.txt]
    file copy -force [file join $frag summary.txt] [file join $folder summary.txt]
    puts $message
    return "APP ENTRY PASS run=[file tail $folder] messages=[llength $msgs] fragmented_metrics=report output=$folder"
}

proc app_entry::main {root parameters} {
    variable folder
    set app_entry::root $root
    set stimulus [file join $root sim vectors app stimulus.txt]
    set vl_config [file join $root sim vectors app vl_config.txt]
    set name ""
    if {[llength $parameters] >= 1 && [lindex $parameters 0] ne ""} {
        set stimulus [lindex $parameters 0]
        if {[file pathtype $stimulus] ne "absolute"} {set stimulus [file join $root $stimulus]}
    }
    if {[llength $parameters] >= 2 && [lindex $parameters 1] ne ""} {
        set vl_config [lindex $parameters 1]
        if {[file pathtype $vl_config] ne "absolute"} {set vl_config [file join $root $vl_config]}
    }
    if {[llength $parameters] >= 3} {set name [lindex $parameters 2]}
    set cfg [read_config $vl_config]
    set msgs [read_stimulus $stimulus $cfg]
    if {$name eq ""} {set name [clock format [clock seconds] -format %Y%m%d_%H%M%S]}
    set base [file join $root out app $name]
    set folder $base
    set suffix 0
    while {[file exists $folder]} {incr suffix; set folder ${base}_$suffix}
    file mkdir $folder
    set window [write_vectors $folder $msgs $cfg $stimulus]
    file copy -force $vl_config [file join $folder vectors vl_config.txt]
    set has_long 0
    foreach message $msgs {if {[lindex $message 2] > 1471} {set has_long 1}}
    if {$has_long} {
        set result [run_fragmented $folder $cfg $msgs]
    } else {
        compile $folder
        lassign [simulate $folder] checks warnings
        set result [analyse $folder $msgs $cfg $window]
        puts [format "APP ENTRY SUMMARY checks=%d warnings=%d" $checks $warnings]
    }
    puts $result
    return $result
}

set app_root [file normalize [pwd]]
set app_parameters {}
if {[info exists argc] && $argc > 0} {
    for {set app_index 1} {$app_index <= $argc} {incr app_index} {
        lappend app_parameters [set $app_index]
    }
}
set app_failed [catch {app_entry::main $app_root $app_parameters} app_message]
if {$app_failed} {
    puts "APP ENTRY FAIL: $app_message"
}
if {[batch_mode]} {quit -f -code $app_failed}
