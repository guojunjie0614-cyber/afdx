// 本模块把外部配置读写请求送到对应模块，并统计收发事件。
// 输入来自顶层配置口和各模块的事件脉冲，读结果返回顶层。
// 本模块为赛题的收发配置和网络管理提供寄存器接口。
module afdx_cfg (

    // tx_ready 为高表示收发核心都已初始化。
    input wire clk, reset, tx_ready,

    // cfg_wr 和 cfg_ready 同为高时接收写请求。
    // cfg_rd 发起读请求，两拍后 cfg_rvalid 指示 cfg_rdata 有效。
    // 此读口返回寄存器和统计值，不读回配置存储表。
    input wire cfg_wr, cfg_rd,
    input wire [17:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg cfg_ready, cfg_rvalid,
    output reg [31:0] cfg_rdata,

    // user_id 是源以太网地址中的端系统编号。
    // tx/rx_cfg_ok 为高时，对应核心允许写配置。
    output reg [15:0] user_id,
    input wire tx_cfg_ok, rx_cfg_ok,

    // tx_cfg_* 写发送配置表。
    // rx_map_we 写编号到索引的映射，rx_cfg_we 写接收配置。
    output reg tx_cfg_we,
    output reg [9:0] tx_cfg_addr,
    output reg [31:0] tx_cfg_wdata,
    output reg rx_map_we, rx_cfg_we,
    output reg [15:0] rx_cfg_addr,
    output reg [31:0] rx_cfg_wdata,

    // ev_tx[0] 表示消息被接纳。
    // ev_tx[1] 表示所选虚拟链路未启用。
    // ev_tx[2] 表示消息队列已满。
    // ev_tx[3] 表示消息过长。
    // ev_tx[4] 表示没有空闲页。
    // ev_tx[5] 表示 A 网发送完成。
    // ev_tx[6] 表示 B 网发送完成。
    input wire [6:0] ev_tx,

    // ev_a 和 ev_b 分别报告 A 网和 B 网的事件。
    // 位 0 表示帧校验通过。
    // 位 1 表示帧校验值错误。
    // 位 2 表示帧长或前导码错误。
    // 位 3 表示协议头错误。
    // 位 4 表示虚拟链路编号没有映射。
    // 位 5 表示接收配置不允许此帧。
    // 位 6 表示序号检查失败。
    // 位 7 表示接收缓存或交付队列已满。
    input wire [7:0] ev_a, ev_b,

    // ev_rm_drop 表示丢弃重复帧，ev_deliver 表示接纳消息。
    // ev_gdrop 表示适配器丢帧，当前顶层将它固定为零。
    // 服务模块的读值由对应 rdata/count 输入提供。
    input wire ev_rm_drop, ev_deliver,
    input wire [1:0] ev_gdrop,
    input wire [31:0] rtc_rdata, rtc_sync_count,
    input wire [31:0] snmp_control_data, snmp_status_data, snmp_descr_data, load_rdata, load_extra_data);

    // 0x01000–0x013ff 对应发送配置表。
    // 0x10000–0x1ffff 对应接收编号映射表。
    // 0x20000–0x20fff 对应接收配置表。
    wire select_tx = (cfg_addr[17:10] == 8'b00000100);
    wire select_map = (cfg_addr[17:16] == 2'b01);
    wire select_rx = (cfg_addr[17:12] == 6'b100000);

    // 单个寄存器的地址（按 32 位字编址）和版本号。
    localparam ADDR_VERSION = 18'h00000, ADDR_STATUS = 18'h00001, ADDR_USER_ID = 18'h00002;
    localparam ADDR_RM_DROP = 18'h00058, ADDR_DELIVER = 18'h00059;
    localparam ADDR_A_GDROP = 18'h0005a, ADDR_B_GDROP = 18'h0005b, ADDR_RTC_SYNC_COUNT = 18'h00088;
    localparam VERSION_VALUE = 32'hc3110000;

    // 每 8 个地址为一组，下面是各组地址的高 15 位。
    // 0x40 组是发送计数，0x48、0x50 组是 A、B 网接收计数，0x80 组是时钟同步，
    // 0x90、0x98、0xa0 组是网络管理，0xb0、0xb8 组是加卸载。
    localparam GROUP_TX_COUNT = 15'h0008, GROUP_A_COUNT = 15'h0009, GROUP_B_COUNT = 15'h000a;
    localparam GROUP_RTC = 15'h0010, GROUP_SNMP_CONTROL = 15'h0012, GROUP_SNMP_STATUS = 15'h0013;
    localparam GROUP_SNMP_DESCR = 15'h0014, GROUP_LOAD = 15'h0016, GROUP_LOAD_EXTRA = 15'h0017;

    // read_select 的取值：第二拍从哪一组读值里选结果。
    localparam SEL_REGS = 3'd0, SEL_TX = 3'd1, SEL_A = 3'd2, SEL_B = 3'd3, SEL_RTC = 3'd4;
    localparam SEL_SNMP_CONTROL = 3'd5, SEL_SNMP_STATUS = 3'd6, SEL_SHARED = 3'd7;

    // read_loader 的取值：SEL_SHARED 这一组里再选哪个读值。
    localparam SHARED_SNMP_DESCR = 0, SHARED_LOAD = 1, SHARED_LOAD_EXTRA = 2;

    // read_valid/read_select 将读有效标记与两拍后的数据对齐。
    // read_loader 选择共享地址组中的服务读值。
    reg read_valid;
    reg [2:0] read_select;
    reg [1:0] read_loader;
    reg [31:0] read_regs, read_tx, read_a, read_b;

    // 这 27 个计数器分别累计一种事件。
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
            // 事件脉冲到来时，对应计数器加一；复位清零，读取不清零。
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
        // 等待核心接收写请求时，模块保持地址和数据，并拉低 cfg_ready。
        else if ( ! tx_ready) begin
            cfg_ready <= 0;
            tx_cfg_we <= 0;
            rx_map_we <= 0;
            rx_cfg_we <= 0;
        end
        else if (tx_cfg_we) begin
            // 核心接收请求后，模块重新拉高 cfg_ready。
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
                else if (cfg_addr == ADDR_USER_ID) begin
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
            // 读请求到来时保存此前的计数值，本拍新事件不计入此次读值。
            // 第一拍保存各组读值，第二拍选择本次请求对应的一组。
            read_valid <= cfg_rd;
            case (cfg_addr)
                ADDR_VERSION : read_regs <= VERSION_VALUE;
                ADDR_STATUS : read_regs <= { 31'b0, tx_ready };
                ADDR_USER_ID : read_regs <= { 16'b0, user_id };
                ADDR_RM_DROP : read_regs <= count_rm_drop;
                ADDR_DELIVER : read_regs <= count_deliver;
                ADDR_A_GDROP : read_regs <= count_a_gdrop;
                ADDR_B_GDROP : read_regs <= count_b_gdrop;
                ADDR_RTC_SYNC_COUNT : read_regs <= rtc_sync_count;
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
                GROUP_TX_COUNT : read_select <= SEL_TX;
                GROUP_A_COUNT : read_select <= SEL_A;
                GROUP_B_COUNT : read_select <= SEL_B;
                GROUP_RTC : read_select <= SEL_RTC;
                GROUP_SNMP_CONTROL : read_select <= SEL_SNMP_CONTROL;
                GROUP_SNMP_STATUS : read_select <= SEL_SNMP_STATUS;
                GROUP_SNMP_DESCR : read_select <= SEL_SHARED;
                GROUP_LOAD : read_select <= SEL_SHARED;
                GROUP_LOAD_EXTRA : read_select <= SEL_SHARED;
                default : read_select <= SEL_REGS;
            endcase
            read_loader <= cfg_addr[17:3] == GROUP_LOAD ? SHARED_LOAD
                : cfg_addr[17:3] == GROUP_LOAD_EXTRA ? SHARED_LOAD_EXTRA : SHARED_SNMP_DESCR;
            // 读结果分两级选择，并在请求后第二拍返回。
            cfg_rvalid <= read_valid;
            case (read_select)
                SEL_REGS : cfg_rdata <= read_regs;
                SEL_TX : cfg_rdata <= read_tx;
                SEL_A : cfg_rdata <= read_a;
                SEL_B : cfg_rdata <= read_b;
                SEL_RTC : cfg_rdata <= rtc_rdata;
                SEL_SNMP_CONTROL : cfg_rdata <= snmp_control_data;
                SEL_SNMP_STATUS : cfg_rdata <= snmp_status_data;
                SEL_SHARED : case (read_loader)
                    SHARED_LOAD : cfg_rdata <= load_rdata;
                    SHARED_LOAD_EXTRA : cfg_rdata <= load_extra_data;
                    default : cfg_rdata <= snmp_descr_data;
                endcase
            endcase
        end
    end

endmodule
