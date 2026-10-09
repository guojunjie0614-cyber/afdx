// 识别前导/SFD、检查帧长与FCS，输出去掉FCS的帧字节。
// 输入逐拍GMII字节，输出帧开始、内容、结束和检查结果。
// 保留末尾四字节用于FCS判定；错误帧仍由结束状态通知上层。
module afdx_mac_rx (
    input wire clk, reset,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg m_valid,
    output reg [7:0] m_data,
    output reg m_first, f_end,
    output reg [1:0] f_err,
    output reg [10:0] f_len);
    localparam IDLE = 2'd0, PREAMBLE = 2'd1, FRAME = 2'd2, BAD_PRE = 2'd3;
    reg [7:0] data_q;
    reg valid_q, armed;
    reg [1:0] state;
    reg [10:0] length;
    reg [31:0] crc;
    // 四字节延迟寄存器，不是逐VL存储；剥离末尾FCS。
    reg [7:0] delay0, delay1, delay2, delay3;
    wire [31:0] next_crc;
    afdx_crc32_d8 update_crc (crc, data_q, next_crc);
    always @(posedge clk) begin
        data_q <= rx_data;
        valid_q <= rx_valid;
        if (reset) begin
            state <= IDLE;
            armed <= 0;
            length <= 0;
            crc <= 32'hffffffff;
            delay0 <= 0;
            delay1 <= 0;
            delay2 <= 0;
            delay3 <= 0;
            m_valid <= 0;
            m_data <= 0;
            m_first <= 0;
            f_end <= 0;
            f_err <= 0;
            f_len <= 0;
        end
        else begin
            m_valid <= 0;
            m_first <= 0;
            f_end <= 0;
            if (state == IDLE) begin
                if (! valid_q) armed <= 1;
                else if (armed) begin
                    state <= data_q == 8'hd5 ? FRAME : data_q == 8'h55 ? PREAMBLE : BAD_PRE;
                    armed <= 0;
                    length <= 0;
                    crc <= 32'hffffffff;
                end
            end
            else begin
                // 输入先寄存，随后逐拍处理；末尾四字节只用于FCS。
                begin
                    if (! valid_q) begin
                        f_end <= 1;
                        state <= IDLE;
                        armed <= 1;
                        f_len <= length;
                        if (state != FRAME) begin
                            f_err <= 3;
                            f_len <= 0;
                        end
                        else if (length < 64 || length > 1518) f_err <= 2;
                        else if (crc != 32'hdebb20e3) f_err <= 1;
                        else f_err <= 0;
                    end
                    else if (state == PREAMBLE) begin
                        if (data_q == 8'hd5) state <= FRAME;
                        else if (data_q != 8'h55) state <= BAD_PRE;
                    end
                    else if (state == FRAME && length < 1519) begin
                        length <= length + 1'b1;
                        if (length < 1518) begin
                            crc <= next_crc;
                            delay3 <= delay2;
                            delay2 <= delay1;
                            delay1 <= delay0;
                            delay0 <= data_q;
                            if (length >= 4) begin
                                m_valid <= 1;
                                m_data <= delay3;
                                m_first <= (length == 4);
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
