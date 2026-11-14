# Official post-synthesis reproduction, prepared by tools/run_load_sim.py.
# The implementation-simulation .vo source is replaced by synth_1's .vqm;
# official_inputs.tcl records that VQM simulation copy and unchanged vendor libs.
# Run: vsim -batch -do "do sim/run_load_post_synth.do PREPARED_RUN_FOLDER"
# External batch tools avoid the host's unavailable vish/vsim RPC transport.
onerror {quit -code 1}
onbreak {quit -code 1}
proc load_official {folder} {
    set folder [file normalize $folder]
    cd $folder
    source [file join $folder official_inputs.tcl]
    set vqm 0
    foreach path $load_sources {if {[file extension $path] eq ".vqm"} {incr vqm}}
    if {$vqm!=1} {error "exactly one official VQM is required in place of .vo"}
    set tools $::env(MODELSIM_HOME)
    if {[info exists ::env(MODELSIM)]} {unset ::env(MODELSIM)}
    exec [file join $tools vlib.exe] work > official_vlib.log 2>@1
    exec [file join $tools vlog.exe] -vlog01compat +define+AFDX_CE_DIV=2 {*}$load_sources > official_compile.log 2>@1
    exec [file join $tools vsim.exe] -batch -t 1ps work.tb_t76_load {*}$load_parameters \
        -wlf simulation.wlf -do {do run.do} > simulation.log 2>@1
    set fd [open simulation.log r];set report [read $fd];close $fd
    puts $report
    if {![regexp {\[RESULT\] tb_t76_load PASS checks=[0-9]+ errors=0} $report]} {error "official VQM self-check did not pass"}
    puts "LOAD OFFICIAL .VO TO .VQM ENTRY PASS"
}
if {$argc!=1} {error "one prepared run folder is required"}
set failed [catch {load_official [set 1]} message]
if {$failed} {puts "LOAD OFFICIAL ENTRY FAIL: $message"}
quit -code $failed
