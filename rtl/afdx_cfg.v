// 本模块把外部配置读写请求送到对应模块，并统计收发事件。
// 输入来自顶层配置口和各模块的事件脉冲，读结果返回顶层。
// 本模块为赛题的收发配置和网络管理提供寄存器接口。
module afdx_cfg #(parameter RX_BUS_COPIES = 1, BANKED_READY = 0) (

    // tx_ready 为高表示收发核心都已初始化。
    input wire clk, reset, tx_ready,
    input wire [RX_BUS_COPIES:0] rx_ready_by_bank,

    // cfg_wr 和 cfg_ready 同为高时接收写请求。
    // cfg_rd 发起读请求，两拍后 cfg_rvalid 指示 cfg_rdata 有效。
    // 此读口返回寄存器和统计值，不读回配置存储表。
    input wire cfg_wr, cfg_rd,
    input wire [17:0] cfg_addr, cfg_write_addr,
    input wire [31:0] cfg_wdata,
    input wire mib_user_wr,
    input wire [15:0] mib_user_wdata,
    input wire [17:0] mib_read_addr,
    input wire [2:0] host_read_addr,
    input wire host_read,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg cfg_ready, cfg_rvalid,
    // cfg_ready_m 与 cfg_ready 同值同拍，单独驱动下游模块写选通方向的负载。
    (* preserve = 1, dont_merge = 1 *) output reg cfg_ready_m,
    // 网络管理写选通按寄存器独热译码，远端不再串接完整地址比较。
    output wire [7:0] snmp_wr_sel,
    output reg [31:0] cfg_rdata,

    // user_id 是源以太网地址中的端系统编号。
    // tx/rx_cfg_ok 为高时，对应核心允许写配置。
    output reg [15:0] user_id,
    input wire tx_cfg_ok,
    input wire [RX_BUS_COPIES - 1:0] rx_cfg_ok,

    // tx_cfg_* 写发送配置表。
    // rx_map_we 写编号到索引的映射，rx_cfg_we 写接收配置。
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) output reg tx_cfg_we,
    output reg [9:0] tx_cfg_addr,
    output reg [31:0] tx_cfg_wdata,
    // rx_map_we 按总线副本各出一比特，远端 bank 只收本地副本的选通。
    output wire [RX_BUS_COPIES - 1:0] rx_map_we,
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) output reg rx_cfg_we,
    output wire [RX_BUS_COPIES * 16 - 1:0] rx_cfg_addr,
    output wire [RX_BUS_COPIES * 32 - 1:0] rx_cfg_wdata,

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
    wire select_tx = (cfg_write_addr[17:10] == 8'b00000100);
    wire select_map = (cfg_write_addr[17:16] == 2'b01);
    wire select_rx = (cfg_write_addr[17:12] == 6'b100000);

    // 每个接收 bank 在配置源处有独立副本，不让一个地址寄存器跨越整片存储区。
    // 捕获条件和原写请求相同；忙时保持，因此没有增加写入拍数。
    genvar bus_copy;
    generate
        for (bus_copy = 0; bus_copy < RX_BUS_COPIES; bus_copy = bus_copy + 1) begin : receive_bus
            localparam DATA_WIDTH = bus_copy == 0 ? 32 : 13;
            (* preserve = 1, dont_merge = 1 *) reg [15:0] address;
            (* preserve = 1, dont_merge = 1 *) reg [DATA_WIDTH - 1:0] data;
            (* preserve = 1, dont_merge = 1 *) reg ready, transmit_pending, receive_pending;
            // 本副本的映射写选通：本地握手位会合，长距离状态机锥不进使能端。
            (* preserve = 1, dont_merge = 1 *) reg map_we_q;
            wire bank_ready = BANKED_READY ? rx_ready_by_bank[bus_copy] : tx_ready;
            wire data_ready = BANKED_READY && bus_copy == 0 ? rx_ready_by_bank[RX_BUS_COPIES] : bank_ready;
            // 就绪电平本地寄存一拍：该电平一旦置位保持到复位，晚一拍只影响初始化边界。
            (* preserve = 1, dont_merge = 1 *) reg bank_ready_q, data_ready_q;
            wire capture_address = bank_ready_q && !transmit_pending && !receive_pending
                && cfg_wr && ready && (select_map || select_rx);
            wire capture_data = data_ready_q && !transmit_pending && !receive_pending
                && cfg_wr && ready && (select_map || select_rx);
            assign rx_cfg_addr[bus_copy * 16 +: 16] = address;
            assign rx_cfg_wdata[bus_copy * 32 +: 32] = {{(32 - DATA_WIDTH){1'b0}}, data};
            assign rx_map_we[bus_copy] = map_we_q;
            // 握手状态也按目的地复制；每个 ready 只驱动本 bank 的地址和数据保持端。
            // 和总线主状态同拍更新，避免全局 ready 跨片驱动一千多个寄存器。
            always @(posedge clk) begin
                if (reset) begin
                    bank_ready_q <= 0;
                    data_ready_q <= 0;
                    ready <= 0;
                    transmit_pending <= 0;
                    receive_pending <= 0;
                    map_we_q <= 0;
                    address <= 0;
                    data <= 0;
                end
                else begin
                    bank_ready_q <= bank_ready;
                    data_ready_q <= data_ready;
                    if (!bank_ready_q) begin
                        ready <= 0;
                        transmit_pending <= 0;
                        receive_pending <= 0;
                        map_we_q <= 0;
                    end
                    else if (transmit_pending) begin
                        if (tx_cfg_ok) begin
                            transmit_pending <= 0;
                            ready <= 1;
                        end
                    end
                    else if (receive_pending) begin
                        if (rx_cfg_ok[bus_copy]) begin
                            receive_pending <= 0;
                            ready <= 1;
                        end
                    end
                    else begin
                        ready <= 1;
                        if (cfg_wr && ready) begin
                            if (select_tx) begin
                                transmit_pending <= 1;
                                ready <= 0;
                            end
                            else if (select_map || select_rx) begin
                                receive_pending <= 1;
                                ready <= 0;
                            end
                        end
                    end
                    if (capture_address) address <= cfg_write_addr[15:0];
                    if (capture_data) data <= cfg_wdata[DATA_WIDTH - 1:0];
                    // 映射写选通在受理拍置位、本副本应答拍清除，与主状态机同拍。
                    if (capture_address) map_we_q <= select_map;
                    else if (rx_cfg_ok[bus_copy]) map_we_q <= 0;
                end
            end
        end
    endgenerate

    // 单个寄存器的地址（按 32 位字编址）和版本号。
    localparam ADDR_VERSION = 18'h00000, ADDR_STATUS = 18'h00001, ADDR_USER_ID = 18'h00002;
    localparam ADDR_RM_DROP = 18'h00058, ADDR_DELIVER = 18'h00059;
    localparam ADDR_A_GDROP = 18'h0005a, ADDR_B_GDROP = 18'h0005b, ADDR_RTC_SYNC_COUNT = 18'h00088;
    localparam ADDR_SNMP_ENABLE = 18'h00090, ADDR_SNMP_TX_VL = 18'h00091, ADDR_SNMP_COMMUNITY_LENGTH = 18'h00092;
    localparam ADDR_SNMP_COMMUNITY0 = 18'h00093, ADDR_SNMP_COMMUNITY1 = 18'h00094;
    localparam ADDR_SNMP_COMMUNITY2 = 18'h00095, ADDR_SNMP_COMMUNITY3 = 18'h00096, ADDR_SNMP_TRAP_ENABLE = 18'h0009b;
    localparam VERSION_VALUE = 32'hc3110000;

    // 位 0..7 依次对应使能、发送虚拟链路、团体名长度、团体名四字和通知使能。
    // 请求与地址先会合，cfg_ready_m 只进入末级与门；不增加写入拍数。
    (* keep = 1 *) wire [7:0] snmp_write_hit = {
        cfg_wr && cfg_write_addr == ADDR_SNMP_TRAP_ENABLE,
        cfg_wr && cfg_write_addr == ADDR_SNMP_COMMUNITY3,
        cfg_wr && cfg_write_addr == ADDR_SNMP_COMMUNITY2,
        cfg_wr && cfg_write_addr == ADDR_SNMP_COMMUNITY1,
        cfg_wr && cfg_write_addr == ADDR_SNMP_COMMUNITY0,
        cfg_wr && cfg_write_addr == ADDR_SNMP_COMMUNITY_LENGTH,
        cfg_wr && cfg_write_addr == ADDR_SNMP_TX_VL,
        cfg_wr && cfg_write_addr == ADDR_SNMP_ENABLE
    };
    assign snmp_wr_sel = {8{cfg_ready_m}} & snmp_write_hit;

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
    // read_loader 选择共享地址组中的服务读值；
    // read_sel_* 把共享组二次选择预译码成独热位，第二拍只剩一级选择。
    reg read_valid;
    reg [2:0] read_select;
    reg [1:0] read_loader;
    reg read_sel_load, read_sel_extra;
    // rx_pending 表示主机写请求已受理、正在等待接收核心应答。
    reg rx_pending;
    reg [31:0] read_regs, read_tx, read_a, read_b;

    // 主机写任何地址时都优先于 MIB；保留原状态机的忙和初始化屏蔽条件。
    wire user_id_hit = cfg_wr && cfg_write_addr == ADDR_USER_ID;
    wire mib_user_hit = !cfg_wr && mib_user_wr;
    (* keep = 1 *) wire user_id_write_hit = tx_ready && !tx_cfg_we && !rx_pending
        && (user_id_hit || mib_user_hit);

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

    function [7:0] register_select;
        input [17:0] address;
        begin
            register_select = 0;
            case (address)
                ADDR_VERSION : register_select[0] = 1;
                ADDR_STATUS : register_select[1] = 1;
                ADDR_USER_ID : register_select[2] = 1;
                ADDR_RM_DROP : register_select[3] = 1;
                ADDR_DELIVER : register_select[4] = 1;
                ADDR_A_GDROP : register_select[5] = 1;
                ADDR_B_GDROP : register_select[6] = 1;
                ADDR_RTC_SYNC_COUNT : register_select[7] = 1;
            endcase
        end
    endfunction

    function [2:0] group_select;
        input [17:0] address;
        begin
            case (address[17:3])
                GROUP_TX_COUNT : group_select = SEL_TX;
                GROUP_A_COUNT : group_select = SEL_A;
                GROUP_B_COUNT : group_select = SEL_B;
                GROUP_RTC : group_select = SEL_RTC;
                GROUP_SNMP_CONTROL : group_select = SEL_SNMP_CONTROL;
                GROUP_SNMP_STATUS : group_select = SEL_SNMP_STATUS;
                GROUP_SNMP_DESCR : group_select = SEL_SHARED;
                GROUP_LOAD : group_select = SEL_SHARED;
                GROUP_LOAD_EXTRA : group_select = SEL_SHARED;
                default : group_select = SEL_REGS;
            endcase
        end
    endfunction

    function [1:0] loader_select;
        input [17:0] address;
        begin
            loader_select = address[17:3] == GROUP_LOAD ? SHARED_LOAD
                : address[17:3] == GROUP_LOAD_EXTRA ? SHARED_LOAD_EXTRA : SHARED_SNMP_DESCR;
        end
    endfunction

    reg [2:0] mib_group;
    reg [1:0] mib_loader;
    // 与 read_loader 同拍的共享组独热选择，预译码只进本地寄存器。
    wire [1:0] read_loader_next = host_read ? loader_select(cfg_write_addr) : mib_loader;
    wire [31:0] status_value = {31'b0, tx_ready};
    wire [31:0] user_value = {16'b0, user_id};
    always @(posedge clk) begin
        if (reset) begin
            mib_group <= SEL_REGS;
            mib_loader <= SHARED_SNMP_DESCR;
        end
        else begin
            mib_group <= group_select(mib_read_addr);
            mib_loader <= loader_select(mib_read_addr);
        end
    end

    // 每四位计数值使用独立的地址译码寄存器，发送和 B 网各用本地副本。
    // 三组副本同拍更新，每个计数选择位只驱动本组四个数据位。
    // 网络管理先发地址、下一拍再发读请求；主机读口直接译码，仍在两拍后返回。
    genvar read_slice;
    generate
        for (read_slice = 0; read_slice < 8; read_slice = read_slice + 1) begin : counter_read
            (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_lane;
            (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_lane_tx, mib_lane_b;
            wire [7:0] lane = host_read ? (8'b1 << host_read_addr) : mib_lane;
            wire [7:0] lane_tx = host_read ? (8'b1 << host_read_addr) : mib_lane_tx;
            wire [7:0] lane_b = host_read ? (8'b1 << host_read_addr) : mib_lane_b;
            (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_register_lane;
            wire [7:0] reg_lane = host_read ? register_select(cfg_write_addr) : mib_register_lane;
            always @(posedge clk) begin
                if (reset) begin
                    mib_lane <= 8'b1;
                    mib_lane_tx <= 8'b1;
                    mib_lane_b <= 8'b1;
                    mib_register_lane <= 0;
                    read_regs[read_slice * 4 +: 4] <= 0;
                    read_tx[read_slice * 4 +: 4] <= 0;
                    read_a[read_slice * 4 +: 4] <= 0;
                    read_b[read_slice * 4 +: 4] <= 0;
                end
                else begin
                    mib_lane <= 8'b1 << mib_read_addr[2:0];
                    mib_lane_tx <= 8'b1 << mib_read_addr[2:0];
                    mib_lane_b <= 8'b1 << mib_read_addr[2:0];
                    mib_register_lane <= register_select(mib_read_addr);
                    read_regs[read_slice * 4 +: 4] <=
                        ({4{reg_lane[0]}} & VERSION_VALUE[read_slice * 4 +: 4])
                        | ({4{reg_lane[1]}} & status_value[read_slice * 4 +: 4])
                        | ({4{reg_lane[2]}} & user_value[read_slice * 4 +: 4])
                        | ({4{reg_lane[3]}} & count_rm_drop[read_slice * 4 +: 4])
                        | ({4{reg_lane[4]}} & count_deliver[read_slice * 4 +: 4])
                        | ({4{reg_lane[5]}} & count_a_gdrop[read_slice * 4 +: 4])
                        | ({4{reg_lane[6]}} & count_b_gdrop[read_slice * 4 +: 4])
                        | ({4{reg_lane[7]}} & rtc_sync_count[read_slice * 4 +: 4]);
                    read_tx[read_slice * 4 +: 4] <=
                        ({4{lane_tx[0]}} & count_accept[read_slice * 4 +: 4])
                        | ({4{lane_tx[1]}} & count_drop_dis[read_slice * 4 +: 4])
                        | ({4{lane_tx[2]}} & count_drop_full[read_slice * 4 +: 4])
                        | ({4{lane_tx[3]}} & count_drop_long[read_slice * 4 +: 4])
                        | ({4{lane_tx[4]}} & count_drop_nopage[read_slice * 4 +: 4])
                        | ({4{lane_tx[5]}} & count_tx_a[read_slice * 4 +: 4])
                        | ({4{lane_tx[6]}} & count_tx_b[read_slice * 4 +: 4]);
                    read_a[read_slice * 4 +: 4] <=
                        ({4{lane[0]}} & count_a_good[read_slice * 4 +: 4])
                        | ({4{lane[1]}} & count_a_fcs[read_slice * 4 +: 4])
                        | ({4{lane[2]}} & count_a_len[read_slice * 4 +: 4])
                        | ({4{lane[3]}} & count_a_hdr[read_slice * 4 +: 4])
                        | ({4{lane[4]}} & count_a_unk[read_slice * 4 +: 4])
                        | ({4{lane[5]}} & count_a_cfg[read_slice * 4 +: 4])
                        | ({4{lane[6]}} & count_a_ic[read_slice * 4 +: 4])
                        | ({4{lane[7]}} & count_a_ovf[read_slice * 4 +: 4]);
                    read_b[read_slice * 4 +: 4] <=
                        ({4{lane_b[0]}} & count_b_good[read_slice * 4 +: 4])
                        | ({4{lane_b[1]}} & count_b_fcs[read_slice * 4 +: 4])
                        | ({4{lane_b[2]}} & count_b_len[read_slice * 4 +: 4])
                        | ({4{lane_b[3]}} & count_b_hdr[read_slice * 4 +: 4])
                        | ({4{lane_b[4]}} & count_b_unk[read_slice * 4 +: 4])
                        | ({4{lane_b[5]}} & count_b_ic[read_slice * 4 +: 4])
                        | ({4{lane_b[6]}} & count_b_ic[read_slice * 4 +: 4])
                        | ({4{lane_b[7]}} & count_b_ovf[read_slice * 4 +: 4]);
                end
            end
        end
    endgenerate

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

    // 数据源和地址预先选择，就绪信号只参与最后一级写使能。
    always @(posedge clk) begin
        if (reset) user_id <= 0;
        else if (user_id_write_hit && cfg_ready)
            user_id <= cfg_wr ? cfg_wdata[15:0] : mib_user_wdata;
    end

    always @(posedge clk) begin
        if (reset) begin
            cfg_ready <= 0;
            tx_cfg_we <= 0;
            tx_cfg_addr <= 0;
            tx_cfg_wdata <= 0;
            rx_pending <= 0;
            rx_cfg_we <= 0;
        end
        // 等待核心接收写请求时，模块保持地址和数据，并拉低 cfg_ready。
        else if ( ! tx_ready) begin
            cfg_ready <= 0;
            tx_cfg_we <= 0;
            rx_pending <= 0;
            rx_cfg_we <= 0;
        end
        else if (tx_cfg_we) begin
            // 核心接收请求后，模块重新拉高 cfg_ready。
            if (tx_cfg_ok) begin
                tx_cfg_we <= 0;
                cfg_ready <= 1;
            end
        end
        else if (rx_pending) begin
            if (rx_cfg_ok[0]) begin
                rx_pending <= 0;
                rx_cfg_we <= 0;
                cfg_ready <= 1;
            end
        end
        else begin
            cfg_ready <= 1;
            if (cfg_wr && cfg_ready) begin
                if (select_tx) begin
                    tx_cfg_we <= 1;
                    tx_cfg_addr <= cfg_write_addr[9:0];
                    tx_cfg_wdata <= cfg_wdata;
                    cfg_ready <= 0;
                end
                else if (select_map || select_rx) begin
                    rx_pending <= 1;
                    rx_cfg_we <= select_rx;
                    cfg_ready <= 0;
                end
            end
        end
    end

    // 镜像寄存器沿用同一递推，保证任何拍都与 cfg_ready 同值。
    always @(posedge clk) begin
        if (reset) cfg_ready_m <= 0;
        else if ( ! tx_ready) cfg_ready_m <= 0;
        else if (tx_cfg_we) begin
            if (tx_cfg_ok) cfg_ready_m <= 1;
        end
        else if (rx_pending) begin
            if (rx_cfg_ok[0]) cfg_ready_m <= 1;
        end
        else begin
            cfg_ready_m <= 1;
            if (cfg_wr && cfg_ready_m && (select_tx || select_map || select_rx)) cfg_ready_m <= 0;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            read_valid <= 0;
            cfg_rvalid <= 0;
            read_select <= 0;
            read_loader <= 0;
            read_sel_load <= 0;
            read_sel_extra <= 0;
            cfg_rdata <= 0;
        end
        else begin
            // 读请求到来时保存此前的计数值，本拍新事件不计入此次读值。
            // 第一拍保存各组读值，第二拍选择本次请求对应的一组。
            read_valid <= cfg_rd;
            read_select <= host_read ? group_select(cfg_write_addr) : mib_group;
            read_loader <= read_loader_next;
            read_sel_load <= read_loader_next == SHARED_LOAD;
            read_sel_extra <= read_loader_next == SHARED_LOAD_EXTRA;
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
                SEL_SHARED : cfg_rdata <= read_sel_load ? load_rdata
                    : read_sel_extra ? load_extra_data : snmp_descr_data;
            endcase
        end
    end

endmodule
