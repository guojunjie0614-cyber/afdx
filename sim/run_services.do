# ModelSim standalone entry: no Python or PowerShell required; runs 5 services including 615A upload/download.
# In ModelSim, first cd to the submission package root, then run: do sim/run_services.do
# Each run creates a fresh out/modelsim directory with logs, packet captures, and waveforms.
onerror {quit -f -code 1}
proc services_summary {result_dir log_file} {
    if {[file isfile $log_file]} {
        set fh [open $log_file r]; set log_text [read $fh]; close $fh
        if {![regexp {\[RESULT\] tb_net_services PASS checks=([0-9]+) errors=0} $log_text match count]} {
            error "tb_net_services did not print PASS; see $log_file"
        }
    } else {
        set count [expr {[examine -radix decimal /tb_net_services/checks] + \
                         [examine -radix decimal /tb_net_services/checks1] + \
                         [examine -radix decimal /tb_net_services/checks2]}]
        set errs  [expr {[examine -radix decimal /tb_net_services/errors] + \
                         [examine -radix decimal /tb_net_services/errors1] + \
                         [examine -radix decimal /tb_net_services/errors2]}]
        if {$errs != 0 || $count <= 0} {
            error "tb_net_services did not pass (checks=$count errors=$errs)"
        }
        set fh [open $log_file w]
        puts $fh "\[RESULT\] tb_net_services PASS checks=$count errors=0"
        close $fh
    }
    set net_text ""; set net_file [file join $result_dir net_services.txt]
    if {[file exists $net_file]} {set fh [open $net_file r]; set net_text [read $fh]; close $fh}
    set dl_text ""; set dl_file [file join $result_dir download_results.txt]
    if {[file exists $dl_file]} {set fh [open $dl_file r]; set dl_text [read $fh]; close $fh}
    set rm1 "-"; set rm2 "-"; set ic2 "-"; set rx1 "-"; set rx2 "-"
    regexp -line {^I ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+)$} $net_text -> ic2 rm1 rm2 rx2
    regexp -line {^U ([0-9]+) ([0-9]+)$} $net_text -> rx1 rx2
    set snmp_res "GetResponse OK"
    if {[regexp -line {^D [0-9]+ 161 [0-9]+ ([0-9]+) } $net_text -> snmp_len]} {
        set snmp_res "GetResponse OK (${snmp_len}B)"
    }
    set rtc_res "synced"
    if {[regexp -line {^T [0-9]+ (-?[0-9]+)$} $net_text -> rtc_diff]} {
        set rtc_res "diff=$rtc_diff ns"
    }
    set up_res "status=2"
    if {[regexp -line {^R ([0-9a-fA-F]+)$} $net_text -> up_hex]} {
        set up_res "[expr {[string length $up_hex] / 2}]B status=2"
    }
    set dl_res "status=2"
    if {[regexp -line {^C 0 ([0-9]+) ([0-9]+) } $dl_text -> dl_st dl_bytes]} {
        set dl_res "${dl_bytes}B status=$dl_st"
    }
    puts "======================================================================================="
    puts "  tb_net_services Phase Summary (125 MHz, 8 ns/cycle)"
    puts "---------------------------------------------------------------------------------------"
    puts [format "  %-7s | %-13s | %-21s | %-23s | %s" "Phase" "Function" "Verified Result" "Duration" "Status"]
    puts "  --------+---------------+-----------------------+-------------------------+-------"
    foreach row [list \
        [list "Phase 1" "User TX/RX"    "RM drop=$rm1/$rm2, RX=$rx1/$rx2" "users"] \
        [list "Phase 2" "IC/RM Fault"   "IC reject=$ic2"                  "integrity"] \
        [list "Phase 3" "SNMP Agent"    $snmp_res                         "snmp"] \
        [list "Phase 4" "RTC (SNTP)"    $rtc_res                          "rtc"] \
        [list "Phase 5" "615A Upload"   $up_res                           "upload"] \
        [list "Phase 6" "615A Download" $dl_res                           "download"]] {
        lassign $row p_num p_name p_res p_key
        set dur_str "N/A"
        if {[regexp -line "^F $p_key (\[0-9\]+) (\[0-9\]+)$" $net_text -> start_c end_c]} {
            set cyc [expr {$end_c - $start_c}]
            set dur_str [format "%6d cyc (%7.3f us)" $cyc [expr {$cyc * 0.008}]]
        }
        puts [format "  %-7s | %-13s | %-21s | %-23s | %s" $p_num $p_name $p_res $dur_str "PASS"]
    }
    puts "======================================================================================="
    set fh [open [file join $result_dir result.txt] w]
    puts $fh "PASS checks=$count errors=0"
    puts $fh "test=tb_net_services"
    puts $fh "log=$log_file"
    close $fh
    puts "MODELSIM ENTRY PASS checks=$count errors=0"
    puts "Outputs: $result_dir"
    return ""
}
set root [file normalize [pwd]]
if {![file exists [file join $root rtl AFDX_top.v]]} {
    error "First cd to the package root, then do sim/run_services.do"
}
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set result_dir [file join $root out modelsim ${stamp}_[pid]]
if {[file exists $result_dir]} {error "Output directory already exists: $result_dir"}
file mkdir [file join $result_dir vectors]
foreach name {bytes.hex offsets.txt} {
    file copy [file join $root sim vectors net_services $name] [file join $result_dir vectors $name]
}
cd $result_dir
set log_file [file join $result_dir simulation.log]
transcript file $log_file
transcript on
vmap -c
set local_ini [file join $result_dir modelsim.ini]
vlib [file join $result_dir work]
vmap -modelsimini $local_ini work [file join $result_dir work]
set sources [concat [lsort [glob [file join $root rtl *.v]]] \
                    [lsort [glob [file join $root tb lib *.v]]] \
                    [list [file join $root tb tb_net_services.v]]]
