// R120-3/R124/R126：赛题顶层直接接收和交付“高字节 VLID、低字节 VLID、载荷”。
// valid 连续区间是一条消息，两条消息之间至少空一拍；rx_ready 按 R62 不使用。
`ifndef AFDX_CE_DIV
`define AFDX_CE_DIV 2
`endif
module AFDX_top #(
    parameter CE_DIV=`AFDX_CE_DIV,TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,
    RX_RING_AW=12,RX_DQ_AW=5,RX_CONFIG_BANKS=16
)(
    input wire clk,reset,
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready,
    output wire [7:0] rx_data,
    output wire rx_valid,
    input wire rx_ready,
    output wire [7:0] gmii_txd_a,gmii_txd_b,
    output wire gmii_tx_en_a,gmii_tx_en_b,
    input wire [7:0] gmii_rxd_a,gmii_rxd_b,
    input wire gmii_rx_dv_a,gmii_rx_dv_b,
    input wire cfg_wr,cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output wire [31:0] cfg_rdata,
    output wire cfg_rvalid,cfg_ready,
    output wire [6:0] ev_tx,
    output wire [7:0] ev_a,ev_b,
    output wire ev_rm_drop,ev_deliver,
    output wire [2:0] ev_app
);
    wire initialized,m_valid,m_ready,m_last,d_valid,d_last;
    wire [7:0] m_data,d_data;
    wire [6:0] m_vl;
    wire [11:0] d_index;
    reg tx_cfg_write,rx_cfg_write;
    reg [6:0] tx_cfg_index;
    reg [11:0] rx_cfg_index;
    reg [15:0] tx_cfg_vlid,rx_cfg_vlid;
    always @(posedge clk)begin
        if(reset)begin tx_cfg_write<=0;rx_cfg_write<=0;tx_cfg_index<=0;rx_cfg_index<=0;tx_cfg_vlid<=0;rx_cfg_vlid<=0;end
        else begin
            tx_cfg_write<=cfg_wr && cfg_ready && cfg_addr[17:10]==8'b00000100 && cfg_addr[2:0]==2;
            rx_cfg_write<=cfg_wr && cfg_ready && cfg_addr[17:16]==2'b01 && cfg_wdata[12];
            tx_cfg_index<=cfg_addr[9:3];tx_cfg_vlid<=cfg_wdata[15:0];
            rx_cfg_index<=cfg_wdata[11:0];rx_cfg_vlid<=cfg_addr[15:0];
        end
    end
    afdx_app_tx application_tx(clk,reset,initialized,tx_data,tx_valid,tx_ready,
        tx_cfg_write,tx_cfg_index,tx_cfg_vlid,m_valid,m_ready,m_data,m_last,m_vl,ev_app[1:0]);
    afdx_app_rx application_rx(clk,reset,rx_cfg_write,rx_cfg_index,rx_cfg_vlid,
        d_valid,d_data,d_last,d_index,rx_valid,rx_data,ev_app[2]);
    afdx_es #(.CE_DIV(CE_DIV),.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),
        .LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW),.RX_CONFIG_BANKS(RX_CONFIG_BANKS)) es(
        .clk(clk),.reset(reset),.tx_data(gmii_txd_a),.tx_valid(gmii_tx_en_a),
        .rx_data(gmii_rxd_a),.rx_valid(gmii_rx_dv_a),.tx_ready(initialized),.rx_ready(1'b0),
        .tx_data_b(gmii_txd_b),.tx_valid_b(gmii_tx_en_b),.rx_data_b(gmii_rxd_b),.rx_valid_b(gmii_rx_dv_b),
        .app_tx_valid(m_valid),.app_tx_ready(m_ready),.app_tx_data(m_data),.app_tx_last(m_last),.app_tx_vl(m_vl),
        .app_tx_port_en(1'b0),.app_tx_sport(16'd0),.app_tx_dport(16'd0),
        .app_rx_valid(d_valid),.app_rx_data(d_data),.app_rx_last(d_last),.app_rx_vl(d_index),
        .app_rx_port(),.app_rx_sport(),.app_rx_net(),
        .cfg_wr(cfg_wr),.cfg_rd(cfg_rd),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata),.cfg_rvalid(cfg_rvalid),.cfg_ready(cfg_ready),
        .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver));
endmodule
