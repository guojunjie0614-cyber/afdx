// 本模块连接发送缓存、发送调度、组帧和以太网发送模块。
// 它从 afdx_svc 接收消息，再输出到两路以太网。
// 本模块对应赛题的发送、带宽控制和双网冗余发送功能。
module afdx_tx_core #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9, LOOKAHEAD = 512) (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // now 提供周期数，当前顶层将 byte_en 每拍置为有效。
    input wire [31:0] now,
    input wire byte_en,
    // m_valid 和 m_ready 同为高时接收一个用户字节。
    // m_last 标记消息末字节，m_vl 指定发送配置索引。
    input wire m_valid,
    output wire m_ready,
    input wire [7:0] m_data,
    input wire m_last,
    input wire [6:0] m_vl,
    // m_port_en 为高时使用消息自带端口，否则使用虚拟链路配置。
    input wire m_port_en,
    input wire [15:0] m_sport, m_dport,
    // cfg_* 写入 128 条虚拟链路的配置，每项占八个字。
    // cfg_ok 为高时允许写入，user_id 设置源以太网地址中的端系统编号。
    input wire cfg_we,
    input wire [9:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    input wire [15:0] user_id,
    // 对应 valid 为高时，tx_data_a/b 是两网本拍发送的字节。
    // 配置表、状态表和空闲页队列都初始化完成后，init_done 才变高。
    output wire [7:0] tx_data_a,
    output wire tx_valid_a,
    output wire [7:0] tx_data_b,
    output wire tx_valid_b,
    output reg init_done,
    // ev_* 用单拍脉冲报告消息接纳、丢弃原因和两网发送完成。
    output wire ev_accept, ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage, ev_tx_a, ev_tx_b,
    output wire cfg_ok);
    localparam PAGES = (1 << TX_PAGE_AW), PAYLOAD_DEPTH = (1 << (TX_PAGE_AW + TX_OFF_AW));
    // init_addr 逐项将配置表置零，init_flush 等待最后一次写入完成。
    // 初始化完成后，外部配置使用这个写口。
    reg cfg_write, init_flush, cfg_initialized;
    reg [9:0] cfg_write_addr, init_addr;
    reg [31:0] cfg_write_data;
    wire free_initialized, engine_initialized;
    wire cfg_read, state_write, state_read, mnext_write, mnext_read, desc_write, desc_read, pnext_write, pnext_read,
        payload_write, payload_read;
    wire [9:0] cfg_read_addr;
    wire [31:0] cfg_data;
    wire [6:0] state_write_addr, state_read_addr;
    wire [62:0] state_write_data, state_data;
    wire [TX_PAGE_AW - 1:0] mnext_write_addr, mnext_read_addr, desc_write_addr, desc_read_addr, pnext_write_addr,
        pnext_read_addr;
    wire [7:0] mnext_write_data, mnext_data, pnext_write_data, pnext_data, payload_write_data, payload_data;
    wire [43:0] desc_write_data, desc_data;
    wire [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_write_addr, payload_read_addr;
    wire pop_req, pop_ready, pop_ack, pop_ok, ret1_valid, ret1_ready, ret2_valid, ret2_ready;
    wire [7:0] pop_page, ret1_page, ret2_page;
    wire enq_valid, enq_ack;
    wire [6:0] enq_vl;
    wire [7:0] enq_head;
    wire [10:0] enq_len;
    wire [2:0] enq_result;
    wire start_valid, grant_ready, grant_valid, grant_a, grant_b, grant_timed;
    wire [31:0] t_start, grant_time, grant_src, grant_dst;
    wire [15:0] grant_vlid, grant_sport, grant_dport;
    wire [10:0] grant_len;
    wire [7:0] grant_sn, grant_page;
    wire s_valid, s_ready, s_last, s_en_a, s_en_b, tx_sof, tx_eof, tx_underrun;
    wire [7:0] s_data_a, s_data_b;
    // 配置表、调度状态和空闲页队列全部就绪后，才接收消息和配置。
    always @(posedge clk) begin
        if (reset) begin
            cfg_write <= 0;
            cfg_write_addr <= 0;
            cfg_write_data <= 0;
            init_addr <= 0;
            init_flush <= 0;
            cfg_initialized <= 0;
            init_done <= 0;
        end
        else begin
            cfg_write <= 0;
            if (! cfg_initialized) begin
                if (! init_flush) begin
                    cfg_write <= 1;
                    cfg_write_addr <= init_addr;
                    cfg_write_data <= 0;
                    init_addr <= init_addr + 1'b1;
                    if (init_addr == 1023) init_flush <= 1;
                end
                else cfg_initialized <= 1;
            end
            else if (init_done) begin
                cfg_write <= cfg_we && cfg_ok;
                cfg_write_addr <= cfg_addr;
                cfg_write_data <= cfg_wdata;
            end
            if (cfg_initialized && free_initialized && engine_initialized) init_done <= 1;
        end
    end
    // cfg 保存各虚拟链路的配置。
    // state 保存队列位置、序号和发送时间。
    // mnext 记录同一虚拟链路的下一条消息。
    // desc 保存消息长度和端口。
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(1024)) tx_cfg (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(cfg_write),
        .write_address(cfg_write_addr),
        .write_data(cfg_write_data),
        .read_enable(cfg_read),
        .read_address(cfg_read_addr),
        .read_data(cfg_data)
    );
    afdx_ram_sdp #(.WIDTH(63), .DEPTH(128)) tx_state (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(state_write),
        .write_address(state_write_addr),
        .write_data(state_write_data),
        .read_enable(state_read),
        .read_address(state_read_addr),
        .read_data(state_data)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_mnext (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(mnext_write),
        .write_address(mnext_write_addr),
        .write_data(mnext_write_data),
        .read_enable(mnext_read),
        .read_address(mnext_read_addr),
        .read_data(mnext_data)
    );
    afdx_ram_sdp #(.WIDTH(44), .DEPTH(PAGES)) tx_desc (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(desc_write),
        .write_address(desc_write_addr),
        .write_data(desc_write_data),
        .read_enable(desc_read),
        .read_address(desc_read_addr),
        .read_data(desc_data)
    );
    // pnext 记录同一消息的下一页，payload 保存消息字节。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_pnext (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(pnext_write),
        .write_address(pnext_write_addr),
        .write_data(pnext_write_data),
        .read_enable(pnext_read),
        .read_address(pnext_read_addr),
        .read_data(pnext_data)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAYLOAD_DEPTH)) tx_payload (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(payload_write),
        .write_address(payload_write_addr),
        .write_data(payload_write_data),
        .read_enable(payload_read),
        .read_address(payload_read_addr),
        .read_data(payload_data)
    );
    // 消息先存入空闲页，再由调度器选择，组帧模块发送后归还页。
    afdx_tx_free #(.TX_PAGE_AW(TX_PAGE_AW)) free_pages (
        // 这些端口用于时钟和复位。
        .clk(clk),
        .reset(reset),
        // 这些端口用于配置和初始化。
        .init_done(free_initialized),
        // 这些端口用于数据和握手。
        .pop_req(pop_req),
        .pop_ready(pop_ready),
        .pop_ack(pop_ack),
        .pop_ok(pop_ok),
        .pop_page(pop_page),
        .ret1_valid(ret1_valid),
        .ret1_page(ret1_page),
        .ret1_ready(ret1_ready),
        .ret2_valid(ret2_valid),
        .ret2_page(ret2_page),
        .ret2_ready(ret2_ready)
    );
    afdx_tx_buf #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW)) buffer (
        // 这些端口用于时钟和复位。
        .clk(clk),
        .reset(reset),
        // 这些端口用于配置和初始化。
        .init_done(init_done),
        // 这些端口用于数据和握手。
        .m_valid(m_valid),
        .m_ready(m_ready),
        .m_data(m_data),
        .m_last(m_last),
        .m_vl(m_vl),
        .m_port_en(m_port_en),
        .m_sport(m_sport),
        .m_dport(m_dport),
        .pop_req(pop_req),
        .pop_ready(pop_ready),
        .pop_ack(pop_ack),
        .pop_ok(pop_ok),
        .pop_page(pop_page),
        .ret_valid(ret2_valid),
        .ret_page(ret2_page),
        .ret_ready(ret2_ready),
        .payload_we(payload_write),
        .payload_wa(payload_write_addr),
        .payload_wd(payload_write_data),
        .pnext_we(pnext_write),
        .pnext_wa(pnext_write_addr),
        .pnext_wd(pnext_write_data),
        .desc_we(desc_write),
        .desc_wa(desc_write_addr),
        .desc_wd(desc_write_data),
        .enq_valid(enq_valid),
        .enq_vl(enq_vl),
        .enq_head(enq_head),
        .enq_len(enq_len),
        .enq_ack(enq_ack),
        .enq_result(enq_result),
        // 这些端口用于事件。
        .ev_accept(ev_accept),
        .ev_drop_dis(ev_drop_dis),
        .ev_drop_full(ev_drop_full),
        .ev_drop_long(ev_drop_long),
        .ev_drop_nopage(ev_drop_nopage)
    );
    afdx_tx_engine #(.TX_PAGE_AW(TX_PAGE_AW), .LOOKAHEAD(LOOKAHEAD)) engine (
        // 这些端口用于时钟和复位。
        .clk(clk),
        .reset(reset),
        .now(now),
        // 这些端口用于配置和初始化。
        .enable(init_done),
        .initialized(engine_initialized),
        .cfg_re(cfg_read),
        .cfg_ra(cfg_read_addr),
        .cfg_q(cfg_data),
        .cfg_ok(cfg_ok),
        // 这些端口用于数据和握手。
        .state_we(state_write),
        .state_re(state_read),
        .state_wa(state_write_addr),
        .state_ra(state_read_addr),
        .state_wd(state_write_data),
        .state_q(state_data),
        .mnext_we(mnext_write),
        .mnext_re(mnext_read),
        .mnext_wa(mnext_write_addr),
        .mnext_ra(mnext_read_addr),
        .mnext_wd(mnext_write_data),
        .mnext_q(mnext_data),
        .desc_re(desc_read),
        .desc_ra(desc_read_addr),
        .desc_q(desc_data),
        .enq_valid(enq_valid),
        .enq_vl(enq_vl),
        .enq_head(enq_head),
        .enq_len(enq_len),
        .enq_ack(enq_ack),
        .enq_result(enq_result),
        .start_valid(start_valid),
        .t_start(t_start),
        .grant_ready(grant_ready),
        .grant_valid(grant_valid),
        .grant_a(grant_a),
        .grant_b(grant_b),
        .grant_timed(grant_timed),
        .grant_time(grant_time),
        .grant_vlid(grant_vlid),
        .grant_sport(grant_sport),
        .grant_dport(grant_dport),
        .grant_src(grant_src),
        .grant_dst(grant_dst),
        .grant_len(grant_len),
        .grant_sn(grant_sn),
        .grant_page(grant_page)
    );
    afdx_tx_builder #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW)) builder (
        // 这些端口用于时钟和复位。
        .clk(clk),
        .reset(reset),
        .now(now),
        // 这些端口用于配置和初始化。
        .user_id(user_id),
        // 这些端口用于数据和握手。
        .grant_ready(grant_ready),
        .grant_valid(grant_valid),
        .grant_a(grant_a),
        .grant_b(grant_b),
        .grant_timed(grant_timed),
        .grant_time(grant_time),
        .grant_src(grant_src),
        .grant_dst(grant_dst),
        .grant_vlid(grant_vlid),
        .grant_sport(grant_sport),
        .grant_dport(grant_dport),
        .grant_len(grant_len),
        .grant_sn(grant_sn),
        .grant_page(grant_page),
        .start_valid(start_valid),
        .t_start(t_start),
        .payload_re(payload_read),
        .payload_ra(payload_read_addr),
        .payload_q(payload_data),
        .pnext_re(pnext_read),
        .pnext_ra(pnext_read_addr),
        .pnext_q(pnext_data),
        .ret_valid(ret1_valid),
        .ret_page(ret1_page),
        .ret_ready(ret1_ready),
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_data_a(s_data_a),
        .s_data_b(s_data_b),
        .s_last(s_last),
        .s_en_a(s_en_a),
        .s_en_b(s_en_b),
        .tx_sof(tx_sof),
        .tx_eof(tx_eof),
        .tx_underrun(tx_underrun),
        // 这些端口用于事件。
        .ev_tx_a(ev_tx_a),
        .ev_tx_b(ev_tx_b)
    );
    afdx_mac_tx mac (
        // 这些端口用于时钟和复位。
        .clk(clk),
        .reset(reset),
        .byte_en(byte_en),
        // 这些端口用于数据和握手。
        .s_valid(s_valid),
        .s_ready(s_ready),
        .s_data_a(s_data_a),
        .s_data_b(s_data_b),
        .s_last(s_last),
        .s_en_a(s_en_a),
        .s_en_b(s_en_b),
        .tx_sof(tx_sof),
        .tx_eof(tx_eof),
        .tx_underrun(tx_underrun),
        .tx_data_a(tx_data_a),
        .tx_valid_a(tx_valid_a),
        .tx_data_b(tx_data_b),
        .tx_valid_b(tx_valid_b)
    );
endmodule
