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

    // prep 用十拍算出 IPv4 头校验和，每拍只做一次加法。
    // prep=0：计算 IPv4 和 UDP 的长度字段，下一拍转 1。
    // prep=1：加上 IPv4 总长度字段，下一拍转 2。
    // prep=2：加上 IPv4 标识字段，下一拍转 3。
    // prep=3：加上源 IP 地址的高 16 位，下一拍转 4。
    // prep=4：加上源 IP 地址的低 16 位，下一拍转 5。
    // prep=5：加上目的 IP 地址的高 16 位，下一拍转 6。
    // prep=6：加上目的 IP 地址的低 16 位，下一拍转 7。
    // prep=7：把进位加回低 16 位，下一拍转 8。
    // prep=8：再处理一次进位，下一拍转 9。
    // prep=9：取反得到校验和，置 prepared 后等待发送。
    reg [3:0] prep;

    // part 的取值：一帧依次发送协议头、用户数据、补零和序号。
    localparam PART_HEADER = 0, PART_PAYLOAD = 1, PART_PADDING = 2, PART_SN = 3;

    // 协议头共 42 字节，下标 0–41；发到下标 10 时，下一个字节是源地址里的网络标识。
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

    // 时间判定再寄存一拍，因此提前五拍比较；准备过程已保证 p_time 稳定。
    localparam START_LEAD_REGISTERED = 32'hfffffffb;
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg time_due;

    // 预读队列里已有这么多字节时，暂停发出新的读请求。
    localparam FIFO_STOP_LEVEL = 5;
    reg [31:0] p_time, p_src, p_dst, now_q, time_difference;
    reg [15:0] p_vlid, p_sport, p_dport, p_user, p_ident, ident, ip_length, udp_length, checksum;
    reg [10:0] p_len, active_len, payload_index;
    reg [7:0] p_sn, p_page, active_sn;
    reg [19:0] sum;

    // header 保存 42 字节协议头：以太网头 14 字节、IPv4 头 20 字节、UDP 头 8 字节。
    // 发送时按顺序移出；两网的协议头只有源地址里的网络标识不同。
    reg [335:0] header;
    wire [335:0] prepared_header = { DMAC_PREFIX, p_vlid, SMAC_PREFIX, p_user, NETWORK_A, ETHERTYPE_IPV4,
                    IP_VERSION_TOS, ip_length, p_ident,
                    IP_NO_FRAGMENT, IP_TTL_PROTOCOL, checksum, p_src, p_dst, p_sport, p_dport, udp_length,
                    UDP_NO_CHECKSUM };
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
    wire fifo_pop = s_valid && s_ready[0] && ! s_last &&
        ((part == PART_HEADER && header_index == HEADER_LAST)
        || (part == PART_PAYLOAD && payload_index < active_len));
    wire return_push = payload_pipe[1] && return_pipe[1];
    wire return_pop = ( ! ret_valid || ret_ready) && return_count != 0;
    reg [TX_OFF_AW - 1:0] fetch_offset;
    reg complete_a, complete_b, bad;

    assign grant_ready = ! pending;

    genvar header_group;
    generate
        for (header_group = 0; header_group < 14; header_group = header_group + 1) begin : header_word
            localparam READY_BIT = READY_COPIES > 1 ? header_group + 1 : 0;
            // 顶层提供 15 份接纳窗口，bit 0 供控制，其余各驱动 24 位。
            always @(posedge clk) begin
                if (reset) header[header_group * 24 +: 24] <= 0;
                else if (s_valid && s_ready[READY_BIT] && !s_last
                    && part == PART_HEADER && header_index < HEADER_LAST)
                    header[header_group * 24 +: 24] <= shifted_header[header_group * 24 +: 24];
                else if (!stream_active)
                    header[header_group * 24 +: 24] <= prepared_header[header_group * 24 +: 24];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            pending <= 0;
            prepared <= 0;
            stream_active <= 0;
            prep <= 0;
            p_a <= 0;
            p_b <= 0;
            p_timed <= 0;
            p_time <= 0;
            p_src <= 0;
            p_dst <= 0;
            p_vlid <= 0;
            p_sport <= 0;
            p_dport <= 0;
            p_user <= 0;
            p_ident <= 0;
            ident <= 0;
            p_len <= 0;
            p_sn <= 0;
            p_page <= 0;
            ip_length <= 0;
            udp_length <= 0;
            checksum <= 0;
            sum <= 0;
            now_q <= 0;
            time_difference <= 0;
            time_due <= 0;
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
            padding_left <= 0;
            fetch_page <= 0;
            fetch_offset <= 0;
            next_page <= 0;
            payload_qr <= 0;
            pnext_qr <= 0;
            fetch_left <= 0;
            payload_fifo <= 0;
            fifo_wr <= 0;
            fifo_rd <= 0;
            fifo_count <= 0;
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
            // 空闲时预装帧头；启动拍使用的字段与原来相同。

            now_q <= now;
            time_difference <= now_q - p_time;
            // 等价于上一版下一拍的有符号“差值 >= -4”，包含 32 位回绕边界。
            time_due <= !p_timed || time_difference < 32'h7fffffff
                || time_difference >= START_LEAD_REGISTERED;
            payload_re <= 0;
            pnext_re <= 0;
            start_valid <= 0;
            ev_tx_a <= 0;
            ev_tx_b <= 0;
            payload_pipe <= { payload_pipe[0], payload_re };
            pnext_pipe <= { pnext_pipe[0], pnext_re };
            // 存储器读结果先寄存，再与有效标记一起写入字节队列。
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
            end else if (ret_valid && ret_ready) ret_valid <= 0;
            case ({return_push, return_pop})
                2'b10 : return_count <= return_count + 1'b1;
                2'b01 : return_count <= return_count - 1'b1;
                default : ;
            endcase
            // 最多同时等待三个读结果，队列剩五项时就暂停发出新读请求。
            if (stream_active && fetch_left != 0 && fifo_count < FIFO_STOP_LEVEL) begin
                payload_re <= 1;
                payload_ra <= { fetch_page[TX_PAGE_AW - 1:0], fetch_offset };
                issue_page <= fetch_page;
                issue_end <= fetch_left == 1 || ( & fetch_offset);
                fetch_left <= fetch_left - 1'b1;
                if ( & fetch_offset) begin
                    fetch_page <= next_page;
                    fetch_offset <= 0;
                    pnext_re <= 1;
                    pnext_ra <= next_page;
                end else fetch_offset <= fetch_offset + 1'b1;
            end
            if (grant_valid && grant_ready) begin
                pending <= 1;
                prepared <= 0;
                prep <= 0;
                p_a <= grant_a;
                p_b <= grant_b;
                p_timed <= grant_timed;
                p_time <= grant_time;
                p_src <= grant_src;
                p_dst <= grant_dst;
                p_vlid <= grant_vlid;
                p_sport <= grant_sport;
                p_dport <= grant_dport;
                p_len <= grant_len;
                p_sn <= grant_sn;
                p_page <= grant_page;
                p_user <= user_id;
                p_ident <= ident;
                ident <= ident + 1'b1;
            end
            else if (pending && ! prepared) begin
                prep <= prep + 1'b1;
                case (prep)
                    0 : begin
                        ip_length <= p_len + IP_UDP_OVERHEAD;
                        udp_length <= p_len + UDP_HEADER_LENGTH;
                        // 校验和从两个固定字段之和开始累加：
                        // 0x4500（版本 4、头长 20 字节）加 0x0111（生存时间 1、协议号 17 即 UDP）。
                        sum <= IP_SUM_SEED;
                    end
                    1 : sum <= sum + ip_length;
                    2 : sum <= sum + p_ident;
                    3 : sum <= sum + p_src[31:16];
                    4 : sum <= sum + p_src[15:0];
                    5 : sum <= sum + p_dst[31:16];
                    6 : sum <= sum + p_dst[15:0];
                    7 : sum <= { 4'b0, sum[15:0] } + sum[19:16];
                    8 : sum <= { 4'b0, sum[15:0] } + sum[19:16];
                    9 : begin
                        checksum <= ~ sum[15:0];
                        prepared <= 1;
                    end
                    default : ;
                endcase
            end
            // 提前四拍判断发送时刻，以补偿计时和输出寄存器的延迟。
            if (pending && prepared && ! stream_active && time_due) begin
                stream_active <= 1;
                s_valid <= 1;
                s_last <= 0;
                s_en_a <= p_a;
                s_en_b <= p_b;
                // 目的 MAC 地址是 03:00:00:00 加 16 位虚拟链路编号。
                // 源 MAC 地址是 02:00:00 加 16 位端系统编号，最后一字节是网络标识，A 网为 0x20。

                s_data_a <= DMAC_BYTE0;
                s_data_b <= DMAC_BYTE0;
                header_index <= 0;
                part <= PART_HEADER;
                active_len <= p_len;
                active_sn <= p_sn;
                payload_index <= 0;
                fetch_page <= p_page;
                fetch_offset <= 0;
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
                t_start <= now;
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
                if (s_last) begin
                    s_valid <= 0;
                    s_last <= 0;
                    stream_active <= 0;
                end
                else if (part == PART_HEADER && header_index < HEADER_LAST) begin
                    header_index <= header_index + 1'b1;
                    s_data_a <= header[327:320];
                    // B 网把源 MAC 地址里的网络标识换成 0x40，其余字节与 A 网相同。
                    s_data_b <= header_index == NETWORK_ID_INDEX ? NETWORK_B : header[327:320];
                end
                else if (part == PART_HEADER || (part == PART_PAYLOAD && payload_index < active_len)) begin
                    part <= PART_PAYLOAD;
                    s_data_a <= payload_fifo[{fifo_rd, 3'b0} +: 8];
                    s_data_b <= payload_fifo[{fifo_rd, 3'b0} +: 8];
                    payload_index <= payload_index + 1'b1;
                end
                else if (part == PART_PAYLOAD) begin
                    if (active_len < MIN_PAYLOAD) begin
                        part <= PART_PADDING;
                        padding_left <= MIN_PAYLOAD - active_len;
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

endmodule
