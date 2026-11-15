// MAC 层以太网字节流接收模块：完成前导码与帧起始定界符同步、帧长边界检查及 FCS 校验，
// 剥离前导码和末尾 4 字节 FCS 后，将净荷字节流输出至 afdx_rx_parse。
module afdx_mac_rx (
    // clk 为工作时钟，reset 为同步高有效复位。
    input  wire        clk, reset,

    // rx_valid 为高时，rx_data 为本拍线路接收字节；rx_valid 拉低表示当前帧结束。
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // m_valid 为高时，m_data 为剥离末尾 FCS 后的帧字节；m_first 标记目的 MAC 地址首字节。
    output reg         m_valid,
    output reg  [7:0]  m_data,
    output reg         m_first, f_end,

    // f_end 拉高当拍，f_err 与 f_len 输出本帧检查结果（f_len 包含末尾 4 字节 FCS）：
    //   f_err = 0：校验通过
    //   f_err = 1：FCS 校验错误
    //   f_err = 2：帧长越界错误
    //   f_err = 3：前导码或帧起始定界符错误
    output reg  [1:0]  f_err,
    output reg  [10:0] f_len
);

    // IDLE     ：等待线路空闲后开启接收，按首字节转入 PREAMBLE、FRAME 或 BAD_PRE
    // PREAMBLE ：检测帧起始定界符（0xd5）进入 FRAME，遇非法字节转入 BAD_PRE
    // FRAME    ：接收帧内容，线路空闲时输出检查结果并返回 IDLE
    // BAD_PRE  ：丢弃错误前导码后续字节，等待线路空闲后返回 IDLE
    localparam IDLE = 2'd0, PREAMBLE = 2'd1, FRAME = 2'd2, BAD_PRE = 2'd3;

    // 前导码字节、帧起始定界符，以及 CRC-32 初值与整帧含 FCS 校验后的固定余数。
    localparam PREAMBLE_BYTE = 8'h55, SFD_BYTE = 8'hd5;
    localparam CRC_INIT = 32'hffffffff, CRC_RESIDUE = 32'hdebb20e3;

    // 帧长自目的 MAC 地址首字节计至 FCS 末字节（不含前导码）；计数到达 LENGTH_LIMIT 后饱和锁定为超长。
    localparam FCS_LENGTH = 4, MIN_FRAME_LENGTH = 64, MAX_FRAME_LENGTH = 1518, LENGTH_LIMIT = 1519;

    // f_err 错误码编码。
    localparam [1:0] ERR_NONE = 2'd0, ERR_FCS = 2'd1, ERR_LENGTH = 2'd2, ERR_PREAMBLE = 2'd3;

    // data_q/valid_q 将输入同步寄存一拍；armed 要求复位后先捕获一次线路空闲，避免从半帧中途接入。
    reg [7:0] data_q;
    reg valid_q, armed;
    reg [1:0] state;

    // length 自目的 MAC 地址起计，到达上限后停止递增；
    // crc 将帧数据连同收到的 4 字节 FCS 一并计算，帧尾与固定余数 CRC_RESIDUE 比对。
    reg [10:0] length;
    reg [31:0] crc;

    // 4 字节移位延时链：确保末尾 4 字节仅参与 FCS 计算，不作为帧内容向后输出。
    reg [7:0] delay0, delay1, delay2, delay3;
    wire [31:0] next_crc;

    afdx_crc32_d8 update_crc (
        .crc      (crc),
        .data     (data_q),
        .next_crc (next_crc)
    );

    // 帧结束时才能确认整帧检查结论，下游解析器在此之前先暂存净荷数据。
    always @(posedge clk) begin
        data_q <= rx_data;
        valid_q <= rx_valid;
        if (reset) begin
            state <= IDLE;
            armed <= 0;
            length <= 0;
            crc <= CRC_INIT;
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
                if (!valid_q) armed <= 1;
                else if (armed) begin
                    state <= data_q == SFD_BYTE ? FRAME : data_q == PREAMBLE_BYTE ? PREAMBLE : BAD_PRE;
                    armed <= 0;
                    length <= 0;
                    crc <= CRC_INIT;
                end
            end
            else begin
                // 输入已寄存一拍再逐拍处理，末尾四字节滞留移位链用于 FCS 校验。
                begin
                    if (!valid_q) begin
                        f_end <= 1;
                        state <= IDLE;
                        armed <= 1;
                        f_len <= length;
                        if (state != FRAME) begin
                            f_err <= ERR_PREAMBLE;
                            f_len <= 0;
                        end
                        else if (length < MIN_FRAME_LENGTH || length > MAX_FRAME_LENGTH)
                            f_err <= ERR_LENGTH;
                        else if (crc != CRC_RESIDUE) f_err <= ERR_FCS;
                        else f_err <= ERR_NONE;
                    end
                    else if (state == PREAMBLE) begin
                        if (data_q == SFD_BYTE) state <= FRAME;
                        else if (data_q != PREAMBLE_BYTE) state <= BAD_PRE;
                    end
                    else if (state == FRAME && length < LENGTH_LIMIT) begin
                        length <= length + 1'b1;
                        if (length < MAX_FRAME_LENGTH) begin
                            crc <= next_crc;
                            delay3 <= delay2;
                            delay2 <= delay1;
                            delay1 <= delay0;
                            delay0 <= data_q;
                            if (length >= FCS_LENGTH) begin
                                m_valid <= 1;
                                m_data <= delay3;
                                m_first <= (length == FCS_LENGTH);
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
