`timescale 1ns/1ps
module tb_rx_ovf_dq #(parameter RX_RING_AW=12,RX_DQ_AW=1);
    rx_core_suite #(.NAME("tb_rx_ovf_dq"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
