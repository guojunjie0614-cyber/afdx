// 产生125 MHz周期计数、慢字节节拍和粗粒度时间。
// now逐拍递增，byte_en逐拍有效，now_c为now的位片。
// 复位后统一相位；now_c不增加额外组合运算或寄存级。
module afdx_timebase (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // now 为模 2^32 的周期计数；byte_en 复位后逐拍有效。
    output reg [31:0] now,
    output reg byte_en,
    // now_c 每 4096 拍进一格，供接收冗余窗口和老化使用。
    output wire [15:0] now_c);
    // now_c直接连接计数寄存器的位片，不增加组合级。
    assign now_c = now[27:12];
    // 时基更新：复位归零，随后按 125 MHz 每拍递增；无独立状态机。
    always @(posedge clk) begin
        if (reset) begin
            now <= 0;
            byte_en <= 0;
        end
        else begin
            now <= now + 1'b1;
            byte_en <= 1'b1;
        end
    end
endmodule
