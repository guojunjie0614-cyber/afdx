# tb_sys_perf uses the same input sequence as tools/sys_cases.py (seed 20261007).
# This file generates that sequence and measures the simulator's public records.
namespace eval judge_perf {variable commands; variable payload; variable offset; variable message; variable hex}
source [file join [file dirname [info script]] r97_measure.tcl]
source [file join [file dirname [info script]] perf_var_vectors.tcl]

proc judge_perf::emit {line} {variable commands; puts $commands $line}
proc judge_perf::write_cfg {es address value} {emit [format {C %d %x %x 0} $es $address $value]}
proc judge_perf::config {es vl} {
    set vlid [expr {($es == 1 ? 100 : 2000)+$vl}]
    set words [list [expr {(1471<<9)|(63<<3)|7}] 125000 $vlid \
        [expr {0x0a000001+$es*256+$vl}] [expr {0xe0e00000|$vlid}] \
        [expr {((1000+$vl)<<16)|(2000+$vl)}]]
    set word 0
    foreach value $words {write_cfg $es [expr {0x1000+$vl*8+$word}] $value; incr word}
    write_cfg [expr {3-$es}] [expr {0x10000+$vlid}] [expr {0x1000|$vl}]
    write_cfg [expr {3-$es}] [expr {0x20000+$vl}] [expr {1|6|8|16|(20<<5)|(1471<<17)}]
}

proc judge_perf::blob {length count} {
    variable payload; variable offset; variable message; variable hex
    set first $offset
    for {set k 0} {$k<$count} {incr k} {
        incr message
        set pattern ""
        # The byte formula repeats every 768 bytes; this avoids a large input file in Git.
        for {set i 0} {$i<min($length,768)} {incr i} {
            append pattern $hex([expr {($message*37+$i*19+($message>>($i%3)))&255}])
        }
        puts -nonewline $payload [string range [string repeat $pattern [expr {($length+767)/768}]] 0 [expr {$length*3-1}]]
        incr offset $length
    }
    return $first
}

proc judge_perf::vectors {folder} {
    variable commands; variable payload; variable offset; variable message; variable hex
    file mkdir $folder
    set commands [open [file join $folder sys_commands.txt] w]
    set payload [open [file join $folder sys_payload.hex] w]
    fconfigure $commands -translation crlf -encoding ascii
    fconfigure $payload -translation crlf -encoding ascii
    set offset 0; set message 0
    for {set i 0} {$i<256} {incr i} {set hex($i) [format "%02x\n" $i]}
    emit {P light_d0}
    write_cfg 1 2 0x1234; write_cfg 2 2 0xabcd
    foreach es {1 2} {config $es 0}
    foreach delay {0 257} {
        if {$delay} {emit {P light_d257}}
        foreach link {0 1 2 3} {emit "L $link $delay"}
        foreach length {1 17 18 1471 511} {
            set a [blob $length 8]; set b [blob $length 8]
            emit "K $length 8 150003 $a $b"
            emit D; emit {W 150003}
        }
        emit T
    }
    foreach {name delay directions vls} {
        throughput_d0 0 1 10 duplex_d0 0 2 10
        throughput_d257 257 1 10 duplex_d257 257 2 10
        gbe77_d0 0 2 77 gbe77_d257 257 2 77
        gbe81_d0 0 2 81 gbe81_d257 257 2 81
    } {
        emit "P $name"; emit {W 125000}
        foreach link {0 1 2 3} {emit "L $link $delay"}
        for {set es 1} {$es<=$directions} {incr es} {
            for {set vl 0} {$vl<$vls} {incr vl} {config $es $vl}
        }
        set a [blob 1471 [expr {23*$vls}]]
        set b 0
        if {$directions==2} {set b [blob 1471 [expr {23*$vls}]]}
        emit "F $directions 23 125000 $vls $a $b"
        emit D; emit T
    }
    close $commands; close $payload
    set fh [open [file join $folder sys_payload.count] w]
    fconfigure $fh -translation crlf -encoding ascii
    puts $fh $offset; close $fh
}

proc judge_perf::require {condition message} {if {!$condition} {error "Performance check: $message"}}
proc judge_perf::overlap {start end begin finish} {expr {max(0,min($end,$finish)-max($start,$begin))}}

