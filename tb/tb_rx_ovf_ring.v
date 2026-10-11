// 本测试使用较小的接收字节缓存，让整帧无法存下。
// 它检查失败帧是否释放暂占空间，以及后续帧能否继续接收。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_rx_ovf_ring #(parameter RX_RING_AW=9,RX_DQ_AW=5);
    rx_core_suite #(.NAME("tb_rx_ovf_ring"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
