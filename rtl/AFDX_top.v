// 双网AFDX端系统顶层，连接原生收发核心、GMII、配置总线及三种服务。
// 外部为125 MHz GMII；应用口交付UDP载荷，cfg_*读写配置和统计。
// 同一时钟域；服务与应用按整条消息共享核心，错误通过ev_*输出。
// 125 MHz 官方 GMII 外壳：收发核心逐拍直连引脚。
module AFDX_top #(
    parameter TX_PAGE_AW = 8,
    parameter TX_OFF_AW = 9,
    parameter LOOKAHEAD = 512,
    parameter RX_RING_AW = 12,
    parameter RX_DQ_AW = 4,
    parameter GMII_RX_AW = 12) (
    input wire clk, reset,
    output wire [7:0] tx_data,
    output wire tx_valid,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg tx_ready,
    input wire rx_ready,
    output wire [7:0] tx_data_b,
    output wire tx_valid_b,
    input wire [7:0] rx_data_b,
    input wire rx_valid_b,
    input wire app_tx_valid,
    output wire app_tx_ready,
    input wire [7:0] app_tx_data,
    input wire app_tx_last,
    input wire [6:0] app_tx_vl,
    input wire app_tx_port_en,
    input wire [15:0] app_tx_sport, app_tx_dport,
    output wire app_rx_valid,
    output wire [7:0] app_rx_data,
    output wire app_rx_last,
    output wire [11:0] app_rx_vl,
    output wire [15:0] app_rx_port, app_rx_sport,
    output wire app_rx_net,
    input wire cfg_wr, cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output wire [31:0] cfg_rdata,
    output wire cfg_rvalid, cfg_ready,
    output wire [6:0] ev_tx,
    output wire [7:0] ev_a, ev_b,
    output wire ev_rm_drop, ev_deliver,
    output wire [1:0] ev_gdrop);
    wire [31:0] now;
    wire [15:0] now_c, user_id;
    wire byte_en, tx_initialized, rx_initialized;
    wire tx_cfg_ok, rx_cfg_ok, tx_cfg_we, rx_map_we, rx_cfg_we;
    wire [9:0] tx_cfg_addr;
    wire [15:0] rx_cfg_addr;
    wire [31:0] tx_cfg_wdata, rx_cfg_wdata;
    // 原生 GMII 直接连接核心；兼容的适配丢弃事件口固定为零。
    assign ev_gdrop = 2'b00;
    wire m_valid, m_ready, m_last, m_port_en;
    wire [7:0] m_data, d_data, rtc_tx_data, svc_rx_data;
    wire [6:0] m_vl, rtc_tx_vl;
    wire [15:0] m_sport, m_dport, d_sport, d_dport, rtc_port, svc_rx_port, svc_rx_sport;
    wire d_valid, d_last, d_net, rtc_tx_valid, rtc_tx_last, rtc_claim, svc_rx_valid, svc_rx_last, svc_rx_net;
    wire [11:0] d_vl, svc_rx_vl;
    wire [2:0] svc_tx_ready;
    wire [31:0] rtc_rdata, rtc_sync_count;
    wire snmp_tx_valid, snmp_tx_last, snmp_claim, snmp_mib_rd, snmp_mib_wr, snmp_mib_ready, snmp_grant;
    wire [7:0] snmp_tx_data;
    wire [6:0] snmp_tx_vl;
    wire [15:0] snmp_tx_dport;
    wire [17:0] snmp_mib_addr, bus_addr;
    wire [31:0] snmp_mib_wdata, bus_wdata;
    wire [31:0] snmp_control_data, snmp_status_data, snmp_descr_data;
    wire load_tx_valid, load_tx_last, load_claim;
    wire [7:0] load_tx_data;
    wire [6:0] load_tx_vl;
    wire [15:0] load_tx_sport, load_tx_dport;
    wire [31:0] load_rdata, load_extra_data;
    wire bus_rd, bus_wr, bus_rvalid;
    reg [1:0] host_read_pipe, snmp_read_pipe;
    // 主机优先；同地址读合并为同一拍快照，分别返回各自的valid。
    assign snmp_mib_ready = ! cfg_wr && (! cfg_rd || (! snmp_mib_wr && cfg_addr == snmp_mib_addr)) && (! snmp_mib_wr || cfg_ready);
    assign snmp_grant = (snmp_mib_rd || snmp_mib_wr) && snmp_mib_ready;
    assign bus_addr = snmp_grant ? snmp_mib_addr : cfg_addr;
    assign bus_rd = cfg_rd || (snmp_grant && snmp_mib_rd);
    assign bus_wr = cfg_wr || (snmp_grant && snmp_mib_wr);
    assign bus_wdata = (snmp_grant && snmp_mib_wr) ? snmp_mib_wdata : cfg_wdata;
    assign cfg_rvalid = host_read_pipe[1];
    always @(posedge clk) begin
        if (reset) begin
            host_read_pipe <= 0;
            snmp_read_pipe <= 0;
        end
        else begin
            host_read_pipe <= { host_read_pipe[0], cfg_rd };
            snmp_read_pipe <= { snmp_read_pipe[0], snmp_grant && snmp_mib_rd };
        end
    end
    wire rtc_select = (bus_addr[17:4] == 14'h0008);
    afdx_615a loader (.clk(clk), .reset(reset), .enable(tx_ready),
        .cfg_we(cfg_wr && cfg_ready && bus_addr[17:4] == 14'h000b), .cfg_addr(bus_addr[7:0]), .cfg_wdata(cfg_wdata),
        .cfg_rdata(load_rdata), .cfg_extra_data(load_extra_data), .tx_valid(load_tx_valid), .tx_ready(svc_tx_ready[2]),
        .tx_data(load_tx_data), .tx_last(load_tx_last), .tx_vl(load_tx_vl), .tx_sport(load_tx_sport),
        .tx_dport(load_tx_dport), .rx_valid(svc_rx_valid), .rx_data(svc_rx_data), .rx_last(svc_rx_last),
        .rx_sport(svc_rx_sport), .rx_dport(svc_rx_port), .rx_claim(load_claim));
    afdx_snmp snmp (.clk(clk), .reset(reset), .enable(tx_ready), .now(now),
        .cfg_we(cfg_wr && cfg_ready && bus_addr[17:8] == 0), .cfg_addr(bus_addr[7:0]), .cfg_wdata(cfg_wdata),
        .cfg_control_data(snmp_control_data), .cfg_status_data(snmp_status_data), .cfg_descr_data(snmp_descr_data),
        .mib_rd(snmp_mib_rd), .mib_wr(snmp_mib_wr), .mib_wdata(snmp_mib_wdata), .mib_addr(snmp_mib_addr),
        .mib_ready(snmp_mib_ready), .mib_rvalid(snmp_read_pipe[1]), .mib_rdata(cfg_rdata), .tx_valid(snmp_tx_valid),
        .tx_ready(svc_tx_ready[1]), .tx_data(snmp_tx_data), .tx_last(snmp_tx_last), .tx_vl(snmp_tx_vl),
        .tx_dport(snmp_tx_dport), .rx_valid(svc_rx_valid), .rx_data(svc_rx_data), .rx_last(svc_rx_last),
        .rx_sport(svc_rx_sport), .rx_dport(svc_rx_port), .rx_claim(snmp_claim));
    afdx_rtc rtc (.clk(clk), .reset(reset), .enable(tx_ready), .cfg_we(cfg_wr && cfg_ready && rtc_select),
        .cfg_re(bus_rd && rtc_select), .cfg_addr(bus_addr[3:0]), .cfg_wdata(cfg_wdata), .cfg_rdata(rtc_rdata),
        .sync_count(rtc_sync_count), .tx_valid(rtc_tx_valid), .tx_ready(svc_tx_ready[0]), .tx_data(rtc_tx_data),
        .tx_last(rtc_tx_last), .tx_vl(rtc_tx_vl), .tx_port(rtc_port), .rx_valid(svc_rx_valid), .rx_data(svc_rx_data),
        .rx_last(svc_rx_last), .rx_port(svc_rx_port), .rx_claim(rtc_claim));
    afdx_svc service_channel (.clk(clk), .reset(reset), .app_tx_valid(app_tx_valid), .app_tx_ready(app_tx_ready),
        .app_tx_data(app_tx_data), .app_tx_last(app_tx_last), .app_tx_vl(app_tx_vl), .app_tx_port_en(app_tx_port_en),
        .app_tx_sport(app_tx_sport), .app_tx_dport(app_tx_dport), .svc_tx_valid({ load_tx_valid, snmp_tx_valid,
        rtc_tx_valid }), .svc_tx_ready(svc_tx_ready), .svc_tx_data({ load_tx_data, snmp_tx_data, rtc_tx_data }),
        .svc_tx_last({ load_tx_last, snmp_tx_last, rtc_tx_last }), .svc_tx_vl({ load_tx_vl, snmp_tx_vl, rtc_tx_vl }),
        .svc_tx_port_en(3'b111), .svc_tx_sport({ load_tx_sport, 16'd161, rtc_port }), .svc_tx_dport({ load_tx_dport,
        snmp_tx_dport, rtc_port }), .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_last(m_last), .m_vl(m_vl),
        .m_port_en(m_port_en), .m_sport(m_sport), .m_dport(m_dport), .d_valid(d_valid), .d_data(d_data), .d_last(d_last),
        .d_vl(d_vl), .d_sport(d_sport), .d_dport(d_dport), .d_net(d_net), .svc_rx_claim({ load_claim, snmp_claim,
        rtc_claim }), .svc_rx_valid(svc_rx_valid), .svc_rx_data(svc_rx_data), .svc_rx_last(svc_rx_last),
        .svc_rx_vl(svc_rx_vl), .svc_rx_sport(svc_rx_sport), .svc_rx_dport(svc_rx_port), .svc_rx_net(svc_rx_net),
        .app_rx_valid(app_rx_valid), .app_rx_data(app_rx_data), .app_rx_last(app_rx_last), .app_rx_vl(app_rx_vl),
        .app_rx_sport(app_rx_sport), .app_rx_dport(app_rx_port), .app_rx_net(app_rx_net));
    always @(posedge clk) begin
        if (reset) tx_ready <= 0;
        else tx_ready <= tx_initialized && rx_initialized;
    end
    afdx_timebase timebase (.clk(clk), .reset(reset), .now(now), .byte_en(byte_en), .now_c(now_c));
    afdx_tx_core #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW), .LOOKAHEAD(LOOKAHEAD)) tx_core (.clk(clk), .reset(reset),
        .now(now), .byte_en(byte_en), .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_last(m_last), .m_vl(m_vl),
        .m_port_en(m_port_en), .m_sport(m_sport), .m_dport(m_dport), .cfg_we(tx_cfg_we), .cfg_addr(tx_cfg_addr),
        .cfg_wdata(tx_cfg_wdata), .user_id(user_id), .tx_data_a(tx_data), .tx_valid_a(tx_valid),
        .tx_data_b(tx_data_b), .tx_valid_b(tx_valid_b), .init_done(tx_initialized), .ev_accept(ev_tx[0]),
        .ev_drop_dis(ev_tx[1]), .ev_drop_full(ev_tx[2]), .ev_drop_long(ev_tx[3]), .ev_drop_nopage(ev_tx[4]),
        .ev_tx_a(ev_tx[5]), .ev_tx_b(ev_tx[6]), .cfg_ok(tx_cfg_ok));
    afdx_rx_core #(.RX_RING_AW(RX_RING_AW), .RX_DQ_AW(RX_DQ_AW)) rx_core (.clk(clk), .reset(reset), .now_c(now_c),
        .rx_data_a(rx_data), .rx_valid_a(rx_valid), .rx_data_b(rx_data_b), .rx_valid_b(rx_valid_b),
        .cfg_map_we(rx_map_we), .cfg_cfg_we(rx_cfg_we), .cfg_addr(rx_cfg_addr), .cfg_wdata(rx_cfg_wdata), .d_valid(d_valid),
        .d_data(d_data), .d_last(d_last), .d_vl(d_vl), .d_sport(d_sport), .d_dport(d_dport), .d_net(d_net),
        .init_done(rx_initialized), .ev_a(ev_a), .ev_b(ev_b), .ev_rm_drop(ev_rm_drop), .ev_deliver(ev_deliver),
        .cfg_ok(rx_cfg_ok));
    afdx_cfg cfg_regs (.clk(clk), .reset(reset), .tx_ready(tx_ready), .cfg_wr(bus_wr), .cfg_rd(bus_rd), .cfg_addr(bus_addr),
        .cfg_wdata(bus_wdata), .cfg_ready(cfg_ready), .cfg_rvalid(bus_rvalid), .cfg_rdata(cfg_rdata), .user_id(user_id),
        .tx_cfg_ok(tx_cfg_ok), .rx_cfg_ok(rx_cfg_ok), .tx_cfg_we(tx_cfg_we), .tx_cfg_addr(tx_cfg_addr),
        .tx_cfg_wdata(tx_cfg_wdata), .rx_map_we(rx_map_we), .rx_cfg_we(rx_cfg_we), .rx_cfg_addr(rx_cfg_addr),
        .rx_cfg_wdata(rx_cfg_wdata), .ev_tx(ev_tx), .ev_a(ev_a), .ev_b(ev_b), .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver), .ev_gdrop(ev_gdrop), .rtc_rdata(rtc_rdata), .rtc_sync_count(rtc_sync_count),
        .snmp_control_data(snmp_control_data), .snmp_status_data(snmp_status_data), .snmp_descr_data(snmp_descr_data),
        .load_rdata(load_rdata), .load_extra_data(load_extra_data));
endmodule
