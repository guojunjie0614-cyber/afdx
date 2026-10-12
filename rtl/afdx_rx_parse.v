// 本模块检查收到的以太网头、IPv4 头和 UDP 头，并暂存用户数据。
// afdx_mac_rx 提供帧内容和校验结果，完整帧的信息交给接收引擎。
// 本模块对应赛题的接收协议检查，检查失败时释放本帧暂占的空间。
module afdx_rx_parse #(
    parameter RX_RING_AW = 12) (
    // enable 为高时允许接收新帧，rx_valid 标记线路有数据。
    input wire clk, reset, enable, rx_valid,
    // f_end 有效时记录 now_c，作为比较两网到达时间的依据。
    input wire [15:0] now_c,
    // m_valid 为高时，m_data 是已去掉帧校验值的内容。
    // m_first 标记首字节，f_end 有效时 f_err/f_len 给出检查结果。
    input wire m_valid, m_first,
    input wire [7:0] m_data,
    input wire f_end,
    input wire [1:0] f_err,
    input wire [10:0] f_len,
    // read_ptr 指向已读完的位置，ring_* 暂存本帧用户数据。
    input wire [RX_RING_AW:0] read_ptr,
    output reg ring_we,
    output reg [RX_RING_AW - 1:0] ring_wa,
    output reg [7:0] ring_wd,
    // desc_valid 为高时提交完整帧信息，desc_take 表示引擎已取走。
    // resolve_valid 为高时，commit 决定保留还是释放本帧数据。
    output reg desc_valid,
    output reg [RX_RING_AW + 82:0] desc_data,
    input wire desc_take,
    input wire resolve_valid, resolve_commit,
    // ev[0] 表示帧校验通过。
    // ev[1] 表示帧校验值错误。
    // ev[2] 表示长度或前导码错误。
    // ev[3] 表示协议头错误。
    // ev[7] 表示用户数据缓存已满。
    output reg [7:0] ev);
    localparam [RX_RING_AW:0] CAPACITY = (1 << RX_RING_AW);
    // committed 指向已接纳数据的末端，trial 指向本帧暂存位置。
    // frame_begin 记录本帧起点，失败时写位置退回这里。
    // desc_finish 保存等待引擎确认的帧末位置。
    reg [RX_RING_AW:0] committed, trial, frame_begin, desc_finish;
    wire [RX_RING_AW:0] occupied = committed - read_ptr;
    reg prev_line, allowed, overflow, header_bad, n_ok, has_payload;
    // position 从目的以太网地址的首字节开始计数。
    // 第 4–5 字节保存虚拟链路编号。
    // 第 14–33 字节是 IPv4 头。
    // 第 34–41 字节是 UDP 头。
    reg [10:0] position;
    reg [7:0] high_byte, sn;
    reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, ip_expected, end_data, sn_position, expected_len;
    reg [RX_RING_AW:0] space_limit;
    // IPv4 头校验和与 UDP 校验和分别累加。
    // 两次处理进位后，结果应为 0xffff。
    // UDP 校验和字段为零表示发送方没有计算，此时跳过这项检查。
    reg [19:0] ip_sum;
    reg [25:0] udp_sum;
    reg [16:0] ip_fold, ip_final, udp_fold, udp_final;
    // length_phase=0：等到报文长度字段，收到后转 1。
    // length_phase=1：计算用户数据和网络报文长度，然后转 2。
    // length_phase=2：计算序号位置与所需缓存空间，然后转 0。
    reg [2:0] length_phase;
    // finish_phase=0：等待帧结束，收到后转 1。
    // finish_phase=1：等待末字节校验和稳定，然后转 2。
    // finish_phase=2：报告错误或提交完整帧信息，然后转 0。
    reg [1:0] finish_phase, err_saved;
    reg end_bad, end_overflow, end_alloc;
    reg [15:0] arrival;
    reg [RX_RING_AW + 82:0] end_desc;
    always @(posedge clk) begin
        if (reset) begin
            committed <= 0;
            trial <= 0;
            frame_begin <= 0;
            desc_finish <= 0;
            prev_line <= rx_valid;
            allowed <= 0;
            ring_we <= 0;
            ring_wa <= 0;
            ring_wd <= 0;
            desc_valid <= 0;
            desc_data <= 0;
            ev <= 0;
            position <= 0;
            high_byte <= 0;
            sn <= 0;
            vlid <= 0;
            sport <= 0;
            dport <= 0;
            ip_len <= 0;
            udp_len <= 0;
            udp_check <= 0;
            n <= 0;
            n_ok <= 0;
            ip_expected <= 0;
            end_data <= 0;
            sn_position <= 0;
            expected_len <= 0;
            space_limit <= 0;
            overflow <= 0;
            header_bad <= 0;
            has_payload <= 0;
            ip_sum <= 0;
            udp_sum <= 0;
            ip_fold <= 0;
            ip_final <= 0;
            udp_fold <= 0;
            udp_final <= 0;
            length_phase <= 0;
            finish_phase <= 0;
            err_saved <= 0;
            end_bad <= 0;
            end_overflow <= 0;
            end_alloc <= 0;
            arrival <= 0;
            end_desc <= 0;
        end
        else begin
            ring_we <= 0;
            ev <= 0;
            prev_line <= rx_valid;
            if (rx_valid && ! prev_line) begin
                allowed <= enable;
                has_payload <= 0;
            end
            if (! enable) allowed <= 0;
            if (desc_take) desc_valid <= 0;
            // 只有引擎决定接纳本帧后，才更新有效数据的末端指针。
            if (resolve_valid) begin
                if (resolve_commit) committed <= desc_finish;
                else trial <= committed;
            end
            ip_fold <= { 1'b0, ip_sum[15:0] } + ip_sum[19:16];
            ip_final <= { 1'b0, ip_fold[15:0] } + ip_fold[16];
            udp_fold <= { 1'b0, udp_sum[15:0] } + udp_sum[25:16];
            udp_final <= { 1'b0, udp_fold[15:0] } + udp_fold[16];
            case (length_phase)
                1 : begin
                    n <= udp_len - 16'd8;
                    n_ok <= udp_len >= 9 && udp_len <= 1479;
                    ip_expected <= udp_len + 16'd20;
                    udp_sum <= udp_sum + udp_len;
                    length_phase <= 2;
                end
                2 : begin
                    end_data <= n + 16'd42;
                    sn_position <= n < 17 ? 16'd59 : n + 16'd42;
                    expected_len <= n < 17 ? 16'd64 : n + 16'd47;
                    space_limit <= CAPACITY - n;
                    length_phase <= 0;
                end
                default :;
            endcase
            // 本模块只接受不带选项的 20 字节 IPv4 头和未分片的 UDP 报文。
            // 一字节序号位于帧的最后（补零之后），不计入 UDP 长度。
            if (m_valid && allowed) begin
                if (m_first) begin
                    position <= 1;
                    high_byte <= m_data;
                    header_bad <= m_data != 8'h03;
                    overflow <= 0;
                    ip_sum <= 0;
                    udp_sum <= 26'h0000011;
                    n_ok <= 0;
                    length_phase <= 0;
                    vlid <= 0;
                    sport <= 0;
                    dport <= 0;
                    ip_len <= 0;
                    udp_len <= 0;
                    udp_check <= 0;
                    sn <= 0;
                end
                else begin
                    position <= position + 1'b1;
                    if (! position[0]) high_byte <= m_data;
                    case (position)
                        1, 2, 3, 13 : if (m_data != 0) header_bad <= 1;
                        12 : if (m_data != 8'h08) header_bad <= 1;
                        14 : if (m_data != 8'h45) header_bad <= 1;
                        20 : if ((m_data & 8'h3f) != 0) header_bad <= 1;
                        21 : if (m_data != 0) header_bad <= 1;
                        23 : if (m_data != 8'h11) header_bad <= 1;
                        5 : vlid <= { high_byte, m_data };
                        17 : ip_len <= { high_byte, m_data };
                        35 : sport <= { high_byte, m_data };
                        37 : dport <= { high_byte, m_data };
                        39 : begin
                            udp_len <= { high_byte, m_data };
                            length_phase <= 1;
                        end
                        41 : udp_check <= { high_byte, m_data };
                        default :;
                    endcase
                    if (position >= 14 && position <= 33 && position[0]) ip_sum <= ip_sum + { high_byte, m_data };
                    if (position >= 26 && position <= 41 && position[0]) udp_sum <= udp_sum + { high_byte, m_data };
                    if (n_ok && position >= 42 && position < end_data) begin
                        if (position[0]) udp_sum <= udp_sum + { high_byte, m_data };
                        else if (position == end_data - 1'b1) udp_sum <= udp_sum + { m_data, 8'b0 };
                        if (position == 42) begin
                            // 第 42 字节到达时，检查缓存剩余空间能否容纳本帧用户数据。
                            frame_begin <= committed;
                            has_payload <= 1;
                            overflow <= n > CAPACITY || occupied > space_limit;
                            if (n <= CAPACITY && occupied <= space_limit) begin
                                ring_we <= 1;
                                ring_wa <= committed[RX_RING_AW - 1:0];
                                ring_wd <= m_data;
                                trial <= committed + 1'b1;
                            end
                        end
                        else if (! overflow) begin
                            ring_we <= 1;
                            ring_wa <= trial[RX_RING_AW - 1:0];
                            ring_wd <= m_data;
                            trial <= trial + 1'b1;
                        end
                    end
                    if (n_ok && position == sn_position) sn <= m_data;
                end
            end
            // 帧信息包含虚拟链路编号和序号。
            // 源端口和目的端口随帧信息一起交给接收引擎。
            // 帧信息还包含用户数据长度、缓存起点和到达时间。
            if (f_end && allowed) begin
                err_saved <= f_err;
                arrival <= now_c;
                end_overflow <= overflow;
                end_alloc <= has_payload;
                end_bad <= header_bad || ! n_ok || ip_final[15:0] != 16'hffff || ip_len != ip_expected
                    || f_len != expected_len;
                end_desc <= { vlid, sn, sport, dport, n[10:0], frame_begin[RX_RING_AW - 1:0], now_c };
                desc_finish <= trial;
                finish_phase <= 1;
            end
            else if (finish_phase != 0) begin
                finish_phase <= finish_phase + 1'b1;
                // 连续收字节时，末字节校验和要到帧尾后的下一拍才稳定。
                if (finish_phase == 1 && udp_check != 0 && udp_final[15:0] != 16'hffff) end_bad <= 1;
                if (finish_phase == 2) begin
                    finish_phase <= 0;
                    if (err_saved == 1) ev <= 8'h02;
                    else if (err_saved == 2 || err_saved == 3) ev <= 8'h04;
                    else if (end_bad) ev <= 8'h08;
                    else if (end_overflow) ev <= 8'h80;
                    else begin
                        ev <= 8'h01;
                        desc_valid <= 1;
                        desc_data <= end_desc;
                    end
                    // 坏帧在这里释放暂占空间。
                    // 没有用户数据的前导码错误，不影响尚待判定的完整帧。
                    if ((err_saved != 0 || end_bad || end_overflow) && end_alloc) trial <= frame_begin;
                end
            end
        end
    end
endmodule
