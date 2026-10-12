// 本测试向以太网发送模块提供帧内容，并在部分帧中故意断供字节。
// 它检查组帧、帧间隔，以及缺字节时是否输出错误校验值。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_mac_tx;
    mac_tx_suite #(0,"tb_mac_tx") suite();
endmodule
