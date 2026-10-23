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
    foreach row [rows [file join $folder sys_events.txt]] {
        set kind [lindex $row 0]; set cycle [lindex $row 1]
        if {[string is integer -strict $cycle]} {set finalcycle [expr {max($finalcycle,$cycle)}]}
        if {$kind eq "P"} {lappend marks [list $cycle [lindex $row 2]]}
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
        set id 0
        foreach row [rows [file join $folder es${es}_tx events.txt]] {
            set kind [lindex $row 0]; set cycle [lindex $row 1]
            if {$kind eq "E" && [stage_at $marks $cycle] in $wanted && [lindex $row 2] in {drop_dis drop_full drop_long drop_nopage}} {error "R97: application rejection ES$es at $cycle"}
            if {$kind ne "M"} {continue}
            incr id
            lassign $row kind cycle vl n pen sport dport payload
            set stage [stage_at $marks $cycle]
            require [expr {[string length $payload]==2*$n}] "M payload length ES$es frame$id"
            dict set messages $es $id [dict create cycle $cycle vl $vl n $n payload $payload stage $stage]
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
                    }
                    foreach group [list all $n] {
                        dict for {metric value} $values {
                            dict lappend samples $net/$group/$metric [list $vl $id $value]
                            if {$winner eq $net} {dict lappend samples accepted/$group/$metric [list $vl $id $value]}
                        }
                    }
                }
            }
            foreach net {A B accepted} {foreach group $groups {foreach metric {L_gmii L_tx L_rx L_rx_last L_app L_app_last} {
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
        foreach {name metric stat} {l_gmii_max_us L_gmii max l_tx_max_us L_tx max l_rx_max_us L_rx max l_rx_last_max_us L_rx_last max l_app_max_us L_app max l_app_last_max_us L_app_last max jitter_r97_us L_app jitter jitter_r97_gmii_us L_gmii jitter} {
            set v [dict get $results $p/$metric/$stat]
            if {$v eq "NA"} {set formatted NA} else {set formatted [format %.3f [expr {$v*0.008}]]}
            append line " $name=" $formatted
        }
        append line " tx_interval_jitter_us=" [format %.3f [expr {[dict get $results $p/tx_interval_jitter/max]*0.008}]]
        lappend lines $line
    }
    return $lines
}
