// 接收应用消息，按页写入发送载荷RAM并形成消息描述。
// m_*为输入握手；页申请、描述队列及丢弃事件接发送外壳。
// 先检查VL/长度/队列容量；整条消息成功收完才提交描述。
// 接收状态：首字节暂存、取页、连续写入、登记、回滚、清尾、结果脉冲。
module afdx_tx_buf #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9) (
    input wire clk, reset, init_done,
    input wire m_valid,
    output wire m_ready,
    input wire [7:0] m_data,
    input wire m_last,
    input wire [6:0] m_vl,
    input wire m_port_en,
    input wire [15:0] m_sport, m_dport,
    output reg pop_req,
    input wire pop_ready, pop_ack, pop_ok,
    input wire [7:0] pop_page,
    output reg ret_valid,
    output reg [7:0] ret_page,
    input wire ret_ready,
    output reg payload_we,
    output reg [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_wa,
    output reg [7:0] payload_wd,
    output reg pnext_we,
    output reg [TX_PAGE_AW - 1:0] pnext_wa,
    output reg [7:0] pnext_wd,
    output reg desc_we,
    output reg [TX_PAGE_AW - 1:0] desc_wa,
    output reg [43:0] desc_wd,
    output reg enq_valid,
    output reg [6:0] enq_vl,
    output reg [7:0] enq_head,
    output reg [10:0] enq_len,
    input wire enq_ack,
    input wire [2:0] enq_result,
    output reg ev_accept, ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage);
    localparam IDLE = 0, ALLOC = 1, WAIT_PAGE = 2, RECV = 3, DESC = 4, ENQUEUE = 5, REPLY = 6, RETURN = 7, DRAIN = 8,
        EVENT = 9;
    reg [3:0] state;
    // 一条消息最多六页；这是消息暂存寄存器，不是逐 VL 状态表。
    // 显式六项，防止 eLinx 把带输出寄存器的小数组也推成额外 RAM。
    reg [7:0] page0, page1, page2, page3, page4, page5;
    reg [2:0] used, returned, reason;
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
            reason <= 0;
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
            payload_we <= 0;
            pnext_we <= 0;
            desc_we <= 0;
            ev_accept <= 0;
            ev_drop_dis <= 0;
            ev_drop_full <= 0;
            ev_drop_long <= 0;
            ev_drop_nopage <= 0;
            case (state)
                IDLE : if (m_valid && m_ready) begin
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
                    reason <= 0;
                    boundary <= 0;
                    state <= ALLOC;
                end
                ALLOC : begin
                    pop_req <= 1;
                    state <= WAIT_PAGE;
                end
                WAIT_PAGE : begin
                    if (pop_req && pop_ready) pop_req <= 0;
                    if (pop_ack) begin
                        if (! pop_ok) begin
                            reason <= 4;
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
                                default :;
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
                            payload_wa <= { pop_page[TX_PAGE_AW - 1:0], { TX_OFF_AW { 1'b0 } } };
                            payload_wd <= held_data;
                            state <= held_last ? DESC : RECV;
                        end
                    end
                end
                RECV : if (m_valid && m_ready) begin
                    ended <= m_last;
                    if (enq_len == 1471) begin
                        reason <= 3;
                        returned <= 0;
                        state <= RETURN;
                    end
                    else begin
                        enq_len <= enq_len + 1'b1;
                        if (boundary) begin
                            held_data <= m_data;
                            held_last <= m_last;
                            state <= ALLOC;
                        end
                        else begin
                            payload_we <= 1;
                            payload_wa <= { current_page[TX_PAGE_AW - 1:0], offset };
                            payload_wd <= m_data;
                            offset <= offset + 1'b1;
                            if (& offset) boundary <= 1;
                            if (m_last) state <= DESC;
                        end
                    end
                end
                DESC : begin
                    desc_we <= 1;
                    desc_wa <= enq_head;
                    desc_wd <= { enq_len, port_en, sport, dport };
                    state <= ENQUEUE;
                end
                ENQUEUE : begin
                    enq_valid <= 1;
                    state <= REPLY;
                end
                REPLY : if (enq_ack) begin
                    enq_valid <= 0;
                    reason <= enq_result;
                    if (enq_result == 0) state <= EVENT;
                    else begin
                        returned <= 0;
                        state <= RETURN;
                    end
                end
                RETURN : begin
                    // 先逐页归还再清尾；故障原因保持第一次遇到的接收错误。
                    if (! ret_valid && returned < used) begin
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
                DRAIN : if (m_valid && m_ready && m_last) state <= EVENT;
                EVENT : begin
                    case (reason)
                        0 : ev_accept <= 1;
                        1 : ev_drop_dis <= 1;
                        2 : ev_drop_full <= 1;
                        3 : ev_drop_long <= 1;
                        4 : ev_drop_nopage <= 1;
                        default :;
                    endcase
                    state <= IDLE;
                end
                default : state <= IDLE;
            endcase
        end
    end
endmodule
