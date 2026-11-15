// 封装专用反查 RAM：读口持续工作，同拍同址的读值允许未定义。
// afdx_app_rx 在对应 map_pending 拍通过 map_bypass 使用写入值，绝不消费冲突读值。
// 与核心通用 RAM 分开，保留核心 afdx_ram_sdp 的禁止碰撞检查语义。
module afdx_app_map #(parameter WIDTH = 16, parameter AW = 12) (
    input  wire             clk, write_enable,
    input  wire [AW-1:0]    write_address,
    input  wire [WIDTH-1:0] write_data,
    input  wire             read_enable,
    input  wire [AW-1:0]    read_address,
    output reg  [WIDTH-1:0] read_data
);
    (* ramstyle = "no_rw_check" *) reg [WIDTH-1:0] memory[0:(1<<AW)-1];

    // 保留写数据输入门控隔离，满足综合网表中寄存器到存储块输入端的保持时间裕量。
    always @(posedge clk) if (write_enable)
    memory[write_address] <= write_enable ? write_data : {WIDTH{1'b0}};

    always @(posedge clk) if (read_enable) read_data <= memory[read_address];

endmodule
