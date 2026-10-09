`timescale 1ns/1ps
module tb_rx_ovf_ring #(parameter RX_RING_AW=9,RX_DQ_AW=5);
    rx_core_suite #(.NAME("tb_rx_ovf_ring"),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) suite();
endmodule
