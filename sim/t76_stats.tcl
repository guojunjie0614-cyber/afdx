# Independent Tcl implementation: parses only public application and GMII files.
# No Python output, DUT hierarchy, or helper statistics are read.
proc require {ok message} {if {!$ok} {error $message}}
proc read_rows {path} {
    set fd [open $path r];set text [read $fd];close $fd
    set rows {}
    foreach line [split [string trim $text] "\n"] {
        set words [regexp -all -inline {\S+} $line]
        if {[llength $words]} {lappend rows $words}
    }
    return $rows
}
proc overlap {a b begin end} {return [expr {max(0,min($b,$end)-max($a,$begin))}]}
proc main {folder} {
    lassign [lindex [read_rows [file join $folder window.txt]] 0] begin end vls length mixed duplex burst
    if {$burst eq ""} {set burst 0}
    set result [dict create window/begin $begin window/end $end window/cycles [expr {$end-$begin}]]
    for {set source 0} {$source <= $duplex} {incr source} {
        set tx [read_rows [file join $folder ep${source}_tx.txt]]
        set destination [expr {1-$source}]
        set rx [read_rows [file join $folder ep${destination}_rx.txt]]
        set received [dict create]
        foreach r $rx {
            lassign $r type first last vl n sequence payload
            require [expr {[string length $payload]==2*$n && $last-$first+1==$n+2}] "RX record length"
            set key $vl/$sequence
            require [expr {![dict exists $received $key]}] "duplicate RX key"
            dict set received $key $r
        }
        set previous [dict create];set indices [dict create];set predecessors [dict create]
        set frame_first [dict create];set frame_complete [dict create]
        foreach frame [read_rows [file join $folder ep${source}_a.txt]] {
            lassign $frame start finish wire
            scan [string range $wire 24 27] %x vlid
            scan [string range $wire 56 59] %x fragment
            set vl [expr {$vlid-256}]
            if {($fragment & 8191)==0} {
                set sequence [expr {[dict exists $indices $vl] ? [dict get $indices $vl] : 0}]
                if {[dict exists $previous $vl]} {dict set predecessors $vl/$sequence [dict get $previous $vl]}
                dict set frame_first $vl/$sequence $start
                dict set indices $vl [expr {$sequence+1}]
            }
            if {($fragment & 8192)==0} {
                dict set frame_complete $vl/[expr {[dict get $indices $vl]-1}] $finish
            }
            dict set previous $vl $start
        }
        set buckets [dict create];set inject_total 0;set receive_total 0
        set page_events {};set pairs 0;set pair_failures 0
        foreach t $tx {
            lassign $t type first last vl n sequence planned payload
            require [expr {[string length $payload]==2*$n && $last-$first+1==$n+2}] "TX record length"
            incr inject_total [overlap [expr {$first+2}] [expr {$last+1}] $begin $end]
            set pages [expr {($n+511)/512}]
            lappend page_events [list $first $pages]
            if {[dict exists $frame_complete $vl/$sequence]} {
                lappend page_events [list [expr {[dict get $frame_complete $vl/$sequence]+1}] [expr {-$pages}]]
            }
            set prior_key $vl/[expr {$sequence-1}]
            if {$burst && $sequence%2 && [dict exists $frame_first $vl/$sequence] && [dict exists $frame_first $prior_key]} {
                incr pairs
                set gap [expr {[dict get $frame_first $vl/$sequence]-[dict get $frame_first $prior_key]}]
                set bound [expr {[dict get $frame_first $prior_key]+125000-$last}]
                if {$gap<125000 || $bound<=0} {incr pair_failures}
            }
            if {![dict exists $received $vl/$sequence]} {continue}
            set r [dict get $received $vl/$sequence]
            lassign $r rtype rf rl rv rn rq rp
            require [expr {$payload eq $rp && $rn==$n}] "public application bytes differ"
            set wait [expr {$burst && $sequence%2}]
            dict lappend buckets $vl/$n [list $first $rl [expr {$rl-$first}] $wait $last $rf]
        }
        foreach r $rx {
            lassign $r type first last vl n sequence payload
            incr receive_total [overlap [expr {$first+2}] [expr {$last+1}] $begin $end]
        }
        foreach key [dict keys $buckets] {
            set rows [lsort -integer -index 0 [dict get $buckets $key]]
            set cold [lindex $rows 0];set worst $cold;set minimum [lindex $cold 2];set all_wait 1
            foreach row $rows {
                if {[lindex $row 2]>[lindex $worst 2]} {set worst $row}
                set minimum [expr {min($minimum,[lindex $row 2])}]
                set all_wait [expr {$all_wait && [lindex $row 3]}]
            }
            set deduction [expr {$burst ? 125000 : 0}]
            set minimum_target [expr {$burst ? [lindex $cold 2] : $minimum}]
            set raw [expr {[lindex $worst 2]-$minimum_target}]
            set jitter [expr {$raw-$deduction}]
            set valid [expr {$jitter>=0 && (!$burst || $raw>125000)}]
            lassign [split $key /] vl n
            set inject 0;set payload_bytes 0
            foreach t $tx {
                lassign $t type first last tv tn sequence planned body
                if {$tv==$vl && $tn==$n} {incr inject [overlap [expr {$first+2}] [expr {$last+1}] $begin $end]}
            }
            foreach r $rx {
                lassign $r type first last rv rn sequence body
                if {$rv==$vl && $rn==$n} {incr payload_bytes [overlap [expr {$first+2}] [expr {$last+1}] $begin $end]}
            }
            set values [dict create samples [llength $rows] first_min [lindex $cold 2] observed_min $minimum \
                maximum [lindex $worst 2] deduction $deduction jitter $jitter formula_valid $valid \
                inject_bytes $inject receive_bytes $payload_bytes first_tx [lindex $cold 0] \
                first_rx [lindex $cold 1] worst_tx [lindex $worst 0] worst_rx [lindex $worst 1]]
            foreach metric [dict keys $values] {dict set result $source/$key/$metric [dict get $values $metric]}
        }
        dict set result $source/total/inject_bytes $inject_total
        dict set result $source/total/receive_bytes $receive_total
        dict set result $source/total/tx_messages [llength $tx]
        dict set result $source/total/rx_messages [llength $rx]
        set used 0;set peak 0
        foreach event [lsort -integer -index 0 [lsort -integer -index 1 $page_events]] {
            incr used [lindex $event 1];set peak [expr {max($peak,$used)}]
        }
        dict set result $source/total/page_upper_bound $peak
        dict set result $source/total/bag_pairs $pairs
        dict set result $source/total/bag_pair_failures $pair_failures
    }
    set fd [open [file join $folder t76_tcl.tsv] w]
    fconfigure $fd -encoding ascii -translation lf
    foreach key [lsort [dict keys $result]] {puts $fd "$key\t[dict get $result $key]"}
    close $fd
    puts "T76 TCL STATS keys=[dict size $result]"
}
if {$argc!=1} {error "usage: t76_stats.tcl RUN_FOLDER"}
main [file normalize [lindex $argv 0]]
