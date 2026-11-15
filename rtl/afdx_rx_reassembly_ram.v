// 接收重组专用同步简单双端口 RAM：上下文浅表强制映射为 M4K 存储块而非触发器阵列，
// 调用方在调度时序上显式保证同拍读写地址互斥。
module afdx_rx_reassembly_ram #(
    parameter WIDTH        = 8,
    AW                     = 3,
    REGISTER_WRITE_ADDRESS = 0
) (
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    wa,
    input  wire [WIDTH-1:0] wd,
    input  wire             re,
    input  wire [AW-1:0]    ra,
    output reg  [WIDTH-1:0] q
);

    wire [AW-1:0] write_address;

    generate
        if (REGISTER_WRITE_ADDRESS) begin : local_write
            // 调用方提前一拍给出目标行地址并在表内本地寄存，物理写入时钟沿保持不变。
            (* preserve = 1, dont_merge = 1 *) reg [AW-1:0] address;
            always @(posedge clk) address <= wa;
            assign write_address = address;
        end
        else begin : direct_write
            assign write_address = wa;
        end
    endgenerate
    (* ramstyle = "M4K,no_rw_check" *) reg [WIDTH-1:0] memory[0:(1<<AW)-1];

    // 保持与通用双端口 RAM 封装一致的写数据输入 LUT 隔离结构。
    always @(posedge clk)
        if (we) memory[write_address] <= we ? wd : {WIDTH{1'b0}};

    always @(posedge clk)
        if (re) q <= memory[ra];
`ifndef SYNTHESIS
    always @(posedge clk)
        if (we && re && write_address == ra) begin
            $display("** Error: [RAMCOLL] %m time=%0t address=%0d", $time, write_address);
            $finish_and_return(1);
        end
`endif

endmodule
