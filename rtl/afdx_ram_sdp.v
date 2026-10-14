// 本模块提供一个写口和一个同步读口的存储器。
// 收发缓存和配置表通过读写地址访问这里的数据。
// 本模块为赛题的消息存储和多条虚拟链路提供存储空间。
// 调用方应避免同一拍读写同一地址。
module afdx_ram_sdp #(
    parameter WIDTH = 8,
    parameter DEPTH = 2048) (clk, write_enable, write_address, write_data, read_enable, read_address, read_data);

    // 地址宽度由容量计算，至少保留一位。
    function integer address_width;
        input integer depth;
        integer bit_index;
        begin
            address_width = 1;
            for (bit_index = 1; bit_index < 31; bit_index = bit_index + 1)
                if (depth > (1 << bit_index)) address_width = bit_index + 1;
        end
    endfunction

    localparam AW = address_width(DEPTH);

    // 读写共用一个时钟，地址按存储字编号。
    input wire clk;

    // write_enable 为高时，把 write_data 写入 write_address。
    input wire write_enable;
    input wire [AW - 1:0] write_address;
    input wire [WIDTH - 1:0] write_data;

    // read_enable 为高时，在时钟上升沿读出 read_address。
    // read_enable 为低时，read_data 保持不变。
    input wire read_enable;
    input wire [AW - 1:0] read_address;
    output reg [WIDTH - 1:0] read_data;

    // memory 保存数据，独立的读写过程用于推断片内存储器。
    reg [WIDTH - 1:0] memory[0:DEPTH - 1];

    always @(posedge clk) if (write_enable) memory[write_address] <= write_data;

    always @(posedge clk) if (read_enable) read_data <= memory[read_address];

    // 调用方不能依赖同一拍读写同一地址时的读值。
`ifndef SYNTHESIS

    // 仿真发现同拍同址读写时报告错误。
    always @(posedge clk) if (write_enable && read_enable
        && write_address == read_address) $display ("** Error: [RAMCOLL] %m time=%0t address=%0d",
        $time, write_address);
`endif

endmodule
