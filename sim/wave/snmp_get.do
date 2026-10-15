# 第一笔 Get：管理请求到达代理，代理从双网发出 Response。
source [file join [pwd] sim wave common.do]
wave_setup snmp_get tb_judge_snmp
set dut /tb_judge_snmp/agent/dut
foreach name {rx_valid rx_data rx_valid_b rx_data_b tx_valid tx_data tx_valid_b tx_data_b} {
    wave_signal $dut/$name $name
}
wave_signal $dut/snmp/requests SNMP_requests unsigned
run 550us
set cursor_request [wave cursor add -time 525300ns -name Get_request]
set cursor_response [wave cursor add -time 531684ns -name Get_response]
wave cursor active $cursor_request
wave_snapshot snmp_get_1 525280ns 525600ns
wave cursor active $cursor_response
wave_snapshot snmp_get_2 531660ns 531980ns
