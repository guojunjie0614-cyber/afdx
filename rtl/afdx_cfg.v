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
    (* preserve = 1, dont_merge = 1 *) output reg [1:0] app_cfg_ready,
    output wire service_ready_next,
    output wire service_ready_base, service_ready_rx_term,
    // 网络管理写选通按寄存器独热译码，远端不再串接完整地址比较。
    output wire [7:0] snmp_wr_sel,
    output wire [6:0] loader_wr_sel,
    output wire [5:0] rtc_wr_sel,
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

    // 初始化电平就地寄存，与各接收 bank 的本地初始化级同拍，远端就绪不直驱宽写总线。
    (* preserve = 1, dont_merge = 1 *) reg tx_ready_q;
    // 发送核心允许写入的组合锥只进本地寄存器，再用于写通道重新武装。
    (* preserve = 1, dont_merge = 1 *) reg tx_cfg_ok_q;
    always @(posedge clk) begin
        if (reset) begin
            tx_ready_q <= 0;
            tx_cfg_ok_q <= 0;
        end
        else begin
            tx_ready_q <= tx_ready;
            tx_cfg_ok_q <= tx_cfg_ok;
        end
    end
    // 必须先由真实同拍握手撤销写请求，不能把请求之前采到的空闲电平误当作应答。
    wire tx_cfg_rearm = !tx_cfg_we && tx_cfg_ok_q;

    // 每个接收 bank 在配置源处有独立副本，不让一个地址寄存器跨越整片存储区。
    // 捕获条件和原写请求相同；忙时保持，因此没有增加写入拍数。
    genvar bus_copy, data_slice;
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
            (* preserve = 1, dont_merge = 1 *) reg bank_ready_q;
            // ready is low throughout either pending transaction.  Precompute
            // its conjunction with the next sampled bank readiness locally.
            (* preserve = 1, dont_merge = 1 *) reg address_available;
            (* preserve = 1, dont_merge = 1 *) reg transmit_ack_q;
            wire local_tx_rearm = !tx_cfg_we && transmit_ack_q;
            // ready is zero for the full pending lifetime. Express the next
            // value as parallel acceptance/rearm terms, not nested hold muxes.
            wire local_idle = !transmit_pending && !receive_pending;
            wire next_local_ready = bank_ready_q &&
                ((transmit_pending && local_tx_rearm)
                 || (receive_pending && rx_cfg_ok[bus_copy])
                 || (local_idle && !(cfg_wr && ready && (select_tx || select_map || select_rx))));
            wire capture_address = address_available && cfg_wr && (select_map || select_rx);
            assign rx_cfg_addr[bus_copy * 16 +: 16] = address;
            assign rx_cfg_wdata[bus_copy * 32 +: 32] = {{(32 - DATA_WIDTH){1'b0}}, data};
            assign rx_map_we[bus_copy] = map_we_q;
            // 握手状态也按目的地复制；每个 ready 只驱动本 bank 的地址和数据保持端。
            // 和总线主状态同拍更新，避免全局 ready 跨片驱动一千多个寄存器。
            always @(posedge clk) begin
                if (reset) begin
                    bank_ready_q <= 0;
                    transmit_ack_q <= 0;
                    address_available <= 0;
                    ready <= 0;
                    transmit_pending <= 0;
                    receive_pending <= 0;
                    map_we_q <= 0;
                    address <= 0;
                end
                else begin
                    bank_ready_q <= bank_ready;
                    transmit_ack_q <= tx_cfg_ok;
                    address_available <= bank_ready && next_local_ready;
                    if (!bank_ready_q) begin
                        ready <= 0;
                        transmit_pending <= 0;
                        receive_pending <= 0;
                        map_we_q <= 0;
                    end
                    else if (transmit_pending) begin
                        if (local_tx_rearm) begin
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
                    // 映射写选通在受理拍置位、本副本应答拍清除，与主状态机同拍。
                    if (capture_address) map_we_q <= select_map;
                    else if (rx_cfg_ok[bus_copy]) map_we_q <= 0;
                end
            end
            // 每四位数据使用同拍的本地就绪副本，不再让一个使能跨越整个数据字。
            // 只复制初始化电平；请求、忙状态和写数据仍在原受理拍会合，捕获窗口不后移。
            for (data_slice = 0; data_slice < (DATA_WIDTH + 3) / 4; data_slice = data_slice + 1) begin : data_lane
                localparam SLICE_WIDTH = DATA_WIDTH - data_slice * 4 < 4 ? DATA_WIDTH - data_slice * 4 : 4;
                (* preserve = 1, dont_merge = 1 *) reg data_ready_q;
                wire capture_data = data_ready_q && !transmit_pending && !receive_pending
                    && cfg_wr && ready && (select_map || select_rx);
                always @(posedge clk) begin
                    if (reset) begin
                        data_ready_q <= 0;
                        data[data_slice * 4 +: SLICE_WIDTH] <= 0;
                    end
                    else begin
                        data_ready_q <= data_ready;
                        if (capture_data)
                            data[data_slice * 4 +: SLICE_WIDTH] <= cfg_wdata[data_slice * 4 +: SLICE_WIDTH];
                    end
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
    // Each writable service field owns a same-cycle ready replica. The
    // recurrence is identical to cfg_ready_m; no write or acknowledgement
    // gains a cycle, and one remote ready FF no longer drives all field enables.
    (* preserve = 1, dont_merge = 1 *) reg [20:0] service_ready;
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
    assign snmp_wr_sel = service_ready[7:0] & snmp_write_hit;
    // 加卸载同样先译码完整主机地址，ready 只参与末级选通，不增加写入拍数。
    // 位 0..6 对应 b0、b1、b4、b8、b9、ba、bb。
    (* keep = 1 *) wire [6:0] loader_write_hit = {
        cfg_wr && cfg_write_addr == 18'h000bb,
        cfg_wr && cfg_write_addr == 18'h000ba,
        cfg_wr && cfg_write_addr == 18'h000b9,
        cfg_wr && cfg_write_addr == 18'h000b8,
        cfg_wr && cfg_write_addr == 18'h000b4,
        cfg_wr && cfg_write_addr == 18'h000b1,
        cfg_wr && cfg_write_addr == 18'h000b0
    };
    assign loader_wr_sel = service_ready[14:8] & loader_write_hit;
    // RTC 的六个可写寄存器同样先译码，ready 只驱动末级选通。
    (* keep = 1 *) wire [5:0] rtc_write_hit = {
        cfg_wr && cfg_write_addr == 18'h00085,
        cfg_wr && cfg_write_addr == 18'h00084,
        cfg_wr && cfg_write_addr == 18'h00083,
        cfg_wr && cfg_write_addr == 18'h00082,
        cfg_wr && cfg_write_addr == 18'h00081,
        cfg_wr && cfg_write_addr == 18'h00080
    };
    assign rtc_wr_sel = service_ready[20:15] & rtc_write_hit;

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
    localparam [1:0] SHARED_SNMP_DESCR = 2'd0, SHARED_LOAD = 2'd1, SHARED_LOAD_EXTRA = 2'd2;

    // read_valid 将读有效标记与请求后第二拍的本地选择结果对齐。
    reg read_valid;
    // pending 表示主机写请求已受理；发送写在真实应答后一拍恢复就绪，地址和数据继续保持。
    reg tx_pending, rx_pending;
    reg [31:0] read_regs, read_tx, read_a, read_b;
    reg [31:0] read_regs_upper, read_tx_upper, read_a_upper, read_b_upper;

    // Host writes suppress MIB at every address, including non-user writes.
    wire user_write_request = cfg_wr ? cfg_write_addr == ADDR_USER_ID : mib_user_wr;

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

    // 事件来自收发核心，与计数器相隔大半个芯片；计数器只供读取，晚两拍加一不改变任何行为。
    // 先经两级寄存再进计数器使能，每级都能放在途中，把一条长线拆成三段。
    (* preserve = 1, dont_merge = 1 *) reg [6:0] ev_tx_p, ev_tx_q;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] ev_a_p, ev_a_q, ev_b_p, ev_b_q;
    (* preserve = 1, dont_merge = 1 *) reg ev_rm_drop_p, ev_rm_drop_q, ev_deliver_p, ev_deliver_q;
    always @(posedge clk) begin
        if (reset) begin
            ev_tx_p <= 0;
            ev_tx_q <= 0;
            ev_a_p <= 0;
            ev_a_q <= 0;
            ev_b_p <= 0;
            ev_b_q <= 0;
            ev_rm_drop_p <= 0;
            ev_rm_drop_q <= 0;
            ev_deliver_p <= 0;
            ev_deliver_q <= 0;
        end
        else begin
            ev_tx_p <= ev_tx;
            ev_tx_q <= ev_tx_p;
            ev_a_p <= ev_a;
            ev_a_q <= ev_a_p;
            ev_b_p <= ev_b;
            ev_b_q <= ev_b_p;
            ev_rm_drop_p <= ev_rm_drop;
            ev_rm_drop_q <= ev_rm_drop_p;
            ev_deliver_p <= ev_deliver;
            ev_deliver_q <= ev_deliver_p;
        end
    end

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
                default : ;
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

    function [9:0] result_select;
        input [17:0] address;
        begin
            result_select = 0;
            case (address[17:3])
                GROUP_TX_COUNT: result_select[1] = 1;
                GROUP_A_COUNT: result_select[2] = 1;
                GROUP_B_COUNT: result_select[3] = 1;
                GROUP_RTC: result_select[4] = 1;
                GROUP_SNMP_CONTROL: result_select[5] = 1;
                GROUP_SNMP_STATUS: result_select[6] = 1;
                GROUP_SNMP_DESCR: result_select[7] = 1;
                GROUP_LOAD: result_select[8] = 1;
                GROUP_LOAD_EXTRA: result_select[9] = 1;
                default: result_select[0] = 1;
            endcase
        end
    endfunction
    reg [9:0] mib_result_select;
    wire [31:0] status_value = {31'b0, tx_ready};
    wire [31:0] user_value = {16'b0, user_id};
    always @(posedge clk) begin
        if (reset) mib_result_select <= 10'b1;
        else mib_result_select <= result_select(mib_read_addr);
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
                    read_regs_upper[read_slice*4+:4]<=0;read_tx_upper[read_slice*4+:4]<=0;
                    read_a_upper[read_slice*4+:4]<=0;read_b_upper[read_slice*4+:4]<=0;
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
                        | ({4{reg_lane[3]}} & count_rm_drop[read_slice * 4 +: 4]);
                    read_regs_upper[read_slice*4+:4] <=
                          ({4{reg_lane[4]}} & count_deliver[read_slice * 4 +: 4])
                        | ({4{reg_lane[5]}} & count_a_gdrop[read_slice * 4 +: 4])
                        | ({4{reg_lane[6]}} & count_b_gdrop[read_slice * 4 +: 4])
                        | ({4{reg_lane[7]}} & rtc_sync_count[read_slice * 4 +: 4]);
                    read_tx[read_slice * 4 +: 4] <=
                        ({4{lane_tx[0]}} & count_accept[read_slice * 4 +: 4])
                        | ({4{lane_tx[1]}} & count_drop_dis[read_slice * 4 +: 4])
                        | ({4{lane_tx[2]}} & count_drop_full[read_slice * 4 +: 4])
                        | ({4{lane_tx[3]}} & count_drop_long[read_slice * 4 +: 4]);
                    read_tx_upper[read_slice*4+:4] <=
                          ({4{lane_tx[4]}} & count_drop_nopage[read_slice * 4 +: 4])
                        | ({4{lane_tx[5]}} & count_tx_a[read_slice * 4 +: 4])
                        | ({4{lane_tx[6]}} & count_tx_b[read_slice * 4 +: 4]);
                    read_a[read_slice * 4 +: 4] <=
                        ({4{lane[0]}} & count_a_good[read_slice * 4 +: 4])
                        | ({4{lane[1]}} & count_a_fcs[read_slice * 4 +: 4])
                        | ({4{lane[2]}} & count_a_len[read_slice * 4 +: 4])
                        | ({4{lane[3]}} & count_a_hdr[read_slice * 4 +: 4]);
                    read_a_upper[read_slice*4+:4] <=
                          ({4{lane[4]}} & count_a_unk[read_slice * 4 +: 4])
                        | ({4{lane[5]}} & count_a_cfg[read_slice * 4 +: 4])
                        | ({4{lane[6]}} & count_a_ic[read_slice * 4 +: 4])
                        | ({4{lane[7]}} & count_a_ovf[read_slice * 4 +: 4]);
                    read_b[read_slice * 4 +: 4] <=
                        ({4{lane_b[0]}} & count_b_good[read_slice * 4 +: 4])
                        | ({4{lane_b[1]}} & count_b_fcs[read_slice * 4 +: 4])
                        | ({4{lane_b[2]}} & count_b_len[read_slice * 4 +: 4])
                        | ({4{lane_b[3]}} & count_b_hdr[read_slice * 4 +: 4]);
                    read_b_upper[read_slice*4+:4] <=
                          ({4{lane_b[4]}} & count_b_unk[read_slice * 4 +: 4])
                        | ({4{lane_b[5]}} & count_b_cfg[read_slice * 4 +: 4])
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
            if (ev_tx_q[0]) count_accept <= count_accept + 32'd1;
            if (ev_tx_q[1]) count_drop_dis <= count_drop_dis + 32'd1;
            if (ev_tx_q[2]) count_drop_full <= count_drop_full + 32'd1;
            if (ev_tx_q[3]) count_drop_long <= count_drop_long + 32'd1;
            if (ev_tx_q[4]) count_drop_nopage <= count_drop_nopage + 32'd1;
            if (ev_tx_q[5]) count_tx_a <= count_tx_a + 32'd1;
            if (ev_tx_q[6]) count_tx_b <= count_tx_b + 32'd1;
            if (ev_a_q[0]) count_a_good <= count_a_good + 32'd1;
            if (ev_a_q[1]) count_a_fcs <= count_a_fcs + 32'd1;
            if (ev_a_q[2]) count_a_len <= count_a_len + 32'd1;
            if (ev_a_q[3]) count_a_hdr <= count_a_hdr + 32'd1;
            if (ev_a_q[4]) count_a_unk <= count_a_unk + 32'd1;
            if (ev_a_q[5]) count_a_cfg <= count_a_cfg + 32'd1;
            if (ev_a_q[6]) count_a_ic <= count_a_ic + 32'd1;
            if (ev_a_q[7]) count_a_ovf <= count_a_ovf + 32'd1;
            if (ev_b_q[0]) count_b_good <= count_b_good + 32'd1;
            if (ev_b_q[1]) count_b_fcs <= count_b_fcs + 32'd1;
            if (ev_b_q[2]) count_b_len <= count_b_len + 32'd1;
            if (ev_b_q[3]) count_b_hdr <= count_b_hdr + 32'd1;
            if (ev_b_q[4]) count_b_unk <= count_b_unk + 32'd1;
            if (ev_b_q[5]) count_b_cfg <= count_b_cfg + 32'd1;
            if (ev_b_q[6]) count_b_ic <= count_b_ic + 32'd1;
            if (ev_b_q[7]) count_b_ovf <= count_b_ovf + 32'd1;
            if (ev_rm_drop_q) count_rm_drop <= count_rm_drop + 32'd1;
            if (ev_deliver_q) count_deliver <= count_deliver + 32'd1;
            if (ev_gdrop[0]) count_a_gdrop <= count_a_gdrop + 32'd1;
            if (ev_gdrop[1]) count_b_gdrop <= count_b_gdrop + 32'd1;
        end
    end

    // A local ready replica follows exactly the public ready recurrence.
    // It avoids routing the public handshake register to the user ID bank.
    (* preserve = 1, dont_merge = 1 *) reg user_ready;
    always @(posedge clk) begin
        if (reset || !tx_ready_q) user_ready <= 0;
        else if (tx_pending) begin
            if (tx_cfg_rearm) user_ready <= 1;
        end else if (rx_pending) begin
            if (rx_cfg_ok[0]) user_ready <= 1;
        end else begin
            user_ready <= 1;
            if (cfg_wr && user_ready && (select_tx || select_map || select_rx)) user_ready <= 0;
        end
    end

    // Pending owns ready=0 throughout its lifetime. Parallel rearm/idle
    // terms predict the original ready edge without a priority mux chain.
    // Each byte samples initialization/ack locally; no shared ready FF drives
    // the complete qualification cone and then both byte enables.
    genvar user_byte;
    generate for(user_byte=0;user_byte<2;user_byte=user_byte+1) begin : user_write_lane
        (* preserve = 1, dont_merge = 1 *) reg allowed, initial_ready, transmit_ack;
        wire idle_ready = !tx_pending && !rx_pending &&
            !(cfg_wr && user_ready && (select_tx || select_map || select_rx));
        wire rearm_ready = (tx_pending && !tx_cfg_we && transmit_ack)
            || (rx_pending && rx_cfg_ok[0]);
        always @(posedge clk) begin
            if(reset) begin
                allowed<=0;initial_ready<=0;transmit_ack<=0;
                user_id[user_byte*8+:8]<=0;
            end else begin
                initial_ready<=tx_ready;
                transmit_ack<=tx_cfg_ok;
                allowed<=tx_ready && initial_ready && (idle_ready || rearm_ready);
                if((allowed && cfg_wr && cfg_write_addr==ADDR_USER_ID) ||
                   (allowed && !cfg_wr && mib_user_wr))
                    user_id[user_byte*8+:8]<=cfg_wr ? cfg_wdata[user_byte*8+:8] : mib_user_wdata[user_byte*8+:8];
            end
        end
    end endgenerate

    always @(posedge clk) begin
        if (reset) tx_cfg_we <= 0;
        else if (!tx_ready_q) tx_cfg_we <= 0;
        else if (tx_cfg_we) begin
            // 核心仍按原拍受理且只写一次；延迟的是 ready，不是这个逐拍握手。
            if (tx_cfg_ok) tx_cfg_we <= 0;
        end
        else if (!tx_pending && !rx_pending && cfg_wr && cfg_ready && select_tx)
            tx_cfg_we <= 1;
    end

    always @(posedge clk) begin
        if (reset) begin
            cfg_ready <= 0;
            tx_pending <= 0;
            tx_cfg_addr <= 0;
            tx_cfg_wdata <= 0;
            rx_pending <= 0;
            rx_cfg_we <= 0;
        end
        // 等待核心接收写请求时，模块保持地址和数据，并拉低 cfg_ready。
        else if ( ! tx_ready_q) begin
            cfg_ready <= 0;
            tx_pending <= 0;
            rx_pending <= 0;
            rx_cfg_we <= 0;
        end
        else if (tx_pending) begin
            // 本地应答确认真实写请求已经完成，三处就绪状态同拍重新武装。
            if (tx_cfg_rearm) begin
                tx_pending <= 0;
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
                    tx_pending <= 1;
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

    // D value for destination-local service ready registers. This is a
    // same-edge prediction of public ready, not a delayed ready sample.
    assign service_ready_next = !reset && tx_ready_q &&
        (tx_pending ? (tx_cfg_rearm || cfg_ready) :
         rx_pending ? (rx_cfg_ok[0] || cfg_ready) :
         !(cfg_wr && cfg_ready && (select_tx || select_map || select_rx)));

    // Factor the same D at service destinations. Only the RX acknowledgement
    // crosses into their final AND/OR; public ready and its edge stay intact.
    assign service_ready_base = !reset && tx_ready_q &&
        ((tx_pending && (tx_cfg_rearm || cfg_ready)) ||
         (!tx_pending && rx_pending && cfg_ready) ||
         (!tx_pending && !rx_pending && !(cfg_wr && cfg_ready && (select_tx || select_map || select_rx))));
    assign service_ready_rx_term = !reset && tx_ready_q && !tx_pending && rx_pending;

    // 镜像寄存器沿用同一递推，保证任何拍都与 cfg_ready 同值。
    always @(posedge clk) begin
        if (reset) cfg_ready_m <= 0;
        else if ( ! tx_ready_q) cfg_ready_m <= 0;
        else if (tx_pending) begin
            if (tx_cfg_rearm) cfg_ready_m <= 1;
        end
        else if (rx_pending) begin
            if (rx_cfg_ok[0]) cfg_ready_m <= 1;
        end
        else begin
            cfg_ready_m <= 1;
            if (cfg_wr && cfg_ready_m && (select_tx || select_map || select_rx)) cfg_ready_m <= 0;
        end
    end

    // Dedicated application write domains retain the exact public recurrence.
    genvar app_ready_copy;
    generate for(app_ready_copy=0;app_ready_copy<2;app_ready_copy=app_ready_copy+1) begin : application_ready
        always @(posedge clk) begin
            if(reset || !tx_ready_q) app_cfg_ready[app_ready_copy]<=0;
            else if(tx_pending) begin
                if(tx_cfg_rearm) app_cfg_ready[app_ready_copy]<=1;
            end else if(rx_pending) begin
                if(rx_cfg_ok[0]) app_cfg_ready[app_ready_copy]<=1;
            end else begin
                app_cfg_ready[app_ready_copy]<=1;
                if(cfg_wr && app_cfg_ready[app_ready_copy] && (select_tx || select_map || select_rx))
                    app_cfg_ready[app_ready_copy]<=0;
            end
        end
    end endgenerate

    genvar service_copy;
    generate
        for (service_copy = 0; service_copy < 21; service_copy = service_copy + 1) begin : service_write_ready
            (* preserve = 1, dont_merge = 1 *) reg transmit_ack_q;
            always @(posedge clk) begin
                if (reset) transmit_ack_q<=0;
                else transmit_ack_q<=tx_cfg_ok;
            end
            always @(posedge clk) begin
                if (reset) service_ready[service_copy] <= 0;
                else if (!tx_ready_q) service_ready[service_copy] <= 0;
                else if (tx_pending) begin
                    if (!tx_cfg_we && transmit_ack_q) service_ready[service_copy] <= 1;
                end else if (rx_pending) begin
                    if (rx_cfg_ok[0]) service_ready[service_copy] <= 1;
                end else begin
                    service_ready[service_copy] <= 1;
                    if (cfg_wr && service_ready[service_copy] && (select_tx || select_map || select_rx))
                        service_ready[service_copy] <= 0;
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            read_valid <= 0;
            cfg_rvalid <= 0;
        end
        else begin
            // 请求拍保存各组读值，下一拍返回同一次请求对应的数据。
            read_valid <= cfg_rd;
            cfg_rvalid <= read_valid;
        end
    end

    // Ten independent registered source selects per nibble replace the
    // binary group mux followed by the shared-group mux. Both address paths
    // retain the original capture edge and the public two-clock read latency.
    wire [9:0] read_result_next = host_read ? result_select(cfg_write_addr) : mib_result_select;
    genvar result_slice;
    generate
        for (result_slice = 0; result_slice < 8; result_slice = result_slice + 1) begin : result_bank
            (* preserve = 1, dont_merge = 1 *) reg [3:0] select_cnt_q;
            (* preserve = 1, dont_merge = 1 *) reg [5:0] select_svc_q;
            (* keep = 1 *) wire [3:0] c0 = {4{select_cnt_q[0]}} & (read_regs[result_slice*4+:4] | read_regs_upper[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] c1 = {4{select_cnt_q[1]}} & (read_tx[result_slice*4+:4] | read_tx_upper[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] c2 = {4{select_cnt_q[2]}} & (read_a[result_slice*4+:4] | read_a_upper[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] c3 = {4{select_cnt_q[3]}} & (read_b[result_slice*4+:4] | read_b_upper[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] s_rtc_snmp =
                ({4{select_svc_q[0]}} & rtc_rdata[result_slice*4+:4]) |
                ({4{select_svc_q[1]}} & snmp_control_data[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] s_snmp2 =
                ({4{select_svc_q[2]}} & snmp_status_data[result_slice*4+:4]) |
                ({4{select_svc_q[3]}} & snmp_descr_data[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] s_load =
                ({4{select_svc_q[4]}} & load_rdata[result_slice*4+:4]) |
                ({4{select_svc_q[5]}} & load_extra_data[result_slice*4+:4]);
            (* keep = 1 *) wire [3:0] local_counters = c0 | c1 | c2 | c3;
            (* keep = 1 *) wire [3:0] remote_services = s_rtc_snmp | s_snmp2 | s_load;
            always @(posedge clk) begin
                if (reset) begin
                    select_cnt_q <= 4'b0001;
                    select_svc_q <= 6'b0;
                    cfg_rdata[result_slice * 4 +: 4] <= 0;
                end else begin
                    select_cnt_q <= read_result_next[3:0];
                    select_svc_q <= read_result_next[9:4];
                    cfg_rdata[result_slice * 4 +: 4] <= local_counters | remote_services;
                end
            end
        end
    endgenerate

endmodule
