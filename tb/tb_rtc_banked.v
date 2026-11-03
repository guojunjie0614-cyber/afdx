// Exercise the changed banked receive capture with the existing independent
// wrong-origin, expired-response and recovery scenarios.
`timescale 1ns/1ps
module tb_rtc_banked;
    rtc_retry_suite #(.NAME("tb_rtc_banked"), .NEGATIVE(1)) test();
    defparam test.slave.BANKED_RX = 1;
    defparam test.master.BANKED_RX = 1;
endmodule
