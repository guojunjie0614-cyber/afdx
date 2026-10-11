// 验证 VL 禁用、消息队满、超长及无空闲页的分类丢弃与页回收。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_tx_drop #(parameter TX_PAGE_AW=8,TX_OFF_AW=8,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_drop"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
