`timescale 1ns/1ps
module tb_tx_basic #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512);
    tx_core_suite #(.NAME("tb_tx_basic"),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) suite();
endmodule
