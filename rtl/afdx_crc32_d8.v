// 本模块根据一个新字节更新以太网校验值。
// 收发模块提供上一校验值和当前字节，本模块返回新的校验值。
// 本模块用于赛题要求的帧错误检测。
// CRC（Cyclic Redundancy Check，循环冗余校验）用于发现数据错误。
module afdx_crc32_d8 (
    // crc 是处理上一字节后的余数，data 是本次要处理的字节。
    input wire [31:0] crc,
    input wire [7:0] data,
    // next_crc 是处理完这八个数据位后的余数。
    output reg [31:0] next_crc);
    // 按 IEEE 802.3 使用反射多项式 0xedb88320。
    // 收发模块负责设置初值和最终取反。
    integer bit_index;
    always @ * begin
        next_crc = crc ^ { 24'b0, data };
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) if (next_crc[0]) next_crc = (next_crc >> 1) ^ 32'hedb88320;
        else next_crc = next_crc >> 1;
    end
endmodule