proc judge_perf::limits {stage es rate maximum variation wire_a wire_b} {
    set direction es${es}_to_es[expr {3-$es}]
    set meets [expr {$rate>=100.0 && $maximum<=2000.0 && $variation<=50.0}]
    # T39: 54877a09 adds two RX map pipeline cycles, 24.408 + 0.016 us.
    set expected_e2e_us [expr {3054*0.008}]
    set same [expr {abs($rate-906.136)<0.000000001 && $maximum==$expected_e2e_us && $variation==0 && abs($wire_a-906.136)<0.000000001 && abs($wire_b-906.136)<0.000000001}]
    set lines [list [format {JUDGE METRIC tb_sys_perf stage=%s direction=%s delivered_mbps=%.3f max_e2e_us=%.3f jitter_us=%.3f gmii_a_mbps=%.3f gmii_b_mbps=%.3f} \
        $stage $direction $rate $maximum $variation $wire_a $wire_b]]
    lappend lines [format {JUDGE REQUIREMENT %s stage=%s direction=%s min_mbps=100 throughput_margin_mbps=%.3f max_e2e_us=2000 latency_margin_us=%.3f max_jitter_us=50 jitter_margin_us=%.3f} \
        [expr {$meets ? "PASS" : "FAIL"}] $stage $direction [expr {$rate-100.0}] [expr {2000.0-$maximum}] [expr {50.0-$variation}]]
    lappend lines [format {JUDGE BASELINE %s stage=%s direction=%s expected_mbps=906.136 expected_e2e_us=24.432 expected_jitter_us=0} \
        [expr {$same ? "PASS" : "FAIL"}] $stage $direction]
    if {!$meets || !$same} {
        foreach line $lines {puts $line}
        if {!$meets} {error "Performance requirement not met: $stage $direction"}
        error "Performance baseline mismatch: $stage $direction"
    }
    return $lines
}

