// 本模块是 AFDX 端系统的顶层，把双网收发核心和三种服务连接在一起。
// AFDX（Avionics Full-Duplex Switched Ethernet）
// 是航空电子全双工交换式以太网。
// 应用消息经收发核心送到两路以太网，也从两路网络交付给应用。
// 本模块提供赛题要求的收发、网络管理、加卸载和时钟同步功能。
module AFDX_top #(
    parameter TX_PAGE_AW = 8,
    parameter TX_OFF_AW = 9,
    parameter LOOKAHEAD = 512,
    parameter RX_RING_AW = 12,
    parameter RX_DQ_AW = 5) (

    // 下面八个端口与赛题模板一致，其中的数据口连接 A 网。
    // A 网和 B 网是互为备份的两路以太网，同一帧在两路上各发一份。
    input wire clk, // 所有模块在 clk 的上升沿工作，时钟频率为 125 MHz。
    input wire reset, // reset 为高时，在时钟上升沿复位。
    output wire [7:0] tx_data, // tx_valid 为高时，tx_data 是 A 网本拍发送的字节（含前导码和帧校验值）。
    input wire [7:0] rx_data, // rx_valid 为高时，rx_data 是 A 网本拍接收的字节。
    output wire tx_valid, // tx_valid 为高表示本拍有发送字节，帧内每拍都有效。
    input wire rx_valid, // rx_valid 为高表示本拍有接收字节，拉低表示帧已结束。
    output wire tx_ready, // tx_ready 为高表示收发核心初始化完成，可以配置和使用。
    input wire rx_ready, // rx_ready 是赛题模板规定的端口；以太网线路不能暂停，本设计不使用它。

    // 下面四个是 B 网的数据口，含义与 A 网的对应端口相同。
    output wire [7:0] tx_data_b,
    output wire tx_valid_b,
    input wire [7:0] rx_data_b,
    input wire rx_valid_b,

    // 应用在 app_tx_valid 和 app_tx_ready 同为高时送入一个字节。
    // app_tx_last 标记消息末字节，app_tx_vl 选择发送配置项。
    // app_tx_port_en 为高时使用消息自带端口，否则使用配置中的端口。
    input wire app_tx_valid,
    output wire app_tx_ready,
    input wire [7:0] app_tx_data,
    input wire app_tx_last,
    input wire [6:0] app_tx_vl,
    input wire app_tx_port_en,
    input wire [15:0] app_tx_sport, app_tx_dport,

    // app_rx_valid 为高时，应用必须接收本拍的字节。
    // app_rx_last 标记消息末字节，app_rx_vl 是接收配置索引。
    // app_rx_port 和 app_rx_sport 分别给出目的端口和源端口。
    // app_rx_net 为 0 表示来自 A 网，为 1 表示来自 B 网。
    output wire app_rx_valid,
    output wire [7:0] app_rx_data,
    output wire app_rx_last,
    output wire [11:0] app_rx_vl,
    output wire [15:0] app_rx_port, app_rx_sport,
    output wire app_rx_net,

    // cfg_wr 和 cfg_ready 同为高时，模块接收一次写请求。
    // cfg_rd 发起读请求，两拍后 cfg_rvalid 指示 cfg_rdata 有效。
    // cfg_addr 按 32 位字寻址。
    input wire cfg_wr, cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output wire [31:0] cfg_rdata,
    output wire cfg_rvalid, cfg_ready,

    // ev_tx 报告发送结果，ev_a 和 ev_b 分别报告两网接收结果。
    // ev_rm_drop 表示丢弃一份重复帧，ev_deliver 表示接纳一条消息。
    // ev_gdrop 是预留的丢帧事件口，本设计中固定为零。
    output wire [6:0] ev_tx,
    output wire [7:0] ev_a, ev_b,
    output wire ev_rm_drop, ev_deliver,
    output wire [1:0] ev_gdrop);

    // tx_ready_q 保存收发核心都已初始化的结果。
    reg tx_ready_q;

    assign tx_ready = tx_ready_q;

    // now 供发送调度计时，now_c 供接收引擎判断重复帧。
    // 两路核心都初始化完成后，顶层才允许服务开始工作。
    wire [31:0] now;
    wire [15:0] now_c, user_id;
    wire byte_en, tx_initialized, rx_initialized;
    wire tx_cfg_ok, rx_cfg_ok, tx_cfg_we, rx_map_we, rx_cfg_we;
    wire [9:0] tx_cfg_addr;
    wire [32 * 16 - 1:0] rx_cfg_addr;
    wire [31:0] tx_cfg_wdata;
    wire [32 * 32 - 1:0] rx_cfg_wdata;

    // 收发核心直接连接千兆线路，中间没有会丢帧的缓存，所以 ev_gdrop 固定为零。
    assign ev_gdrop = 2'b00;
    wire m_valid, m_ready, m_last, m_port_en;
    wire [7:0] m_data, d_data, rtc_tx_data, svc_rx_data;
    wire [6:0] m_vl, rtc_tx_vl;
    wire [15:0] m_sport, m_dport, d_sport, d_dport, rtc_port, svc_rx_port, svc_rx_sport;
    wire d_valid, d_last, d_net, rtc_tx_valid, rtc_tx_last, rtc_claim, svc_rx_valid, svc_rx_last;
    wire [11:0] d_vl;
    wire [2:0] svc_tx_ready;
    wire [31:0] rtc_rdata, rtc_sync_count;
    wire snmp_tx_valid, snmp_tx_last, snmp_claim, snmp_mib_rd, snmp_mib_wr, snmp_mib_ready, snmp_grant;
    wire [7:0] snmp_tx_data;
    wire [6:0] snmp_tx_vl;
    wire [15:0] snmp_tx_dport;
    wire [17:0] snmp_mib_addr, bus_addr;
    wire [31:0] snmp_mib_wdata;
    wire [31:0] snmp_control_data, snmp_status_data, snmp_descr_data;
    wire load_tx_valid, load_tx_last, load_claim;
    wire [7:0] load_tx_data;
    wire [6:0] load_tx_vl;
    wire [15:0] load_tx_sport, load_tx_dport;
    wire [31:0] load_rdata, load_extra_data;
    wire bus_rd, mib_user_write;

    // 主机和网络管理服务共用配置读口。
    // 各自的读有效标记延后两拍，与返回数据对齐。
    reg [1:0] host_read_pipe, snmp_read_pipe;

    // 主机优先读取；两者读同一地址时，共用本次读取结果。
    assign snmp_mib_ready = ! cfg_wr && ( ! cfg_rd || ( ! snmp_mib_wr && cfg_addr == snmp_mib_addr))
        && ( ! snmp_mib_wr || cfg_ready);

    assign snmp_grant = (snmp_mib_rd || snmp_mib_wr) && snmp_mib_ready;
    // 主机正在读写时地址直接来自主机，其余时间预选网络管理读地址。
    // 网络管理仅能写 user_id，独立分发该写使能，避免写握手进入所有读地址和 RTC 控制链。
    assign bus_addr = (cfg_rd || cfg_wr) ? cfg_addr : snmp_mib_addr;
    assign bus_rd = cfg_rd || (snmp_grant && snmp_mib_rd);
    assign mib_user_write = snmp_grant && snmp_mib_wr && snmp_mib_addr == 18'h00002;
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

    // 时钟配置位于 0x80 组。
    // 网络管理配置位于 0x90、0x98 和 0xa0 组。
    // 网络管理模块会收到地址高位为零的全部写操作，再由模块内部按低 8 位挑出自己的寄存器。
    // 加卸载配置位于 0xb0 和 0xb8 组。
    // 每 16 个地址为一组，下面是时钟同步和加卸载两组地址的高 14 位。
    localparam RTC_ADDR_GROUP = 14'h0008, LOAD_ADDR_GROUP = 14'h000b;

    // 网络管理回应使用的 UDP 源端口。
    localparam SNMP_PORT = 16'd161;
    wire rtc_select = (bus_addr[17:4] == RTC_ADDR_GROUP);
    afdx_615a #(.LOCAL_RX_PORT(1), .SPLIT_CFG_ADDR(1)) loader (
        .clk(clk),
        .reset(reset),
        .enable(tx_ready),
        .cfg_we(cfg_wr && cfg_ready && cfg_addr[17:4] == LOAD_ADDR_GROUP),
        .cfg_addr({cfg_addr[7:0], bus_addr[2:0]}),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(load_rdata),
        .cfg_extra_data(load_extra_data),
        .tx_valid(load_tx_valid),
        .tx_ready(svc_tx_ready[2]),
        .tx_data(load_tx_data),
        .tx_last(load_tx_last),
        .tx_vl(load_tx_vl),
        .tx_sport(load_tx_sport),
        .tx_dport(load_tx_dport),
        .rx_valid(svc_rx_valid),
        .rx_data(svc_rx_data),
        .rx_last(svc_rx_last),
        .rx_sport(svc_rx_sport),
        .rx_dport(svc_rx_port),
        .rx_claim(load_claim)
    );
    afdx_snmp #(.LOCAL_RX_PORT(1), .SPLIT_CFG_ADDR(1)) snmp (
        .clk(clk),
        .reset(reset),
        .enable(tx_ready),
        .now(now),
        .cfg_we(cfg_wr && cfg_ready && cfg_addr[17:8] == 0),
        .cfg_addr({cfg_addr[7:0], bus_addr[2:0]}),
        .cfg_wdata(cfg_wdata),
        .cfg_control_data(snmp_control_data),
        .cfg_status_data(snmp_status_data),
        .cfg_descr_data(snmp_descr_data),
        .mib_rd(snmp_mib_rd),
        .mib_wr(snmp_mib_wr),
        .mib_wdata(snmp_mib_wdata),
        .mib_addr(snmp_mib_addr),
        .mib_ready(snmp_mib_ready),
        .mib_rvalid(snmp_read_pipe[1]),
        .mib_rdata(cfg_rdata),
        .tx_valid(snmp_tx_valid),
        .tx_ready(svc_tx_ready[1]),
        .tx_data(snmp_tx_data),
        .tx_last(snmp_tx_last),
        .tx_vl(snmp_tx_vl),
        .tx_dport(snmp_tx_dport),
        .rx_valid(svc_rx_valid),
        .rx_data(svc_rx_data),
        .rx_last(svc_rx_last),
        .rx_sport(svc_rx_sport),
        .rx_dport(svc_rx_port),
        .rx_claim(snmp_claim)
    );
    afdx_rtc #(.LOCAL_RX_PORT(1), .BANKED_RX(1), .SPLIT_CFG_ADDR(1)) rtc (
        .clk(clk),
        .reset(reset),
        .enable(tx_ready),
        .cfg_we(cfg_wr && cfg_ready && cfg_addr[17:4] == RTC_ADDR_GROUP),
        .cfg_re(bus_rd && rtc_select),
        .cfg_addr({cfg_addr[3:0], bus_addr[3:0]}),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(rtc_rdata),
        .sync_count(rtc_sync_count),
        .tx_valid(rtc_tx_valid),
        .tx_ready(svc_tx_ready[0]),
        .tx_data(rtc_tx_data),
        .tx_last(rtc_tx_last),
        .tx_vl(rtc_tx_vl),
        .tx_port(rtc_port),
        .rx_valid(svc_rx_valid),
        .rx_data(svc_rx_data),
        .rx_last(svc_rx_last),
        .rx_port(svc_rx_port),
        .rx_claim(rtc_claim)
    );

    // afdx_svc 每次选一条完整消息发送，并按接收端口分配消息。
    afdx_svc service_channel (
        .clk(clk),
        .reset(reset),
        .app_tx_valid(app_tx_valid),
        .app_tx_ready(app_tx_ready),
        .app_tx_data(app_tx_data),
        .app_tx_last(app_tx_last),
        .app_tx_vl(app_tx_vl),
        .app_tx_port_en(app_tx_port_en),
        .app_tx_sport(app_tx_sport),
        .app_tx_dport(app_tx_dport),
        .svc_tx_valid({ load_tx_valid, snmp_tx_valid, rtc_tx_valid }),
        .svc_tx_ready(svc_tx_ready),
        .svc_tx_data({ load_tx_data, snmp_tx_data, rtc_tx_data }),
        .svc_tx_last({ load_tx_last, snmp_tx_last, rtc_tx_last }),
        .svc_tx_vl({ load_tx_vl, snmp_tx_vl, rtc_tx_vl }),
        .svc_tx_port_en(3'b111),
        .svc_tx_sport({ load_tx_sport, SNMP_PORT, rtc_port }),
        .svc_tx_dport({ load_tx_dport, snmp_tx_dport, rtc_port }),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_data(m_data),
        .m_last(m_last),
        .m_vl(m_vl),
        .m_port_en(m_port_en),
        .m_sport(m_sport),
        .m_dport(m_dport),
        .d_valid(d_valid),
        .d_data(d_data),
        .d_last(d_last),
        .d_vl(d_vl),
        .d_sport(d_sport),
        .d_dport(d_dport),
        .d_net(d_net),
        .svc_rx_claim({ load_claim, snmp_claim, rtc_claim }),
        .svc_rx_valid(svc_rx_valid),
        .svc_rx_data(svc_rx_data),
        .svc_rx_last(svc_rx_last),
        .svc_rx_vl(),
        .svc_rx_sport(svc_rx_sport),
        .svc_rx_dport(svc_rx_port),
        .svc_rx_net(),
        .app_rx_valid(app_rx_valid),
        .app_rx_data(app_rx_data),
        .app_rx_last(app_rx_last),
        .app_rx_vl(app_rx_vl),
        .app_rx_sport(app_rx_sport),
        .app_rx_dport(app_rx_port),
        .app_rx_net(app_rx_net)
    );

    always @(posedge clk) begin
        if (reset) tx_ready_q <= 0;
        else tx_ready_q <= tx_initialized && rx_initialized;
    end

    // 双网收发核心直接连接线路，每拍处理一个字节。
    afdx_timebase timebase (
        .clk(clk),
        .reset(reset),
        .now(now),
        .byte_en(byte_en),
        .now_c(now_c)
    );
    afdx_tx_core #(
        .TX_PAGE_AW(TX_PAGE_AW),
        .TX_OFF_AW(TX_OFF_AW),
        .LOOKAHEAD(LOOKAHEAD)
    ) tx_core (
        .clk(clk),
        .reset(reset),
        .now(now),
        .byte_en(byte_en),
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_data(m_data),
        .m_last(m_last),
        .m_vl(m_vl),
        .m_port_en(m_port_en),
        .m_sport(m_sport),
        .m_dport(m_dport),
        .cfg_we(tx_cfg_we),
        .cfg_addr(tx_cfg_addr),
        .cfg_wdata(tx_cfg_wdata),
        .user_id(user_id),
        .tx_data_a(tx_data),
        .tx_valid_a(tx_valid),
        .tx_data_b(tx_data_b),
        .tx_valid_b(tx_valid_b),
        .init_done(tx_initialized),
        .ev_accept(ev_tx[0]),
        .ev_drop_dis(ev_tx[1]),
        .ev_drop_full(ev_tx[2]),
        .ev_drop_long(ev_tx[3]),
        .ev_drop_nopage(ev_tx[4]),
        .ev_tx_a(ev_tx[5]),
        .ev_tx_b(ev_tx[6]),
        .cfg_ok(tx_cfg_ok)
    );
    afdx_rx_core #(
        .RX_RING_AW(RX_RING_AW),
        .RX_DQ_AW(RX_DQ_AW),
        .CFG_COPIES(32)
    ) rx_core (
        .clk(clk),
        .reset(reset),
        .now_c(now_c),
        .rx_data_a(rx_data),
        .rx_valid_a(rx_valid),
        .rx_data_b(rx_data_b),
        .rx_valid_b(rx_valid_b),
        .cfg_map_we(rx_map_we),
        .cfg_cfg_we(rx_cfg_we),
        .cfg_addr(rx_cfg_addr),
        .cfg_wdata(rx_cfg_wdata),
        .d_valid(d_valid),
        .d_data(d_data),
        .d_last(d_last),
        .d_vl(d_vl),
        .d_sport(d_sport),
        .d_dport(d_dport),
        .d_net(d_net),
        .init_done(rx_initialized),
        .ev_a(ev_a),
        .ev_b(ev_b),
        .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver),
        .cfg_ok(rx_cfg_ok)
    );
    afdx_cfg #(.RX_BUS_COPIES(32)) cfg_regs (
        .clk(clk),
        .reset(reset),
        .tx_ready(tx_ready),
        .cfg_wr(cfg_wr),
        .cfg_rd(bus_rd),
        .cfg_addr(bus_addr),
        .cfg_write_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .mib_user_wr(mib_user_write),
        .mib_user_wdata(snmp_mib_wdata[15:0]),
        .mib_read_addr(snmp_mib_addr),
        .host_read(cfg_rd),
        .host_read_addr(cfg_addr[2:0]),
        .cfg_ready(cfg_ready),
        .cfg_rvalid(),
        .cfg_rdata(cfg_rdata),
        .user_id(user_id),
        .tx_cfg_ok(tx_cfg_ok),
        .rx_cfg_ok(rx_cfg_ok),
        .tx_cfg_we(tx_cfg_we),
        .tx_cfg_addr(tx_cfg_addr),
        .tx_cfg_wdata(tx_cfg_wdata),
        .rx_map_we(rx_map_we),
        .rx_cfg_we(rx_cfg_we),
        .rx_cfg_addr(rx_cfg_addr),
        .rx_cfg_wdata(rx_cfg_wdata),
        .ev_tx(ev_tx),
        .ev_a(ev_a),
        .ev_b(ev_b),
        .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver),
        .ev_gdrop(ev_gdrop),
        .rtc_rdata(rtc_rdata),
        .rtc_sync_count(rtc_sync_count),
        .snmp_control_data(snmp_control_data),
        .snmp_status_data(snmp_status_data),
        .snmp_descr_data(snmp_descr_data),
        .load_rdata(load_rdata),
        .load_extra_data(load_extra_data)
    );

endmodule
