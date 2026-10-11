// 参数化单时钟简单双口RAM，一个写口和一个同步读口。
// write_*和read_*分别控制两端口，WIDTH/DEPTH确定容量。
// 读禁用时保持输出；同拍同址读写结果不作定义，调用方须避开。
// 单时钟简单双口RAM：读输出在采样read_enable后的时钟边沿更新。
module afdx_ram_sdp #(
    parameter WIDTH = 8,
    parameter DEPTH = 2048) (clk, write_enable, write_address, write_data, read_enable, read_address, read_data);
    // 使用显式常量表达式，避免厂商前端对常量函数的展开差异。
    localparam AW = DEPTH <= 2 ? 1 : DEPTH <= 4 ? 2 : DEPTH <= 8 ? 3 : DEPTH <= 16 ? 4 : DEPTH <= 32 ? 5 : DEPTH <= 64 ? 6 : DEPTH <= 128 ? 7 : DEPTH <= 256 ? 8 : DEPTH <= 512 ? 9 : DEPTH <= 1024 ? 10 : DEPTH <= 2048 ? 11 : DEPTH <= 4096 ? 12 : DEPTH <= 8192 ? 13 : DEPTH <= 16384 ? 14 : DEPTH <= 32768 ? 15 : DEPTH <= 65536 ? 16 : DEPTH <= 131072 ? 17 : DEPTH <= 262144 ? 18 : DEPTH <= 524288 ? 19 : DEPTH <= 1048576 ? 20 : DEPTH <= 2097152 ? 21 : DEPTH <= 4194304 ? 22 : DEPTH <= 8388608 ? 23 : DEPTH <= 16777216 ? 24 : DEPTH <= 33554432 ? 25 : DEPTH <= 67108864 ? 26 : DEPTH <= 134217728 ? 27 : DEPTH <= 268435456 ? 28 : DEPTH <= 536870912 ? 29 : DEPTH <= 1073741824 ? 30 : 31;
    // 单时钟 RAM；读写地址均按存储字索引。
    input wire clk;
    // write_enable 有效时写入 write_address 所指字，数据来自 write_data。
    input wire write_enable;
    input wire [AW - 1:0] write_address;
    input wire [WIDTH - 1:0] write_data;
    // read_enable 有效时同步读取 read_address；否则 read_data 保持原值。
    input wire read_enable;
    input wire [AW - 1:0] read_address;
    output reg [WIDTH - 1:0] read_data;
    // memory 是唯一存储体；读写端口各一个时序块，供 eLinx 推断块 RAM。
    reg [WIDTH - 1:0] memory[0:DEPTH - 1];
    always @(posedge clk) if (write_enable) memory[write_address] <= write_data;
    always @(posedge clk) if (read_enable) read_data <= memory[read_address];
    // 同拍读写同址没有定义；调用方必须避免依赖该结果。
`ifndef SYNTHESIS
    // 仿真监视：同拍同址读写没有定义，直接报告供运行器判失败。
    always @(posedge clk) if (write_enable && read_enable && write_address == read_address) $display ("** Error: [RAMCOLL] %m time=%0t address=%0d",
        $time, write_address);
`endif
endmodule
