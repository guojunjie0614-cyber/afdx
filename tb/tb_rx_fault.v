`timescale 1ns/1ps
module tb_rx_fault #(parameter RX_RING_AW=12,RX_DQ_AW=4);
    rx_core_suite #(.NAME("tb_rx_fault"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
