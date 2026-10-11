// 验证发送 VL 的 BAG 起发间隔、计时回绕和调度抖动；基于实际线路首字节判定。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_tx_bag #(parameter TX_PAGE_AW=8,TX_OFF_AW=8,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_bag"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
