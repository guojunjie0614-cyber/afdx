// 本测试测量两个端系统的用户数据吞吐、端到端时延和发送间隔变化。
// 它记录应用末字节、线路首字节和交付字节所在的周期，用来计算这三项指标。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_sys_perf #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5);
 sys_suite #(.NAME("tb_sys_perf"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW),.LINK_FRAMES(9000)) suite();
endmodule
