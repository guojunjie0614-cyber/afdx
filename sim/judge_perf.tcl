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

# R119/R120 baseline for the accepted r5 A RTL 18d1606c, measured on 2026-10-28.
# Two RTL runs at fd1013a agree; Tcl/Python 1784 fields match with zero differences.
# Record: out/t63/F1_final/judge_baseline_diagnosis.json; the later VLID pipeline adds two cycles.
# fields: inject_mbps max_e2e_us max_e2e_first_us jitter_r119_us stall_cycles lag_max_cycles
proc judge_perf::baseline {stage} {
    if {[string match gbe77_d0 $stage]} {return {906.136 48.288 36.512 0.008 0 2}}
    if {[string match gbe77_d257 $stage]} {return {906.136 50.344 38.568 0.008 0 2}}
    return {}
}

proc judge_perf::limits {stage es rate maximum variation wire_a wire_b results p} {
    set direction es${es}_to_es[expr {3-$es}]
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
    set lag_ok [expr {$lag eq "NA" || $lag<=1471}]
    set meets [expr {$inject>=100.0 && $e2e ne "NA" && $e2e<=250000 && $jitter ne "NA" &&
        $jitter<=6250 && $dropped==0 && $overflow==0 && $duplicate==0 && $lag_ok}]
    set expected [baseline $stage]
    set same 1; set problems {}
    if {[llength $expected]==6} {
        lassign $expected bi be bf bj bs bl
        set e2e_us [expr {$e2e eq "NA" ? "NA" : $e2e*0.008}]
        set first_us [expr {$first eq "NA" ? "NA" : $first*0.008}]
        set jitter_us [expr {$jitter eq "NA" ? "NA" : $jitter*0.008}]
        set pairs [list inject_mbps $inject $bi max_e2e_us $e2e_us $be \
            max_e2e_first_us $first_us $bf jitter_r119_us $jitter_us $bj \
            stall_cycles $stalls $bs lag_max_cycles $lag $bl]
        foreach {name actual want} $pairs {
            if {$actual eq "NA"} {continue}
            if {$name in {stall_cycles lag_max_cycles}} {
                if {$actual != $want} {lappend problems "$name=$actual!=$want"}
            } elseif {[format %.3f $actual] ne [format %.3f $want]} {
                lappend problems "$name=$actual!=$want"
            }
        }
        if {[llength $problems]} {set same 0}
    } else {set same 0}
    set metric [format {JUDGE METRIC tb_sys_perf stage=%s direction=%s inject_mbps=%.3f max_e2e_us=%.3f max_e2e_first_us=%.3f jitter_r119_us=%.3f jitter_vl=%s jitter_len=%s stall_cycles=%d stall_maxrun=%d lag_max_cycles=%s dropped=%d duplicate=%d overflow=%d delivered_mbps=%.3f gmii_a_mbps=%.3f gmii_b_mbps=%.3f} \
        $stage $direction $inject [expr {$e2e*0.008}] [expr {$first*0.008}] [expr {$jitter*0.008}] \
        $jvl $jlen $stalls $stallmax $lag $dropped $duplicate $overflow $rate $wire_a $wire_b]
    set lines [list $metric]
    lappend lines [format {JUDGE REQUIREMENT %s stage=%s direction=%s min_mbps=100 max_e2e_us=2000 max_jitter_us=50 inject_margin_mbps=%.3f latency_margin_us=%.3f jitter_margin_us=%.3f lag_max_cycles=%s} \
        [expr {$meets ? "PASS" : "FAIL"}] $stage $direction [expr {$inject-100.0}] \
        [expr {$e2e eq "NA" ? "NA" : 2000.0-$e2e*0.008}] [expr {$jitter eq "NA" ? "NA" : 50.0-$jitter*0.008}] $lag]
    lappend lines [format {JUDGE BASELINE %s stage=%s direction=%s expected_inject_mbps=%s expected_max_e2e_us=%s expected_jitter_r119_us=%s} \
        [expr {$same ? "PASS" : "FAIL"}] $stage $direction \
        [lindex $expected 0] [lindex $expected 1] [lindex $expected 3]]
    if {!$meets || !$same} {
        foreach line $lines {puts $line}
        if {[llength $problems]} {puts "JUDGE BASELINE DETAIL [join $problems {; }]"}
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
            # M rows end with two T59 fields: first-valid cycle and longest stall run.
            if {[regexp {^M ([0-9]+) ([0-9]+) ([0-9]+) [0-9]+ [0-9a-f]+ [0-9a-f]+ ([0-9a-f]+)(?: [0-9-]+ [0-9]+(?: [0-9]+ [0-9]+)?)?$} $line all cycle vl n data]} {
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
            if {![regexp {^D ([0-9]+) [AB] ([0-9]+) [0-9a-f]+ [0-9a-f]+ ([0-9]+) ([0-9a-f]+)(?: [0-9]+ [0-9]+)?$} $line all cycle vl n data]} {continue}
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
                require [regexp {^[AB] ([0-9]+) ([0-9]+) ([0-9a-f]+)(?: [0-9]+ [0-9]+)?$} $line all cycle n data] "malformed wire record"
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
    set newmetrics [r97::measure $folder {gbe77_d0 gbe77_d257}]
    foreach stage $phases {
        foreach es {1 2} {
            set direction es${es}_to_es[expr {3-$es}]
            set p $stage/$direction/accepted/all
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
            set lines [concat $lines [limits $stage $es $rate $maximum $variation $wire_rate(A) $wire_rate(B) $newmetrics $p]]
        }
    }
    return $lines
}
