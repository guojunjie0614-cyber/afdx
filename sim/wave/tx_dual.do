# 应用消息经发送核心同时送至 A、B GMII。
source [file join [pwd] sim wave common.do]
wave_setup tx_dual tb_sys_net
set dut /tb_sys_net/suite/es1/dut
foreach name {app_tx_valid app_tx_ready app_tx_data app_tx_last app_tx_vl tx_valid tx_data tx_valid_b tx_data_b} {
    wave_signal $dut/$name $name
}
run 800us
wave cursor add -time 688108ns -name GMII_start
wave_snapshot tx_dual_1 685900ns 688900ns
wave_snapshot tx_dual_2 688100ns 688420ns
