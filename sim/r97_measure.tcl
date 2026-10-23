# Independent R97 measurement of public simulator records; Tcl 8.5 compatible.
namespace eval r97 {}
proc r97::require {value message} {if {!$value} {error "R97: $message"}}
proc r97::stage_at {marks cycle} {
    set result ""
    foreach item $marks {lassign $item t name; if {$t>$cycle} {break}; set result $name}
    return $result
}
proc r97::rows {path} {
    set f [open $path r]; set out {}
    while {[gets $f line]>=0} {if {[string trim $line] ne ""} {lappend out [split [string trim $line]]}}
    close $f; return $out
}
proc r97::stats {samples} {
    set result [dict create samples [llength $samples]]
    foreach k {min max jitter vl min_frame max_frame} {dict set result $k NA}
    if {![llength $samples]} {return $result}
    set byvl {}; set lo {}; set hi {}
    foreach sample $samples {
        lassign $sample vl id value
        if {$lo eq "" || $value<$lo} {set lo $value}
        if {$hi eq "" || $value>$hi} {set hi $value}
        if {![dict exists $byvl $vl]} {dict set byvl $vl [list $value $id $value $id]; continue}
        lassign [dict get $byvl $vl] mn mi mx ma
        if {$value<$mn || ($value==$mn && $id<$mi)} {set mn $value; set mi $id}
        if {$value>$mx || ($value==$mx && $id<$ma)} {set mx $value; set ma $id}
        dict set byvl $vl [list $mn $mi $mx $ma]
    }
    set best -1
    foreach vl [lsort -integer [dict keys $byvl]] {
        lassign [dict get $byvl $vl] mn mi mx ma
        set delta [expr {$mx-$mn}]
        # VL order resolves equal ranges; per-VL extrema already use smallest frame id.
        if {$delta>$best} {set best $delta; set witness [list $vl $mi $ma]}
    }
    dict set result min $lo; dict set result max $hi; dict set result jitter $best
    foreach k {vl min_frame max_frame} v $witness {dict set result $k $v}
    return $result
}
proc r97::measure {folder {stages {}}} {
    set marks {}; set windows {}; set finalcycle 0
    set releases {}; set release_stage ""
    foreach row [rows [file join $folder sys_events.txt]] {
        set kind [lindex $row 0]; set cycle [lindex $row 1]
        if {[string is integer -strict $cycle]} {set finalcycle [expr {max($finalcycle,$cycle)}]}
        if {$kind eq "P"} {set release_stage [lindex $row 2]; lappend marks [list $cycle $release_stage]}
        if {$kind eq "O"} {
            lassign $row kind actual source vl size planned
            dict lappend releases $release_stage,$source,$vl [list $size $planned]
        }
        if {$kind eq "F" && [lindex $row 2] in {begin end}} {dict set windows [lindex $row 3] [lindex $row 2] $cycle}
    }
    set wanted {}
    foreach item $marks {
        lassign $item cycle stage
        if {([llength $stages] && $stage in $stages) || (![llength $stages] && ([string match var_* $stage] || [string match gbe77_* $stage]))} {lappend wanted $stage}
    }
    require [expr {[llength $wanted]>0}] "no requested stages"
    set messages {}; set queues {}; set lengths {}; set rejects {}; set arrivals {}; set frames {}
    foreach es {1 2} {
        set id 0; set release_counts {}
        foreach row [rows [file join $folder es${es}_tx events.txt]] {
            set kind [lindex $row 0]; set cycle [lindex $row 1]
            if {$kind eq "E" && [stage_at $marks $cycle] in $wanted && [lindex $row 2] in {drop_dis drop_full drop_long drop_nopage}} {error "R97: application rejection ES$es at $cycle"}
            if {$kind ne "M"} {continue}
            incr id
            lassign $row kind cycle vl n pen sport dport payload
            set stage [stage_at $marks $cycle]
            require [expr {[string length $payload]==2*$n}] "M payload length ES$es frame$id"
            # Legacy records without O use M as release; no existing metric changes.
            # Variable cases use the host-queue planned release, not actual dispatch.
            set release $cycle; set release_key $stage,$es,$vl
            if {[dict exists $releases $release_key]} {
                set ri 0; if {[dict exists $release_counts $release_key]} {set ri [dict get $release_counts $release_key]}
                require [expr {$ri<[llength [dict get $releases $release_key]]}] "missing planned release $release_key"
                lassign [lindex [dict get $releases $release_key] $ri] release_n release
                require [expr {$release_n==$n}] "planned release length/order mismatch $release_key"
                dict incr release_counts $release_key
            } elseif {[string match var_* $stage]} {error "R97: missing O record $release_key"}
            dict set messages $es $id [dict create cycle $cycle vl $vl n $n payload $payload stage $stage release $release]
            dict lappend queues $es,$vl $id
            if {$stage in $wanted} {dict set lengths $stage $n 1}
        }
        set destination [expr {3-$es}]
        set count {}
        foreach row [rows [file join $folder es${destination}_rx events.txt]] {
            set kind [lindex $row 0]; set cycle [lindex $row 1]; set stage [stage_at $marks $cycle]
            if {$kind eq "E" && [lindex $row 2] eq "rm_drop" && $stage in $wanted} {dict incr rejects $es,$stage}
            if {$kind eq "E" && $stage in $wanted && [regexp {^[ab]_(fcs|len|hdr|unk|cfg|ic|ovf|gdrop)$} [lindex $row 2]]} {error "R97: receive error ES$destination at $cycle"}
            if {$kind ne "D"} {continue}
            lassign $row kind cycle net vl sport dport n payload
            set key $es,$vl; set index 0
            if {[dict exists $count $key]} {set index [dict get $count $key]}
            require [dict exists $queues $key] "D unknown VL $key"
            require [expr {$index<[llength [dict get $queues $key]]}] "extra D $key"
            set id [lindex [dict get $queues $key] $index]; dict incr count $key
            set m [dict get $messages $es $id]
            require [expr {$n==[dict get $m n] && $payload eq [dict get $m payload]}] "D payload/order ES$es frame$id"
            dict set arrivals $es,$id [list $cycle $net $n]
        }
        foreach side {tx rx} {
            set endpoint [expr {$side eq "tx" ? $es : $destination}]
            foreach net {A B} {
                set count {}
                foreach row [rows [file join $folder es${endpoint}_gmii_${side} dump_[string tolower $net].txt]] {
                    lassign $row recorded start n wire
                    require [expr {$recorded eq $net && [string length $wire]==2*$n}] "malformed GMII $endpoint/$side/$net"
                    scan [string range $wire 24 27] %x vlid
                    set vl [expr {$vlid-($es==1 ? 100 : 2000)}]; set key $es,$vl
                    require [dict exists $queues $key] "GMII unknown VL $key"
                    set index 0; if {[dict exists $count $key]} {set index [dict get $count $key]}
                    require [expr {$index<[llength [dict get $queues $key]]}] "extra GMII $key/$side/$net"
                    set id [lindex [dict get $queues $key] $index]; dict incr count $key
                    set m [dict get $messages $es $id]; set size [dict get $m n]
                    require [expr {[string range $wire 100 [expr {99+2*$size}]] eq [dict get $m payload]}] "GMII payload/order ES$es frame$id/$side/$net"
                    if {$side eq "rx"} {
                        require [dict exists $frames $es,$id,tx,$net] "RX without TX"
                        require [expr {$wire eq [lindex [dict get $frames $es,$id,tx,$net] 1]}] "TX/RX bytes differ ES$es frame$id/$net"
                    }
                    dict set frames $es,$id,$side,$net [list $start $wire]
                }
            }
        }
    }
    set out {}
    foreach stage $wanted {
        set begin {}; set end {}
        foreach item $marks {lassign $item cycle label; if {$label eq $stage} {set begin $cycle; continue}; if {$begin ne "" && $cycle>$begin} {set end $cycle; break}}
        if {$end eq ""} {set end [expr {$finalcycle+1}]}
        if {[dict exists $windows $stage begin]} {set begin [dict get $windows $stage begin]}
        if {[dict exists $windows $stage end]} {set end [dict get $windows $stage end]}
        require [expr {$end>$begin}] "invalid window $stage"
        set groups [linsert [lsort -integer [dict keys [dict get $lengths $stage]]] 0 all]
        foreach es {1 2} {
            set direction es${es}_to_es[expr {3-$es}]; set samples {}; set offered 0; set delivered 0; set bytes 0; set interval 0; set previous {}
            foreach id [lsort -integer [dict keys [dict get $messages $es]]] {
                set m [dict get $messages $es $id]
                if {[dict get $m stage] ne $stage} {continue}
                incr offered
                set cycle [dict get $m cycle]; set vl [dict get $m vl]; set n [dict get $m n]
                require [dict exists $arrivals $es,$id] "missing D $stage ES$es frame$id"
                incr delivered; lassign [dict get $arrivals $es,$id] dc winner dn
                incr bytes [expr {max(0,min($dc+$dn,$end)-max($dc,$begin))}]
                set selected [expr {$begin<=$cycle && $cycle<$end}]
                foreach net {A B} {
                    foreach side {tx rx} {require [dict exists $frames $es,$id,$side,$net] "missing $side/$net ES$es frame$id"}
                    set tx [expr {[lindex [dict get $frames $es,$id,tx,$net] 0]+7}]
                    set rx [expr {[lindex [dict get $frames $es,$id,rx,$net] 0]+7}]
                    set bag 125000
                    if {[string match var_* $stage] && ![string match var_high* $stage]} {set bag [lindex {125000 250000 500000 1000000} [expr {$vl/8}]]}
                    if {$selected && [dict exists $previous $vl,$net]} {set interval [expr {max($interval,abs($tx-[dict get $previous $vl,$net]-$bag))}]}
                    dict set previous $vl,$net $tx
                    if {!$selected} {continue}
                    set values [dict create L_gmii [expr {$rx-$tx}] L_tx [expr {$tx-$cycle}]]
                    if {$winner eq $net} {
                        dict set values L_rx [expr {$dc-$rx}]; dict set values L_rx_last [expr {$dc+$n-1-$rx}]
                        dict set values L_app [expr {$dc-$cycle}]; dict set values L_app_last [expr {$dc+$n-1-$cycle}]
                        dict set values L_release_app [expr {$dc-[dict get $m release]}]
                        dict set values L_release_app_last [expr {$dc+$n-1-[dict get $m release]}]
                    }
                    foreach group [list all $n] {
                        dict for {metric value} $values {
                            dict lappend samples $net/$group/$metric [list $vl $id $value]
                            if {$winner eq $net} {dict lappend samples accepted/$group/$metric [list $vl $id $value]}
                        }
                    }
                }
            }
            foreach net {A B accepted} {foreach group $groups {foreach metric {L_gmii L_tx L_rx L_rx_last L_app L_app_last L_release_app L_release_app_last} {
                set sample {}; if {[dict exists $samples $net/$group/$metric]} {set sample [dict get $samples $net/$group/$metric]}
                dict for {stat value} [stats $sample] {dict set out $stage/$direction/$net/$group/$metric/$stat $value}
            }}}
            set prefix $stage/$direction/accepted/all
            dict set out $prefix/throughput/payload_bytes $bytes
            dict set out $prefix/throughput/window_cycles [expr {$end-$begin}]
            dict set out $prefix/offered/messages $offered; dict set out $prefix/delivered/messages $delivered
            set rm 0; if {[dict exists $rejects $es,$stage]} {set rm [dict get $rejects $es,$stage]}
            require [expr {$rm==$offered}] "redundancy count $stage/$direction: $rm != $offered"
            dict set out $prefix/redundancy/rejections $rm; dict set out $prefix/tx_interval_jitter/max $interval
        }
    }
    set f [open [file join $folder r97_tcl.tsv] w]; fconfigure $f -encoding ascii -translation lf
    foreach key [lsort -ascii [dict keys $out]] {puts $f "$key\t[dict get $out $key]"}
    close $f; return $out
}
proc r97::judge_lines {folder {stage_prefix ""}} {
    set results [measure $folder]; set lines {}
    foreach key [lsort -ascii [dict keys $results]] {
        if {![string match */accepted/all/throughput/payload_bytes $key]} {continue}
        lassign [split $key /] stage direction
        if {$stage_prefix ne "" && ![string match ${stage_prefix}* $stage]} {continue}
        set p $stage/$direction/accepted/all
        set rate [expr {[dict get $results $p/throughput/payload_bytes]*1000.0/[dict get $results $p/throughput/window_cycles]}]
        set test tb_sys_perf_var; if {[string match gbe77_* $stage]} {set test tb_sys_perf}
        set line [format {JUDGE METRIC %s stage=%s direction=%s delivered_mbps=%.3f} $test $stage $direction $rate]
        foreach {name metric stat} {l_gmii_max_us L_gmii max l_tx_max_us L_tx max l_rx_max_us L_rx max l_rx_last_max_us L_rx_last max l_app_max_us L_app max l_app_last_max_us L_app_last max jitter_r97_us L_app jitter jitter_r97_gmii_us L_gmii jitter l_release_app_max_us L_release_app max l_release_app_last_max_us L_release_app_last max jitter_r97_release_us L_release_app jitter} {
            set v [dict get $results $p/$metric/$stat]
            if {$v eq "NA"} {set formatted NA} else {set formatted [format %.3f [expr {$v*0.008}]]}
            append line " $name=" $formatted
        }
        append line " tx_interval_jitter_us=" [format %.3f [expr {[dict get $results $p/tx_interval_jitter/max]*0.008}]]
        lappend lines $line
    }
    return $lines
}

