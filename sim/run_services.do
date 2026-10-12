# ModelSim 独立入口：无需 Python 或 PowerShell；五项功能含615A先加载再卸载。
# 在 ModelSim 中先 cd 到提交包根目录，再执行 do sim/run_services.do。
# 每次运行使用新的 out/modelSim 目录，保留日志、抓包和波形。
onerror {quit -f -code 1}
set root [file normalize [pwd]]
if {![file exists [file join $root rtl AFDX_top.v]]} {
    error "First cd to the package root, then do sim/run_services.do"
}
set stamp [clock format [clock seconds] -format %Y%m%d_%H%M%S]
set result_dir [file join $root out modelsim ${stamp}_[pid]]
if {[file exists $result_dir]} {error "Output directory already exists: $result_dir"}
file mkdir [file join $result_dir vectors]
foreach name {bytes.hex offsets.txt} {
    file copy [file join $root sim vectors net_services $name] [file join $result_dir vectors $name]
}
cd $result_dir
set log_file [file join $result_dir simulation.log]
transcript file $log_file
transcript on
vmap -c
set local_ini [file join $result_dir modelsim.ini]
vlib [file join $result_dir work]
vmap -modelsimini $local_ini work [file join $result_dir work]
set sources [concat [lsort [glob [file join $root rtl *.v]]] \
                    [lsort [glob [file join $root tb lib *.v]]] \
                    [list [file join $root tb tb_net_services.v]]]
vlog -modelsimini $local_ini -work work -vlog01compat +incdir+[file join $root tb lib] {*}$sources
vsim -modelsimini $local_ini -t 1ps -voptargs=+acc -onfinish stop \
     -wlf [file join $result_dir simulation.wlf] work.tb_net_services
log /tb_net_services/clk /tb_net_services/reset /tb_net_services/phase \
    /tb_net_services/va12 /tb_net_services/vb12 /tb_net_services/va21 /tb_net_services/vb21 \
    /tb_net_services/a12 /tb_net_services/b12 /tb_net_services/a21 /tb_net_services/b21 \
    /tb_net_services/rm1 /tb_net_services/rm2 /tb_net_services/ic2 \
    /tb_net_services/difference /tb_net_services/status_value \
    /tb_net_services/es1/d_valid /tb_net_services/es1/d_data /tb_net_services/es1/d_last \
    /tb_net_services/es2/d_valid /tb_net_services/es2/d_data /tb_net_services/es2/d_last \
    /tb_net_services/es1/wr /tb_net_services/es1/rd /tb_net_services/es1/address \
    /tb_net_services/es1/wdata /tb_net_services/es1/rdata /tb_net_services/es1/rvalid
if {![batch_mode]} {
    view wave
    add wave -group Clock /tb_net_services/clk /tb_net_services/reset
    add wave -group GMII -radix hexadecimal /tb_net_services/va12 /tb_net_services/a12 \
             /tb_net_services/vb12 /tb_net_services/b12 /tb_net_services/va21 /tb_net_services/a21
    add wave -group Application -radix hexadecimal /tb_net_services/es1/d_valid \
             /tb_net_services/es1/d_data /tb_net_services/es1/d_last \
             /tb_net_services/es2/d_valid /tb_net_services/es2/d_data /tb_net_services/es2/d_last
    add wave -group Integrity -radix unsigned /tb_net_services/rm1 /tb_net_services/rm2 /tb_net_services/ic2
    add wave -group Services -radix decimal /tb_net_services/phase /tb_net_services/difference /tb_net_services/status_value
    add wave -group Configuration -radix hexadecimal /tb_net_services/es1/wr /tb_net_services/es1/rd \
             /tb_net_services/es1/address /tb_net_services/es1/wdata /tb_net_services/es1/rdata /tb_net_services/es1/rvalid
    configure wave -namecolwidth 190 -valuecolwidth 90 -timelineunits us
}
run -all
# 关闭并读回本次日志，以平台自己输出的最终 PASS 为成功条件。
transcript file ""
set fh [open $log_file r]
set log_text [read $fh]
close $fh
if {![regexp {\[RESULT\] tb_net_services PASS checks=([0-9]+) errors=0} $log_text match count]} {
    error "tb_net_services did not print PASS; see $log_file"
}
set fh [open [file join $result_dir result.txt] w]
puts $fh "PASS checks=$count errors=0"
puts $fh "test=tb_net_services"
puts $fh "log=$log_file"
close $fh
puts "MODELSIM ENTRY PASS checks=$count errors=0"
puts "Outputs: $result_dir"
if {![batch_mode]} {wave zoom full}
# GUI 模式保留波形供查看；命令行模式返回成功退出码。
if {[batch_mode]} {quit -f -code 0}
