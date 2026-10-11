# ModelSim-only entry: run from the repository root with do sim/run_judge.do.
# ModelSim creates local vectors and libraries; Python is not required.
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
    if {[regexp -line {^[ \t]*(#[ \t]*)?(\*\* (Error|Fatal)([ \t]+\([^)]*\))?:|.*\mFAIL\M)} $report]} {
        error "$label reported Error, Fatal or FAIL; see its log"
    }
    return $warnings
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
    if {$test eq "tb_sys_perf"} {
        judge_perf::vectors [file join $folder vectors]
        foreach es {1 2} {
            foreach suffix {tx rx gmii_tx gmii_rx} {
                file mkdir [file join $folder es${es}_${suffix}]
            }
        }
    }
    cd $folder
    set logfile [file join $folder simulation.log]
    transcript file $logfile
    transcript on
    set failed [catch {
        vsim -quiet -modelsimini $ini -t 1ps -onfinish stop -wlf simulation.wlf {*}$parameters work.$test
        run -all
    } message options]
    catch {quit -sim}
    transcript file ""
    set report [judge_read $logfile]
    set warnings [judge_diagnostics $report $label]
    if {$failed} {return -options $options $message}
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
    vmap -c
    set ini [file join $output modelsim.ini]
    vlib work
    vmap -modelsimini $ini work [file join $output work]
    transcript file [file join $output compile.log]
    transcript on
    set sources [concat [lsort [glob [file join $root rtl *.v]]] [lsort [glob [file join $root tb lib *.v]]]]
    foreach test {tb_net_services tb_gbe_burst tb_sys_rtc tb_sys_perf} {lappend sources [file join $root tb ${test}.v]}
    set failed [catch {
        vlog -modelsimini $ini -work work -vlog01compat +incdir+[file join $root tb lib] {*}$sources
    } message options]
    transcript file ""
    set compiled [judge_read [file join $output compile.log]]
    set ::judge_warnings [judge_diagnostics $compiled compile]
    if {$failed} {return -options $options $message}
    puts "JUDGE COMPILE PASS warnings=$::judge_warnings"
    set summary {}
    foreach {label test parameters} {
        services tb_net_services {}
        burst77 tb_gbe_burst {-gCOUNT=77}
        burst81 tb_gbe_burst {-gCOUNT=81}
        rtc tb_sys_rtc {}
        performance tb_sys_perf {}
    } {
        set summary [concat $summary [judge_case $root $output $ini $label $test $parameters]]
    }
    set fh [open [file join $output result.txt] w]
    puts $fh [join $summary "\n"]
    close $fh
    puts "Outputs: [file join out modelsim [file tail $output]]"
}

# Both exits restore the caller's directory and transcript before reporting.
set judge_root [file normalize [pwd]]
set judge_transcript [transcript file]
if {$judge_transcript ne ""} {set judge_transcript [file normalize $judge_transcript]}
set judge_echo [transcript -q]
set judge_started [clock milliseconds]
set judge_warnings 0
set judge_output ""
set judge_failed [catch {judge_main $judge_root} judge_message]
set judge_cleanup_failed [catch {
    catch {quit -sim}
    cd $judge_root
    transcript file $judge_transcript
    if {$judge_echo} {transcript on} else {transcript off}
} judge_cleanup_message]
if {$judge_cleanup_failed} {set judge_failed 1; append judge_message " Cleanup: $judge_cleanup_message"}
set judge_seconds [expr {([clock milliseconds]-$judge_started)/1000.0}]
if {$judge_failed} {
    set judge_result "JUDGE ENTRY FAIL: $judge_message"
} else {
    set judge_result [format {JUDGE ENTRY PASS cases=5 warnings=%d elapsed_s=%.3f output_mib=%.1f} $judge_warnings $judge_seconds [expr {[judge_bytes $judge_output]/1048576.0}]]
}
puts $judge_result
if {$judge_output ne "" && [file isdirectory $judge_output]} {
    set judge_fh [open [file join $judge_output result.txt] a]
    puts $judge_fh $judge_result
    close $judge_fh
}
if {[batch_mode]} {quit -f -code $judge_failed}
