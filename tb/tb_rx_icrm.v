// 验证 ARINC 664 P7 的分网完整性、序号回绕、SkewMax 与双网冗余选择。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_rx_icrm #(parameter RX_RING_AW=12,RX_DQ_AW=5);
    rx_core_suite #(.NAME("tb_rx_icrm"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
