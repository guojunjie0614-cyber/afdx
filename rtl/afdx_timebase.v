// 产生125 MHz周期计数、慢字节节拍和粗粒度时间。
// now逐拍递增，byte_en每八拍一次，now_c为now的位片。
// 复位后统一相位；now_c不增加额外组合运算或寄存级。
module afdx_timebase (
    input wire clk, reset,
    output reg [31:0] now,
    output reg byte_en,
    output wire [15:0] now_c);
    // now_c直接连接计数寄存器的位片，不增加组合级。
    assign now_c = now[27:12];
    always @(posedge clk) begin
        if (reset) begin
            now <= 0;
            byte_en <= 0;
        end
        else begin
            now <= now + 1'b1;
            byte_en <= (now[2:0] == 3'd6);
        end
    end
endmodule