# Full official variable-load coverage, intentionally separate from measure:
# short diagnostic runs may measure correctly without meeting this coverage.
proc r97::var_coverage {folder} {
    set required {}
    foreach kind {var_fixed var_cycle var_high var_burst} {
        foreach delay {0 257} {lappend required ${kind}_d${delay}}
    }
    set marks {}; set windows {}; set bases {}; set observed {}; set stage ""
    foreach row [rows [file join $folder sys_events.txt]] {
        set type [lindex $row 0]
        if {$type eq "P"} {
            lassign $row type cycle stage
            lappend marks [list $cycle $stage]
            if {[string match var_* $stage]} {
                require [expr {$stage in $required}] "unexpected variable stage $stage"
                require [expr {![dict exists $observed $stage]}] "duplicate variable stage $stage"
                dict set observed $stage 1
            }
        }
        if {$type eq "F" && [lindex $row 2] in {begin end}} {
            lassign $row type cycle edge label
            require [expr {![dict exists $windows $label $edge]}] "duplicate window edge $label/$edge"
            dict set windows $label $edge $cycle
        }
        if {$type eq "O" && $stage in $required} {
            require [expr {[llength $row]==6}] "malformed planned release row"
            lassign $row type actual es vl n planned
            require [expr {$es in {1 2} && [string is integer -strict $planned]}] "invalid planned release row"
            if {![dict exists $bases $stage $es] || $planned<[dict get $bases $stage $es]} {
                dict set bases $stage $es $planned
            }
        }
    }
    foreach name $required {require [dict exists $observed $name] "missing variable stage $name"}
    set counts {}; set lengths {}
    foreach es {1 2} {
        foreach row [rows [file join $folder es${es}_tx events.txt]] {
            if {[lindex $row 0] ne "M"} {continue}
            lassign $row type cycle vl n
            set name [stage_at $marks $cycle]
            if {$name ni $required} {continue}
            require [expr {[dict exists $windows $name begin] && [dict exists $windows $name end]}] "missing window $name"
            set expected_vls [expr {[string match var_high_* $name] ? 80 : 32}]
            require [expr {$vl>=0 && $vl<$expected_vls}] "out-of-range VL $name/ES$es/$vl"
            require [expr {$n in {1 17 256 1024 1471}}] "unexpected payload length $name/ES$es/$n"
            if {$cycle>=[dict get $windows $name begin] && $cycle<[dict get $windows $name end]} {
                dict incr counts $name,$es,$vl
                dict set lengths $name $es $n 1
            }
        }
    }
    set result {}; set checks 0
    foreach name $required {
        require [expr {[dict exists $windows $name begin] && [dict exists $windows $name end]}] "missing window $name"
        set high [string match var_high_* $name]
        set expected_vls [expr {$high ? 80 : 32}]
        set warm [expr {$high ? 250000 : 2000000}]
        set duration [expr {[dict get $windows $name end]-[dict get $windows $name begin]}]
        set required_duration [expr {$high ? 2500000 : 8000000}]
        require [expr {$duration>=2500000 && $duration>=$required_duration}] "short measurement window $name: $duration"
        incr checks
        foreach es {1 2} {
            require [dict exists $bases $name $es] "missing planned release base $name/ES$es"
            set preheat [expr {[dict get $windows $name begin]-[dict get $bases $name $es]}]
            require [expr {$preheat>=$warm}] "short warmup $name/ES$es: $preheat"
            require [dict exists $lengths $name $es] "no measured messages $name/ES$es"
            require [expr {[lsort -integer [dict keys [dict get $lengths $name $es]]] eq {1 17 256 1024 1471}}] "missing measured lengths $name/ES$es"
            set minimum {}
            for {set vl 0} {$vl<$expected_vls} {incr vl} {
                require [dict exists $counts $name,$es,$vl] "missing measured VL $name/ES$es/$vl"
                set count [dict get $counts $name,$es,$vl]
                require [expr {$count>=8}] "fewer than eight frames $name/ES$es/$vl: $count"
                if {$minimum eq "" || $count<$minimum} {set minimum $count}
                incr checks
            }
            dict set result $name es$es [dict create vls $expected_vls window_cycles $duration warmup_cycles $preheat min_frames_per_vl $minimum lengths {1 17 256 1024 1471}]
            incr checks 3
        }
    }
    dict set result all_frame_latency [all_frame_limits $folder $marks $required]
    dict set result checks $checks
    dict set result passed 1
    return $result
}

