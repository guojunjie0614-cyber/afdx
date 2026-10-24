// 本模块连接两路以太网接收、报文检查和应用交付模块。
// 两路线路分别接收，检查通过后由一个输出口交付消息。
// 本模块对应赛题的接收、错误检测和双网重复帧去除功能。
module afdx_rx_core #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5, CFG_COPIES = 1, REGISTERED_TIME_TICK = 0) (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // now_c 提供粗粒度时间，rx_data_a/b 在对应 valid 为高时有效。
    // 参数为 1 时，bit 16 携带同拍变化脉冲；默认端口宽度和位置不变。
    input wire [15 + REGISTERED_TIME_TICK:0] now_c,
    input wire [7:0] rx_data_a,
    input wire rx_valid_a,
    input wire [7:0] rx_data_b,
    input wire rx_valid_b,

    // cfg_map_we 按配置副本写入线路编号到配置索引的映射。
    // cfg_cfg_we 写入接收参数，cfg_ok 为高时允许这些写操作。
    input wire [CFG_COPIES - 1:0] cfg_map_we,
    input wire cfg_cfg_we,
    input wire [CFG_COPIES * 16 - 1:0] cfg_addr,
    input wire [CFG_COPIES * 32 - 1:0] cfg_wdata,

    // d_valid 为高时交付一个用户字节，d_last 标记消息末字节。
    // d_vl 是接收配置索引，d_sport/d_dport 是源端口和目的端口。
    // d_net 为 0 表示来自 A 网，为 1 表示来自 B 网。
    output wire d_valid,
    output wire [7:0] d_data,
    output wire d_last,
    output wire [11:0] d_vl,
    output wire [15:0] d_sport, d_dport,
    output wire d_net,

    // 所有接收表初始化完成后，init_done 才变高。
    // ev_a/b 分别报告两网检查结果。
    // ev_rm_drop 表示丢弃重复帧，ev_deliver 表示接纳消息。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg init_done,
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,
    output wire [CFG_COPIES - 1:0] cfg_ok);

    // clear_addr 初始化 65536 项映射及前 4096 项接收配置。
    // flush_init 等待最后一次写入完成。
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg cfg_we, flush_init;
    reg [15:0] clear_addr;
    reg [11:0] cfg_wa;
    reg [31:0] cfg_wd;
    wire engine_initialized, cfg_re, state_re, state_we;
    wire [CFG_COPIES - 1:0] map_re;
    wire [CFG_COPIES * 16 - 1:0] map_ra;
    wire [12:0] map_q;
    wire [11:0] cfg_ra, state_ra, state_wa;
    wire [31:0] cfg_q;
    wire [43:0] state_wd, state_q;
    wire ma_valid, mb_valid, ma_first, mb_first, fa_end, fb_end;
    wire [7:0] ma_data, mb_data;
    wire [1:0] fa_err, fb_err;
    wire [10:0] fa_len, fb_len;
    wire ra_we, rb_we, ra_re, rb_re;
    wire [RX_RING_AW - 1:0] ra_wa, rb_wa, ra_ra, rb_ra;
    wire [7:0] ra_wd, rb_wd, ra_q, rb_q;
    wire [RX_RING_AW:0] ptr_a, ptr_b;
    wire [CFG_COPIES - 1:0] da_valid, db_valid;
    wire take_a, take_b, resolve_a, resolve_b, commit_a, commit_b;
    wire [RX_RING_AW + 82:0] desc_a, desc_b;
    wire [7:0] parse_ev_a, parse_ev_b, engine_ev_a, engine_ev_b;

    localparam DQ_WIDTH = RX_RING_AW + 56;
    wire engine_rm, engine_deliver, dq_pop;
    wire dq_we, dq_re;
    wire [RX_DQ_AW - 1:0] dq_wa, dq_ra;
    wire [RX_DQ_AW:0] dq_count;
    wire [DQ_WIDTH - 1:0] dq_wd, dq_q;

    // rx_dq 最多保存 2^RX_DQ_AW 条待交付消息的信息，按先进先出使用。
    // 接收引擎按写指针写入，交付模块每拍读出读指针所指的一项。
    // 队列为空时写入项可能正是读指针所指项，这一拍跳过读出；
    // 交付模块最早在下一拍看到计数非零，那时读出的已是新写入的值。
    assign dq_re = !(dq_we && dq_wa == dq_ra);
    afdx_ram_sdp #(.WIDTH(DQ_WIDTH), .DEPTH(1 << RX_DQ_AW)) rx_dq (
        .clk(clk),
        .write_enable(dq_we),
        .write_address(dq_wa),
        .write_data(dq_wd),
        .read_enable(dq_re),
        .read_address(dq_ra),
        .read_data(dq_q)
    );

    // 初始化完成且 cfg_ok 为高时，外部配置才能写入接收表。
    always @(posedge clk) begin
        if (reset) begin
            init_done <= 0;
            cfg_we <= 0;
            clear_addr <= 0;
            cfg_wa <= 0;
            cfg_wd <= 0;
            flush_init <= 0;
            ev_a <= 0;
            ev_b <= 0;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
        end
        else begin
            cfg_we <= 0;
            if ( ! init_done) begin
                if ( ! flush_init) begin
                    if (clear_addr < 4096) cfg_we <= 1;
                    clear_addr <= clear_addr + 1'b1;
                    if (clear_addr == 65535) flush_init <= 1;
                end
                else if (engine_initialized) init_done <= 1;
            end
            else cfg_we <= cfg_cfg_we && cfg_ok[0];
            // 地址与数据自由运行，写脉冲独立决定提交；清除比较不再出现在写数据锥内。
            cfg_wa <= init_done ? cfg_addr[11:0] : clear_addr[11:0];
            cfg_wd <= init_done ? cfg_wdata[31:0] : 32'b0;
            ev_a <= parse_ev_a | engine_ev_a;
            ev_b <= parse_ev_b | engine_ev_b;
            ev_rm_drop <= engine_rm;
            ev_deliver <= engine_deliver;
        end
    end

    // map 保存有效位和 12 位配置索引。
    // cfg 保存接收开关、长度限制和两网允许的最大时间差。
    // state 保存各虚拟链路的接收序号和交付记录。
    // 32 个 bank 各保存 2048 项；每个局部地址只驱动本 bank 的存储块。
    // 请求寄存器与引擎原来的 map_ra/map_re 同拍更新。
    // RAM 口影子与回读输出各增加一级流水线，引擎的 FRAME 相位同步后移两拍。
    localparam MAP_BANKS = 32, MAP_BANK_AW = 11, MAP_GROUPS = 16;
    wire [MAP_BANKS * 13 - 1:0] map_bank_data;
    // 读地址在源端译码并寄存为独热位，bank 内下一拍只合并单比特请求。
    // 复用原有两级请求流水线，低地址与返回数据的固定相位均不改变。
    // 写选通使用本 bank 所在总线副本的 map_we 位。
    wire [MAP_BANKS - 1:0] map_rd_sel, map_wr_sel;
    (* preserve = 1, dont_merge = 1 *) reg [MAP_BANKS - 1:0] map_bank_oh;
    always @(posedge clk) begin
        if (reset) map_bank_oh <= 0;
        else map_bank_oh <= map_rd_sel;
    end
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg [MAP_GROUPS * 13 - 1:0] map_group_data;
    assign map_q = map_group_data[0 * 13 +: 13] |
        map_group_data[1 * 13 +: 13] |
        map_group_data[2 * 13 +: 13] |
        map_group_data[3 * 13 +: 13] |
        map_group_data[4 * 13 +: 13] |
        map_group_data[5 * 13 +: 13] |
        map_group_data[6 * 13 +: 13] |
        map_group_data[7 * 13 +: 13] |
        map_group_data[8 * 13 +: 13] |
        map_group_data[9 * 13 +: 13] |
        map_group_data[10 * 13 +: 13] |
        map_group_data[11 * 13 +: 13] |
        map_group_data[12 * 13 +: 13] |
        map_group_data[13 * 13 +: 13] |
        map_group_data[14 * 13 +: 13] |
        map_group_data[15 * 13 +: 13];
    (* preserve = 1, dont_merge = 1 *) reg [12:0] map_q_r;
    always @(posedge clk) begin
        if (reset) map_q_r <= 0;
        else map_q_r <= map_q;
    end

    genvar bank, map_group;
    generate
        for (bank = 0; bank < MAP_BANKS; bank = bank + 1) begin : map_bank
            // 相邻 bank 共享一份配置/描述符分发；CFG_COPIES 为 MAP_BANKS 的正因数。
            localparam BUS_COPY = bank / (MAP_BANKS / CFG_COPIES);
            (* preserve = 1, dont_merge = 1 *) reg [MAP_BANK_AW - 1:0] clear_local;
            (* preserve = 1, dont_merge = 1 *) reg cleared;
            wire [15:0] bank_read_addr = map_ra[BUS_COPY * 16 +: 16];
            wire [15:0] bank_cfg_addr = cfg_addr[BUS_COPY * 16 +: 16];
            wire [12:0] bank_cfg_data = cfg_wdata[BUS_COPY * 32 +: 13];
            assign map_rd_sel[bank] = bank_read_addr[15:MAP_BANK_AW] == bank;
            assign map_wr_sel[bank] = init_done && cfg_map_we[BUS_COPY]
                && cfg_ok[BUS_COPY] && bank_cfg_addr[15:MAP_BANK_AW] == bank;
            (* preserve = 1, dont_merge = 1 *) reg read_request, write_request;
            (* preserve = 1, dont_merge = 1 *) reg [MAP_BANK_AW - 1:0] read_address, write_address;
            (* preserve = 1, dont_merge = 1 *) reg ram_request_q;
            (* preserve = 1, dont_merge = 1 *) reg [MAP_BANK_AW - 1:0] ram_address_q;
            (* preserve = 1, dont_merge = 1 *) reg [12:0] write_data;
            (* preserve = 1, dont_merge = 1 *) reg selected;
            wire [12:0] data;
            assign map_bank_data[bank * 13 +: 13] = data & {13{selected}};
            always @(posedge clk) begin
                if (reset) begin
                    read_request <= 0;
                    ram_request_q <= 0;
                    write_request <= 0;
                    selected <= 0;
                    clear_local <= 0;
                    cleared <= 0;
                end
                else begin
                    selected <= ram_request_q;
                    // 使能和源端独热位同拍登记，再在 RAM 口前合并，不额外增加读延迟。
                    read_request <= map_re[BUS_COPY];
                    ram_request_q <= read_request && map_bank_oh[bank];
                    // 各 bank 同时清自己的 2048 项；对外仍等待原初始化完成信号。
                    write_request <= !cleared || map_wr_sel[bank];
                    if (!cleared) begin
                        clear_local <= clear_local + 1'b1;
                        if (&clear_local) cleared <= 1;
                    end
                    // 地址副本每拍更新，读写脉冲在本 bank 内控制存储器。
                    // 返回选择由 RAM 口读脉冲延后一拍，避免全局接纳使能驱动所有 bank 的保持端。
                    read_address <= bank_read_addr[MAP_BANK_AW - 1:0];
                    ram_address_q <= read_address;
                    write_address <= cleared ? bank_cfg_addr[MAP_BANK_AW - 1:0] : clear_local;
                    write_data <= cleared ? bank_cfg_data : 13'b0;
                end
            end
            afdx_ram_sdp #(.WIDTH(13), .DEPTH(1 << MAP_BANK_AW)) memory (
                .clk(clk), .write_enable(write_request), .write_address(write_address), .write_data(write_data),
                .read_enable(ram_request_q), .read_address(ram_address_q),
                .read_data(data)
            );
        end
        // 每两个 bank 在附近合并并寄存，避免存储器输出跨八个 bank 后才遇到寄存器。
        for (map_group = 0; map_group < MAP_GROUPS; map_group = map_group + 1) begin : map_read_group
            always @(posedge clk) begin
                if (reset) map_group_data[map_group * 13 +: 13] <= 0;
                else map_group_data[map_group * 13 +: 13] <=
                    map_bank_data[(map_group * 2) * 13 +: 13]
                    | map_bank_data[(map_group * 2 + 1) * 13 +: 13];
            end
        end
    endgenerate
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(4096)) rx_cfg (
        .clk(clk),
        .write_enable(cfg_we),
        .write_address(cfg_wa),
        .write_data(cfg_wd),
        .read_enable(cfg_re),
        .read_address(cfg_ra),
        .read_data(cfg_q)
    );
    afdx_ram_sdp #(.WIDTH(44), .DEPTH(4096)) rx_state (
        .clk(clk),
        .write_enable(state_we),
        .write_address(state_wa),
        .write_data(state_wd),
        .read_enable(state_re),
        .read_address(state_ra),
        .read_data(state_q)
    );

    // 两网分别暂存用户数据，引擎接纳后交付模块才会读出。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1 << RX_RING_AW)) rx_ring_a (
        .clk(clk),
        .write_enable(ra_we),
        .write_address(ra_wa),
        .write_data(ra_wd),
        .read_enable(ra_re),
        .read_address(ra_ra),
        .read_data(ra_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1 << RX_RING_AW)) rx_ring_b (
        .clk(clk),
        .write_enable(rb_we),
        .write_address(rb_wa),
        .write_data(rb_wd),
        .read_enable(rb_re),
        .read_address(rb_ra),
        .read_data(rb_q)
    );

    // 每网先检查并解析帧，再共用一个引擎检查序号和重复帧。
    afdx_mac_rx mac_a (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .rx_data(rx_data_a),
        .rx_valid(rx_valid_a),
        .m_valid(ma_valid),
        .m_data(ma_data),
        .m_first(ma_first),
        .f_end(fa_end),
        .f_err(fa_err),
        .f_len(fa_len)
    );
    afdx_mac_rx mac_b (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .rx_data(rx_data_b),
        .rx_valid(rx_valid_b),
        .m_valid(mb_valid),
        .m_data(mb_data),
        .m_first(mb_first),
        .f_end(fb_end),
        .f_err(fb_err),
        .f_len(fb_len)
    );
    afdx_rx_parse #(.RX_RING_AW(RX_RING_AW), .DESC_COPIES(CFG_COPIES)) parse_a (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .now_c(now_c[15:0]),
        // 配置和初始化
        .enable(init_done),
        // 数据和握手
        .rx_valid(rx_valid_a),
        .m_valid(ma_valid),
        .m_first(ma_first),
        .m_data(ma_data),
        .f_end(fa_end),
        .f_err(fa_err),
        .f_len(fa_len),
        .read_ptr(ptr_a),
        .ring_we(ra_we),
        .ring_wa(ra_wa),
        .ring_wd(ra_wd),
        .desc_valid(da_valid),
        .desc_data(desc_a),
        .desc_take(take_a),
        .resolve_valid(resolve_a),
        .resolve_commit(commit_a),
        .ev(parse_ev_a)
    );
    afdx_rx_parse #(.RX_RING_AW(RX_RING_AW), .DESC_COPIES(CFG_COPIES)) parse_b (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .now_c(now_c[15:0]),
        // 配置和初始化
        .enable(init_done),
        // 数据和握手
        .rx_valid(rx_valid_b),
        .m_valid(mb_valid),
        .m_first(mb_first),
        .m_data(mb_data),
        .f_end(fb_end),
        .f_err(fb_err),
        .f_len(fb_len),
        .read_ptr(ptr_b),
        .ring_we(rb_we),
        .ring_wa(rb_wa),
        .ring_wd(rb_wd),
        .desc_valid(db_valid),
        .desc_data(desc_b),
        .desc_take(take_b),
        .resolve_valid(resolve_b),
        .resolve_commit(commit_b),
        .ev(parse_ev_b)
    );
    afdx_rx_engine #(.RX_RING_AW(RX_RING_AW), .RX_DQ_AW(RX_DQ_AW), .LOCAL_MAP_READ(1), .REGISTERED_TIME_TICK(REGISTERED_TIME_TICK), .LOCAL_QUEUE_WRITE(0), .DESC_COPIES(CFG_COPIES)) engine (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .now_c(now_c),
                // 配置和初始化
        .enable(init_done),
        .initialized(engine_initialized),
        .cfg_re(cfg_re),
        .cfg_ra(cfg_ra),
        .cfg_q(cfg_q),
        .cfg_ok(cfg_ok),
        // 数据和握手
        .desc_a_valid(da_valid),
        .desc_b_valid(db_valid),
        .desc_a(desc_a),
        .desc_b(desc_b),
        .take_a(take_a),
        .take_b(take_b),
        .resolve_a(resolve_a),
        .resolve_b(resolve_b),
        .commit_a(commit_a),
        .commit_b(commit_b),
        .map_re(map_re),
        .map_ra(map_ra),
        .map_q(map_q_r),
        .state_re(state_re),
        .state_we(state_we),
        .state_ra(state_ra),
        .state_wa(state_wa),
        .state_wd(state_wd),
        .state_q(state_q),
        .dq_pop(dq_pop),
        .dq_we(dq_we),
        .dq_wa(dq_wa),
        .dq_wd(dq_wd),
        .dq_count(dq_count),
        // 事件
        .ev_a(engine_ev_a),
        .ev_b(engine_ev_b),
        .ev_rm_drop(engine_rm),
        .ev_deliver(engine_deliver)
    );
    afdx_rx_deliver #(.RX_RING_AW(RX_RING_AW), .RX_DQ_AW(RX_DQ_AW)) deliver (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .dq_count(dq_count),
        .dq_ra(dq_ra),
        .dq_q(dq_q),
        .dq_pop(dq_pop),
        .ring_a_re(ra_re),
        .ring_b_re(rb_re),
        .ring_a_ra(ra_ra),
        .ring_b_ra(rb_ra),
        .ring_a_q(ra_q),
        .ring_b_q(rb_q),
        .read_ptr_a(ptr_a),
        .read_ptr_b(ptr_b),
        .d_valid(d_valid),
        .d_data(d_data),
        .d_last(d_last),
        .d_vl(d_vl),
        .d_sport(d_sport),
        .d_dport(d_dport),
        .d_net(d_net)
    );

endmodule
