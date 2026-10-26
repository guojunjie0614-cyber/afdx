# exact 场景：同一 VL 的两个 GMII 起点相隔 100000 拍，即 800 us。
source [file join [pwd] sim wave common.do]
wave_setup tx_bag tb_tx_bag
set dut /tb_tx_bag/suite/dut
wave_signal /tb_tx_bag/suite/m_vl VL unsigned
wave_signal $dut/engine/pend_bag BAG_ticks unsigned
foreach name {tx_valid_a tx_data_a tx_valid_b tx_data_b} {wave_signal $dut/$name $name}
wave_signal $dut/engine/grant_sn SN unsigned
run 830us
wave cursor add -time 17092ns -name Frame_1_start
wave cursor add -time 817092ns -name Frame_2_start
wave_snapshot tx_bag 10000ns 830000ns
