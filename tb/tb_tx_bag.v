// 本测试从线路首字节测量同一虚拟链路相邻两帧的间隔。
// 它检查带宽限制、计数回绕和发送间隔变化。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
// 完整回归还用参考检查器核对输出，检查器也必须通过。
`timescale 1ns/1ps
module tb_tx_bag #(parameter TX_PAGE_AW=8,TX_OFF_AW=8,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_bag"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