# Check latency over every offered message, including warmup and drain.
# This does not change the window-selected canonical measurement fields.
proc r97::all_frame_limits {folder marks required} {
    set result {}
    foreach es {1 2} {
        set queues {}; set messages {}; set id 0
        foreach row [rows [file join $folder es${es}_tx events.txt]] {
            if {[lindex $row 0] ne "M"} {continue}
            lassign $row kind cycle vl n
            incr id; dict lappend queues $vl $id
            dict set messages $id [list $cycle [stage_at $marks $cycle]]
        }
        set destination [expr {3-$es}]; set counts {}; set delivered {}
        foreach row [rows [file join $folder es${destination}_rx events.txt]] {
            if {[lindex $row 0] ne "D"} {continue}
            lassign $row kind cycle net vl
            set index 0; if {[dict exists $counts $vl]} {set index [dict get $counts $vl]}
            require [dict exists $queues $vl] "all-frame D unknown VL ES$es/$vl"
            require [expr {$index<[llength [dict get $queues $vl]]}] "all-frame extra D ES$es/$vl"
            set id [lindex [dict get $queues $vl] $index]; dict incr counts $vl
            dict set delivered $id $cycle
        }
        set frames {}
        foreach side {tx rx} {
            set endpoint [expr {$side eq "tx" ? $es : $destination}]
            foreach net {A B} {
                set counts {}
                foreach row [rows [file join $folder es${endpoint}_gmii_${side} dump_[string tolower $net].txt]] {
                    lassign $row recorded cycle n wire
                    scan [string range $wire 24 27] %x vlid
                    set vl [expr {$vlid-($es==1 ? 100 : 2000)}]
                    set index 0; if {[dict exists $counts $vl]} {set index [dict get $counts $vl]}
                    require [dict exists $queues $vl] "all-frame GMII unknown VL ES$es/$vl"
                    require [expr {$index<[llength [dict get $queues $vl]]}] "all-frame extra GMII ES$es/$vl"
                    set id [lindex [dict get $queues $vl] $index]; dict incr counts $vl
                    dict set frames $id,$side,$net [expr {$cycle+7}]
                }
            }
        }
        dict for {id item} $messages {
            lassign $item cycle stage
            if {$stage ni $required} {continue}
            require [dict exists $delivered $id] "all-frame missing D ES$es frame$id"
            set app [expr {[dict get $delivered $id]-$cycle}]
            require [expr {$app>=0 && $app<=250000}] "all-frame L_app >2ms or negative $stage/ES$es/frame$id: $app"
            set key $stage/es$es
            if {![dict exists $result $key]} {dict set result $key [dict create messages 0 L_app_max 0 L_gmii_max 0]}
            set item [dict get $result $key]; dict incr item messages
            dict set item L_app_max [expr {max([dict get $item L_app_max],$app)}]
            foreach net {A B} {
                foreach side {tx rx} {require [dict exists $frames $id,$side,$net] "all-frame missing GMII ES$es/frame$id/$side/$net"}
                set gmii [expr {[dict get $frames $id,rx,$net]-[dict get $frames $id,tx,$net]}]
                require [expr {$gmii>=0 && $gmii<=250000}] "all-frame L_gmii >2ms or negative $stage/ES$es/frame$id/$net: $gmii"
                dict set item L_gmii_max [expr {max([dict get $item L_gmii_max],$gmii)}]
            }
            dict set result $key $item
        }
    }
    return $result
}
