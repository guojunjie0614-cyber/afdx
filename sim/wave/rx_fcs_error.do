# 单个损坏帧令 A 网 FCS 计数从 0 变 1；第二幅显示独立的配置读回。
source [file join [pwd] sim wave common.do]
wave_setup rx_fcs_error tb_sys_net
set dut /tb_sys_net/suite/es2/dut
set host /tb_sys_net/suite/es2
set wave_height 3.3
foreach name {rx_valid rx_data rx_valid_b app_rx_valid ev_a cfg_rd cfg_addr cfg_rvalid cfg_rdata} {
    wave_signal $dut/$name $name
}
wave_signal $dut/app_rx_net {app_rx_net (1=B)} binary
wave_signal $dut/ev_a(1) {ev_a[1] FCS error} binary
wave_signal $dut/cfg_regs/count_a_fcs {A FCS error count} unsigned
log $dut/clk $dut/host_read_pipe
# 测试平台在 972.532--972.742 us 连续逐拍读多个地址，rvalid 因此连续为高。
# 此端点在错误帧前没有读过 0x49。等原读突发结束后追加一个独立请求，
# 仅通过公开配置输入驱动真实 RTL；测试平台原有的两拍响应检查仍然运行。
run 973us
if {[examine -radix unsigned $dut/cfg_rd] != 0 ||
    [examine -radix unsigned $dut/cfg_rvalid] != 0 ||
    [examine -radix unsigned $dut/cfg_regs/count_a_fcs] != 1} {
    error "Expected an idle host port and one A-network FCS error"
}
force -deposit $host/cfg_addr 18'h00049
force -deposit $host/cfg_rd 1
run 8ns
force -deposit $host/cfg_rd 0
run 5ns
if {[examine -radix unsigned $dut/cfg_rvalid] != 1 ||
    [examine -radix unsigned $dut/cfg_rdata] != 1} {
    error "The second sampling edge must return cfg_rvalid=1 and cfg_rdata=1"
}
run 27ns
wave_print 798350ns 799600ns
delete wave *
add wave -divider {Read 0x49: two clock edges}
wave_signal $dut/clk clk binary
wave_signal $dut/cfg_rd {cfg_rd (one clock)} binary
wave_signal $dut/cfg_addr {cfg_addr (hex)}
wave_signal $dut/host_read_pipe {host_read_pipe [1:0]} binary
wave_signal $dut/cfg_rvalid cfg_rvalid binary
wave_signal $dut/cfg_rdata {cfg_rdata (hex)}
wave_signal $dut/cfg_regs/count_a_fcs {A FCS error count} unsigned
set wave_height 2.5
wave_print 972992ns 973040ns counter_read.ps
run -all
if {[examine -radix unsigned /tb_sys_net/suite/errors] != 0 ||
    [examine -radix unsigned $host/errors] != 0} {
    error "The waveform simulation's self-checks failed"
}
# GUI 最终保留独立读窗口；错误帧窗口为 798350ns--799600ns。
wave zoom range 972992ns 973040ns
