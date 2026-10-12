// 本测试使用较小的交付队列，让队列确实被填满。
// 它检查队满时的丢帧事件，以及释放空间后能否恢复交付。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_rx_ovf_dq #(parameter RX_RING_AW=12,RX_DQ_AW=1);
    rx_core_suite #(.NAME("tb_rx_ovf_dq"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
