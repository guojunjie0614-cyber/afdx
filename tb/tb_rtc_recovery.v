// 验证 SNTP 丢回应、主从使能顺序和周期重发后的恢复；对应 RTC 同步可恢复性。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
`timescale 1ns/1ps
module tb_rtc_recovery;
    rtc_retry_suite #(.NAME("tb_rtc_recovery"),.NEGATIVE(0)) test();
endmodule
