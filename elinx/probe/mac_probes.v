// 包装的所有输入/输出各打一拍，计入模块端口附近的组合路径。
module probe_mac_tx(
    input wire clk,reset,byte_en,s_valid,
    input wire [7:0] s_data_a,s_data_b,
    input wire s_last,s_en_a,s_en_b,
    output reg s_ready,tx_sof,tx_eof,tx_underrun,
    output reg [7:0] tx_data_a,tx_data_b,
    output reg tx_valid_a,tx_valid_b
);
    reg reset_q,byte_en_q,valid_q,last_q,en_a_q,en_b_q;
    reg [7:0] data_a_q,data_b_q;
    wire ready_w,sof_w,eof_w,under_w,va_w,vb_w;
    wire [7:0] da_w,db_w;
    always @(posedge clk)begin
        reset_q<=reset;byte_en_q<=byte_en;valid_q<=s_valid;last_q<=s_last;
        en_a_q<=s_en_a;en_b_q<=s_en_b;data_a_q<=s_data_a;data_b_q<=s_data_b;
        s_ready<=ready_w;tx_sof<=sof_w;tx_eof<=eof_w;tx_underrun<=under_w;
        tx_data_a<=da_w;tx_data_b<=db_w;tx_valid_a<=va_w;tx_valid_b<=vb_w;
    end
    afdx_mac_tx u(clk,reset_q,byte_en_q,valid_q,ready_w,data_a_q,data_b_q,last_q,en_a_q,en_b_q,
        sof_w,eof_w,under_w,da_w,va_w,db_w,vb_w);
endmodule

module probe_mac_rx(
    input wire clk,reset,rx_valid,
    input wire [7:0] rx_data,
    output reg m_valid,m_first,f_end,
    output reg [7:0] m_data,
    output reg [1:0] f_err,
    output reg [10:0] f_len
);
    reg reset_q,valid_q;
    reg [7:0] data_q;
    wire valid_w,first_w,end_w;
    wire [7:0] data_w;
    wire [1:0] err_w;
    wire [10:0] len_w;
    always @(posedge clk)begin
        reset_q<=reset;valid_q<=rx_valid;data_q<=rx_data;
        m_valid<=valid_w;m_first<=first_w;f_end<=end_w;m_data<=data_w;f_err<=err_w;f_len<=len_w;
    end
    afdx_mac_rx u(clk,reset_q,data_q,valid_q,valid_w,data_w,first_w,end_w,err_w,len_w);
endmodule
