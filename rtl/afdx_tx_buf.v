// 本模块接收应用消息，把消息分成若干页存入发送缓存。
// 页是发送缓存的分配单位，每页 2^TX_OFF_AW 字节，默认 512 字节。
// afdx_svc 提供字节，整条消息存好后通知 afdx_tx_engine 排队。
// 本模块用于赛题的发送缓存，接收失败时归还本条消息占用的页。
module afdx_tx_buf #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9, EARLY_ENQUEUE = 0) (

    // init_done 为高时才允许接收新消息。
    input wire clk, reset, init_done,

    // m_valid 和 m_ready 同为高时接收 m_data，m_last 标记末字节。
    // m_vl 是发送配置表的 7 位索引。
    input wire m_valid,
    output wire m_ready,
    input wire [7:0] m_data,
    input wire m_last,
    input wire [6:0] m_vl,

    // m_port_en 为高时使用本消息的端口，否则使用配置中的端口。
    input wire m_port_en,
    input wire [15:0] m_sport, m_dport,

    // pop_* 申请一个空闲页，ret_* 归还接收失败的消息所占用的页。
    output reg pop_req,
    input wire pop_ready, pop_ack, pop_ok,
    input wire [7:0] pop_page,
    output reg ret_valid,
    output reg [7:0] ret_page,
    input wire ret_ready,

    // payload_* 写消息字节，pnext_* 保存同一消息的下一页。
    // desc_* 在首页对应位置保存消息长度和端口。
    output reg payload_we,
    output reg [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_wa,
    output reg [7:0] payload_wd,
    output reg pnext_we,
    output reg [TX_PAGE_AW - 1:0] pnext_wa,
    output reg [7:0] pnext_wd,
    output reg desc_we,
    output reg [TX_PAGE_AW - 1:0] desc_wa,
    output reg [43:0] desc_wd,

    // 整条消息存好后，enq_* 请求加入发送队列。
    // enq_ack 为高时，enq_result 给出接纳或拒绝的原因。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg enq_valid,
    output reg [6:0] enq_vl,
    output reg [7:0] enq_head,
    output reg [10:0] enq_len,
    input wire enq_ack,
    input wire [2:0] enq_result,

    // ev_* 每次输出一个结果脉冲，表示接纳或本次拒绝原因。
    output reg ev_accept, ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage);

    localparam ENQ_ACCEPTED = 0;
    localparam ENQ_DISABLED = 1;
    localparam ENQ_FULL = 2;
    localparam ENQ_TOO_LONG = 3;
    localparam ENQ_NO_PAGE = 4;

    // 一条消息最多 1471 字节，加上协议头和序号后正好是最长的以太网帧。
    localparam MAX_PAYLOAD = 1471;
    localparam IDLE = 0, ALLOC = 1, WAIT_PAGE = 2, RECV = 3, DESC = 4, ENQUEUE = 5, REPLY = 6, RETURN = 7, DRAIN = 8,
        EVENT = 9;
    reg [3:0] state;

    // 一条消息最多占六页，六个寄存器保存这些页号。
    // 显式列出六个寄存器，避免综合工具为小数组额外分配存储块。
    reg [7:0] page0, page1, page2, page3, page4, page5;

    // used/returned 分别统计本条消息已占用和已归还的页数。
    // reason 保存本次接收结果。
    reg [2:0] used, returned, reason;

    // held_data/held_last 保存等待新页时的第一个字节。
    // boundary 表示上一页已满，ended 表示已收到消息末字节。
    reg [7:0] current_page, held_data;
    reg [TX_OFF_AW - 1:0] offset;
    reg boundary, ended, held_last, port_en;
    reg [15:0] sport, dport;

    assign m_ready = init_done && (state == IDLE || state == RECV || state == DRAIN);

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            pop_req <= 0;
            enq_valid <= 0;
            payload_we <= 0;
            pnext_we <= 0;
            desc_we <= 0;
            ret_valid <= 0;
            ret_page <= 0;
            page0 <= 0;
            page1 <= 0;
            page2 <= 0;
            page3 <= 0;
            page4 <= 0;
            page5 <= 0;
            payload_wa <= 0;
            payload_wd <= 0;
            pnext_wa <= 0;
            pnext_wd <= 0;
            desc_wa <= 0;
            desc_wd <= 0;
            enq_vl <= 0;
            enq_head <= 0;
            enq_len <= 0;
            used <= 0;
            returned <= 0;
            reason <= ENQ_ACCEPTED;
            current_page <= 0;
            held_data <= 0;
            offset <= 0;
            boundary <= 0;
            ended <= 0;
            held_last <= 0;
            port_en <= 0;
            sport <= 0;
            dport <= 0;
            ev_accept <= 0;
            ev_drop_dis <= 0;
            ev_drop_full <= 0;
            ev_drop_long <= 0;
            ev_drop_nopage <= 0;
        end
        else begin
            // 数据和地址先预存，写使能单独确认真实握手，避免把 ready/valid 串入宽数据路径。
            payload_wd <= state == WAIT_PAGE ? held_data : m_data;
            payload_wa <= state == WAIT_PAGE
                ? {pop_page[TX_PAGE_AW - 1:0], {TX_OFF_AW{1'b0}}} : {current_page[TX_PAGE_AW - 1:0], offset};
            if (state == RECV) begin
                held_data <= m_data;
                held_last <= m_last;
            end
            payload_we <= 0;
            pnext_we <= 0;
            desc_we <= 0;
            ev_accept <= 0;
            ev_drop_dis <= 0;
            ev_drop_full <= 0;
            ev_drop_long <= 0;
            ev_drop_nopage <= 0;
            case (state)

                // IDLE：接收并保存首字节，握手后转 ALLOC。
                // 空闲时预存首字节候选，真实握手拍仍保存同一值；只有握手改变状态。
                IDLE : begin
                    enq_vl <= m_vl;
                    port_en <= m_port_en;
                    sport <= m_sport;
                    dport <= m_dport;
                    held_data <= m_data;
                    held_last <= m_last;
                    ended <= m_last;
                    enq_len <= 1;
                    used <= 0;
                    returned <= 0;
                    reason <= ENQ_ACCEPTED;
                    boundary <= 0;
                    if (m_valid && init_done) state <= ALLOC;
                end

                // ALLOC：发出页申请，下一拍转 WAIT_PAGE。
                ALLOC : begin
                    pop_req <= 1;
                    state <= WAIT_PAGE;
                end

                // WAIT_PAGE：取得页后写首字节，再转 RECV 或 DESC；无页转 RETURN。
                WAIT_PAGE : begin
                    if (pop_req && pop_ready) pop_req <= 0;
                    if (pop_ack) begin
                        if ( ! pop_ok) begin
                            reason <= ENQ_NO_PAGE;
                            returned <= 0;
                            state <= RETURN;
                        end
                        else begin
                            case (used)
                                0 : page0 <= pop_page;
                                1 : page1 <= pop_page;
                                2 : page2 <= pop_page;
                                3 : page3 <= pop_page;
                                4 : page4 <= pop_page;
                                5 : page5 <= pop_page;
                                default : ;
                            endcase
                            used <= used + 1'b1;
                            if (used == 0) enq_head <= pop_page;
                            else begin
                                pnext_we <= 1;
                                pnext_wa <= current_page;
                                pnext_wd <= pop_page;
                            end
                            current_page <= pop_page;
                            offset <= 1;
                            boundary <= 0;
                            payload_we <= 1;
                            state <= held_last ? DESC : RECV;
                        end
                    end
                end

                // RECV：存入字节，跨页转 ALLOC，末字节转 DESC，过长转 RETURN。
                RECV : if (m_valid && init_done) begin
                    ended <= m_last;
                    if (enq_len == MAX_PAYLOAD) begin
                        reason <= ENQ_TOO_LONG;
                        returned <= 0;
                        state <= RETURN;
                    end
                    else begin
                        enq_len <= enq_len + 1'b1;
                        if (boundary) begin
                            state <= ALLOC;
                        end
                        else begin
                            payload_we <= 1;
                            offset <= offset + 1'b1;
                            if ( & offset) boundary <= 1;
                            if (m_last) state <= DESC;
                        end
                    end
                end

                // DESC：保存消息长度和端口，下一拍转 ENQUEUE。
                DESC : begin
                    if (EARLY_ENQUEUE) enq_valid <= 1;
                    desc_we <= 1;
                    desc_wa <= enq_head;
                    desc_wd <= { enq_len, port_en, sport, dport };
                    state <= ENQUEUE;
                end

                // ENQUEUE：提交入队请求，下一拍转 REPLY。
                ENQUEUE : begin
                    enq_valid <= 1;
                    state <= REPLY;
                end

                // REPLY：等待调度结果，接纳转 EVENT，拒绝转 RETURN。
                REPLY : if (enq_ack) begin
                    enq_valid <= 0;
                    reason <= enq_result;
                    if (enq_result == ENQ_ACCEPTED) state <= EVENT;
                    else begin
                        returned <= 0;
                        state <= RETURN;
                    end
                end

                // RETURN：逐页归还空间，完成后按消息是否结束转 EVENT 或 DRAIN。
                RETURN : begin
                    // 先归还已经占用的页，再丢弃尚未接收完的字节。
                    // reason 保持第一次出现的错误原因。
                    if ( ! ret_valid && returned < used) begin
                        ret_valid <= 1;
                        case (returned)
                            0 : ret_page <= page0;
                            1 : ret_page <= page1;
                            2 : ret_page <= page2;
                            3 : ret_page <= page3;
                            4 : ret_page <= page4;
                            5 : ret_page <= page5;
                            default : ret_page <= 0;
                        endcase
                    end
                    if (ret_valid && ret_ready) begin
                        returned <= returned + 1'b1;
                        ret_valid <= 0;
                    end
                    if (returned == used) state <= ended ? EVENT : DRAIN;
                end

                // DRAIN：继续接收但不保存字节，收到末字节后转 EVENT。
                DRAIN : if (m_valid && init_done && m_last) state <= EVENT;

                // EVENT：输出一拍结果脉冲，下一拍转 IDLE。
                EVENT : begin
                    case (reason)
                        ENQ_ACCEPTED : ev_accept <= 1;
                        ENQ_DISABLED : ev_drop_dis <= 1;
                        ENQ_FULL : ev_drop_full <= 1;
                        ENQ_TOO_LONG : ev_drop_long <= 1;
                        ENQ_NO_PAGE : ev_drop_nopage <= 1;
                        default : ;
                    endcase
                    state <= IDLE;
                end

                default : state <= IDLE;
            endcase
        end
    end

endmodule
