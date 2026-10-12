// 所有数据、控制输入与输出各一级寄存器，用来检查核心边界路径。
module probe_tx_core(
    input wire clk,reset,input wire [31:0] now,input wire byte_en,
    input wire m_valid,input wire [7:0] m_data,input wire m_last,input wire [6:0] m_vl,
    input wire m_port_en,input wire [15:0] m_sport,m_dport,
    input wire cfg_we,input wire [9:0] cfg_addr,input wire [31:0] cfg_wdata,input wire [15:0] user_id,
    output reg m_ready,output reg [7:0] tx_data_a,output reg tx_valid_a,
    output reg [7:0] tx_data_b,output reg tx_valid_b,output reg init_done,
    output reg ev_accept,ev_drop_dis,ev_drop_full,ev_drop_long,ev_drop_nopage,ev_tx_a,ev_tx_b,cfg_ok
);
    reg reset_q,byte_en_q,m_valid_q,m_last_q,m_port_en_q,cfg_we_q;
    reg [31:0] now_q,cfg_wdata_q;
    reg [7:0] m_data_q;
    reg [6:0] m_vl_q;
    reg [9:0] cfg_addr_q;
    reg [15:0] m_sport_q,m_dport_q,user_id_q;
    wire ready_q,va_q,vb_q,init_q,accept_q,dis_q,full_q,long_q,nopage_q,txa_q,txb_q;
    wire [7:0] da_q,db_q;
    wire cfg_ok_q;
    always @(posedge clk) begin
        reset_q<=reset;now_q<=now;byte_en_q<=byte_en;
        m_valid_q<=m_valid;m_data_q<=m_data;m_last_q<=m_last;m_vl_q<=m_vl;
        m_port_en_q<=m_port_en;m_sport_q<=m_sport;m_dport_q<=m_dport;
        cfg_we_q<=cfg_we;cfg_addr_q<=cfg_addr;cfg_wdata_q<=cfg_wdata;user_id_q<=user_id;
        m_ready<=ready_q;tx_data_a<=da_q;tx_valid_a<=va_q;tx_data_b<=db_q;tx_valid_b<=vb_q;init_done<=init_q;
        ev_accept<=accept_q;ev_drop_dis<=dis_q;ev_drop_full<=full_q;ev_drop_long<=long_q;
        ev_drop_nopage<=nopage_q;ev_tx_a<=txa_q;ev_tx_b<=txb_q;
        cfg_ok<=cfg_ok_q;
    end
    afdx_tx_core core(clk,reset_q,now_q,byte_en_q,m_valid_q,ready_q,m_data_q,m_last_q,m_vl_q,m_port_en_q,m_sport_q,m_dport_q,
        cfg_we_q,cfg_addr_q,cfg_wdata_q,user_id_q,da_q,va_q,db_q,vb_q,init_q,accept_q,dis_q,full_q,long_q,nopage_q,txa_q,txb_q,cfg_ok_q);
endmodule
