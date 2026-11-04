# Current RTL waveform experiments. Run with: do sim/wave/current_report.do <scenario>
# Windows are derived from this run's real events; all scenarios run to HDL PASS.
set scenario $1
set tests [dict create tx_dual tb_sys_net rx_redundancy tb_sys_delay rx_fcs_error tb_sys_net snmp_get tb_judge_snmp tx_bag tb_tx_bag]
if {![dict exists $tests $scenario]} {error "Unknown waveform scenario: $scenario"}
source [file join [pwd] sim wave common.do]
wave_setup $scenario [dict get $tests $scenario]

proc wave_rows {name} {
    global wave_output
    set f [open [file join $wave_output $name] r]
    set rows [split [string trim [read $f]] "\n"];close $f
    return $rows
}
proc wave_ns {cycle} {expr {$cycle*8-4}}
proc wave_event {rows kind value {after -1}} {
    foreach row $rows {
        if {[lindex $row 0] eq $kind && [lindex $row 2] eq $value && [lindex $row 1]>=$after} {return [lindex $row 1]}
    }
    error "Required current waveform event absent: $kind $value after $after"
}
proc wave_range {name center before after} {
    wave_snapshot $name [format %.3fns [expr {max(0,$center-$before)}]] [format %.3fns [expr {$center+$after}]]
}
proc wave_cursor {name time} {wave cursor add -time [format %.3fns $time] -name $name}

if {$scenario eq "tx_dual"} {
    set dut /tb_sys_net/suite/es1/dut
    foreach name {app_tx_valid app_tx_ready app_tx_data app_tx_last app_tx_vl tx_valid tx_data tx_valid_b tx_data_b} {wave_signal $dut/$name $name}
} elseif {$scenario eq "rx_redundancy"} {
    set dut /tb_sys_delay/suite/es2/dut
    foreach name {rx_valid rx_data rx_valid_b rx_data_b ev_deliver app_rx_valid app_rx_data app_rx_last app_rx_net ev_rm_drop} {wave_signal $dut/$name $name}
} elseif {$scenario eq "rx_fcs_error"} {
    set dut /tb_sys_net/suite/es2/dut
    set core $dut/wrapped/top/es
    foreach name {rx_valid rx_data rx_valid_b app_rx_valid ev_a cfg_rd cfg_addr cfg_rvalid cfg_rdata} {wave_signal $dut/$name $name}
    wave_signal $dut/app_rx_net app_rx_net binary
    wave_signal $core/cfg_regs/count_a_fcs count_a_fcs unsigned
    wave_signal $dut/clk clk binary
    wave_signal $core/host_read_pipe host_read_pipe binary
} elseif {$scenario eq "snmp_get"} {
    set dut /tb_judge_snmp/agent/dut
    foreach name {rx_valid rx_data rx_valid_b rx_data_b tx_valid tx_data tx_valid_b tx_data_b} {wave_signal $dut/$name $name}
    set requests $dut/wrapped/top/es/snmp/requests
    wave_signal $requests SNMP_requests unsigned
    set ::wave_rx_starts {};set ::wave_tx_starts {};set ::wave_request_ns -1
    when -label report_rx "$dut/rx_valid == 1" {lappend ::wave_rx_starts [wave_now_ns]}
    when -label report_tx "$dut/tx_valid == 1" {lappend ::wave_tx_starts [wave_now_ns]}
    when -label report_get "$requests == 1" {if {$::wave_request_ns<0} {set ::wave_request_ns [wave_now_ns]}}
} else {
    set dut /tb_tx_bag/suite/dut
    wave_signal /tb_tx_bag/suite/m_vl VL unsigned
    wave_signal $dut/engine/pend_bag BAG_ticks unsigned
    foreach name {tx_valid_a tx_data_a tx_valid_b tx_data_b} {wave_signal $dut/$name $name}
    wave_signal $dut/engine/grant_sn SN unsigned
}
run -all
transcript off
set fh [open [file join $wave_output simulation.log] r];set report [read $fh];close $fh
transcript on
set test [dict get $tests $scenario]
if {![regexp [format {\[RESULT\] %s PASS checks=([0-9]+) errors=0} $test] $report]} {error "Waveform HDL test did not pass: $test"}
if {[regexp {\*\* (Error|Fatal|Warning)|RAMCOLL|\[RESULT\].*FAIL} $report]} {error "Waveform run contains diagnostics"}

