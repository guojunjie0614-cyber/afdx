# ModelSim batch entry: run from the repository root with do sim/run_judge.do.
# The current T76 fallback uses Python only to prepare RTL simulation copies.
# Configuration tasks stay in non-top endpoint modules; application file input
# is isolated in tb/lib/afdx_sys_config.v (sim/run_app.do).
# Compilation and each case are launched as external `vlog`/`vsim -batch`
# processes: `vsim -c` uses the local vish<->vsim RPC transport, which is
# unavailable on some hosts, and `transcript` is not available in -batch mode.
onerror {resume}
# Testbenches finish with $finish; validate the final result after run returns.
onbreak {}

proc judge_read {name} {
    set fh [open $name r]
    set value [read $fh]
    close $fh
    return $value
}

proc judge_diagnostics {report label} {
    set warnings [regexp -all -line {^[ \t]*(#[ \t]*)?\*\* Warning([ \t]+\([^)]*\))?:} $report]
    puts "JUDGE WARNINGS $label count=$warnings"
    if {[string first "RAMCOLL" $report] >= 0 || [regexp -line {^[ \t]*(#[ \t]*)?(\*\* (Error|Fatal)([ \t]+\([^)]*\))?:|.*\mFAIL\M)} $report]} {
        error "$label reported RAMCOLL, Error, Fatal or FAIL; see its log"
    }
    return $warnings
}

proc judge_tools {} {
    if {[info exists ::env(MODEL_TECH)] && [file isfile [file join $::env(MODEL_TECH) vsim.exe]]} {
        return $::env(MODEL_TECH)
    }
    return [file dirname [info nameofexecutable]]
}

proc judge_run {log command} {
    # Child tools resolve the library map from their own -modelsimini/cwd; the
    # outer session's MODELSIM pointer is not valid for them.
    if {[info exists ::env(MODELSIM)]} {unset ::env(MODELSIM)}
    if {[catch {exec {*}$command > $log 2>@1} message]} {
        if {![file isfile $log]} {error "launch failed: $message"}
    }
    return [judge_read $log]
}

proc judge_case {root output ini label test parameters} {
    set started [clock milliseconds]
    set folder [file join $output $label]
    file mkdir [file join $folder vectors]
    if {$test eq "tb_net_services"} {
        foreach name {bytes.hex offsets.txt} {
            file copy [file join $root sim vectors net_services $name] [file join $folder vectors $name]
        }
    }
    if {$test eq "tb_sys_rtc"} {
        file copy [file join $root sim vectors judge fractions.txt] [file join $folder vectors fractions.txt]
    }
    if {$test eq "tb_sys_perf" || $test eq "tb_sys_perf_var"} {
        if {$test eq "tb_sys_perf_var"} {judge_perf::var_vectors [file join $folder vectors]} else {judge_perf::vectors [file join $folder vectors]}
        foreach es {1 2} {
            foreach suffix {tx rx gmii_tx gmii_rx} {
                file mkdir [file join $folder es${es}_${suffix}]
            }
        }
    }
    cd $folder
    set logfile [file join $folder simulation.log]
    set command [list [file join [judge_tools] vsim.exe] -batch -quiet]
    if {$ini ne ""} {lappend command -modelsimini $ini}
    lappend command -t 1ps -onfinish stop -wlf simulation.wlf {*}$parameters work.$test \
        -do "run -all; quit -f"
    set report [judge_run $logfile $command]
    set warnings [judge_diagnostics $report $label]
    set pattern [format {\[RESULT\] %s PASS checks=([0-9]+) errors=0} $test]
    if {![regexp $pattern $report match checks]} {
        error "$label failed; see $label/simulation.log"
    }
    set lines {}
    if {$test eq "tb_gbe_burst"} {
        if {![regexp {\[BURST_SUMMARY\] count=([0-9]+).*max_queue_cycles=([0-9]+) max_raw_m_to_d=([0-9]+)} $report all count queue raw]} {
            error "$label has no measured burst summary"
        }
        lappend lines [format {JUDGE METRIC burst_vls=%d queue_clear_us=%.3f app_last_to_delivery_last_us=%.3f} $count [expr {$queue*0.008}] [expr {$raw*0.008}]]
    }
    if {$test eq "tb_sys_rtc"} {
        set idle 0
        set loaded 0
        set gbe 0
        set syncs 0
        foreach line [split [judge_read rtc_results.txt] "\n"] {
            if {[scan $line {S %d %d %d %d} phase slave count difference] == 4} {
                incr syncs
                set error_ns [expr {abs($difference)}]
                if {$phase == 6} {set gbe [expr {max($gbe,$error_ns)}]} elseif {$phase == 3} {
                    set loaded [expr {max($loaded,$error_ns)}]
                } else {set idle [expr {max($idle,$error_ns)}]}
            }
        }
        if {$syncs != 68} {error "RTC synchronization records incomplete: $syncs"}
        lappend lines "JUDGE METRIC rtc_idle_max_ns=$idle rtc_loaded_max_ns=$loaded rtc_77vl_max_ns=$gbe"
    }
    if {$test eq "tb_sys_perf"} {
        set lines [concat $lines [judge_perf::measure $folder]]
    }
    if {$test eq "tb_sys_perf_var"} {
        set lines [concat $lines [judge_perf::var_measure $folder]]
    }
    cd $output
    set seconds [expr {([clock milliseconds]-$started)/1000.0}]
    set lines [linsert $lines 0 [format {JUDGE CASE PASS %s checks=%s errors=0 warnings=%d elapsed_s=%.3f} $label $checks $warnings $seconds]]
    incr ::judge_warnings $warnings
    foreach line $lines {puts $line}
    return $lines
}

proc judge_bytes {folder} {
    set bytes 0
    foreach name [glob -nocomplain -directory $folder *] {
        if {[file isdirectory $name]} {incr bytes [judge_bytes $name]} else {incr bytes [file size $name]}
    }
    return $bytes
}

proc judge_main {root} {
    if {![file isfile [file join $root rtl AFDX_top.v]]} {error "First cd to the repository root"}
    if {[regexp {[[:space:]]|[^\x20-\x7e]} $root]} {
        error "ModelSim requires a repository path without spaces or non-ASCII characters"
    }
    source [file join $root sim judge_perf.tcl]
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set base [file join $root out modelsim judge_${stamp}_[pid]]
    set output $base
    set suffix 0
    while {[file exists $output]} {incr suffix; set output ${base}_$suffix}
    set ::judge_output $output
    file mkdir $output
    cd $output
    set ini [file join $output modelsim.ini]
    if {[catch {vmap -c}] || ![file isfile $ini]} {set ini ""}
    vlib work
    if {$ini ne ""} {catch {vmap -modelsimini $ini work [file join $output work]}}
    source [file join $root sim modelsim_compat.tcl]
    set sources [concat [afdx_modelsim_rtl $root $output] [lsort [glob [file join $root tb lib *.v]]]]
    foreach test {tb_net_services tb_gbe_burst tb_sys_rtc tb_sys_perf tb_sys_perf_var tb_judge_capacity tb_judge_snmp} {lappend sources [file join $root tb ${test}.v]}
    set ce_div 2
    if {[info exists ::env(AFDX_CE_DIV)]} {set ce_div $::env(AFDX_CE_DIV)}
    if {$ce_div ni {1 2}} {error "AFDX_CE_DIV must be 1 or 2"}
    puts "JUDGE CE_DIV=$ce_div"
    set command [list [file join [judge_tools] vlog.exe] -work work -vlog01compat \
        +define+AFDX_CE_DIV=$ce_div +incdir+[file join $root tb lib]]
    if {$ini ne ""} {set command [linsert $command 1 -modelsimini $ini]}
    set compiled [judge_run [file join $output compile.log] [concat $command $sources]]
    set ::judge_warnings [judge_diagnostics $compiled compile]
    puts "JUDGE COMPILE PASS warnings=$::judge_warnings"
    set summary {}
    foreach {label test parameters} {
        services tb_net_services {}
        capacity tb_judge_capacity {}
        snmp tb_judge_snmp {}
        burst77 tb_gbe_burst {-gCOUNT=77}
        burst81 tb_gbe_burst {-gCOUNT=81}
        rtc tb_sys_rtc {}
        performance tb_sys_perf {}
        perf_var tb_sys_perf_var {}
    } {
        if {[info exists ::env(AFDX_JUDGE_CASE)] && $::env(AFDX_JUDGE_CASE) ne $label} {continue}
        set summary [concat $summary [judge_case $root $output $ini $label $test $parameters]]
        incr ::judge_cases
    }
    if {$::judge_cases==0} {error "No matching AFDX_JUDGE_CASE"}
    set fh [open [file join $output result.txt] w]
    puts $fh [join $summary "\n"]
    close $fh
    puts "Outputs: [file join out modelsim [file tail $output]]"
}

# Both exits restore the caller's directory before reporting.
set judge_root [file normalize [pwd]]
set judge_started [clock milliseconds]
set judge_warnings 0
set judge_cases 0
set judge_output ""
set judge_failed [catch {judge_main $judge_root} judge_message]
set judge_cleanup_failed [catch {
    catch {quit -sim}
    cd $judge_root
} judge_cleanup_message]
if {$judge_cleanup_failed} {set judge_failed 1; append judge_message " Cleanup: $judge_cleanup_message"}
set judge_seconds [expr {([clock milliseconds]-$judge_started)/1000.0}]
if {$judge_failed} {
    set judge_result "JUDGE ENTRY FAIL: $judge_message"
} else {
    set judge_result [format {JUDGE ENTRY PASS cases=%d warnings=%d elapsed_s=%.3f output_mib=%.1f} $judge_cases $judge_warnings $judge_seconds [expr {[judge_bytes $judge_output]/1048576.0}]]
}
puts $judge_result
if {$judge_output ne "" && [file isdirectory $judge_output]} {
    set judge_fh [open [file join $judge_output result.txt] a]
    puts $judge_fh $judge_result
    close $judge_fh
}
if {[batch_mode]} {quit -f -code $judge_failed}
