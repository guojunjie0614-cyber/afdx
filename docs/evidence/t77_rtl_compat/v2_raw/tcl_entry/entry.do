onerror {quit -code 1}
source {E:/2026_Embedded_FPGA/worktrees/active/c3_t77/sim/modelsim_compat.tcl}
set root {E:/2026_Embedded_FPGA/worktrees/active/c3_t77}
unset -nocomplain ::env(AFDX_MODELSIM_DECL_ORDER)
set a [afdx_modelsim_rtl $root [pwd]]
if {[llength $a] != 34} {error "default source count"}
set ::env(AFDX_MODELSIM_DECL_ORDER) 0
set b [afdx_modelsim_rtl $root [pwd]]
if {$a ne $b} {error "direct paths differ"}
puts "T77_TCL_DIRECT_DEFAULT_PASS files=[llength $a]"
quit -code 0
