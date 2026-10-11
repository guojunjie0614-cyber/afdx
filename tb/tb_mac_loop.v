// 本测试把以太网发送端接回接收端。
// 它检查不同帧长和双网帧内容，并核对帧校验值。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_mac_loop;
    mac_tx_suite #(1,"tb_mac_loop") suite();
endmodule
