# ModelSim-only entry: run from the repository root with do sim/run_judge.do.
# No Python, generated vectors, global library mappings or persistent settings.
onerror {puts "JUDGE ENTRY FAIL: ModelSim command error"; quit -f -code 1}
# Testbenches finish with $finish; validate the final result after run returns.
onbreak {}

proc judge_read {name} {
    set fh [open $name r]
    set value [read $fh]
    close $fh
    return $value
}

proc judge_case {root output ini label test parameters} {
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
    cd $folder
    set logfile [file join $folder simulation.log]
    transcript file $logfile
    transcript on
    vsim -quiet -modelsimini $ini -t 1ps -onfinish stop -wlf simulation.wlf {*}$parameters work.$test
    run -all
    quit -sim
    transcript file ""
    set report [judge_read $logfile]
    set pattern [format {\[RESULT\] %s PASS checks=([0-9]+) errors=0} $test]
    if {![regexp $pattern $report match checks] || [regexp {\*\* (Error|Fatal|Warning):|\[RESULT\][^\n]* FAIL} $report]} {
        error "$label failed; see $label/simulation.log"
    }
    set lines [list "JUDGE CASE PASS $label checks=$checks errors=0"]
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
    cd $output
    foreach line $lines {puts $line}
    return $lines
}

proc judge_main {} {
    set root [file normalize [pwd]]
    if {![file isfile [file join $root rtl AFDX_top.v]]} {error "First cd to the repository root"}
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set output [file join $root out modelsim judge_${stamp}_[pid]]
    if {[file exists $output]} {error "Output directory already exists"}
    file mkdir $output
    cd $output
    vmap -c
    set ini [file join $output modelsim.ini]
    vlib work
    vmap -modelsimini $ini work [file join $output work]
    transcript file [file join $output compile.log]
    transcript on
    set sources [concat [lsort [glob [file join $root rtl *.v]]] [lsort [glob [file join $root tb lib *.v]]]]
    foreach test {tb_net_services tb_gbe_burst tb_sys_rtc} {lappend sources [file join $root tb ${test}.v]}
    vlog -modelsimini $ini -work work -vlog01compat +incdir+[file join $root tb lib] {*}$sources
    transcript file ""
    set compiled [judge_read [file join $output compile.log]]
    if {![regexp {Errors: 0, Warnings: 0} $compiled]} {error "Compilation diagnostics; see compile.log"}
    set summary {}
    foreach {label test parameters} {
        services tb_net_services {}
        burst77 tb_gbe_burst {-gCOUNT=77}
        burst81 tb_gbe_burst {-gCOUNT=81}
        rtc tb_sys_rtc {}
    } {
        set summary [concat $summary [judge_case $root $output $ini $label $test $parameters]]
    }
    set fh [open [file join $output result.txt] w]
    puts $fh [join $summary "\n"]
    puts $fh "JUDGE ENTRY PASS cases=4"
    close $fh
    puts "JUDGE ENTRY PASS cases=4"
    puts "Outputs: [file join out modelsim [file tail $output]]"
    cd $root
}

if {[catch {judge_main} message]} {
    puts "JUDGE ENTRY FAIL: $message"
    if {[batch_mode]} {quit -f -code 1}
} elseif {[batch_mode]} {quit -f -code 0}
