// AFDX 端系统顶层封装模块（AFDX_top）
// 对上提供“2 字节大端 VLID + 原始载荷”的连续应用字节流接口，帧间至少间隔一拍空闲；
// 对下连接 A/B 双冗余千兆以太网 GMII 收发接口，并提供 32 位主机配置与统计访问总线。
// 接收流不启用下游反压，rx_ready 端口按顶层接口定义保留悬空。
`ifndef AFDX_CE_DIV
`define AFDX_CE_DIV 2
`endif

module AFDX_top #(
    parameter CE_DIV = `AFDX_CE_DIV,
    parameter TX_PAGE_AW = 8,
    parameter TX_OFF_AW = 9,
    parameter LOOKAHEAD = 512,
    parameter RX_RING_AW = 12,
    parameter RX_DQ_AW = 5,
    parameter RX_CONFIG_BANKS = 16
) (
    // 全局同步时钟（125 MHz）与高有效同步复位
    input wire clk,
    input wire reset,

    // 应用发送字节流接口（首 2 字节为大端 VLID，紧接 1~8192 B 载荷）
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready,

    // 应用接收字节流接口（首 2 字节为大端 VLID，忽略 rx_ready 反压）
    output wire [7:0] rx_data,
    output wire rx_valid,
    input wire rx_ready,

    // A/B 双冗余网络 GMII 接口
    output wire [7:0] gmii_txd_a,
    output wire [7:0] gmii_txd_b,
    output wire gmii_tx_en_a,
    output wire gmii_tx_en_b,
    input wire [7:0] gmii_rxd_a,
    input wire [7:0] gmii_rxd_b,
    input wire gmii_rx_dv_a,
    input wire gmii_rx_dv_b,

    // 主机配置与 MIB/统计访问总线（32 位字寻址）
    input wire cfg_wr,
    input wire cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output wire [31:0] cfg_rdata,
    output wire cfg_rvalid,
    output wire cfg_ready,

    // 状态与异常事件单拍指示脉冲
    output wire [6:0] ev_tx,
    output wire [7:0] ev_a,
    output wire [7:0] ev_b,
    output wire ev_rm_drop,
    output wire ev_deliver,
    output wire [2:0] ev_app
);

    // 配置总线地址映射常量（与 afdx_cfg 寄存器译码空间一致）：
    //   0x01000..0x013FF：128 项发送 VL 配置表（每项 8 字，偏移 2 存放 16 位 VLID）
    //   0x10000..0x1FFFF：64K 项接收 VL 映射表（低 12 位为内部索引，第 12 位为使能标志）
    localparam [7:0] CFG_TX_VL_PREFIX = 8'b00000100;
    localparam CFG_TX_VLID_WORD = 2;
    localparam [1:0] CFG_RX_MAP_SPACE = 2'b01;
    localparam CFG_RX_MAP_EN_BIT = 12;

    wire initialized;
    wire m_valid, m_ready, m_last;
    wire d_valid, d_last;
    wire [1:0] app_cfg_ready;
    wire [7:0] m_data, d_data;
    wire [6:0] m_vl;
    wire [11:0] d_index;

    // 核心交付端口包含片上服务分流组合选择，在封装边界整组打拍后再送入接收缓存
    (* preserve = 1, dont_merge = 1 *) reg delivery_valid, delivery_last;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] delivery_data;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] delivery_index;

    always @(posedge clk) begin
        if (reset) begin
            delivery_valid <= 0;
            delivery_last <= 0;
            delivery_data <= 0;
            delivery_index <= 0;
        end
        else begin
            delivery_valid <= d_valid;
            delivery_last <= d_last;
            delivery_data <= d_data;
            delivery_index <= d_index;
        end
    end

    // 同步监听主机对发送 VL 表与接收映射表的写操作，维护应用层 VLID 正/反向查找表
    (* preserve = 1, dont_merge = 1 *) reg tx_cfg_write, rx_cfg_write;
    (* preserve = 1, dont_merge = 1 *) reg [6:0] tx_cfg_index;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] rx_cfg_index;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] tx_cfg_vlid, rx_cfg_vlid;

    always @(posedge clk) begin
        if (reset) begin
            tx_cfg_write <= 0;
            rx_cfg_write <= 0;
            tx_cfg_index <= 0;
            rx_cfg_index <= 0;
            tx_cfg_vlid <= 0;
            rx_cfg_vlid <= 0;
        end
        else begin
            tx_cfg_write <= cfg_wr && app_cfg_ready[0]
                && cfg_addr[17:10] == CFG_TX_VL_PREFIX
                && cfg_addr[2:0] == CFG_TX_VLID_WORD;
            rx_cfg_write <= cfg_wr && app_cfg_ready[1]
                && cfg_addr[17:16] == CFG_RX_MAP_SPACE
                && cfg_wdata[CFG_RX_MAP_EN_BIT];
            tx_cfg_index <= cfg_addr[9:3];
            tx_cfg_vlid <= cfg_wdata[15:0];
            rx_cfg_index <= cfg_wdata[11:0];
            rx_cfg_vlid <= cfg_addr[15:0];
        end
    end

    // 应用发送适配层：剥离首 2 字节 VLID，整包缓存并并行查找内部发送 VL 索引
    afdx_app_tx application_tx (
        .clk(clk),
        .reset(reset),
        .initialized(initialized),
        .data(tx_data),
        .valid(tx_valid),
        .ready(tx_ready),
        .cfg_write(tx_cfg_write),
        .cfg_index(tx_cfg_index),
        .cfg_vlid(tx_cfg_vlid),
        .app_valid(m_valid),
        .app_ready(m_ready),
        .app_data(m_data),
        .app_last(m_last),
        .app_vl(m_vl),
        .drop(ev_app[1:0])
    );

    // 应用接收适配层：反查 16 位 VLID 并在重组载荷前插入 2 字节 VLID 首部连续输出
    afdx_app_rx application_rx (
        .clk(clk),
        .reset(reset),
        .cfg_write(rx_cfg_write),
        .cfg_index(rx_cfg_index),
        .cfg_vlid(rx_cfg_vlid),
        .app_valid(delivery_valid),
        .app_data(delivery_data),
        .app_last(delivery_last),
        .app_index(delivery_index),
        .valid(rx_valid),
        .data(rx_data),
        .drop(ev_app[2])
    );

    // AFDX 端系统协议与双网收发核心（含 BAG 调度、分片重组及 SNTP/SNMP/ARINC 615A 服务）
    afdx_es #(
        .CE_DIV(CE_DIV),
        .TX_PAGE_AW(TX_PAGE_AW),
        .TX_OFF_AW(TX_OFF_AW),
        .LOOKAHEAD(LOOKAHEAD),
        .RX_RING_AW(RX_RING_AW),
        .RX_DQ_AW(RX_DQ_AW),
        .RX_CONFIG_BANKS(RX_CONFIG_BANKS)
    ) es (
        .clk(clk),
        .reset(reset),
        .tx_data(gmii_txd_a),
        .tx_valid(gmii_tx_en_a),
        .rx_data(gmii_rxd_a),
        .rx_valid(gmii_rx_dv_a),
        .tx_ready(initialized),
        .rx_ready(1'b0),
        .tx_data_b(gmii_txd_b),
        .tx_valid_b(gmii_tx_en_b),
        .rx_data_b(gmii_rxd_b),
        .rx_valid_b(gmii_rx_dv_b),
        .app_tx_valid(m_valid),
        .app_tx_ready(m_ready),
        .app_tx_data(m_data),
        .app_tx_last(m_last),
        .app_tx_vl(m_vl),
        .app_tx_port_en(1'b0),
        .app_tx_sport(16'd0),
        .app_tx_dport(16'd0),
        .app_rx_valid(d_valid),
        .app_rx_data(d_data),
        .app_rx_last(d_last),
        .app_rx_vl(d_index),
        .app_rx_port(),
        .app_rx_sport(),
        .app_rx_net(),
        .cfg_wr(cfg_wr),
        .cfg_rd(cfg_rd),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata),
        .cfg_rvalid(cfg_rvalid),
        .cfg_ready(cfg_ready),
        .app_cfg_ready(app_cfg_ready),
        .ev_tx(ev_tx),
        .ev_a(ev_a),
        .ev_b(ev_b),
        .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver)
    );

endmodule
