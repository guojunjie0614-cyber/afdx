// 验证全长帧稳态吞吐、BAG 抖动和应用入口到交付末字节的时延；通过外部事件/线路记录计算指标。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_sys_perf #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5,GMII_RX_AW=12);
 sys_suite #(.NAME("tb_sys_perf"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW),.GMII_RX_AW(GMII_RX_AW),.LINK_FRAMES(9000)) suite();
endmodule
