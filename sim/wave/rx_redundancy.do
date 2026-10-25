# b_late 场景：A 先交付，晚 2002 拍的 B 副本被去重。
source [file join [pwd] sim wave common.do]
wave_setup rx_redundancy tb_sys_delay
set dut /tb_sys_delay/suite/es2/dut
foreach name {rx_valid rx_data rx_valid_b rx_data_b ev_deliver app_rx_valid app_rx_data app_rx_last app_rx_net ev_rm_drop} {
    wave_signal $dut/$name $name
}
run 3040us
set cursor_a [wave cursor add -time 3014236ns -name A_delivered]
set cursor_b [wave cursor add -time 3030252ns -name B_duplicate]
wave cursor active $cursor_a
wave_snapshot rx_redundancy_1 3014186ns 3014446ns
wave cursor active $cursor_b
wave_snapshot rx_redundancy_2 3030026ns 3030286ns
