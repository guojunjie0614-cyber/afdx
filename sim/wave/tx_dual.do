# 应用消息经发送核心同时送至 A、B GMII。
source [file join [pwd] sim wave common.do]
wave_setup tx_dual tb_sys_net
set dut /tb_sys_net/suite/es1/dut
foreach name {app_tx_valid app_tx_ready app_tx_data app_tx_last app_tx_vl tx_valid tx_data tx_valid_b tx_data_b} {
    wave_signal $dut/$name $name
}
run 800us
wave cursor add -time 688108ns -name {Dual GMII start}
wave_print 685900ns 688900ns
