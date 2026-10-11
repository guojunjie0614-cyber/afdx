// 验证 SNTP 错误秒、小数或过期 Originate 的回应不得校时，合法回应仍可恢复；对应 RTC 同步防误配。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
`timescale 1ns/1ps
module tb_rtc_originate;
    rtc_retry_suite #(.NAME("tb_rtc_originate"),.NEGATIVE(1)) test();
endmodule