if {$scenario eq "tx_dual"} {
    set first [lindex [lindex [wave_rows es1_gmii_tx/dump_a.txt] 0] 1]
    set at [wave_ns $first]
    wave_cursor GMII_start $at
    wave_range tx_dual_1 $at 2300 800
    wave_range tx_dual_2 $at 8 320
} elseif {$scenario eq "rx_redundancy"} {
    set begin [wave_event [wave_rows sys_events.txt] P b_late]
    set rows [wave_rows es2_rx/events.txt]
    set a [wave_ns [wave_event $rows D A $begin]]
    set b [wave_ns [wave_event $rows E rm_drop $begin]]
    wave_cursor A_delivered $a;wave_cursor B_duplicate $b
    wave_range rx_redundancy_1 $a 50 260
    wave_range rx_redundancy_2 $b 220 40
} elseif {$scenario eq "rx_fcs_error"} {
    set at [wave_ns [wave_event [wave_rows es2_rx/events.txt] E a_fcs]]
    wave_cursor FCS_error $at
    wave_range rx_fcs_error_1 $at 1000 300
    wave_range rx_fcs_error_2 $at 220 100
    set response -1;set request -1
    foreach row [wave_rows sys_events.txt] {
        if {[lindex $row 0] ne "V" || [lindex $row 2]!=2} {continue}
        scan [lindex $row 3] %x address;scan [lindex $row 4] %x value
        if {$address==0x49 && $value==1} {set response [lindex $row 1];set request [lindex $row 5];break}
    }
    if {$request<0 || $response-$request!=2} {error "No actual public FCS-counter read at exactly t+2"}
    # Use the original test's real public read, which is independently checked.
    # No hierarchical force or fabricated read pulse is added for the picture.
    delete wave *
    foreach name {clk cfg_rd cfg_addr cfg_rvalid cfg_rdata} {wave_signal $dut/$name $name}
    wave_signal $core/host_read_pipe host_read_pipe binary
    wave_signal $core/cfg_regs/count_a_fcs count_a_fcs unsigned
    wave_cursor Read_request [wave_ns $request];wave_cursor Read_response [wave_ns $response]
    wave_snapshot rx_fcs_error_3 [format %.3fns [expr {[wave_ns $request]-8}]] [format %.3fns [expr {[wave_ns $response]+16}]]
} elseif {$scenario eq "snmp_get"} {
    set request -1;set response -1
    foreach at $::wave_rx_starts {if {$at<=$::wave_request_ns} {set request $at}}
    foreach at $::wave_tx_starts {if {$at>=$::wave_request_ns} {set response $at;break}}
    if {$request<0 || $response<0} {error "Get request/response transitions absent"}
    wave_cursor Get_request $request;wave_cursor Get_response $response
    wave_range snmp_get_1 $request 20 320
    wave_range snmp_get_2 $response 24 320
} else {
    set marks [wave_rows events.txt]
    set begin [wave_event $marks P exact]
    set stop 1000000000000
    foreach row $marks {if {[lindex $row 0] eq "P" && [lindex $row 1]>$begin} {set stop [lindex $row 1];break}}
    set starts {}
    foreach row [wave_rows dump_a.txt] {
        set c [lindex $row 1]
        if {$c>=$begin && $c<$stop} {lappend starts $c}
    }
    if {[llength $starts]<2 || [lindex $starts 1]-[lindex $starts 0]!=100000} {error "Exact BAG scenario does not show 100000-clock launch spacing"}
    set a [wave_ns [lindex $starts 0]];set b [wave_ns [lindex $starts 1]]
    wave_cursor Frame_1_start $a;wave_cursor Frame_2_start $b
    wave_snapshot tx_bag [format %.3fns [expr {$a-1000}]] [format %.3fns [expr {$b+2000}]]
    # The overview exposes exact BAG spacing; separate close-ups keep the
    # actual short Ethernet pulses and changing frame SN readable.
    wave_range tx_bag_first $a 24 640
    wave_range tx_bag_second $b 24 640
}
set fh [open [file join $wave_output current_wave_result.txt] w]
puts $fh "WAVE CURRENT PASS scenario=$scenario test=$test windows=windows.txt";close $fh
puts "WAVE CURRENT PASS scenario=$scenario output=$wave_output"
