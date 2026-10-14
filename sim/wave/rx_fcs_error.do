# 单个损坏帧令 A 网 FCS 计数从 0 变 1；第二幅原生视图显示总线读回。
source [file join [pwd] sim wave common.do]
wave_setup rx_fcs_error tb_sys_net
set dut /tb_sys_net/suite/es2/dut
set wave_height 3.3
foreach name {rx_valid rx_data rx_valid_b app_rx_valid ev_a cfg_rd cfg_addr cfg_rvalid cfg_rdata} {
    wave_signal $dut/$name $name
}
wave_signal $dut/app_rx_net {app_rx_net (1=B)} binary
wave_signal $dut/ev_a(1) {ev_a[1] FCS error} binary
wave_signal $dut/cfg_regs/count_a_fcs {A FCS error count} unsigned
run 980us
wave_print 798350ns 799600ns
wave_print 972580ns 972616ns counter_read.ps
# GUI 最终保留错误帧窗口；第二幅可在 Transcript 中 wave zoom range 972580ns 972616ns。
wave zoom range 798350ns 799600ns
