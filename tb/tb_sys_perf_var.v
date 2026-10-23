// R97变长帧、多VL并发；只驱动公开端口，不修改被测RTL。
`timescale 1ns/1ps
module tb_sys_perf_var;
 sys_suite #(.NAME("tb_sys_perf_var"),.LINK_FRAMES(16000),.MAX_CYCLES(120000000)) suite();
endmodule
