// 本测试向时钟同步模块发送请求时间错误或已经过期的回应。
// 错误回应不能校时，随后到达的合法回应应能完成同步。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
`timescale 1ns/1ps
module tb_rtc_originate;
    rtc_retry_suite #(.NAME("tb_rtc_originate"),.NEGATIVE(1)) test();
endmodule
