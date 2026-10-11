// 验证 Ethernet MAC 组帧、帧间隔及断粮错误 FCS；对应 AFDX 以太网发送基础。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_mac_tx;
    mac_tx_suite #(0,"tb_mac_tx") suite();
endmodule
