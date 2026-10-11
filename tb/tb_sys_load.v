// 本测试让多个虚拟链路同时在两个端系统之间传输。
// 它检查消息交付、发送间隔，以及各接收配置互不干扰。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_sys_load #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5);
 sys_suite #(.NAME("tb_sys_load"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
