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
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg init_done,

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
    wire [46:0] desc_write_data, desc_data;
    wire [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_write_addr, payload_read_addr;
    wire pop_req, pop_ready, pop_ack, pop_ok, ret1_valid, ret1_ready, ret2_valid, ret2_ready;
    wire [7:0] pop_page, ret1_page, ret2_page;
    wire enq_valid, enq_ack;
    wire [6:0] enq_vl;
    wire [7:0] enq_head;
    wire [13:0] enq_len;
    wire [2:0] enq_result;
    wire start_valid, grant_ready, grant_valid, grant_a, grant_b, grant_timed;
    wire [31:0] t_start, grant_time, grant_src, grant_dst;
    wire [15:0] grant_vlid, grant_sport, grant_dport;
    wire [10:0] grant_len;
    wire [7:0] grant_sn, grant_page, grant_head;
    wire [TX_OFF_AW-1:0] grant_offset, fragment_done_offset;
    wire [12:0] grant_ip_offset;
    wire [13:0] grant_message_len;
    wire [15:0] grant_ident;
    wire grant_first, grant_more;
    wire [6:0] grant_vl_index, fragment_done_vl;
    wire fragment_done, completion_now;
    wire [6:0] completion_vl;
    wire [7:0] fragment_done_page;
    wire s_valid, s_last, s_en_a, s_en_b, tx_sof, tx_eof, tx_underrun;
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
            if ( ! cfg_initialized) begin
                if ( ! init_flush) begin
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
        .clk(clk),
        .write_enable(cfg_write),
        .write_address(cfg_write_addr),
        .write_data(cfg_write_data),
        .read_enable(cfg_read),
        .read_address(cfg_read_addr),
        .read_data(cfg_data)
    );
    afdx_ram_sdp #(.WIDTH(63), .DEPTH(128)) tx_state (
        .clk(clk),
        .write_enable(state_write),
        .write_address(state_write_addr),
        .write_data(state_write_data),
        .read_enable(state_read),
        .read_address(state_read_addr),
        .read_data(state_data)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_mnext (
        .clk(clk),
        .write_enable(mnext_write),
        .write_address(mnext_write_addr),
        .write_data(mnext_write_data),
        .read_enable(mnext_read),
        .read_address(mnext_read_addr),
        .read_data(mnext_data)
    );
    afdx_ram_sdp #(.WIDTH(47), .DEPTH(PAGES)) tx_desc (
        .clk(clk),
        .write_enable(desc_write),
        .write_address(desc_write_addr),
        .write_data(desc_write_data),
        .read_enable(desc_read),
        .read_address(desc_read_addr),
        .read_data(desc_data)
    );

    // pnext 记录同一消息的下一页，payload 保存消息字节。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_pnext (
        .clk(clk),
        .write_enable(pnext_write),
        .write_address(pnext_write_addr),
        .write_data(pnext_write_data),
        .read_enable(pnext_read),
        .read_address(pnext_read_addr),
        .read_data(pnext_data)
    );
    afdx_tx_payload_store #(.AW(TX_PAGE_AW+TX_OFF_AW)) tx_payload (
        .clk(clk),.reset(reset),
        .write_enable(payload_write),
        .write_address(payload_write_addr),
        .write_data(payload_write_data),
        // Used only to diagnose a collision on an actually consumed response;
        // the storage read itself is unconditional.
        .read_request(payload_read),
        .read_address(payload_read_addr),
        .read_data(payload_data)
    );

    // 消息先存入空闲页，再由调度器选择，组帧模块发送后归还页。
    afdx_tx_free #(.TX_PAGE_AW(TX_PAGE_AW)) free_pages (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 配置和初始化
        .init_done(free_initialized),
        // 数据和握手
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
    afdx_tx_buf #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW), .EARLY_ENQUEUE(1)) buffer (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 配置和初始化
        .init_done(init_done),
        // 数据和握手
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
        // 事件
        .ev_accept(ev_accept),
        .ev_drop_dis(ev_drop_dis),
        .ev_drop_full(ev_drop_full),
        .ev_drop_long(ev_drop_long),
        .ev_drop_nopage(ev_drop_nopage)
    );
    afdx_tx_engine #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW), .LOOKAHEAD(LOOKAHEAD), .PIPELINED_ENQUEUE(1), .COMPLETION_LOOKAHEAD(1)) engine (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .now(now),
        // 配置和初始化
        .enable(init_done),
        .initialized(engine_initialized),
        .cfg_re(cfg_read),
        .cfg_ra(cfg_read_addr),
        .cfg_q(cfg_data),
        .cfg_ok(cfg_ok),
        // 数据和握手
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
        .grant_page(grant_page),
        .grant_head(grant_head), .grant_offset(grant_offset),
        .grant_ip_offset(grant_ip_offset), .grant_message_len(grant_message_len),
        .grant_ident(grant_ident), .grant_first(grant_first), .grant_more(grant_more),
        .completion_now(completion_now),.completion_vl(completion_vl),
        .grant_vl_index(grant_vl_index), .fragment_done(fragment_done),
        .fragment_done_vl(fragment_done_vl), .fragment_done_page(fragment_done_page),
        .fragment_done_offset(fragment_done_offset)
    );
    localparam READY_COPIES = 15;
    wire [READY_COPIES - 1:0] s_ready;

    afdx_tx_builder #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW), .READY_COPIES(READY_COPIES)) builder (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .now(now),
        // 配置和初始化
        .user_id(user_id),
        // 数据和握手
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
        .grant_head(grant_head), .grant_offset(grant_offset),
        .grant_ip_offset(grant_ip_offset), .grant_message_len(grant_message_len),
        .grant_ident(grant_ident), .grant_first(grant_first), .grant_more(grant_more),
        .completion_now(completion_now),.completion_vl(completion_vl),
        .grant_vl_index(grant_vl_index), .fragment_done(fragment_done),
        .fragment_done_vl(fragment_done_vl), .fragment_done_page(fragment_done_page),
        .fragment_done_offset(fragment_done_offset),
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
        // 事件
        .ev_tx_a(ev_tx_a),
        .ev_tx_b(ev_tx_b)
    );
    // 组帧模块到 MAC 之间放一级两项的流水缓冲：组帧模块只看缓冲的寄存 ready，
    // MAC 看到的有效、数据都由靠近它的寄存器驱动，两段长线各自只有一级寄存器到寄存器。
    // 缓冲满速时每拍进出一个字节，不插空拍；发送整体晚一拍。
    localparam STREAM_WIDTH = 19;
    wire [STREAM_WIDTH - 1:0] up_word = { s_data_a, s_data_b, s_last, s_en_a, s_en_b };
    (* preserve = 1, dont_merge = 1 *) reg [READY_COPIES - 1:0] up_ready;
    reg main_valid, skid_valid;
    reg [STREAM_WIDTH - 1:0] main_word, skid_word;
    wire mac_ready;
    wire up_take = s_valid && up_ready[0];
    wire main_free = !main_valid || mac_ready;
    assign s_ready = up_ready;
    always @(posedge clk) begin
        if (reset) begin
            up_ready <= {READY_COPIES{1'b1}};
            main_valid <= 0;
            skid_valid <= 0;
            main_word <= 0;
            skid_word <= 0;
        end
        else begin
            // Invariant: up_ready == !skid_valid. Predict the next empty
            // reserve slot every edge, including held cycles, without a ready
            // feedback enable. The advertised credit always has real storage.
            up_ready <= {READY_COPIES{main_free || (!skid_valid && !s_valid)}};
            if (main_free) begin
                // MAC 取走或缓冲为空时，先补入暂存项，否则补入本拍新字节。
                main_valid <= skid_valid || up_take;
                main_word <= skid_valid ? skid_word : up_word;
                skid_valid <= 0;
            end
            else if (up_take) begin
                // MAC 本拍不取：新字节进暂存项，下一拍停止向组帧模块要数。
                skid_valid <= 1;
                skid_word <= up_word;
            end
        end
    end

    afdx_mac_tx mac (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        .byte_en(byte_en),
        // 数据和握手
        .s_valid(main_valid),
        .s_ready(mac_ready),
        .s_data_a(main_word[18:11]),
        .s_data_b(main_word[10:3]),
        .s_last(main_word[2]),
        .s_en_a(main_word[1]),
        .s_en_b(main_word[0]),
        .tx_sof(tx_sof),
        .tx_eof(tx_eof),
        .tx_underrun(tx_underrun),
        .tx_data_a(tx_data_a),
        .tx_valid_a(tx_valid_a),
        .tx_data_b(tx_data_b),
        .tx_valid_b(tx_valid_b)
    );

endmodule

// Preserve the original single logical RAM and free-running synchronous read.
// Builder E0 request -> E1 RAM -> E2 builder return FF -> E3 payload FIFO.
// A complete write bundle is captured locally, then physically written one
// clock later. Descriptor/admission scheduling leaves >=36 clocks before the
// earliest new-message read; rollback cannot return a page before retirement.
module afdx_tx_payload_store #(parameter AW=17) (
    input wire clk,reset,write_enable,
    input wire [AW-1:0] write_address,
    input wire [7:0] write_data,
    input wire read_request,
    input wire [AW-1:0] read_address,
    output reg [7:0] read_data
);
    (* preserve=1,dont_merge=1 *) reg write_command,write_qualifier;
    (* preserve=1,dont_merge=1 *) reg [AW-1:0] write_address_command;
    (* preserve=1,dont_merge=1 *) reg [7:0] write_data_command;
    (* ramstyle="no_rw_check" *) reg [7:0] memory[0:(1<<AW)-1];
    always @(posedge clk)begin
        if(reset)begin write_command<=0;write_qualifier<=0;end
        else begin write_command<=write_enable;write_qualifier<=write_enable;end
        // Empty/unaccepted commands may sample; WE never gates wide FFs.
        write_address_command<=write_address;
        write_data_command<=write_data;
    end
    // Command and data qualifier have identical values but independent local
    // loads. Reset flushes valid; a previously accepted write may retire on
    // the first reset edge while all allocation/descriptor ownership is reset.
    always @(posedge clk)if(write_command)
        memory[write_address_command]<=write_qualifier ? write_data_command : 8'b0;
    always @(posedge clk)read_data<=memory[read_address];
`ifndef SYNTHESIS
    // Only actual physical writes and consumed read requests may collide.
    always @(posedge clk)if(!reset && write_command && read_request && write_address_command==read_address)
        $display("** Error: [RAMCOLL] %m physical_read time=%0t address=%0d",$time,write_address_command);
`endif
endmodule
