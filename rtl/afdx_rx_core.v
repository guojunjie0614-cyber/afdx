// 本模块连接两路以太网接收、报文检查和应用交付模块。
// 两路线路分别接收，检查通过后由一个输出口交付消息。
// 本模块对应赛题的接收、错误检测和双网重复帧去除功能。
module afdx_rx_core #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5) (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // now_c 提供粗粒度时间，rx_data_a/b 在对应 valid 为高时有效。
    input wire [15:0] now_c,
    input wire [7:0] rx_data_a,
    input wire rx_valid_a,
    input wire [7:0] rx_data_b,
    input wire rx_valid_b,
    // cfg_map_we 写入线路编号到配置索引的映射。
    // cfg_cfg_we 写入接收参数，cfg_ok 为高时允许这些写操作。
    input wire cfg_map_we, cfg_cfg_we,
    input wire [15:0] cfg_addr,
    input wire [31:0] cfg_wdata,
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
    output reg init_done,
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,
    output wire cfg_ok);
    // clear_addr 初始化 65536 项映射及前 4096 项接收配置。
    // flush_init 等待最后一次写入完成。
    reg map_we, cfg_we, flush_init;
    reg [15:0] clear_addr, map_wa;
    reg [11:0] cfg_wa;
    reg [12:0] map_wd;
    reg [31:0] cfg_wd;
    wire engine_initialized, map_re, cfg_re, state_re, state_we;
    wire [15:0] map_ra;
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
    wire da_valid, db_valid, take_a, take_b, resolve_a, resolve_b, commit_a, commit_b;
    wire [RX_RING_AW + 82:0] desc_a, desc_b;
    wire [7:0] parse_ev_a, parse_ev_b, engine_ev_a, engine_ev_b;
    localparam DQ_WIDTH = RX_RING_AW + 56;
    wire engine_rm, engine_deliver, dq_pop, dq_we;
    wire [RX_DQ_AW - 1:0] dq_wa;
    wire [RX_DQ_AW:0] dq_count;
    wire [DQ_WIDTH - 1:0] dq_wd;
    wire [32 * DQ_WIDTH - 1:0] dq_entries;
    // rx_dq 最多保存 32 条待交付消息的信息。
    // 接收引擎写入这些寄存器，交付模块按顺序读取。
    genvar i;
    generate
        for (i = 0; i < 32; i = i + 1) begin : queue_slot
            if (i < (1 << RX_DQ_AW)) begin : present
                reg [DQ_WIDTH - 1:0] entry;
                always @(posedge clk) if (dq_we && dq_wa == i) entry <= dq_wd;
                assign dq_entries[(i + 1) * DQ_WIDTH - 1:i * DQ_WIDTH] = entry;
            end
            else begin : absent
                assign dq_entries[(i + 1) * DQ_WIDTH - 1:i * DQ_WIDTH] = { DQ_WIDTH { 1'b0 } };
            end
        end
    endgenerate
    // 初始化完成且 cfg_ok 为高时，外部配置才能写入接收表。
    always @(posedge clk) begin
        if (reset) begin
            init_done <= 0;
            map_we <= 0;
            cfg_we <= 0;
            clear_addr <= 0;
            map_wa <= 0;
            cfg_wa <= 0;
            map_wd <= 0;
            cfg_wd <= 0;
            flush_init <= 0;
            ev_a <= 0;
            ev_b <= 0;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
        end
        else begin
            map_we <= 0;
            cfg_we <= 0;
            if (! init_done) begin
                if (! flush_init) begin
                    map_we <= 1;
                    map_wa <= clear_addr;
                    map_wd <= 0;
                    if (clear_addr < 4096) begin
                        cfg_we <= 1;
                        cfg_wa <= clear_addr[11:0];
                        cfg_wd <= 0;
                    end
                    clear_addr <= clear_addr + 1'b1;
                    if (clear_addr == 65535) flush_init <= 1;
                end
                else if (engine_initialized) init_done <= 1;
            end
            else begin
                map_we <= cfg_map_we && cfg_ok;
                map_wa <= cfg_addr;
                map_wd <= cfg_wdata[12:0];
                cfg_we <= cfg_cfg_we && cfg_ok;
                cfg_wa <= cfg_addr[11:0];
                cfg_wd <= cfg_wdata;
            end
            ev_a <= parse_ev_a | engine_ev_a;
            ev_b <= parse_ev_b | engine_ev_b;
            ev_rm_drop <= engine_rm;
            ev_deliver <= engine_deliver;
        end
    end
    // map 保存有效位和 12 位配置索引。
    // cfg 保存接收开关、长度限制和两网允许的最大时间差。
    // state 保存各虚拟链路的接收序号和交付记录。
    afdx_ram_sdp #(.WIDTH(13), .DEPTH(65536)) rx_map (clk, map_we, map_wa, map_wd, map_re, map_ra, map_q);
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(4096)) rx_cfg (clk, cfg_we, cfg_wa, cfg_wd, cfg_re, cfg_ra, cfg_q);
    afdx_ram_sdp #(.WIDTH(44), .DEPTH(4096)) rx_state (clk, state_we, state_wa, state_wd, state_re, state_ra, state_q);
    // 两网分别暂存用户数据，引擎接纳后交付模块才会读出。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1 << RX_RING_AW)) rx_ring_a (clk, ra_we, ra_wa, ra_wd, ra_re, ra_ra, ra_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1 << RX_RING_AW)) rx_ring_b (clk, rb_we, rb_wa, rb_wd, rb_re, rb_ra, rb_q);
    // 每网先检查并解析帧，再共用一个引擎检查序号和重复帧。
    afdx_mac_rx mac_a (clk, reset, rx_data_a, rx_valid_a, ma_valid, ma_data, ma_first, fa_end, fa_err, fa_len);
    afdx_mac_rx mac_b (clk, reset, rx_data_b, rx_valid_b, mb_valid, mb_data, mb_first, fb_end, fb_err, fb_len);
    afdx_rx_parse #(.RX_RING_AW(RX_RING_AW)) parse_a (clk, reset, init_done, rx_valid_a, now_c, ma_valid, ma_first, ma_data,
        fa_end, fa_err, fa_len, ptr_a, ra_we, ra_wa, ra_wd, da_valid, desc_a, take_a, resolve_a, commit_a, parse_ev_a);
    afdx_rx_parse #(.RX_RING_AW(RX_RING_AW)) parse_b (clk, reset, init_done, rx_valid_b, now_c, mb_valid, mb_first, mb_data,
        fb_end, fb_err, fb_len, ptr_b, rb_we, rb_wa, rb_wd, db_valid, desc_b, take_b, resolve_b, commit_b, parse_ev_b);
    afdx_rx_engine #(.RX_RING_AW(RX_RING_AW), .RX_DQ_AW(RX_DQ_AW)) engine (clk, reset, init_done, now_c, engine_initialized,
        da_valid, db_valid, desc_a, desc_b, take_a, take_b, resolve_a, resolve_b, commit_a, commit_b, map_re, map_ra, map_q,
        cfg_re, cfg_ra, cfg_q, state_re, state_we, state_ra, state_wa, state_wd, state_q, dq_pop, dq_we, dq_wa, dq_wd,
        dq_count, engine_ev_a, engine_ev_b, engine_rm, engine_deliver, cfg_ok);
    afdx_rx_deliver #(.RX_RING_AW(RX_RING_AW), .RX_DQ_AW(RX_DQ_AW)) deliver (clk, reset, dq_count, dq_entries, dq_pop, ra_re,
        rb_re, ra_ra, rb_ra, ra_q, rb_q, ptr_a, ptr_b, d_valid, d_data, d_last, d_vl, d_sport, d_dport, d_net);
endmodule
