# 在仓库根目录调用场景脚本；工作库、日志和原始截图只写 out/wave。
proc wave_setup {scenario test} {
    global wave_root wave_output
    set wave_root [file normalize [pwd]]
    if {![file exists [file join $wave_root rtl AFDX_top.v]]} {
        error "First cd to the package root, then do sim/wave/<scene>.do"
    }
    catch {quit -sim}
    set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
    set wave_output [file join $wave_root out wave ${scenario}_${stamp}_[pid]]
    file mkdir [file join $wave_output vectors]
    cd $wave_output
    transcript file [file join $wave_output simulation.log]
    transcript on
    if {$test in {tb_sys_net tb_sys_delay tb_tx_bag}} {
        if {[info exists ::env(AFDX_PYTHON)]} {
            set python [list $::env(AFDX_PYTHON)]
        } else {set python [auto_execok python]}
        if {![llength $python]} {error "Python is required for this test's input vectors"}
        set generator [expr {$test eq "tb_tx_bag" ? "afdx_ref.py" : "sys_cases.py"}]
        set command [concat $python [list -X utf8 [file join $wave_root tools $generator]]]
        if {$test eq "tb_tx_bag"} {lappend command vectors}
        lappend command --test $test --seed 20261007 --out [file join $wave_output vectors]
        puts [exec {*}$command]
        foreach sub {es1_tx es1_rx es2_tx es2_rx es1_gmii_tx es1_gmii_rx es2_gmii_tx es2_gmii_rx} {
            file mkdir [file join $wave_output $sub]
        }
    }
    vmap -c
    set ini [file join $wave_output modelsim.ini]
    vlib [file join $wave_output work]
    vmap -modelsimini $ini work [file join $wave_output work]
    if {[info exists ::env(AFDX_PYTHON)]} {
        set python [list $::env(AFDX_PYTHON)]
    } else {set python [auto_execok python]}
    if {![llength $python]} {error "Python is required to prepare isolated ModelSim sources"}
    set source_root [file join $wave_output source_tree]
    puts [exec {*}$python -I -X utf8 [file join $wave_root tools prepare_modelsim_sources.py] --out $source_root]
    set sources [concat [lsort [glob [file join $source_root rtl *.v]]] \
        [lsort [glob [file join $source_root tb lib *.v]]] \
        [list [file join $source_root tb ${test}.v]]]
    vlog -modelsimini $ini -work work -vlog01compat +incdir+[file join $source_root tb lib] {*}$sources
    vsim -modelsimini $ini -t 1ps -voptargs=+acc -onfinish stop \
        -wlf [file join $wave_output simulation.wlf] work.$test
    # 只设置窗口布局，颜色沿用 ModelSim 默认值。
    set wave_window [view wave -undock -title Wave -width 1880 -height 650 -x 0 -y 0]
    set wave_top [winfo toplevel $wave_window]
    set width [expr {min(1880, [winfo screenwidth $wave_window] - 32)}]
    set height [expr {min(650, [winfo screenheight $wave_window] - 100)}]
    wm maxsize $wave_top $width $height
    wm geometry $wave_top ${width}x${height}+0+0
    catch {delete wave *}
    catch {wave cursor delete 1}
    configure wave -displayfreq 0 -namecolwidth 180 -valuecolwidth 100 \
        -signalnamewidth 0 -timelineunits us
}

# ModelSim exposes time through Tcl variables, not a `now` command.
# Numeric $now values use $resolution; formatted values carry their own unit.
proc wave_now_ns {} {
    set unit {};set value 0
    scan $::now {%f %s} value unit
    if {$unit eq {}} {
        if {![regexp {^([0-9.]+)\s*(fs|ps|ns|us|ms|sec)$} $::resolution match step unit]} {
            error "Unsupported simulator resolution: $::resolution"
        }
        set value [expr {$value*$step}]
    }
    set scales [dict create fs 0.000001 ps 0.001 ns 1 us 1000 ms 1000000 sec 1000000000]
    if {![dict exists $scales $unit]} {error "Unsupported simulator time unit: $::now"}
    return [expr {$value*[dict get $scales $unit]}]
}

proc wave_signal {path label {radix hexadecimal}} {
    log $path
    add wave -label $label -radix $radix $path
}

proc wave_snapshot {name start end} {
    global wave_output
    set window [view wave]
    set top [winfo toplevel $window]
    wm deiconify $top
    wave zoom range $start $end
    update
    puts "WAVE_WINDOW $name $start $end"
    set fh [open [file join $wave_output windows.txt] a]
    puts $fh "$name $start $end"
    close $fh
    # 手工 do 时停留在同样的真实 Wave 视图；自动导出时由 PrintWindow 截图。
    if {[info exists ::env(AFDX_WAVE_CAPTURE_DIR)]} {
        set directory $::env(AFDX_WAVE_CAPTURE_DIR)
        set done [file join $directory ${name}.done]
        set request [file join $directory capture_request.txt]
        set fh [open ${request}.tmp w]
        puts $fh [pid]
        puts $fh $name
        puts $fh "$start $end"
        close $fh
        file rename -force ${request}.tmp $request
        set deadline [expr {[clock seconds] + 60}]
        while {![file exists $done]} {
            if {[clock seconds] >= $deadline} {error "Wave window capture timed out: $name"}
            after 100
            update
        }
    }
}
