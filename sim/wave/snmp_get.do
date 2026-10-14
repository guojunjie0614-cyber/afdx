# 第一笔 Get：管理请求到达代理，代理从双网发出 Response。
source [file join [pwd] sim wave common.do]
wave_setup snmp_get tb_judge_snmp
set dut /tb_judge_snmp/agent/dut
foreach name {rx_valid rx_data rx_valid_b rx_data_b tx_valid tx_data tx_valid_b tx_data_b} {
    wave_signal $dut/$name $name
}
wave_signal $dut/snmp/requests SNMP_requests unsigned
run 550us
wave_print 524500ns 540000ns
