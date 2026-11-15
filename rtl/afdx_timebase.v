// 本模块记录复位后经过的时钟周期数。
// 发送调度器用完整计数控制间隔，接收引擎用高位计数判断重复帧。
// 为端系统的发送整形与冗余管理提供统一时间基准。
module afdx_timebase (
    // clk 为工作时钟，reset 为同步高有效复位。
    input  wire        clk, reset,

    // now 每拍加一，到 32 位上限后回零。
    // 复位结束后，byte_en 每拍都有效。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *)
    output reg  [31:0] now,
    (* preserve = 1, dont_merge = 1 *)
    output reg         byte_en,

    // now_c 每 4096 拍加一，供重复帧比较和过期检查使用。
    output wire [15:0] now_c
);

    // now_c 直接取 now 的部分高位。
    assign now_c = now[27:12];

    // 进位预测信号 low_carry 与当前低 16 位半字对齐：仅在 now[15:0] 为 16'hffff 时置高，
    // 确保高低 16 位半字仍在原有同一时钟沿同步进位（含完整 32 位回绕）。
    (* preserve = 1, dont_merge = 1 *) reg low_carry;
    always @(posedge clk) begin
        if (reset) begin
            now       <= 0;
            low_carry <= 0;
            byte_en   <= 0;
        end
        else begin
            now[15:0]  <= now[15:0] + 16'd1;
            now[31:16] <= now[31:16] + low_carry;
            low_carry  <= now[15:0] == 16'hfffe;
            byte_en    <= 1'b1;
        end
    end

endmodule
