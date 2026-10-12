// 本模块给帧内容添加前导码和校验值，再发到两路以太网。
// afdx_tx_builder 提供帧内容，本模块逐字节输出到线路。
// 本模块用于赛题的以太网发送，并保证两帧之间的空闲时间。
// FCS（Frame Check Sequence，帧校验序列）用于让接收方检查帧内容。
module afdx_mac_tx (
    // byte_en 为高时推进一个字节，当前顶层每拍都为高。
    input wire clk, reset, byte_en,
    // s_valid 和 s_ready 同为高时接收一个帧内容字节。
    // s_last 标记最后的序号字节，s_en_a/b 选择发送网络。
    input wire s_valid,
    output wire s_ready,
    // s_data_a/b 分别提供两网帧内容，以便使用不同的源网络标识。
    input wire [7:0] s_data_a, s_data_b,
    input wire s_last, s_en_a, s_en_b,
    // tx_sof 标记首个前导字节，tx_eof 标记帧结束。
    // 发送途中缺少字节时，tx_underrun 变高并发送错误校验值。
    output reg tx_sof, tx_eof, tx_underrun,
    // tx_valid_a/b 为高时，tx_data_a/b 是对应网络本拍发送的字节。
    output reg [7:0] tx_data_a,
    output reg tx_valid_a,
    output reg [7:0] tx_data_b,
    output reg tx_valid_b);
    localparam GAP = 3'd0, PREAMBLE = 3'd1, DATA = 3'd2, FCS = 3'd3, DRAIN = 3'd4;
    // pre_index/fcs_index 记录前导码和校验值发到哪个字节。
    // gap_left 保证两帧之间至少空闲 12 拍。
    reg [2:0] state, pre_index;
    reg [1:0] fcs_index;
    reg [6:0] gap_left;
    // en_a/b 保存本帧使用的网络。
    // discard_tail 表示发送中途缺字节后，还要丢弃上游剩余内容。
    reg en_a, en_b, last_byte, discard_tail;
    // 两网分别计算帧校验值，正常时取反并先发低字节。
    // 发送途中缺字节时故意不取反，让接收方发现错误。
    reg [31:0] crc_a, crc_b, fcs_a, fcs_b;
    wire [31:0] next_a, next_b;
    afdx_crc32_d8 update_a (
        // 这些端口用于数据和握手。
        .crc(crc_a),
        .data(s_data_a),
        .next_crc(next_a)
    );
    afdx_crc32_d8 update_b (
        // 这些端口用于数据和握手。
        .crc(crc_b),
        .data(s_data_b),
        .next_crc(next_b)
    );
    assign s_ready = byte_en && ((state == PREAMBLE && pre_index == 7) || (state == DATA && ! last_byte)
        || state == DRAIN);
    always @(posedge clk) begin
        if (reset) begin
            state <= GAP;
            gap_left <= 12;
            pre_index <= 0;
            fcs_index <= 0;
            en_a <= 0;
            en_b <= 0;
            last_byte <= 0;
            discard_tail <= 0;
            crc_a <= 32'hffffffff;
            crc_b <= 32'hffffffff;
            fcs_a <= 0;
            fcs_b <= 0;
            tx_sof <= 0;
            tx_eof <= 0;
            tx_underrun <= 0;
            tx_data_a <= 0;
            tx_data_b <= 0;
            tx_valid_a <= 0;
            tx_valid_b <= 0;
        end
        else begin
            tx_sof <= 0;
            tx_eof <= 0;
            tx_underrun <= 0;
            if (gap_left != 0) gap_left <= gap_left - 1'b1;
            // DRAIN：丢弃上游剩余字节，末字节握手后转 GAP。
            if (state == DRAIN) begin
                // 丢弃剩余字节也只在 byte_en 为高时进行。
                if (byte_en && s_valid && s_last) begin
                    state <= GAP;
                    discard_tail <= 0;
                end
            end
            else if (byte_en) begin
                case (state)
                    // GAP：空闲间隔已满且首字节就绪时，保存网络选择并转 PREAMBLE。
                    GAP : if (gap_left == 0 && s_valid) begin
                        en_a <= s_en_a;
                        en_b <= s_en_b;
                        tx_valid_a <= s_en_a;
                        tx_valid_b <= s_en_b;
                        tx_data_a <= s_en_a ? 8'h55 : 0;
                        tx_data_b <= s_en_b ? 8'h55 : 0;
                        crc_a <= 32'hffffffff;
                        crc_b <= 32'hffffffff;
                        pre_index <= 0;
                        last_byte <= 0;
                        discard_tail <= 0;
                        state <= PREAMBLE;
                        tx_sof <= 1;
                    end
                    // PREAMBLE：发完前导码后转 DATA；上游缺字节时转 FCS。
                    PREAMBLE : begin
                        if (pre_index < 7) begin
                            pre_index <= pre_index + 1'b1;
                            tx_data_a <= en_a ? (pre_index == 6 ? 8'hd5 : 8'h55) : 0;
                            tx_data_b <= en_b ? (pre_index == 6 ? 8'hd5 : 8'h55) : 0;
                        end
                        else if (s_valid) begin
                            tx_data_a <= en_a ? s_data_a : 0;
                            tx_data_b <= en_b ? s_data_b : 0;
                            crc_a <= next_a;
                            crc_b <= next_b;
                            last_byte <= s_last;
                            state <= DATA;
                        end
                        else begin
                            tx_underrun <= 1;
                            discard_tail <= 1;
                            state <= FCS;
                            fcs_index <= 0;
                            tx_data_a <= en_a ? crc_a[7:0] : 0;
                            tx_data_b <= en_b ? crc_b[7:0] : 0;
                            fcs_a <= { 8'b0, crc_a[31:8] };
                            fcs_b <= { 8'b0, crc_b[31:8] };
                        end
                    end
                    // DATA：逐字节发送内容，末字节或上游缺字节时转 FCS。
                    DATA : begin
                        if (last_byte || ! s_valid) begin
                            state <= FCS;
                            fcs_index <= 0;
                            if (last_byte) begin
                                tx_data_a <= en_a ? ~ crc_a[7:0] : 0;
                                tx_data_b <= en_b ? ~ crc_b[7:0] : 0;
                                fcs_a <= { 8'b0, ~ crc_a[31:8] };
                                fcs_b <= { 8'b0, ~ crc_b[31:8] };
                            end
                            else begin
                                tx_underrun <= 1;
                                discard_tail <= 1;
                                tx_data_a <= en_a ? crc_a[7:0] : 0;
                                tx_data_b <= en_b ? crc_b[7:0] : 0;
                                fcs_a <= { 8'b0, crc_a[31:8] };
                                fcs_b <= { 8'b0, crc_b[31:8] };
                            end
                        end
                        else begin
                            tx_data_a <= en_a ? s_data_a : 0;
                            tx_data_b <= en_b ? s_data_b : 0;
                            crc_a <= next_a;
                            crc_b <= next_b;
                            last_byte <= s_last;
                        end
                    end
                    // FCS：发完四字节校验值，正常转 GAP，缺字节时转 DRAIN。
                    FCS : begin
                        if (fcs_index == 3) begin
                            tx_data_a <= 0;
                            tx_data_b <= 0;
                            tx_valid_a <= 0;
                            tx_valid_b <= 0;
                            tx_eof <= 1;
                            state <= discard_tail ? DRAIN : GAP;
                            // 本拍已是第一个空闲周期，再等 11 拍即可满足帧间隔。
                            gap_left <= 11;
                        end
                        else begin
                            fcs_index <= fcs_index + 1'b1;
                            tx_data_a <= en_a ? fcs_a[7:0] : 0;
                            tx_data_b <= en_b ? fcs_b[7:0] : 0;
                            fcs_a <= { 8'b0, fcs_a[31:8] };
                            fcs_b <= { 8'b0, fcs_b[31:8] };
                        end
                    end
                    default : state <= GAP;
                endcase
            end
        end
    end
endmodule
