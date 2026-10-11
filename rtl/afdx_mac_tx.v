// 把帧内容装成含前导、SFD和FCS的以太网GMII帧。
// 上游提供帧字节和尾标志，byte_en驱动逐拍的发送节拍。
// 按前导、内容、FCS、帧间隔推进；FCS按低字节在前输出。
module afdx_mac_tx (
    // clk/reset 为同步控制；byte_en 决定取数和输出节拍，原生 GMII 顶层逐拍有效。
    input wire clk, reset, byte_en,
    // s_valid/s_ready 握手输入帧内容；s_last 为最后的序号字节，s_en_a/b 选择发送网络。
    input wire s_valid,
    output wire s_ready,
    // s_data_a/b 为两网帧内容，允许源 MAC 网络标识不同。
    input wire [7:0] s_data_a, s_data_b,
    input wire s_last, s_en_a, s_en_b,
    // tx_sof/tx_eof 标记首前导/帧结束；tx_underrun 表示发送中断粮，输出故意错误的 FCS。
    output reg tx_sof, tx_eof, tx_underrun,
    // tx_data_a/b、tx_valid_a/b 为含前导、SFD、FCS 的线路输出。
    output reg [7:0] tx_data_a,
    output reg tx_valid_a,
    output reg [7:0] tx_data_b,
    output reg tx_valid_b);
    localparam GAP = 3'd0, PREAMBLE = 3'd1, DATA = 3'd2, FCS = 3'd3, DRAIN = 3'd4;
    // pre_index/fcs_index 标记前导和 FCS 字节；gap_left 保证 12 拍帧间隔。
    reg [2:0] state, pre_index;
    reg [1:0] fcs_index;
    reg [6:0] gap_left;
    // en_a/b 锁存当前帧目的网络；discard_tail 记住断粮后还需清掉的上游残帧。
    reg en_a, en_b, last_byte, discard_tail;
    // 两网独立累积 CRC；正常帧取反后低字节先发，断粮帧不取反。
    reg [31:0] crc_a, crc_b, fcs_a, fcs_b;
    wire [31:0] next_a, next_b;
    afdx_crc32_d8 update_a (crc_a, s_data_a, next_a);
    afdx_crc32_d8 update_b (crc_b, s_data_b, next_b);
    assign s_ready = byte_en && ((state == PREAMBLE && pre_index == 7) || (state == DATA && ! last_byte) || state == DRAIN);
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
            // DRAIN 丢弃上游尾部，握手到 s_last 后回 GAP；防止残帧被当作新帧。
            if (state == DRAIN) begin
                // 清尾也在字节边界取数，所有非复位状态转换保持byte_en节拍。
                if (byte_en && s_valid && s_last) begin
                    state <= GAP;
                    discard_tail <= 0;
                end
            end
            else if (byte_en) begin
                case (state)
                    // GAP：帧间隔结束且首字节就绪，锁存网络并开始前导。
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
                    // PREAMBLE：发完七个 0x55 和 SFD 后取首内容字节；断粮转错误 FCS。
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
                    // DATA：每个有效节拍取内容；前拍已取末字节或发生断粮时转 FCS。
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
                    // FCS：依次输出四字节；随后回 GAP，若断粮则转 DRAIN 清尾。
                    FCS : begin
                        if (fcs_index == 3) begin
                            tx_data_a <= 0;
                            tx_data_b <= 0;
                            tx_valid_a <= 0;
                            tx_valid_b <= 0;
                            tx_eof <= 1;
                            state <= discard_tail ? DRAIN : GAP;
                            // 此拍已经开始第一个空闲周期，余下11拍后满足12拍帧间隔。
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
