// 验证 Ethernet MAC 发收闭环，覆盖前导、最短/最长帧、FCS 和双网内容一致性。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_mac_loop;
    mac_tx_suite #(1,"tb_mac_loop") suite();
endmodule