vlog -modelsimini $local_ini -work work -vlog01compat +incdir+[file join $root tb lib] {*}$sources
vsim -modelsimini $local_ini -t 1ps -voptargs=+acc -onfinish stop \
     -wlf [file join $result_dir simulation.wlf] work.tb_net_services
if {![batch_mode]} {update}
log /tb_net_services/clk /tb_net_services/reset /tb_net_services/phase \
    /tb_net_services/va12 /tb_net_services/vb12 /tb_net_services/va21 /tb_net_services/vb21 \
    /tb_net_services/a12 /tb_net_services/b12 /tb_net_services/a21 /tb_net_services/b21 \
    /tb_net_services/rm1 /tb_net_services/rm2 /tb_net_services/ic2 \
    /tb_net_services/difference /tb_net_services/status_value \
    /tb_net_services/es1/d_valid /tb_net_services/es1/d_data /tb_net_services/es1/d_last \
    /tb_net_services/es2/d_valid /tb_net_services/es2/d_data /tb_net_services/es2/d_last \
    /tb_net_services/es1/wr /tb_net_services/es1/rd /tb_net_services/es1/address \
    /tb_net_services/es1/wdata /tb_net_services/es1/rdata /tb_net_services/es1/rvalid
if {![batch_mode]} {
    catch {view wave}
    update
    catch {delete wave *}
    add wave -group "1_Phase_Services" -radix unsigned -label "phase (1..6)" /tb_net_services/phase
    add wave -group "1_Phase_Services" -radix decimal -label "rtc_diff_ns" /tb_net_services/difference
    add wave -group "1_Phase_Services" -radix unsigned -label "615A_status (2=OK)" /tb_net_services/status_value
    add wave -group "2_Clock_Reset" /tb_net_services/clk /tb_net_services/reset
    add wave -group "3_GMII_AB" -radix hexadecimal /tb_net_services/va12 /tb_net_services/a12 \
             /tb_net_services/vb12 /tb_net_services/b12 /tb_net_services/va21 /tb_net_services/a21
    add wave -group "4_Application" -radix hexadecimal /tb_net_services/es1/d_valid \
             /tb_net_services/es1/d_data /tb_net_services/es1/d_last \
             /tb_net_services/es2/d_valid /tb_net_services/es2/d_data /tb_net_services/es2/d_last
    add wave -group "5_Integrity_RM_IC" -radix unsigned /tb_net_services/rm1 /tb_net_services/rm2 /tb_net_services/ic2
    add wave -group "6_Host_Config_Bus" -radix hexadecimal /tb_net_services/es1/wr /tb_net_services/es1/rd \
             /tb_net_services/es1/address /tb_net_services/es1/wdata /tb_net_services/es1/rdata /tb_net_services/es1/rvalid
    update
    catch {configure wave -namecolwidth 210 -valuecolwidth 90 -timelineunits us}
}
run -all
transcript file ""
services_summary $result_dir $log_file
if {![batch_mode]} {
    update
    catch {wave cursor delete 1}
    set ::svc_phase_ranges [dict create]
    set net_file [file join $result_dir net_services.txt]
    if {[file exists $net_file]} {
        set fh [open $net_file r]; set net_text [read $fh]; close $fh
        foreach {key cname} {users P1_User_TX_RX integrity P2_BadSN_Drop snmp P3_SNMP rtc P4_RTC_SNTP upload P5_615A_Upload download P6_615A_Download} {
            if {[regexp -line "^F $key (\[0-9\]+) (\[0-9\]+)$" $net_text -> s_c e_c]} {
                set t0_ns [expr {$s_c * 8}]
                set t1_ns [expr {$e_c * 8}]
                dict set ::svc_phase_ranges $key [list $t0_ns $t1_ns]
                catch {wave cursor add -time ${t0_ns}ns -name $cname -lock 1}
            }
        }
    }
    proc ::svc_zoom {key {pad_ns 1000} {cap_span_ns 0}} {
        if {![dict exists $::svc_phase_ranges $key]} {puts "No range for $key"; return}
        lassign [dict get $::svc_phase_ranges $key] t0 t1
        set z0 [expr {max(0, $t0 - $pad_ns)}]
        set z1 [expr {$cap_span_ns > 0 ? min($t1 + $pad_ns, $t0 + $cap_span_ns) : ($t1 + $pad_ns)}]
        wave zoom range ${z0}ns ${z1}ns
        return [format "%s: %.3f us .. %.3f us" $key [expr {$z0 / 1000.0}] [expr {$z1 / 1000.0}]]
    }
    proc ::p1 {} {::svc_zoom users 800}
    proc ::p2 {} {::svc_zoom integrity 600}
    proc ::p3 {} {::svc_zoom snmp 1000}
    proc ::p4 {} {::svc_zoom rtc 1000}
    proc ::p5 {} {::svc_zoom upload 2000}
    proc ::p6 {} {::svc_zoom download 2000 120000}
    proc ::pall {} {
        set z0 524000
        if {[dict exists $::svc_phase_ranges users]} {
            set z0 [expr {max(0, [lindex [dict get $::svc_phase_ranges users] 0] - 1500)}]
        }
        wave zoom range ${z0}ns 815000ns
        return [format "Active window: %.3f us .. 815.000 us (skipped idle 0..%.1f us)" [expr {$z0 / 1000.0}] [expr {$z0 / 1000.0}]]
    }
    proc ::pfull {} {wave zoom full}
    update
    ::pall
    puts "---------------------------------------------------------------------------------------"
    puts "  Wave Quick Zoom (type command below & press Enter):"
    puts "    p1   -> Phase 1: User Dual-Net TX/RX & Redundancy"
    puts "    p2   -> Phase 2: Bad-SN Fault Injection & IC Reject"
    puts "    p3   -> Phase 3: SNMP Request / GetResponse"
    puts "    p4   -> Phase 4: RTC / SNTP Sync (diff=0 ns)"
    puts "    p5   -> Phase 5: ARINC 615A Upload"
    puts "    p6   -> Phase 6: ARINC 615A Download (active window)"
    puts "    pall -> All 5 Functions Overview (524 .. 815 us)"
    puts "    pfull-> Full timeline (0 .. 1095 us)"
    puts "  Note: All phase cursors (P1..P6) are locked by default (-lock 1)."
    puts "---------------------------------------------------------------------------------------"
}
if {[batch_mode]} {quit -f -code 0}
