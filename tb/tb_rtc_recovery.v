// 本测试丢弃时钟同步回应，并交换主从端的启动顺序。
// 从端应在下个周期重新请求，最终恢复同步。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
`timescale 1ns/1ps
module tb_rtc_recovery;
    rtc_retry_current #(.NAME("tb_rtc_recovery"),.NEGATIVE(0)) test();
endmodule
