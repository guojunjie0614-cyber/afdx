// 所有输入、输出各打一拍，检查接收核心边界路径；时钟直接连接。
module probe_rx_core(
    input wire clk,reset,input wire [15:0] now_c,
    input wire [7:0] rx_data_a,input wire rx_valid_a,input wire [7:0] rx_data_b,input wire rx_valid_b,
    input wire cfg_map_we,cfg_cfg_we,input wire [15:0] cfg_addr,input wire [31:0] cfg_wdata,
    output reg d_valid,output reg [7:0] d_data,output reg d_last,output reg [11:0] d_vl,
    output reg [15:0] d_sport,d_dport,output reg d_net,init_done,
    output reg [7:0] ev_a,ev_b,output reg ev_rm_drop,ev_deliver,cfg_ok
);
    reg reset_q,valid_a_q,valid_b_q,map_we_q,cfg_we_q;
    reg [15:0] now_q,addr_q;reg [31:0] wdata_q;reg [7:0] data_a_q,data_b_q;
    wire valid_q,last_q,net_q,init_q,rm_q,deliver_q;
    wire cfg_ok_q;
    wire [7:0] data_q,event_a_q,event_b_q;wire [11:0] vl_q;wire [15:0] sport_q,dport_q;
    always @(posedge clk)begin
        reset_q<=reset;now_q<=now_c;data_a_q<=rx_data_a;data_b_q<=rx_data_b;
        valid_a_q<=rx_valid_a;valid_b_q<=rx_valid_b;map_we_q<=cfg_map_we;cfg_we_q<=cfg_cfg_we;
        addr_q<=cfg_addr;wdata_q<=cfg_wdata;
        d_valid<=valid_q;d_data<=data_q;d_last<=last_q;d_vl<=vl_q;
        d_sport<=sport_q;d_dport<=dport_q;d_net<=net_q;init_done<=init_q;
        ev_a<=event_a_q;ev_b<=event_b_q;ev_rm_drop<=rm_q;ev_deliver<=deliver_q;
        cfg_ok<=cfg_ok_q;
    end
    afdx_rx_core core(clk,reset_q,now_q,data_a_q,valid_a_q,data_b_q,valid_b_q,map_we_q,cfg_we_q,addr_q,wdata_q,
        valid_q,data_q,last_q,vl_q,sport_q,dport_q,net_q,init_q,event_a_q,event_b_q,rm_q,deliver_q,cfg_ok_q);
endmodule
