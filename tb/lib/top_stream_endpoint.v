// 测试端点的字节流适配；被测实例始终是公开应用口 AFDX_top。
// 发送序号来自测试配置；直接激励可用 raw_vlid 绕过测试端的序号查表。
`timescale 1ns/1ps
module top_stream_endpoint #(
    parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5,
    DIRECT_CORE=0
)(
    input wire clk,reset,
    output wire [7:0] tx_data,tx_data_b,
    output wire tx_valid,tx_valid_b,
    input wire [7:0] rx_data,rx_data_b,
    input wire rx_valid,rx_valid_b,
    output wire tx_ready,
    input wire rx_ready,
    input wire app_tx_valid,app_tx_last,
    input wire [7:0] app_tx_data,
    input wire [6:0] app_tx_vl,
    input wire app_tx_port_en,
    input wire [15:0] app_tx_sport,app_tx_dport,
    output wire app_tx_ready,
    output wire app_rx_valid,app_rx_last,
    output wire [7:0] app_rx_data,
    output wire [11:0] app_rx_vl,
    output wire [15:0] app_rx_sport,app_rx_port,
    output wire app_rx_net,
    input wire cfg_wr,cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output wire [31:0] cfg_rdata,
    output wire cfg_rvalid,cfg_ready,
    output wire [6:0] ev_tx,
    output wire [7:0] ev_a,ev_b,
    output wire ev_rm_drop,ev_deliver,
    input wire raw_mode,
    input wire [15:0] raw_vlid,
    output wire initialized
);
    wire [7:0] stream_tx,stream_rx;
    wire stream_tv,stream_rv,stream_ready;
    wire [2:0] ev_app;
    integer cycle=0,source_first=0,source_last=0,receive_first=0,receive_last=0;
    integer backpressure=0,backpressure_max=0,stall=0;
    wire core_valid,core_ready,core_last;
    wire [31:0] current_source_first,current_source_last,current_stalls,current_maxstall;
    wire input_empty;
    wire [7:0] core_data;
    wire [6:0] core_vl;
    wire core_dvalid,core_dlast,core_dnet;
    wire [7:0] core_ddata;
    wire [11:0] core_dvl;
    wire [15:0] core_dsp,core_ddp;
    generate if(DIRECT_CORE)begin:direct
        afdx_es #(.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) es(
            .clk(clk),.reset(reset),.tx_data(tx_data),.tx_valid(tx_valid),.rx_data(rx_data),.rx_valid(rx_valid),.tx_ready(tx_ready),.rx_ready(rx_ready),
            .tx_data_b(tx_data_b),.tx_valid_b(tx_valid_b),.rx_data_b(rx_data_b),.rx_valid_b(rx_valid_b),
            .app_tx_valid(app_tx_valid),.app_tx_ready(app_tx_ready),.app_tx_data(app_tx_data),.app_tx_last(app_tx_last),.app_tx_vl(app_tx_vl),
            .app_tx_port_en(app_tx_port_en),.app_tx_sport(app_tx_sport),.app_tx_dport(app_tx_dport),
            .app_rx_valid(app_rx_valid),.app_rx_data(app_rx_data),.app_rx_last(app_rx_last),.app_rx_vl(app_rx_vl),
            .app_rx_sport(app_rx_sport),.app_rx_port(app_rx_port),.app_rx_net(app_rx_net),
            .cfg_wr(cfg_wr),.cfg_rd(cfg_rd),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),.cfg_rdata(cfg_rdata),.cfg_rvalid(cfg_rvalid),.cfg_ready(cfg_ready),
            .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver));
        assign initialized=tx_ready;
        assign current_source_first=cycle;assign current_source_last=cycle;assign current_stalls=0;assign current_maxstall=0;assign input_empty=1;
        assign core_valid=app_tx_valid;assign core_ready=app_tx_ready;assign core_last=app_tx_last;assign core_data=app_tx_data;assign core_vl=app_tx_vl;
        assign core_dvalid=app_rx_valid;assign core_dlast=app_rx_last;assign core_ddata=app_rx_data;assign core_dvl=app_rx_vl;
        assign core_dsp=app_rx_sport;assign core_ddp=app_rx_port;assign core_dnet=app_rx_net;
    end else begin:wrapped
`ifdef SYS_TOP_NETLIST
        AFDX_top top(
`else
        AFDX_top #(.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) top(
`endif
            .clk(clk),.reset(reset),.tx_data(stream_tx),.tx_valid(stream_tv),.tx_ready(stream_ready),.rx_data(stream_rx),.rx_valid(stream_rv),.rx_ready(rx_ready),
            .gmii_txd_a(tx_data),.gmii_tx_en_a(tx_valid),.gmii_rxd_a(rx_data),.gmii_rx_dv_a(rx_valid),
            .gmii_txd_b(tx_data_b),.gmii_tx_en_b(tx_valid_b),.gmii_rxd_b(rx_data_b),.gmii_rx_dv_b(rx_valid_b),
            .cfg_wr(cfg_wr),.cfg_rd(cfg_rd),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),.cfg_rdata(cfg_rdata),.cfg_rvalid(cfg_rvalid),.cfg_ready(cfg_ready),
            .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver),.ev_app(ev_app));
        assign tx_ready=stream_ready;
