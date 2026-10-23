# Independent Tcl generator for the R97 schedule; existing vectors() is unchanged.
proc judge_perf::var_events {kind} {
    set lengths {1 17 256 1024 1471}
    set vls [expr {$kind eq "var_high" ? 80 : 32}]
    set warm [expr {$kind eq "var_high" ? 250000 : 2000000}]
    set window [expr {$kind eq "var_high" ? 2500000 : 8000000}]
    set events {}
    for {set vl 0} {$vl<$vls} {incr vl} {
        set period [expr {$kind eq "var_high" ? 125000 : [lindex {125000 250000 500000 1000000} [expr {$vl/8}]]}]
        set phase [expr {$kind eq "var_burst" ? 0 : $vl*125000/$vls}]
        set k 0
        for {set target $phase} {$target<$warm+$window} {incr target $period} {
            if {$kind eq "var_high"} {set n [expr {$vl<4 ? [lindex $lengths $vl] : 1471}]} elseif {$kind eq "var_cycle"} {set n [lindex $lengths [expr {$k%5}]]} else {set n [lindex $lengths [expr {$vl%5}]]}
            lappend events [list $target $vl $n]; incr k
        }
    }
    return [list $warm $window $vls [lsort -integer -index 0 $events]]
}
proc judge_perf::var_config {es vl bag} {
    set vlid [expr {($es==1 ? 100 : 2000)+$vl}]
    set words [list [expr {(1471<<9)|(63<<3)|7}] $bag $vlid [expr {0x0a000001+$es*256+$vl}] [expr {0xe0e00000|$vlid}] [expr {((1000+$vl)<<16)|(2000+$vl)}]]
    set word 0
    foreach value $words {write_cfg $es [expr {0x1000+$vl*8+$word}] $value; incr word}
    write_cfg [expr {3-$es}] [expr {0x10000+$vlid}] [expr {0x1000|$vl}]
    write_cfg [expr {3-$es}] [expr {0x20000+$vl}] [expr {1|6|8|16|(20<<5)|(1471<<17)}]
}
proc judge_perf::var_vectors {folder} {
    variable commands;variable payload;variable offset;variable message;variable hex
    file mkdir $folder
    set commands [open [file join $folder sys_commands.txt] w]
    set payload [open [file join $folder sys_payload.hex] w]
    fconfigure $commands -translation crlf -encoding ascii
    fconfigure $payload -translation crlf -encoding ascii
    set offset 0;set message 0
    for {set i 0} {$i<256} {incr i} {set hex($i) [format "%02x\n" $i]}
    foreach kind {var_fixed var_cycle var_high var_burst} {
        foreach delay {0 257} {
            emit "P ${kind}_d$delay";emit {W 1000000}
            write_cfg 1 2 0x1234;write_cfg 2 2 0xabcd
            foreach link {0 1 2 3} {emit "L $link $delay"}
            lassign [var_events $kind] warm window vls events
            foreach es {1 2} {
                for {set vl 0} {$vl<$vls} {incr vl} {
                    set bag [expr {$kind eq "var_high" ? 125000 : [lindex {125000 250000 500000 1000000} [expr {$vl/8}]]}]
                    var_config $es $vl $bag
                }
            }
            emit "N $warm $window [llength $events]"
            foreach event $events {
                lassign $event target vl length
                set a [blob $length 1];set b [blob $length 1]
                emit "I $target $vl $length $a $b"
            }
            emit D;emit T
        }
    }
    close $commands;close $payload
    set fh [open [file join $folder sys_payload.count] w];fconfigure $fh -translation crlf -encoding ascii
    puts $fh $offset;close $fh
}

proc judge_perf::var_measure {folder} {
    r97::var_coverage $folder
    set results [r97::measure $folder]
    set lines [r97::judge_lines $folder var_]
    set failures 0
    foreach key [lsort -ascii [dict keys $results]] {
        if {![string match var_*/accepted/all/throughput/payload_bytes $key]} {continue}
        lassign [split $key /] stage direction
        set prefix $stage/$direction/accepted/all
        set rate [expr {[dict get $results $prefix/throughput/payload_bytes]*1000.0/[dict get $results $prefix/throughput/window_cycles]}]
        set ok [expr {(![string match var_high_* $stage] || $rate>=100) && [dict get $results $prefix/L_gmii/max]<=250000 && [dict get $results $prefix/L_app/max]<=250000}]
        lappend lines [format {JUDGE REQUIREMENT %s stage=%s direction=%s max_latency_us=2000} [expr {$ok ? "PASS" : "FAIL"}] $stage $direction]
        set throughput_status [expr {[string match var_high_* $stage] ? ($rate>=100 ? "PASS" : "FAIL") : "REPORT"}]
        lappend lines [format {JUDGE THROUGHPUT %s stage=%s direction=%s delivered_mbps=%.3f} $throughput_status $stage $direction $rate]
        lappend lines "JUDGE JITTER REPORT stage=$stage direction=$direction policy=no_failure_threshold"
        if {!$ok} {incr failures}
    }
    if {$failures} {
        foreach line $lines {puts $line}
        error "R97 variable requirements not met in $failures direction/scenarios; see r97_tcl.tsv"
    }
    return $lines
}
