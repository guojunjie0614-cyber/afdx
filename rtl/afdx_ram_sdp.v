// 本模块提供一个写口和一个同步读口的存储器。
// 收发缓存和配置表通过读写地址访问这里的数据。
// 本模块为赛题的消息存储和多条虚拟链路提供存储空间。
// 调用方应避免同一拍读写同一地址。
module afdx_ram_sdp #(
    parameter WIDTH = 8,
    parameter DEPTH = 2048) (clk, write_enable, write_address, write_data, read_enable, read_address, read_data);
    // 地址宽度由容量计算，至少保留一位。
    localparam AW = DEPTH <= 2 ? 1 : DEPTH <= 4 ? 2 : DEPTH <= 8 ? 3 : DEPTH <= 16 ? 4 : DEPTH <= 32 ? 5 : DEPTH <= 64 ? 6 : DEPTH <= 128 ? 7 : DEPTH <= 256 ? 8 : DEPTH <= 512 ? 9 : DEPTH <= 1024 ? 10 : DEPTH <= 2048 ? 11 : DEPTH <= 4096 ? 12 : DEPTH <= 8192 ? 13 : DEPTH <= 16384 ? 14 : DEPTH <= 32768 ? 15 : DEPTH <= 65536 ? 16 : DEPTH <= 131072 ? 17 : DEPTH <= 262144 ? 18 : DEPTH <= 524288 ? 19 : DEPTH <= 1048576 ? 20 : DEPTH <= 2097152 ? 21 : DEPTH <= 4194304 ? 22 : DEPTH <= 8388608 ? 23 : DEPTH <= 16777216 ? 24 : DEPTH <= 33554432 ? 25 : DEPTH <= 67108864 ? 26 : DEPTH <= 134217728 ? 27 : DEPTH <= 268435456 ? 28 : DEPTH <= 536870912 ? 29 : DEPTH <= 1073741824 ? 30 : 31;
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
    always @(posedge clk) if (write_enable && read_enable && write_address == read_address) $display ("** Error: [RAMCOLL] %m time=%0t address=%0d",
        $time, write_address);
`endif
endmodule