`ifndef SYS_TOP_NETLIST
        assign initialized=top.initialized;
        assign core_valid=top.es.app_tx_valid;assign core_ready=top.es.app_tx_ready;assign core_last=top.es.app_tx_last;
        assign core_data=top.es.app_tx_data;assign core_vl=top.es.app_tx_vl;
        assign core_dvalid=top.es.app_rx_valid;assign core_dlast=top.es.app_rx_last;assign core_ddata=top.es.app_rx_data;assign core_dvl=top.es.app_rx_vl;
        assign core_dsp=top.es.app_rx_sport;assign core_ddp=top.es.app_rx_port;assign core_dnet=top.es.app_rx_net;
`else
        assign initialized=stream_ready;
        assign core_valid=0;assign core_ready=0;assign core_last=0;assign core_data=0;assign core_vl=0;
        assign core_dvalid=0;assign core_dlast=0;assign core_ddata=0;assign core_dvl=0;
        assign core_dsp=0;assign core_ddp=0;assign core_dnet=0;
`endif
        reg [15:0] ids[0:127];
        reg [11:0] indices[0:65535];
        reg [2:0] tx_state=0;
        reg [15:0] id;
        reg previous_tv=0,previous_rv=0;
        integer rx_pos=0,source_write=0,core_read=0;
        integer firsts[0:63],lasts[0:63],stalls[0:63],maxstalls[0:63];
        integer pending_stall=0,pending_max=0;
        assign current_source_first=firsts[core_read%64];
        assign current_source_last=lasts[core_read%64];assign current_stalls=stalls[core_read%64];assign current_maxstall=maxstalls[core_read%64];
        assign input_empty=source_write==core_read;
        reg [15:0] receive_id;
        integer gmii_pos=0;reg gmii_previous=0;
        reg [15:0] gmii_id,gmii_sp,gmii_dp;
        reg [31:0] wire_ports[0:65535];
        reg [7:0] previous_data;
        reg d_valid=0,d_last=0;
        reg [7:0] d_data=0;
        reg [11:0] d_index=0;
        reg [15:0] d_sp=0,d_dp=0;
        reg d_net=0;
        reg [44:0] metadata[0:63];
        integer mw=0,mr=0;
        reg receiving_core=0;
        assign app_tx_ready=tx_state==3;
        assign stream_tv=tx_state==1 || tx_state==2 || (tx_state==3 && app_tx_valid);
        assign stream_tx=tx_state==1?id[15:8]:tx_state==2?id[7:0]:app_tx_data;
        assign app_rx_valid=d_valid;assign app_rx_last=d_last;assign app_rx_data=d_data;
        assign app_rx_vl=d_index;assign app_rx_sport=d_sp;assign app_rx_port=d_dp;assign app_rx_net=d_net;
        always @(posedge clk)begin
            cycle=cycle+1;
            if(reset)begin tx_state<=0;rx_pos=0;previous_rv=0;previous_tv=0;d_valid<=0;d_last<=0;mw=0;mr=0;receiving_core=0;stall=0;source_write=0;core_read<=0;end
            else begin
                if(cfg_wr && cfg_ready)begin
                    if(cfg_addr[17:10]==8'b00000100 && cfg_addr[2:0]==2)ids[cfg_addr[9:3]]=cfg_wdata[15:0];
                    if(cfg_addr[17:16]==2'b01 && cfg_wdata[12])indices[cfg_addr[15:0]]=cfg_wdata[11:0];
                end
                case(tx_state)
                    0:if(app_tx_valid && stream_ready)begin id<=raw_mode === 1'b1 ? raw_vlid : ids[app_tx_vl];tx_state<=1;end
                    1:tx_state<=2;
                    2:tx_state<=3;
                    3:if(app_tx_valid && app_tx_last)tx_state<=4;
                    4:tx_state<=0;
                endcase
                if(app_tx_valid && tx_state==0 && !stream_ready)begin
                    backpressure=backpressure+1;pending_stall=pending_stall+1;stall=stall+1;if(stall>backpressure_max)backpressure_max=stall;if(stall>pending_max)pending_max=stall;
                end else stall=0;
                if(stream_tv && !previous_tv)begin source_first=cycle;firsts[source_write%64]=cycle;stalls[source_write%64]=pending_stall;maxstalls[source_write%64]=pending_max;pending_stall=0;pending_max=0;source_write=source_write+1;end
                if(core_valid && core_ready && core_last)core_read<=core_read+1;
                if(stream_tv)begin source_last=cycle;lasts[(source_write-1)%64]=cycle;end
                previous_tv=stream_tv;
                if(|ev_app)$display("** Error: [APP_DROP] events=%b",ev_app);
                if(rx_valid)begin
                    if(!gmii_previous)gmii_pos=0;
                    case(gmii_pos)
                        12:gmii_id[15:8]=rx_data;13:gmii_id[7:0]=rx_data;
                        42:gmii_sp[15:8]=rx_data;43:gmii_sp[7:0]=rx_data;
                        44:gmii_dp[15:8]=rx_data;
                        45:begin gmii_dp[7:0]=rx_data;wire_ports[gmii_id]={gmii_sp,gmii_dp};end
                    endcase
                    gmii_pos=gmii_pos+1;
                end
                gmii_previous=rx_valid;
                if(core_dvalid)begin
                    if(!receiving_core)begin metadata[mw%64]={core_dnet,core_dvl,core_dsp,core_ddp};mw=mw+1;end
                    receiving_core=!core_dlast;
                end
                d_valid<=previous_rv && rx_pos>=3;
                d_last<=previous_rv && rx_pos>=3 && !stream_rv;
                d_data<=previous_data;
                if(stream_rv)begin
                    if(!previous_rv)begin
                        receive_first=cycle;rx_pos=0;
`ifndef SYS_TOP_NETLIST
                        {d_net,d_index,d_sp,d_dp}<=metadata[mr%64];mr=mr+1;
`endif
                    end
                    if(rx_pos==0)receive_id[15:8]=stream_rx;
                    if(rx_pos==1)begin
                        receive_id[7:0]=stream_rx;d_index<=indices[receive_id];
`ifdef SYS_TOP_NETLIST
                        {d_sp,d_dp}<=wire_ports[receive_id];d_net<=0;
`endif
                    end
                    rx_pos=rx_pos+1;receive_last=cycle;
                end else if(previous_rv)rx_pos=0;
                previous_rv=stream_rv;previous_data=stream_rx;
            end
        end
    end endgenerate
endmodule