proc judge_perf::measure {folder} {
    set phases {gbe77_d0 gbe77_d257}
    set fh [open [file join $folder sys_events.txt] r]
    set previous ""
    while {[gets $fh line]>=0} {
        if {[regexp {^P ([0-9]+) (\S+)$} $line all cycle stage]} {
            if {$previous ne ""} {set stop($previous) $cycle}
            set start($stage) $cycle; set previous $stage
        }
        if {[regexp {^F ([0-9]+) (begin|end) (\S+)$} $line all cycle edge stage]} {set window($stage,$edge) $cycle}
    }
    close $fh
    foreach stage $phases {
        require [expr {[info exists window($stage,begin)] && [info exists window($stage,end)] && [info exists stop($stage)]}] "missing window $stage"
        set begin($stage) $window($stage,begin); set end($stage) $window($stage,end)
        require [expr {$end($stage)-$begin($stage)==2625000}] "expected a 21 ms window for $stage"
        require [expr {$begin($stage)-$start($stage)>=250000}] "missing two warmup intervals"
    }
    # M rows record the accepted application last byte; D rows record delivery first bytes.
    foreach es {1 2} {
        set fh [open [file join $folder es${es}_tx events.txt] r]
        set stage ""
        while {[gets $fh line]>=0} {
            if {[regexp {^P [0-9]+ (\S+)$} $line all label]} {set stage $label}
            if {$stage ni $phases} {continue}
            if {[regexp {^M ([0-9]+) ([0-9]+) ([0-9]+) [0-9]+ [0-9a-f]+ [0-9a-f]+ ([0-9a-f]+)$} $line all cycle vl n data]} {
                require [expr {$vl<77 && $n==1471 && [string length $data]==$n*2}] "invalid application message"
                lappend messages($es,$stage,$vl) [list $cycle $n $data]
            }
            if {[regexp {^E [0-9]+ (drop_dis|drop_full|drop_long|drop_nopage)$} $line]} {error "Performance check: rejected application message"}
        }
        close $fh
        foreach stage $phases {
            set bytes($es,$stage) 0; set latency($es,$stage) 0; set samples($es,$stage) 0
            foreach net {A B} {set wirebytes($es,$stage,$net) 0; set jitter($es,$stage,$net) 0}
            for {set vl 0} {$vl<77} {incr vl} {
                require [info exists messages($es,$stage,$vl)] "missing virtual link $vl"
                require [expr {[llength $messages($es,$stage,$vl)]==23}] "missing application messages"
                set delivered($es,$stage,$vl) 0
                foreach net {A B} {set sent($es,$stage,$vl,$net) 0}
            }
        }
    }
    foreach destination {1 2} {
        set es [expr {3-$destination}]
        set fh [open [file join $folder es${destination}_rx events.txt] r]
        set stage ""
        while {[gets $fh line]>=0} {
            if {[regexp {^P [0-9]+ (\S+)$} $line all label]} {set stage $label}
            if {$stage ni $phases} {continue}
            if {[regexp {^E [0-9]+ [ab]_(fcs|len|hdr|unk|cfg|ic|ovf|gdrop)$} $line]} {error "Performance check: receive error"}
            if {![regexp {^D ([0-9]+) [AB] ([0-9]+) [0-9a-f]+ [0-9a-f]+ ([0-9]+) ([0-9a-f]+)$} $line all cycle vl n data]} {continue}
            set key $es,$stage,$vl
            require [info exists messages($key)] "unexpected delivered virtual link"
            set index $delivered($key)
            require [expr {$index<[llength $messages($key)]}] "duplicate delivery"
            lassign [lindex $messages($key) $index] accepted length expected
            require [expr {$n==$length && $data eq $expected}] "delivery payload/order mismatch"
            incr delivered($key)
            incr bytes($es,$stage) [overlap $cycle [expr {$cycle+$n}] $begin($stage) $end($stage)]
            if {$accepted >= $begin($stage) && $accepted < $end($stage)} {
                set delay [expr {$stage eq "gbe77_d257" ? 257 : 0}]
                set value [expr {$cycle+$n-1-$accepted-$delay}]
                require [expr {$value>0}] "nonpositive end-to-end latency"
                set latency($es,$stage) [expr {max($latency($es,$stage),$value)}]
                incr samples($es,$stage)
            }
        }
        close $fh
    }
    # Each network is measured separately; redundant copies are never added together.
    foreach es {1 2} {
        foreach net {A B} {
            set fh [open [file join $folder es${es}_gmii_tx dump_[string tolower $net].txt] r]
            while {[gets $fh line]>=0} {
                require [regexp {^[AB] ([0-9]+) ([0-9]+) ([0-9a-f]+)$} $line all cycle n data] "malformed wire record"
                set stage ""
                foreach candidate $phases {if {$cycle >= $start($candidate) && $cycle < $stop($candidate)} {set stage $candidate}}
                if {$stage eq ""} {continue}
                scan [string range $data 24 27] %x vlid
                set vl [expr {$vlid-($es==1 ? 100 : 2000)}]
                set key $es,$stage,$vl
                require [info exists messages($key)] "unexpected transmitted virtual link"
                set index $sent($key,$net)
                require [expr {$index<23}] "extra transmitted frame"
                lassign [lindex $messages($key) $index] accepted length expected
                require [expr {$n==1526 && [string length $data]==$n*2}] "wrong wire frame length"
                require [expr {[string range $data 100 [expr {99+$length*2}]] eq $expected}] "wire payload/order mismatch"
                if {$index>0 && $accepted >= $begin($stage) && $accepted < $end($stage)} {
                    set value [expr {abs($cycle-$last($key,$net)-125000)}]
                    set jitter($es,$stage,$net) [expr {max($jitter($es,$stage,$net),$value)}]
                }
                set last($key,$net) $cycle; incr sent($key,$net)
                incr wirebytes($es,$stage,$net) [overlap [expr {$cycle+50}] [expr {$cycle+50+$length}] $begin($stage) $end($stage)]
            }
            close $fh
        }
    }
    set lines {}
    foreach stage $phases {
        foreach es {1 2} {
            for {set vl 0} {$vl<77} {incr vl} {
                require [expr {$delivered($es,$stage,$vl)==23}] "missing delivery"
                foreach net {A B} {require [expr {$sent($es,$stage,$vl,$net)==23}] "missing wire frame"}
            }
            require [expr {$samples($es,$stage)==21*77}] "incomplete latency sample set"
            set rate [expr {$bytes($es,$stage)*1000.0/($end($stage)-$begin($stage))}]
            set maximum [expr {$latency($es,$stage)*0.008}]
            set variation [expr {max($jitter($es,$stage,A),$jitter($es,$stage,B))*0.008}]
            foreach net {A B} {
                set wire_rate($net) [expr {$wirebytes($es,$stage,$net)*1000.0/($end($stage)-$begin($stage))}]
            }
            set lines [concat $lines [limits $stage $es $rate $maximum $variation $wire_rate(A) $wire_rate(B)]]
        }
    }
    set newmetrics [r97::measure $folder {gbe77_d0 gbe77_d257}]
    set augmented {}
    foreach line $lines {
        if {[regexp {^JUDGE METRIC tb_sys_perf stage=(\S+) direction=(\S+)} $line all stage direction]} {
            set key "$stage/$direction/accepted/all"
            append line [format { l_gmii_max_us=%.3f l_app_max_us=%.3f jitter_r97_us=%.3f jitter_r97_gmii_us=%.3f tx_interval_jitter_us=%.3f} \
                [expr {[dict get $newmetrics $key/L_gmii/max]*0.008}] [expr {[dict get $newmetrics $key/L_app/max]*0.008}] \
                [expr {[dict get $newmetrics $key/L_app/jitter]*0.008}] [expr {[dict get $newmetrics $key/L_gmii/jitter]*0.008}] [expr {[dict get $newmetrics $key/tx_interval_jitter/max]*0.008}]]
        }
        lappend augmented $line
    }
    set lines $augmented
    return $lines
}
