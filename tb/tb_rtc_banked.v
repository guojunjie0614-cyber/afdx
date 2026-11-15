// 复用既有的错误源时间戳、过期回应及重同步恢复场景，验证分体接收捕获逻辑。
`timescale 1ns/1ps
module tb_rtc_banked;
    rtc_retry_suite #(
        .NAME     ("tb_rtc_banked"),
        .NEGATIVE (1)
    ) test();

    defparam test.slave.BANKED_RX  = 1;
    defparam test.master.BANKED_RX = 1;
endmodule
