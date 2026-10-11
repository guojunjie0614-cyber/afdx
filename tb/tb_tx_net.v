// 本测试用固定消息序列检查发送核心。
// 同一输入还用于网表仿真，线路内容和事件记录应相同。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_tx_net #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_net"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
