// 解析MAC帧、校验IPv4/UDP头并暂存UDP载荷。
// 接MAC帧字节/结束状态；输出完好描述和本网上的分类事件。
// 坏帧由本模块撤销暂写位置；帧结束到完好描述的延迟固定。
// 每网解析：按字节累计字段/校验和；固定三拍收尾；好帧等待引擎提交或回退。
// 坏帧由本模块分类和回退，不占用公共查表引擎。
module afdx_rx_parse #(
    parameter RX_RING_AW = 12) (
    input wire clk, reset, enable, rx_valid,
    input wire [15:0] now_c,
    input wire m_valid, m_first,
    input wire [7:0] m_data,
    input wire f_end,
    input wire [1:0] f_err,
    input wire [10:0] f_len,
    input wire [RX_RING_AW:0] read_ptr,
    output reg ring_we,
    output reg [RX_RING_AW - 1:0] ring_wa,
    output reg [7:0] ring_wd,
    output reg desc_valid,
    output reg [RX_RING_AW + 82:0] desc_data,
    input wire desc_take,
    input wire resolve_valid, resolve_commit,
    output reg [7:0] ev);
    localparam [RX_RING_AW:0] CAPACITY = (1 << RX_RING_AW);
    reg [RX_RING_AW:0] committed, trial, frame_begin, desc_finish;
    wire [RX_RING_AW:0] occupied = committed - read_ptr;
    reg prev_line, allowed, overflow, header_bad, n_ok, has_payload;
    reg [10:0] position;
    reg [7:0] high_byte, sn;
    reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, ip_expected, end_data, sn_position, expected_len;
    reg [RX_RING_AW:0] space_limit;
    reg [19:0] ip_sum;
    reg [25:0] udp_sum;
    reg [16:0] ip_fold, ip_final, udp_fold, udp_final;
    reg [2:0] length_phase;
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
            // 引擎的决定在下一帧载荷到来前返回；只有提交改变有效写指针。
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
                            // 第42字节到达的这一拍，用完整容量与当前读指针比较空间。
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
            if (f_end && allowed) begin
                err_saved <= f_err;
                arrival <= now_c;
                end_overflow <= overflow;
                end_alloc <= has_payload;
                end_bad <= header_bad || ! n_ok || ip_final[15:0] != 16'hffff || ip_len != ip_expected || f_len != expected_len;
                end_desc <= { vlid, sn, sport, dport, n[10:0], frame_begin[RX_RING_AW - 1:0], now_c };
                desc_finish <= trial;
                finish_phase <= 1;
            end
            else if (finish_phase != 0) begin
                finish_phase <= finish_phase + 1'b1;
                // 连续字节下，末载荷的UDP折叠在帧尾后下一拍才全部有效。
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
                    // 不完好帧在这里本地回退；无载荷的前导错误不触碰在途好帧。
                    if ((err_saved != 0 || end_bad || end_overflow) && end_alloc) trial <= frame_begin;
                end
            end
        end
    end
endmodule
