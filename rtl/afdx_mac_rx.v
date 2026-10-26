// 本模块从以太网字节流中找出帧，并检查帧长和校验值。
// 输入来自线路，去掉校验值后的内容交给 afdx_rx_parse。
// 本模块用于赛题的以太网接收和错误检测。
module afdx_mac_rx (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // rx_valid 为高时，rx_data 是线路本拍收到的字节。
    // rx_valid 拉低表示帧已结束。
    input wire [7:0] rx_data,
    input wire rx_valid,

    // m_valid 为高时，m_data 是去掉校验值后的帧内容。
    // m_first 标记目的以太网地址的首字节。
    output reg m_valid,
    output reg [7:0] m_data,
    output reg m_first, f_end,

    // f_end 为高时，f_err 和 f_len 给出本帧检查结果。
    // f_err=0 表示通过。
    // f_err=1 表示校验值错误。
    // f_err=2 表示长度错误。
    // f_err=3 表示前导码错误。
    // f_len 包含末尾四字节校验值。
    output reg [1:0] f_err,
    output reg [10:0] f_len);

    // IDLE：先等线路空闲，再按首字节转 PREAMBLE、FRAME 或 BAD_PRE。
    // PREAMBLE：遇帧起始定界符转 FRAME，遇非法字节转 BAD_PRE。
    // FRAME：接收内容，线路空闲时报告结果并转 IDLE。
    // BAD_PRE：丢弃错误前导码后的内容，线路空闲时转 IDLE。
    localparam IDLE = 2'd0, PREAMBLE = 2'd1, FRAME = 2'd2, BAD_PRE = 2'd3;

    // 前导码字节、帧起始定界符，以及校验值的初值和整帧校验后的固定余数。
    localparam PREAMBLE_BYTE = 8'h55, SFD_BYTE = 8'hd5;
    localparam CRC_INIT = 32'hffffffff, CRC_RESIDUE = 32'hdebb20e3;

    // 帧长从目的以太网地址数到校验值末字节，不含前导码。
    // 计数到 LENGTH_LIMIT 就不再增加，表示帧已超长。
    localparam FCS_LENGTH = 4, MIN_FRAME_LENGTH = 64, MAX_FRAME_LENGTH = 1518, LENGTH_LIMIT = 1519;

    // f_err 的取值。
    localparam [1:0] ERR_NONE = 2'd0, ERR_FCS = 2'd1, ERR_LENGTH = 2'd2, ERR_PREAMBLE = 2'd3;

    // data_q/valid_q 将数据与有效标记一起延迟一拍。
    // armed 要求复位后先看到线路空闲，避免从半帧开始接收。
    reg [7:0] data_q;
    reg valid_q, armed;
    reg [1:0] state;

    // length 从目的以太网地址开始计数，到上限后不再增加。
    // crc 连同收到的校验字节一起计算，再与固定余数比较。
    reg [10:0] length;
    reg [31:0] crc;

    // 末尾四个字节只参与校验，不作为帧内容输出。
    reg [7:0] delay0, delay1, delay2, delay3;
    wire [31:0] next_crc;
    afdx_crc32_d8 update_crc (
        .crc(crc),
        .data(data_q),
        .next_crc(next_crc)
    );

    // 帧结束时才确定检查结果，解析器在此前暂存数据。
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
                if ( ! valid_q) armed <= 1;
                else if (armed) begin
                    state <= data_q == SFD_BYTE ? FRAME : data_q == PREAMBLE_BYTE ? PREAMBLE : BAD_PRE;
                    armed <= 0;
                    length <= 0;
                    crc <= CRC_INIT;
                end
            end
            else begin
                // 输入先寄存再逐拍处理，最后四个字节用于帧校验。
                begin
                    if ( ! valid_q) begin
                        f_end <= 1;
                        state <= IDLE;
                        armed <= 1;
                        f_len <= length;
                        if (state != FRAME) begin
                            f_err <= ERR_PREAMBLE;
                            f_len <= 0;
                        end
                        else if (length < MIN_FRAME_LENGTH || length > MAX_FRAME_LENGTH) f_err <= ERR_LENGTH;
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
