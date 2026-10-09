// 按发送描述读取载荷并构造以太网/IPv4/UDP帧。
// 调度授权给出VL、SN和载荷页；输出字节流交给MAC发送。
// 头部校验和及RAM读取分拍处理，授权与实际发送分开。
// 下一帧顺序准备校验和；活动帧由移位帧头、载荷预读和补零状态发送。
module afdx_tx_builder #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 8) (
    input wire clk, reset,
    input wire [31:0] now,
    input wire [15:0] user_id,
    output wire grant_ready,
    input wire grant_valid, grant_a, grant_b, grant_timed,
    input wire [31:0] grant_time, grant_src, grant_dst,
    input wire [15:0] grant_vlid, grant_sport, grant_dport,
    input wire [10:0] grant_len,
    input wire [7:0] grant_sn, grant_page,
    output reg start_valid,
    output reg [31:0] t_start,
    output reg payload_re,
    output reg [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_ra,
    input wire [7:0] payload_q,
    output reg pnext_re,
    output reg [TX_PAGE_AW - 1:0] pnext_ra,
    input wire [7:0] pnext_q,
    output reg ret_valid,
    output reg [7:0] ret_page,
    input wire ret_ready,
    output reg s_valid,
    input wire s_ready,
    output reg [7:0] s_data_a, s_data_b,
    output reg s_last, s_en_a, s_en_b,
    input wire tx_sof, tx_eof, tx_underrun,
    output reg ev_tx_a, ev_tx_b);
    reg pending, prepared, stream_active, p_a, p_b, p_timed;
    reg [3:0] prep;
    reg [31:0] p_time, p_src, p_dst, now_q, time_difference;
    reg [15:0] p_vlid, p_sport, p_dport, p_user, p_ident, ident, ip_length, udp_length, checksum;
    reg [10:0] p_len, active_len, payload_index;
    reg [7:0] p_sn, p_page, active_sn;
    reg [19:0] sum;
    reg [335:0] header;
    reg [1:0] part;
    reg [5:0] header_index;
    reg [4:0] padding_left;
    reg [7:0] fetch_page, next_page, read_byte;
    reg [TX_OFF_AW - 1:0] fetch_offset;
    reg [1:0] payload_pipe, pnext_pipe;
    reg complete_a, complete_b, bad;
    assign grant_ready = ! pending;
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
            header <= 0;
            header_index <= 0;
            part <= 0;
            active_len <= 0;
            active_sn <= 0;
            payload_index <= 0;
            padding_left <= 0;
            fetch_page <= 0;
            fetch_offset <= 0;
            next_page <= 0;
            read_byte <= 0;
            payload_pipe <= 0;
            pnext_pipe <= 0;
            complete_a <= 0;
            complete_b <= 0;
            bad <= 0;
            ev_tx_a <= 0;
            ev_tx_b <= 0;
        end
        else begin
            now_q <= now;
            time_difference <= now_q - p_time;
            payload_re <= 0;
            pnext_re <= 0;
            start_valid <= 0;
            ev_tx_a <= 0;
            ev_tx_b <= 0;
            payload_pipe <= { payload_pipe[0], payload_re };
            pnext_pipe <= { pnext_pipe[0], pnext_re };
            if (payload_pipe[1]) read_byte <= payload_q;
            if (pnext_pipe[1]) next_page <= pnext_q;
            if (ret_valid && ret_ready) ret_valid <= 0;
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
                        ip_length <= p_len + 16'd28;
                        udp_length <= p_len + 16'd8;
                        sum <= 20'h04611;
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
                    default :;
                endcase
            end
            // now 经寄存器和减法两级；提前四个计数单位判断，让 s_valid 在 T-1 可见。
            // 非整字节 T 仍由 MAC 的 byte_en 向上取整，不能提早一个字节。
            if (pending && prepared && ! stream_active && (! p_timed || ! time_difference[31] || time_difference >= 32'hfffffffc)) begin
                stream_active <= 1;
                s_valid <= 1;
                s_last <= 0;
                s_en_a <= p_a;
                s_en_b <= p_b;
                header <= { 32'h03000000, p_vlid, 24'h020000, p_user, 8'h20, 16'h0800, 16'h4500, ip_length, p_ident,
                    16'h0000, 16'h0111, checksum, p_src, p_dst, p_sport, p_dport, udp_length, 16'h0000 };
                s_data_a <= 8'h03;
                s_data_b <= 8'h03;
                header_index <= 0;
                part <= 0;
                active_len <= p_len;
                active_sn <= p_sn;
                payload_index <= 0;
                fetch_page <= p_page;
                fetch_offset <= 0;
                payload_re <= 1;
                payload_ra <= { p_page[TX_PAGE_AW - 1:0], { TX_OFF_AW { 1'b0 } } };
                pnext_re <= 1;
                pnext_ra <= p_page;
            end
            if (tx_sof) begin
                // 此拍读到的 now 与 tx_sof 同属第一个前导字节；下一帧槽在此释放。
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
            if (s_valid && s_ready) begin
                if (s_last) begin
                    s_valid <= 0;
                    s_last <= 0;
                    stream_active <= 0;
                end
                else if (part == 0 && header_index < 41) begin
                    header <= header << 8;
                    header_index <= header_index + 1'b1;
                    s_data_a <= header[327:320];
                    s_data_b <= header_index == 10 ? 8'h40 : header[327:320];
                end
                else if (part == 0 || (part == 1 && payload_index < active_len)) begin
                    part <= 1;
                    s_data_a <= read_byte;
                    s_data_b <= read_byte;
                    payload_index <= payload_index + 1'b1;
                    if (payload_index + 1'b1 == active_len) begin
                        // 最后一字节已复制到输出寄存器，整条消息的末页可以归还。
                        ret_valid <= 1;
                        ret_page <= fetch_page;
                    end
                    else if (& fetch_offset) begin
                        // 最后字节和下一页指针都已捕获，才归还本页并转入下一页。
                        ret_valid <= 1;
                        ret_page <= fetch_page;
                        fetch_page <= next_page;
                        fetch_offset <= 0;
                        payload_re <= 1;
                        payload_ra <= { next_page[TX_PAGE_AW - 1:0], { TX_OFF_AW { 1'b0 } } };
                        pnext_re <= 1;
                        pnext_ra <= next_page;
                    end
                    else begin
                        fetch_offset <= fetch_offset + 1'b1;
                        payload_re <= 1;
                        payload_ra <= { fetch_page[TX_PAGE_AW - 1:0], fetch_offset + { { (TX_OFF_AW - 1) { 1'b0 } },
                            1'b1 } };
                    end
                end
                else if (part == 1) begin
                    if (active_len < 17) begin
                        part <= 2;
                        padding_left <= 17 - active_len;
                        s_data_a <= 0;
                        s_data_b <= 0;
                    end
                    else begin
                        part <= 3;
                        s_data_a <= active_sn;
                        s_data_b <= active_sn;
                        s_last <= 1;
                    end
                end
                else if (part == 2) begin
                    padding_left <= padding_left - 1'b1;
                    if (padding_left == 1) begin
                        part <= 3;
                        s_data_a <= active_sn;
                        s_data_b <= active_sn;
                        s_last <= 1;
                    end
                end
            end
        end
    end
endmodule
