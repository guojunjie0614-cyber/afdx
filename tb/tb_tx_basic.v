// 验证消息分页面存储、IPv4/UDP 组帧、序号与双网输出；含载荷长度边界。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_tx_basic #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_basic"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
