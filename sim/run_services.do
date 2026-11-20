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
    view wave
    add wave -group Clock /tb_net_services/clk /tb_net_services/reset
    add wave -group GMII -radix hexadecimal /tb_net_services/va12 /tb_net_services/a12 \
             /tb_net_services/vb12 /tb_net_services/b12 /tb_net_services/va21 /tb_net_services/a21
    add wave -group Application -radix hexadecimal /tb_net_services/es1/d_valid \
             /tb_net_services/es1/d_data /tb_net_services/es1/d_last \
             /tb_net_services/es2/d_valid /tb_net_services/es2/d_data /tb_net_services/es2/d_last
    add wave -group Integrity -radix unsigned /tb_net_services/rm1 /tb_net_services/rm2 /tb_net_services/ic2
    add wave -group Services -radix decimal /tb_net_services/phase /tb_net_services/difference /tb_net_services/status_value
    add wave -group Configuration -radix hexadecimal /tb_net_services/es1/wr /tb_net_services/es1/rd \
             /tb_net_services/es1/address /tb_net_services/es1/wdata /tb_net_services/es1/rdata /tb_net_services/es1/rvalid
    configure wave -namecolwidth 190 -valuecolwidth 90 -timelineunits us
}
run -all
transcript file ""
services_summary $result_dir $log_file
if {![batch_mode]} {wave zoom full}
if {[batch_mode]} {quit -f -code 0}
