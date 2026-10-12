// 本测试制造链路禁用、队列满、消息过长和无空闲页四种情况。
// 它检查拒绝原因，并确认失败消息占用的页已归还。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_tx_drop #(parameter TX_PAGE_AW=8,TX_OFF_AW=8,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_drop"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
