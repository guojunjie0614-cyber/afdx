// 初始化完成后监测全部公开输出位（含空闲数据位），确保无未知态输出。
// 在时钟下降沿后采样，避开非阻塞赋值与仿真 delta 周期引起的瞬态毛刺。
`timescale 1ns/1ps
module afdx_x_monitor #(
    parameter WIDTH = 1,
    parameter LABEL = "public_outputs"
) (
    input  wire               clk, reset, armed,
    input  wire [WIDTH - 1:0] outputs,
    output integer            checked_cycles = 0
);
    always @(negedge clk) begin
        #1;
        if (!reset && armed) begin
            checked_cycles = checked_cycles + 1;
            if ((^outputs) === 1'bx)
                $fatal(1, "[XZ_FAIL] %0s outputs=%h time=%0t", LABEL, outputs, $time);
        end
    end
endmodule
