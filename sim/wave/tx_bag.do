# exact 场景：同一 VL 的两个 GMII 起点相隔 100000 拍，即 800 us。
source [file join [pwd] sim wave common.do]
wave_setup tx_bag tb_tx_bag
set dut /tb_tx_bag/suite/dut
wave_signal /tb_tx_bag/suite/m_vl VL unsigned
wave_signal $dut/engine/pend_bag BAG_ticks unsigned
foreach name {tx_valid_a tx_data_a tx_valid_b tx_data_b} {wave_signal $dut/$name $name}
wave_signal $dut/engine/grant_sn SN unsigned
run 830us
catch {wave cursor delete 1}
wave cursor add -time 17076ns -name {Frame 1 start}
wave cursor add -time 817076ns -name {Frame 2 start}
wave_print 10000ns 830000ns
wave_print 17000ns 17800ns frame1.ps
wave_print 817000ns 817800ns frame2.ps
wave zoom range 10000ns 830000ns
