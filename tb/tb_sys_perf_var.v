// R97 变长帧、多 VL 并发测试；仅驱动公开端口，不修改被测 RTL。
`timescale 1ns/1ps
module tb_sys_perf_var;
    sys_suite #(
        .NAME        ("tb_sys_perf_var"),
        .LINK_FRAMES (16000),
        .MAX_CYCLES  (120000000)
    ) suite();
endmodule
