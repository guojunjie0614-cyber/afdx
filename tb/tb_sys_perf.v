`timescale 1ns/1ps
module tb_sys_perf #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5,GMII_RX_AW=12);
 sys_suite #(.NAME("tb_sys_perf"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW),.GMII_RX_AW(GMII_RX_AW),.LINK_FRAMES(9000)) suite();
endmodule
