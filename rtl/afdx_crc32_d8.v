// 按一个字节更新以太网反射CRC32。
// 输入当前CRC状态和8位数据，输出处理该字节后的CRC状态。
// 纯组合逻辑；初值、取反及线上字节顺序由MAC模块负责。
// Ethernet反射CRC；不在此模块取反，发送端决定正常或错误FCS。
module afdx_crc32_d8 (
    // crc 为前一字节后的余数，data 为当前线上字节。
    input wire [31:0] crc,
    input wire [7:0] data,
    // next_crc 为八次反射移位后的余数；不含初始装载和最终取反。
    output reg [31:0] next_crc);
    // IEEE 802.3 FCS 的反射多项式为 0xedb88320；此处没有时序状态。
    integer bit_index;
    always @ * begin
        next_crc = crc ^ { 24'b0, data };
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) if (next_crc[0]) next_crc = (next_crc >> 1) ^ 32'hedb88320;
        else next_crc = next_crc >> 1;
    end
endmodule
