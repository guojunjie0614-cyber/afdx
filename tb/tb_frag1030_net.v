`timescale 1ns/1ps
// Full, unsegmented public-pin fragmentation scenario. The same inherited
// stimulus/checks run against RTL and the official routed-input VQM.
module tb_frag1030_net;
    tb_fragmentation #(.RESULT_NAME("tb_frag1030_net")) scenario();
endmodule
