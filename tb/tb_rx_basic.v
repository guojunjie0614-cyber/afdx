// 验证接收 VL 映射、UDP 载荷及端口交付；覆盖长度边界和基本配置。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_rx_basic #(parameter RX_RING_AW=12,RX_DQ_AW=5);
    rx_core_suite #(.NAME("tb_rx_basic"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
