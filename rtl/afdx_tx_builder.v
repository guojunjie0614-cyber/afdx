// 本模块读取用户数据，在前面加上以太网头、IPv4 头和 UDP 头，组成一帧。
// afdx_tx_engine 给出要发送的消息，组好的字节交给 afdx_mac_tx。
// 本模块用于赛题的发送组帧，也把实际发送时间返回调度器。
module afdx_tx_builder #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9, READY_COPIES = 1) (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // now 提供当前周期数，user_id 提供源以太网地址中的端系统编号。
    input wire [31:0] now,
    input wire [15:0] user_id,

    // grant_valid 和 grant_ready 同为高时接收一条待发送消息。
    // grant_a/b 选择网络，grant_timed/time 给出最早发送时刻。
    output wire grant_ready,
    input wire grant_valid, grant_a, grant_b, grant_timed,

    // grant_* 给出本帧的地址、端口、长度、序号和数据首页。
    input wire [31:0] grant_time, grant_src, grant_dst,
    input wire [15:0] grant_vlid, grant_sport, grant_dport,
    input wire [10:0] grant_len,
    input wire [7:0] grant_sn, grant_page,

    input wire [7:0] grant_head,
    input wire [TX_OFF_AW-1:0] grant_offset,
    input wire [12:0] grant_ip_offset,
    input wire [13:0] grant_message_len,
    input wire [15:0] grant_ident,
    input wire grant_first, grant_more,
    input wire [6:0] grant_vl_index,
    // Actual current stream handshake, sampled locally by engine at F0.
    // Registered fragment_done and pointer publication remain unchanged.
    output wire completion_now,
    output wire [6:0] completion_vl,
    output reg fragment_done,
    output reg [6:0] fragment_done_vl,
    output reg [7:0] fragment_done_page,
    output reg [TX_OFF_AW-1:0] fragment_done_offset,

    // start_valid 为高时，t_start 报告线路实际发送首字节的周期。
    output reg start_valid,
    output reg [31:0] t_start,

    // payload_* 读消息字节，pnext_* 读同一消息的下一页。
    // 读完一页后，通过 ret_* 归还这一页。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg payload_re,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_ra,
    input wire [7:0] payload_q,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg pnext_re,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg [TX_PAGE_AW - 1:0] pnext_ra,
    input wire [7:0] pnext_q,
    output reg ret_valid,
    output reg [7:0] ret_page,
    input wire ret_ready,

    // s_* 把两网的帧内容交给以太网发送模块。
    // tx_sof/eof 分别报告帧开始和结束，tx_underrun 表示中途缺字节。
    // ev_tx_a/b 只统计正常发送完成的帧。
    output reg s_valid,
    input wire [READY_COPIES - 1:0] s_ready,
    output reg [7:0] s_data_a, s_data_b,
    output reg s_last, s_en_a, s_en_b,
    input wire tx_sof, tx_eof, tx_underrun,
    output reg ev_tx_a, ev_tx_b);

    // pending/prepared 记录下一条消息的准备进度。
    // stream_active 为高表示当前帧正在发送，两者可以同时推进。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg pending, prepared, stream_active, p_a, p_b, p_timed;

    // Sequential additions include length, identification, fragment field and addresses.
    reg [3:0] prep;

    // part 的取值：一帧依次发送协议头、用户数据、补零和序号。
    localparam PART_HEADER = 0, PART_PAYLOAD = 1, PART_PADDING = 2, PART_SN = 3;

    // First fragment has a 42-byte Ethernet/IP/UDP header; later fragments have 34 bytes.
    // 用户数据不足 17 字节时补零到 17 字节。
    localparam HEADER_LAST = 41, NETWORK_ID_INDEX = 10, MIN_PAYLOAD = 17;

    // IPv4 总长度比用户数据多 28 字节（IPv4 头 20 字节加 UDP 头 8 字节），UDP 长度多 8 字节。
    localparam IP_UDP_OVERHEAD = 16'd28, UDP_HEADER_LENGTH = 16'd8;

    // IPv4 头校验和的累加初值，见下面 prep=0 处的说明。
    localparam IP_SUM_SEED = 20'h04611;

    // 协议头里的固定字段。
    localparam DMAC_PREFIX = 32'h03000000, DMAC_BYTE0 = 8'h03, SMAC_PREFIX = 24'h020000;
    localparam NETWORK_A = 8'h20, NETWORK_B = 8'h40, ETHERTYPE_IPV4 = 16'h0800;
    localparam IP_VERSION_TOS = 16'h4500, IP_NO_FRAGMENT = 16'h0000, IP_TTL_PROTOCOL = 16'h0111;
    localparam UDP_NO_CHECKSUM = 16'h0000;

    // Time subtraction and partial due reductions are separate stages.
    // Eight clocks of lead compensate all stages, including the stream slot,
    // so the actual first preamble byte still occurs at the scheduled time.
    localparam START_LEAD_REGISTERED = 32'hfffffff8;
    reg due_nonnegative, due_upper_max, due_lower_max, due_near;
    wire due_reduced = (due_nonnegative && !(due_upper_max && due_lower_max)) || due_near;
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg time_due;

    // 预读队列里已有这么多字节时，暂停发出新的读请求。
    localparam FIFO_STOP_LEVEL = 5;
    reg [31:0] p_time, p_src, p_dst, time_difference;
    (* preserve = 1, dont_merge = 1 *) reg [31:0] now_q;
    (* preserve = 1, dont_merge = 1 *) reg [31:0] now_input;
    reg [15:0] p_vlid, p_sport, p_dport, p_user, p_ident, ip_length, udp_length, checksum;
    reg [12:0] p_ip_offset;
    reg [13:0] p_message_len;
    reg p_first, p_more, active_more;
    reg [7:0] p_head, active_head, head_saved;
    reg [6:0] p_vl_index, active_vl_index;
    reg [TX_OFF_AW-1:0] p_offset;
    reg [5:0] active_header_last;
    reg [4:0] active_min_payload;
    reg head_pending;
    reg [2:0] fetch_delay;
    reg [10:0] p_len, active_len, payload_index;
    // 与负载下标同拍更新，移出字节队列控制路径上的长比较。
    reg payload_more;
    wire [10:0] payload_index_next = payload_index + 1'b1;
    reg [7:0] p_sn, p_page, active_sn;
    reg [16:0] first_fold;
    reg [8:0] fold_low;
    reg [7:0] fold_high;
    // 校验和的低 16 位与进位分开累加，每步的加法链不超过 16 位。
    reg [15:0] sum_low;
    reg [3:0] sum_high;
    // 下一次累加的字段提前一拍锁存，低位加法和进位路径不再经过字段选择器。
    reg [15:0] sum_operand;
    localparam [19:0] IP_SUM_LENGTH_SEED = IP_SUM_SEED + IP_UDP_OVERHEAD;
    wire [16:0] sum_step = {1'b0, sum_low} + {1'b0, sum_operand};

    // header 保存 42 字节协议头：以太网头 14 字节、IPv4 头 20 字节、UDP 头 8 字节。
    // 发送时按顺序移出；两网的协议头只有源地址里的网络标识不同。
    reg [335:0] header;
    (* preserve = 1, dont_merge = 1 *) reg [335:0] header_template;
    wire [335:0] prepared_header = { DMAC_PREFIX, p_vlid, SMAC_PREFIX, p_user, NETWORK_A, ETHERTYPE_IPV4,
                    IP_VERSION_TOS, ip_length, p_ident,
                    {2'b00,p_more,p_ip_offset}, IP_TTL_PROTOCOL, checksum, p_src, p_dst,
                    (p_first ? {p_sport, p_dport, udp_length, UDP_NO_CHECKSUM} : 64'b0) };
    wire [335:0] shifted_header = header << 8;


    // part=0：发送协议头，完成后转 1。
    // part=1：发送用户数据，完成后按帧长转 2 或 3。
    // part=2：补零直到满足最小帧长，然后转 3。
    // part=3：发送一字节序号（Sequence Number，SN），握手后结束本帧。
    reg [1:0] part;
    reg [5:0] header_index;
    reg [4:0] padding_left;

    // fetch_page/offset/left 记录下一字节的位置和剩余数量。
    // payload_pipe 和 pnext_pipe 标记同步存储器读结果何时有效。
    reg [7:0] fetch_page, next_page, payload_qr, pnext_qr;
    reg [10:0] fetch_left;

    // 字节队列有八项，归还页号的队列有四项，都使用寄存器。
    reg [63:0] payload_fifo;
    reg [2:0] fifo_wr, fifo_rd;
    reg [3:0] fifo_count;
    reg issue_end;
    reg [7:0] issue_page, return_page0, return_page1;
    reg [1:0] return_pipe;
    reg [31:0] return_fifo;
    reg [1:0] return_wr, return_rd;
    reg [2:0] return_count;
    reg [1:0] payload_pipe, pnext_pipe;
    wire fifo_push = payload_pipe[1];
    // Predict the FIFO action with the staged stream byte. Ready then drives
    // only a local token and count update, without header/part comparisons.
    reg fifo_pop_eligible;
    wire fifo_pop = s_ready[0] && fifo_pop_eligible;
    wire return_push = payload_pipe[1] && return_pipe[1];
    wire return_pop = ( ! ret_valid || ret_ready) && return_count != 0;
    reg [TX_OFF_AW - 1:0] fetch_offset;
    // 与偏移同步预判页尾，页号和下一页读使能不再经过全位归约与。
    (* preserve = 1, dont_merge = 1 *) reg offset_last;
    localparam [TX_OFF_AW - 1:0] OFFSET_BEFORE_LAST = {TX_OFF_AW{1'b1}} - 1'b1;
    reg complete_a, complete_b, bad;

    assign grant_ready = ! pending;
    assign completion_now = s_valid && s_ready[0] && s_last;
    assign completion_vl = active_vl_index;

    // Accept all external fields on E0; local field commands load E1. Pending
    // changes on E0 as before, so a second grant cannot overwrite this snapshot.
    (* preserve = 1, dont_merge = 1 *) reg [TX_OFF_AW+249:0] grant_snapshot;
    (* preserve = 1, dont_merge = 1 *) reg [8:0] capture_grant;
    wire snap_a, snap_b, snap_timed, snap_first, snap_more;
    wire [31:0] snap_time, snap_src, snap_dst;
    wire [15:0] snap_vlid, snap_sport, snap_dport, snap_user, snap_ident;
    wire [10:0] snap_len;
    wire [7:0] snap_sn, snap_page, snap_head;
    wire [12:0] snap_ip_offset;
    wire [13:0] snap_message_len;
    wire [TX_OFF_AW-1:0] snap_offset;
    wire [6:0] snap_vl_index;
    assign {snap_a,snap_b,snap_timed,snap_time,snap_src,snap_dst,
        snap_vlid,snap_sport,snap_dport,snap_len,snap_sn,snap_page,snap_user,
        snap_ident,snap_ip_offset,snap_message_len,snap_first,snap_more,
        snap_head,snap_offset,snap_vl_index}=grant_snapshot;
    always @(posedge clk) begin
        grant_snapshot <= {grant_a,grant_b,grant_timed,grant_time,grant_src,grant_dst,
            grant_vlid,grant_sport,grant_dport,grant_len,grant_sn,grant_page,user_id,
            grant_ident,grant_ip_offset,grant_message_len,grant_first,grant_more,
            grant_head,grant_offset,grant_vl_index};
        if (reset) capture_grant <= 0;
        else capture_grant <= {9{grant_valid && grant_ready}};
    end
    always @(posedge clk) begin
        if (reset) begin p_a<=0;p_b<=0;p_timed<=0;p_first<=0;p_more<=0;p_len<=0;p_vl_index<=0;end
        else if (capture_grant[0]) begin
            p_a<=snap_a;p_b<=snap_b;p_timed<=snap_timed;p_first<=snap_first;
            p_more<=snap_more;p_len<=snap_len;p_vl_index<=snap_vl_index;
        end
    end
    always @(posedge clk) if (reset) p_time<=0; else if(capture_grant[1]) p_time<=snap_time;
    always @(posedge clk) if (reset) p_src<=0; else if(capture_grant[2]) p_src<=snap_src;
    always @(posedge clk) if (reset) p_dst<=0; else if(capture_grant[3]) p_dst<=snap_dst;
    always @(posedge clk) begin
        if(reset)begin p_vlid<=0;p_sport<=0;end
        else if(capture_grant[4])begin p_vlid<=snap_vlid;p_sport<=snap_sport;end
    end
    always @(posedge clk) begin
        if(reset)begin p_dport<=0;p_ident<=0;end
        else if(capture_grant[5])begin p_dport<=snap_dport;p_ident<=snap_ident;end
    end
    always @(posedge clk) begin
        if(reset)begin p_sn<=0;p_page<=0;p_head<=0;end
        else if(capture_grant[6])begin p_sn<=snap_sn;p_page<=snap_page;p_head<=snap_head;end
    end
    always @(posedge clk) begin
        if(reset)begin p_ip_offset<=0;p_message_len<=0;end
        else if(capture_grant[7])begin p_ip_offset<=snap_ip_offset;p_message_len<=snap_message_len;end
    end
    always @(posedge clk) begin
        if(reset)begin p_offset<=0;p_user<=0;end
        else if(capture_grant[8])begin p_offset<=snap_offset;p_user<=snap_user;end
    end
    genvar header_group;
    generate
        for (header_group = 0; header_group < 14; header_group = header_group + 1) begin : header_word
            localparam READY_BIT = READY_COPIES > 1 ? header_group + 1 : 0;
            (* preserve = 1, dont_merge = 1 *) reg header_idle, local_due;
            always @(posedge clk) begin
                header_template[header_group*24+:24] <= prepared_header[header_group*24+:24];
                if (reset) begin header_idle<=1;local_due<=0;end
                else begin
                    local_due <= !p_timed || due_reduced;
                    if (pending && prepared && !stream_active && !head_pending && local_due)
                        header_idle <= 0;
                    // Same-cycle ownership mirror; no extra bubble is required.
                    if (s_valid && s_ready[0] && s_last) header_idle <= 1;
                end
            end
            // Header bits are no longer observed after PART_HEADER. Continue
            // shifting on ready edges during payload instead of adding a
            // header-terminal hold enable to every bit. Idle has load priority.
            always @(posedge clk) begin
                if (reset) header[header_group * 24 +: 24] <= 0;
                else if (header_idle)
                    header[header_group * 24 +: 24] <= header_template[header_group * 24 +: 24];
                else if (s_ready[READY_BIT])
                    header[header_group * 24 +: 24] <= shifted_header[header_group * 24 +: 24];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            pending <= 0;
            prepared <= 0;
            stream_active <= 0;
            prep <= 0;
            active_more <= 0; active_head <= 0; active_vl_index <= 0;
            active_header_last <= HEADER_LAST;
            active_min_payload <= MIN_PAYLOAD;
            head_pending <= 0; head_saved <= 0; fetch_delay <= 0;
            fragment_done <= 0; fragment_done_vl <= 0; fragment_done_page <= 0; fragment_done_offset <= 0;
            ip_length <= 0;
            udp_length <= 0;
            checksum <= 0;
            first_fold <= 0; fold_low <= 0; fold_high <= 0;
            sum_low <= 0;
            sum_high <= 0;
            sum_operand <= 0;
            now_input <= 0; now_q <= 0;
            time_difference <= 0;
            time_due <= 0;
            due_nonnegative <= 0; due_upper_max <= 0;
            due_lower_max <= 0; due_near <= 0;
            start_valid <= 0;
            t_start <= 0;
            payload_re <= 0;
            payload_ra <= 0;
            pnext_re <= 0;
            pnext_ra <= 0;
            ret_valid <= 0;
            ret_page <= 0;
            s_valid <= 0;
            s_data_a <= 0;
            s_data_b <= 0;
            s_last <= 0;
            s_en_a <= 0;
            s_en_b <= 0;
            header_index <= 0;
            part <= PART_HEADER;
            active_len <= 0;
            active_sn <= 0;
            payload_index <= 0;
            payload_more <= 0;
            padding_left <= 0;
            fetch_page <= 0;
            fetch_offset <= 0;
            offset_last <= 0;
            next_page <= 0;
            payload_qr <= 0;
            pnext_qr <= 0;
            fetch_left <= 0;
            payload_fifo <= 0;
            fifo_wr <= 0;
            fifo_rd <= 0;
            fifo_count <= 0;
            fifo_pop_eligible <= 0;
            issue_end <= 0;
            issue_page <= 0;
            return_page0 <= 0;
            return_page1 <= 0;
            return_pipe <= 0;
            return_fifo <= 0;
            return_wr <= 0;
            return_rd <= 0;
            return_count <= 0;
            payload_pipe <= 0;
            pnext_pipe <= 0;
            complete_a <= 0;
            complete_b <= 0;
            bad <= 0;
            ev_tx_a <= 0;
            ev_tx_b <= 0;
        end
        else begin
            // The first destination byte is constant whenever no stream is
            // owned. Preload it without the head-return/time-due launch cone.
            // These data pins are ignored while s_valid is low.
            if (!stream_active) begin
                s_data_a <= DMAC_BYTE0;
                s_data_b <= DMAC_BYTE0;
            end

            now_input <= now;
            now_q <= now_input;
            time_difference <= now_q - p_time;
            // Exact partial reductions for d < 0x7fffffff or d >= -8.
            // The wide difference drives only these local registers; each
            // header group consumes the same registered four-bit conclusion.
            due_nonnegative <= !time_difference[31];
            due_upper_max <= &time_difference[30:16];
            due_lower_max <= &time_difference[15:0];
            due_near <= &time_difference[31:3];
            time_due <= !p_timed || due_reduced;
            payload_re <= 0;
            pnext_re <= 0;
            start_valid <= 0;
            fragment_done <= 0;
            ev_tx_a <= 0;
            ev_tx_b <= 0;
            payload_pipe <= { payload_pipe[0], payload_re };
            pnext_pipe <= { pnext_pipe[0], pnext_re };
            // E0 request -> E1 synchronous RAM -> E2 local return -> E3 FIFO.
            // Valid, page-return tags and fetch timing retain the same edges.
            payload_qr <= payload_q;
            pnext_qr <= pnext_q;
            return_pipe <= { return_pipe[0], payload_re && issue_end };
            return_page0 <= issue_page;
            return_page1 <= return_page0;
            if (pnext_pipe[1]) next_page <= pnext_qr;
            if (fifo_push) begin
                payload_fifo[{fifo_wr, 3'b0} +: 8] <= payload_qr;
                fifo_wr <= fifo_wr + 1'b1;
            end
            if (fifo_pop) fifo_rd <= fifo_rd + 1'b1;
            case ({fifo_push, fifo_pop})
                2'b10 : fifo_count <= fifo_count + 1'b1;
                2'b01 : fifo_count <= fifo_count - 1'b1;
                default : ;
            endcase
            // 连续到达的页号先排队，再逐项保持到归还握手完成。
            if (return_push) begin
                return_fifo[{return_wr, 3'b0} +: 8] <= return_page1;
                return_wr <= return_wr + 1'b1;
            end
            if (return_pop) begin
                ret_valid <= 1;
                ret_page <= return_fifo[{return_rd, 3'b0} +: 8];
                return_rd <= return_rd + 1'b1;
            end else if ((!ret_valid || ret_ready) && head_pending) begin
                ret_valid <= 1;
                ret_page <= head_saved;
                head_pending <= 0;
            end else if (ret_valid && ret_ready) ret_valid <= 0;
            case ({return_push, return_pop})
                2'b10 : return_count <= return_count + 1'b1;
                2'b01 : return_count <= return_count - 1'b1;
                default : ;
            endcase
            // 最多同时等待三个读结果，队列剩五项时就暂停发出新读请求。
            if (stream_active && fetch_delay != 0) fetch_delay <= fetch_delay - 1'b1;
            if (stream_active && fetch_delay == 0 && fetch_left != 0 && fifo_count < FIFO_STOP_LEVEL) begin
                payload_re <= 1;
                payload_ra <= { fetch_page[TX_PAGE_AW - 1:0], fetch_offset };
                issue_page <= fetch_page;
                issue_end <= (offset_last || (fetch_left == 1 && !active_more)) && fetch_page != active_head;
                fetch_left <= fetch_left - 1'b1;
                if (offset_last) begin
                    fetch_page <= next_page;
                    fetch_offset <= 0;
                    offset_last <= 0;
                    pnext_re <= 1;
                    pnext_ra <= next_page;
                end else begin
                    fetch_offset <= fetch_offset + 1'b1;
                    offset_last <= fetch_offset == OFFSET_BEFORE_LAST;
                end
            end
            if (grant_valid && grant_ready) begin
                pending <= 1;
                prepared <= 0;
                prep <= 0;
            end
            else if (pending && !prepared && !capture_grant[0]) begin
                prep <= prep + 1'b1;
                case (prep)
                    0 : sum_operand <= p_len;
                    1 : sum_operand <= p_ident;
                    2 : sum_operand <= {2'b00,p_more,p_ip_offset};
                    3 : sum_operand <= p_src[31:16];
                    4 : sum_operand <= p_src[15:0];
                    5 : sum_operand <= p_dst[31:16];
                    6 : sum_operand <= p_dst[15:0];
                    default : ;
                endcase
                case (prep)
                    0 : begin
                        ip_length <= {5'b0,p_len} + (p_first ? 16'd28 : 16'd20);
                        udp_length <= {2'b0,p_message_len} + 16'd8;
                        sum_low <= p_first ? 16'h462d : 16'h4625;
                        sum_high <= 0;
                    end
                    1, 2, 3, 4, 5, 6, 7 : begin
                        sum_low <= sum_step[15:0];
                        sum_high <= sum_high + sum_step[16];
                    end
                    8 : first_fold <= {1'b0,sum_low} + {13'b0,sum_high};
                    9 : begin
                        fold_low <= {1'b0,first_fold[7:0]} + first_fold[16];
                        fold_high <= first_fold[15:8];
                    end
                    10 : checksum <= ~{(fold_high + {7'b0,fold_low[8]}),fold_low[7:0]};
                    // The local header template has now observed checksum.
                    11 : prepared <= 1;
                    default : ;
                endcase
            end
            // 提前四拍判断发送时刻，以补偿计时和输出寄存器的延迟。
            if (pending && prepared && ! stream_active && !head_pending && time_due) begin
                stream_active <= 1;
                s_valid <= 1;
                s_last <= 0;
                s_en_a <= p_a;
                s_en_b <= p_b;
                // 目的 MAC 地址是 03:00:00:00 加 16 位虚拟链路编号。
                // 源 MAC 地址是 02:00:00 加 16 位端系统编号，最后一字节是网络标识，A 网为 0x20。

                header_index <= 0;
                fifo_pop_eligible <= 0;
                part <= PART_HEADER;
                active_len <= p_len;
                active_header_last <= p_first ? 6'd41 : 6'd33;
                active_min_payload <= p_first ? 5'd17 : 5'd25;
                active_more <= p_more; active_head <= p_head; active_vl_index <= p_vl_index;
                fetch_delay <= 3'd4;
                active_sn <= p_sn;
                payload_index <= 0;
                payload_more <= p_len != 0;
                fetch_page <= p_page;
                fetch_offset <= p_offset;
                offset_last <= &p_offset;
                fetch_left <= p_len;
                fifo_wr <= 0;
                fifo_rd <= 0;
                fifo_count <= 0;
                pnext_re <= 1;
                pnext_ra <= p_page;
            end
            if (tx_sof) begin
                // 首个前导字节发送时，记录实际时间并允许接收下一条消息。
                start_valid <= 1;
                // now_input is the preceding native clock value. Reconstruct
                // this edge locally rather than route now through SOF enables.
                t_start <= {now_input[31:24] + {7'b0,(&now_input[23:0])},
                    now_input[23:16] + {7'b0,(&now_input[15:0])},
                    now_input[15:8] + {7'b0,(&now_input[7:0])},
                    now_input[7:0] + 8'd1};
                pending <= 0;
                prepared <= 0;
                complete_a <= s_en_a;
                complete_b <= s_en_b;
                bad <= 0;
            end
            if (tx_underrun) bad <= 1;
            if (tx_eof && ! bad && ! tx_underrun) begin
                ev_tx_a <= complete_a;
                ev_tx_b <= complete_b;
            end
            // 帧头和用户数据发完后，短帧补零，最后发送序号并结束。
            if (s_valid && s_ready[0]) begin
                fifo_pop_eligible <= 0;
                if (s_last) begin
                    s_valid <= 0;
                    s_last <= 0;
                    stream_active <= 0;
                    fragment_done <= 1;
                    fragment_done_vl <= active_vl_index;
                    fragment_done_page <= fetch_page;
                    fragment_done_offset <= fetch_offset;
                    if (!active_more) begin
                        head_pending <= 1;
                        head_saved <= active_head;
                    end
                end
                else if (part == PART_HEADER && header_index < active_header_last) begin
                    header_index <= header_index + 1'b1;
                    fifo_pop_eligible <= header_index == active_header_last - 6'd1;
                    s_data_a <= header[327:320];
                    // B 网把源 MAC 地址里的网络标识换成 0x40，其余字节与 A 网相同。
                    s_data_b <= header_index == NETWORK_ID_INDEX ? NETWORK_B : header[327:320];
                end
                else if (part == PART_HEADER || (part == PART_PAYLOAD && payload_more)) begin
                    part <= PART_PAYLOAD;
                    s_data_a <= payload_fifo[{fifo_rd, 3'b0} +: 8];
                    s_data_b <= payload_fifo[{fifo_rd, 3'b0} +: 8];
                    payload_index <= payload_index_next;
                    payload_more <= payload_index_next < active_len;
                    fifo_pop_eligible <= payload_index_next < active_len;
                end
                else if (part == PART_PAYLOAD) begin
                    if (active_len < active_min_payload) begin
                        part <= PART_PADDING;
                        padding_left <= active_min_payload - active_len[4:0];
                        s_data_a <= 0;
                        s_data_b <= 0;
                    end
                    else begin
                        part <= PART_SN;
                        s_data_a <= active_sn;
                        s_data_b <= active_sn;
                        s_last <= 1;
                    end
                end
                else if (part == PART_PADDING) begin
                    padding_left <= padding_left - 1'b1;
                    if (padding_left == 1) begin
                        part <= PART_SN;
                        s_data_a <= active_sn;
                        s_data_b <= active_sn;
                        s_last <= 1;
                    end
                end
            end
        end
    end

`ifdef AFDX_CE_DIV
    // 所有 RTL 回归都定义此宏；综合不定义，不产生硬件。
    always @(negedge clk) begin
        if (!reset && (fifo_pop_eligible !== (s_valid && !s_last &&
            ((part == PART_HEADER && header_index == active_header_last) ||
            (part == PART_PAYLOAD && payload_more))))) begin
            $display("[FAIL] fifo_pop_eligible invariant part=%0d header=%0d payload=%0d", part, header_index, payload_index);
            // synthesis translate_off
            $fatal(1, "fifo_pop_eligible invariant");
            // synthesis translate_on
        end
        if (!reset && (payload_more !== (payload_index < active_len))) begin
            $display("[FAIL] payload_more invariant index=%0d len=%0d", payload_index, active_len);
            // synthesis translate_off
            $fatal(1, "payload_more invariant");
            // synthesis translate_on
        end
    end
`endif
endmodule
