// 配置总线译码、核心配置写握手和事件统计。
// cfg_*为外部总线；tx/rx配置口及服务寄存器读值接至对应模块。
// 配置读分两拍返回；计数器在采样边沿读取此前已累计的事件。
// 配置总线：表写保持到核心握手，读出用两级选择，统计只由对应脉冲累加。
module afdx_cfg (
    // clk/reset 为同步控制；tx_ready 表示收发核心均已初始化。
    input wire clk, reset, tx_ready,
    // cfg_wr/ready 完成写请求；cfg_rd 发起读，cfg_rvalid/rdata 两拍返回，不用于读回配置表 RAM。
    input wire cfg_wr, cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg cfg_ready, cfg_rvalid,
    output reg [31:0] cfg_rdata,
    // user_id 为源 MAC 端系统编号；tx/rx_cfg_ok 指示各核心允许写表。
    output reg [15:0] user_id,
    input wire tx_cfg_ok, rx_cfg_ok,
    // tx_cfg_* 写发送 VL 表；rx_map_we 写 VLID 映射，rx_cfg_we 写接收 VL 参数。
    output reg tx_cfg_we,
    output reg [9:0] tx_cfg_addr,
    output reg [31:0] tx_cfg_wdata,
    output reg rx_map_we, rx_cfg_we,
    output reg [15:0] rx_cfg_addr,
    output reg [31:0] rx_cfg_wdata,
    // ev_tx[0:6] 依次累计接纳/禁用/队满/过长/无页/A发完/B发完。
    input wire [6:0] ev_tx,
    // ev_a/b[0:7] 依次累计完好/FCS/长度/协议头/未知VL/配置/完整性/溢出。
    input wire [7:0] ev_a, ev_b,
    // ev_rm_drop/deliver/gdrop 为冗余丢弃、接纳和适配器丢弃；服务 rdata/count 接对应寄存器读值。
    input wire ev_rm_drop, ev_deliver,
    input wire [1:0] ev_gdrop,
    input wire [31:0] rtc_rdata, rtc_sync_count,
    input wire [31:0] snmp_control_data, snmp_status_data, snmp_descr_data, load_rdata, load_extra_data);
    // 地址译码：0x01000–0x013ff 为发送表，0x10000–0x1ffff 为映射表，0x20000–0x20fff 为接收表。
    wire select_tx = (cfg_addr[17:10] == 8'b00000100);
    wire select_map = (cfg_addr[17:16] == 2'b01);
    wire select_rx = (cfg_addr[17:12] == 6'b100000);
    // read_valid/read_select 对齐两拍读响应；read_loader 区分共享服务地址组内的数据源。
    reg read_valid;
    reg [2:0] read_select;
    reg [1:0] read_loader;
    reg [31:0] read_regs, read_tx, read_a, read_b;
    // 27 个独立统计寄存器，不是按 VL 展开的状态表。
    reg [31:0] count_accept;
    reg [31:0] count_drop_dis;
    reg [31:0] count_drop_full;
    reg [31:0] count_drop_long;
    reg [31:0] count_drop_nopage;
    reg [31:0] count_tx_a;
    reg [31:0] count_tx_b;
    reg [31:0] count_a_good;
    reg [31:0] count_a_fcs;
    reg [31:0] count_a_len;
    reg [31:0] count_a_hdr;
    reg [31:0] count_a_unk;
    reg [31:0] count_a_cfg;
    reg [31:0] count_a_ic;
    reg [31:0] count_a_ovf;
    reg [31:0] count_b_good;
    reg [31:0] count_b_fcs;
    reg [31:0] count_b_len;
    reg [31:0] count_b_hdr;
    reg [31:0] count_b_unk;
    reg [31:0] count_b_cfg;
    reg [31:0] count_b_ic;
    reg [31:0] count_b_ovf;
    reg [31:0] count_rm_drop;
    reg [31:0] count_deliver;
    reg [31:0] count_a_gdrop, count_b_gdrop;
    always @(posedge clk) begin
        if (reset) begin
            count_accept <= 0;
            count_drop_dis <= 0;
            count_drop_full <= 0;
            count_drop_long <= 0;
            count_drop_nopage <= 0;
            count_tx_a <= 0;
            count_tx_b <= 0;
            count_a_good <= 0;
            count_a_fcs <= 0;
            count_a_len <= 0;
            count_a_hdr <= 0;
            count_a_unk <= 0;
            count_a_cfg <= 0;
            count_a_ic <= 0;
            count_a_ovf <= 0;
            count_b_good <= 0;
            count_b_fcs <= 0;
            count_b_len <= 0;
            count_b_hdr <= 0;
            count_b_unk <= 0;
            count_b_cfg <= 0;
            count_b_ic <= 0;
            count_b_ovf <= 0;
            count_rm_drop <= 0;
            count_deliver <= 0;
            count_a_gdrop <= 0;
            count_b_gdrop <= 0;
        end
        else begin
            // 事件统计：只累加公开单拍事件，复位清零；读取不清计数。
            if (ev_tx[0]) count_accept <= count_accept + 32'd1;
            if (ev_tx[1]) count_drop_dis <= count_drop_dis + 32'd1;
            if (ev_tx[2]) count_drop_full <= count_drop_full + 32'd1;
            if (ev_tx[3]) count_drop_long <= count_drop_long + 32'd1;
            if (ev_tx[4]) count_drop_nopage <= count_drop_nopage + 32'd1;
            if (ev_tx[5]) count_tx_a <= count_tx_a + 32'd1;
            if (ev_tx[6]) count_tx_b <= count_tx_b + 32'd1;
            if (ev_a[0]) count_a_good <= count_a_good + 32'd1;
            if (ev_a[1]) count_a_fcs <= count_a_fcs + 32'd1;
            if (ev_a[2]) count_a_len <= count_a_len + 32'd1;
            if (ev_a[3]) count_a_hdr <= count_a_hdr + 32'd1;
            if (ev_a[4]) count_a_unk <= count_a_unk + 32'd1;
            if (ev_a[5]) count_a_cfg <= count_a_cfg + 32'd1;
            if (ev_a[6]) count_a_ic <= count_a_ic + 32'd1;
            if (ev_a[7]) count_a_ovf <= count_a_ovf + 32'd1;
            if (ev_b[0]) count_b_good <= count_b_good + 32'd1;
            if (ev_b[1]) count_b_fcs <= count_b_fcs + 32'd1;
            if (ev_b[2]) count_b_len <= count_b_len + 32'd1;
            if (ev_b[3]) count_b_hdr <= count_b_hdr + 32'd1;
            if (ev_b[4]) count_b_unk <= count_b_unk + 32'd1;
            if (ev_b[5]) count_b_cfg <= count_b_cfg + 32'd1;
            if (ev_b[6]) count_b_ic <= count_b_ic + 32'd1;
            if (ev_b[7]) count_b_ovf <= count_b_ovf + 32'd1;
            if (ev_rm_drop) count_rm_drop <= count_rm_drop + 32'd1;
            if (ev_deliver) count_deliver <= count_deliver + 32'd1;
            if (ev_gdrop[0]) count_a_gdrop <= count_a_gdrop + 32'd1;
            if (ev_gdrop[1]) count_b_gdrop <= count_b_gdrop + 32'd1;
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            cfg_ready <= 0;
            user_id <= 0;
            tx_cfg_we <= 0;
            tx_cfg_addr <= 0;
            tx_cfg_wdata <= 0;
            rx_map_we <= 0;
            rx_cfg_we <= 0;
            rx_cfg_addr <= 0;
            rx_cfg_wdata <= 0;
        end
        // 写握手状态由 tx_cfg_we/rx_map_we/rx_cfg_we 表示：待核心接收时保持地址/数据并拉低 ready。
        else if (! tx_ready) begin
            cfg_ready <= 0;
            tx_cfg_we <= 0;
            rx_map_we <= 0;
            rx_cfg_we <= 0;
        end
        else if (tx_cfg_we) begin
            // 当前拍核心接收后，下一可观察拍恢复总线 ready。
            if (tx_cfg_ok) begin
                tx_cfg_we <= 0;
                cfg_ready <= 1;
            end
        end
        else if (rx_map_we || rx_cfg_we) begin
            if (rx_cfg_ok) begin
                rx_map_we <= 0;
                rx_cfg_we <= 0;
                cfg_ready <= 1;
            end
        end
        else begin
            cfg_ready <= 1;
            if (cfg_wr && cfg_ready) begin
                if (select_tx) begin
                    tx_cfg_we <= 1;
                    tx_cfg_addr <= cfg_addr[9:0];
                    tx_cfg_wdata <= cfg_wdata;
                    cfg_ready <= 0;
                end
                else if (select_map || select_rx) begin
                    rx_map_we <= select_map;
                    rx_cfg_we <= select_rx;
                    rx_cfg_addr <= cfg_addr[15:0];
                    rx_cfg_wdata <= cfg_wdata;
                    cfg_ready <= 0;
                end
                else if (cfg_addr == 18'h00002) begin
                    user_id <= cfg_wdata[15:0];
                end
            end
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            read_valid <= 0;
            cfg_rvalid <= 0;
            read_select <= 0;
            read_loader <= 0;
            read_regs <= 0;
            read_tx <= 0;
            read_a <= 0;
            read_b <= 0;
            cfg_rdata <= 0;
        end
        else begin
            // 沿 t 快照旧寄存器值：含 t-1 以前的脉冲，不包含 t 的脉冲。
            // 读流水：第一拍选择并快照各组，第二拍按延迟选择码输出；不存在独立读状态机。
            read_valid <= cfg_rd;
            case (cfg_addr)
                18'h00000 : read_regs <= 32'hc3110000;
                18'h00001 : read_regs <= { 31'b0, tx_ready };
                18'h00002 : read_regs <= { 16'b0, user_id };
                18'h00058 : read_regs <= count_rm_drop;
                18'h00059 : read_regs <= count_deliver;
                18'h0005a : read_regs <= count_a_gdrop;
                18'h0005b : read_regs <= count_b_gdrop;
                18'h00088 : read_regs <= rtc_sync_count;
                default : read_regs <= 0;
            endcase
            case (cfg_addr[2:0])
                3'd0 : read_tx <= count_accept;
                3'd1 : read_tx <= count_drop_dis;
                3'd2 : read_tx <= count_drop_full;
                3'd3 : read_tx <= count_drop_long;
                3'd4 : read_tx <= count_drop_nopage;
                3'd5 : read_tx <= count_tx_a;
                3'd6 : read_tx <= count_tx_b;
                default : read_tx <= 0;
            endcase
            case (cfg_addr[2:0])
                3'd0 : read_a <= count_a_good;
                3'd1 : read_a <= count_a_fcs;
                3'd2 : read_a <= count_a_len;
                3'd3 : read_a <= count_a_hdr;
                3'd4 : read_a <= count_a_unk;
                3'd5 : read_a <= count_a_cfg;
                3'd6 : read_a <= count_a_ic;
                3'd7 : read_a <= count_a_ovf;
            endcase
            case (cfg_addr[2:0])
                3'd0 : read_b <= count_b_good;
                3'd1 : read_b <= count_b_fcs;
                3'd2 : read_b <= count_b_len;
                3'd3 : read_b <= count_b_hdr;
                3'd4 : read_b <= count_b_unk;
                3'd5 : read_b <= count_b_cfg;
                3'd6 : read_b <= count_b_ic;
                3'd7 : read_b <= count_b_ovf;
            endcase
            case (cfg_addr[17:3])
                15'h0008 : read_select <= 1;
                15'h0009 : read_select <= 2;
                15'h000a : read_select <= 3;
                15'h0010 : read_select <= 4;
                15'h0012 : read_select <= 5;
                15'h0013 : read_select <= 6;
                15'h0014 : read_select <= 7;
                15'h0016 : read_select <= 7;
                15'h0017 : read_select <= 7;
                default : read_select <= 0;
            endcase
            read_loader <= cfg_addr[17:3] == 15'h0016 ? 1 : cfg_addr[17:3] == 15'h0017 ? 2 : 0;
            // 每组最多八选一，第二级八选一；NBA 前观察恰好是 t+2。
            cfg_rvalid <= read_valid;
            case (read_select)
                3'd0 : cfg_rdata <= read_regs;
                3'd1 : cfg_rdata <= read_tx;
                3'd2 : cfg_rdata <= read_a;
                3'd3 : cfg_rdata <= read_b;
                3'd4 : cfg_rdata <= rtc_rdata;
                3'd5 : cfg_rdata <= snmp_control_data;
                3'd6 : cfg_rdata <= snmp_status_data;
                3'd7 : case (read_loader)
                    1 : cfg_rdata <= load_rdata;
                    2 : cfg_rdata <= load_extra_data;
                    default : cfg_rdata <= snmp_descr_data;
                endcase
            endcase
        end
    end
endmodule
