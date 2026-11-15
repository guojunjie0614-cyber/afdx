// 8 位并行以太网 CRC-32 组合计算模块。
// 根据上一拍余数与当前输入字节单拍更新下一个 32 位 CRC 余数，供 MAC 收发模块完成整帧 FCS 校验。
module afdx_crc32_d8 (
    // crc 为处理上一字节后的余数，data 为当前待处理字节。
    input  wire [31:0] crc,
    input  wire [7:0]  data,

    // next_crc 为处理完当前 8 位数据后的新余数。
    output reg  [31:0] next_crc
);

    // 采用 IEEE 802.3 标准反射多项式 0xedb88320；初值装载与最终按位取反由上层收发模块完成。
    integer bit_index;

    always @* begin
        next_crc = crc ^ {24'b0, data};
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
            if (next_crc[0]) next_crc = (next_crc >> 1) ^ 32'hedb88320;
            else next_crc = next_crc >> 1;
    end

endmodule
