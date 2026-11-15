`timescale 1ns/1ps
// 完整且未分段的公开引脚分片测试场景。
// 与官方布局布线前网表（VQM）运行相同的激励和检查流程。
module tb_frag_net;
    tb_fragmentation #(.RESULT_NAME ("tb_frag_net")) scenario();
endmodule
