# 在仓库根目录调用场景脚本；工作库、日志与原生打印文件只写 out/wave。
proc wave_setup {scenario test} {
    global wave_root wave_output wave_height PrefWave
    set wave_root [file normalize [pwd]]
    set wave_height 2.8
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
    set sources [concat [lsort [glob [file join $wave_root rtl *.v]]] \
        [lsort [glob [file join $wave_root tb lib *.v]]] \
        [list [file join $wave_root tb ${test}.v]]]
    vlog -modelsimini $ini -work work -vlog01compat +incdir+[file join $wave_root tb lib] {*}$sources
    vsim -modelsimini $ini -t 1ps -voptargs=+acc -onfinish stop \
        -wlf [file join $wave_output simulation.wlf] work.$test
    # 设置白底、深色文字和信号，便于打印。
    set PrefWave(waveBackground) White
    set PrefWave(waveStripBackground) White
    set PrefWave(background) White
    set PrefWave(background2) White
    set PrefWave(textColor) Black
    set PrefWave(foreground) Black
    set PrefWave(waveForeground) Black
    set PrefWave(displayfreq) 0
    set PrefWave(vectorColor) navy
    set PrefWave(timeColor) Black
    set PrefWave(cursorColor) red
    set PrefWave(cursorDeltaColor) Black
    set PrefWave(gridColor) grey75
    set PrefWave(activeRowBackground) White
    view wave
    catch {wm geometry . 1800x800+0+0}
    catch {delete wave *}
    configure wave -foreground Black -wavebackground White -wavestripbackground White \
        -textcolor Black -timecolor Black -cursorcolor red -cursordeltacolor Black \
        -displayfreq 0 -namecolwidth 205 -valuecolwidth 85 -signalnamewidth 0 -timelineunits us
}

proc wave_signal {path label {radix hexadecimal}} {
    log $path
    add wave -label $label -radix $radix -color navy $path
}

proc wave_print {start end {name wave.ps}} {
    global wave_root wave_output wave_height
    wave zoom range $start $end
    update
    write wave [file join $wave_output $name] -start $start -end $end \
        -portrait -width 14 -height $wave_height -margin 0.2
    puts "WAVE_OUTPUT $wave_output"
    puts "WAVE_WINDOW $start $end"
    set fh [open [file join $wave_output ready.txt] w]
    puts $fh "$start $end"
    close $fh
}
