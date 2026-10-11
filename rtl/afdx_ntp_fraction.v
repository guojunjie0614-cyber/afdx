// 在纳秒与NTP的32位二进制小数之间转换。
// start启动一次转换，inverse选择方向，done指示result有效。
// 分多轮移位和加减完成，不使用单拍乘除法器。
// 纳秒/二进制小数互换：32轮，每轮两拍；每拍只有一级32位加减，无乘除法器。
module afdx_ntp_fraction (
    // clk/reset 控制同步运算；start 仅在空闲采样，to_nanoseconds=1 表示 NTP 小数转纳秒。
    input wire clk, reset, start, to_nanoseconds,
    // value 为输入数值；done 单拍有效时 result 为换算结果。
    input wire [31:0] value,
    output reg done,
    output reg [31:0] result);
    // state=0 等待 start；1 计算试商/乘积部分和；2 移位提交，32 轮结束回 0。
    reg [1:0] state;
    reg inverse;
    reg [4:0] bit_count;
    // remainder 保存部分余数，work 保存待处理位或商，trial 隔开加减和移位路径。
    reg [30:0] remainder;
    reg [31:0] work, trial;
    // RFC 4330 时间戳小数换算；逆向的半位余数用于最终四舍五入。
    always @(posedge clk) begin
        if (reset) begin
            state <= 0;
            inverse <= 0;
            bit_count <= 0;
            remainder <= 0;
            work <= 0;
            trial <= 0;
            done <= 0;
            result <= 0;
        end
        else begin
            done <= 0;
            case (state)
                0 : if (start) begin
                    inverse <= to_nanoseconds;
                    bit_count <= 0;
                    remainder <= to_nanoseconds ? 0 : value[30:0];
                    work <= to_nanoseconds ? value : 0;
                    state <= 1;
                end
                1 : begin
                    if (inverse) trial <= { 1'b0, remainder } + (work[0] ? 32'd1000000000 : 32'd0);
                    else trial <= { remainder, 1'b0 } - 32'd1000000000;
                    state <= 2;
                end
                2 : begin
                    if (inverse) begin
                        remainder <= trial[31:1];
                        work <= { 1'b0, work[31:1] };
                    end
                    else begin
                        remainder <= trial[31] ? { remainder[29:0], 1'b0 } : trial[30:0];
                        work <= { work[30:0], ! trial[31] };
                    end
                    if (bit_count == 31) begin
                        // 小数转纳秒四舍五入；自发的整纳秒时间戳往返无偏差。
                        result <= inverse ? { 1'b0, trial[31:1] } + { 31'b0, trial[0] } : { work[30:0], ! trial[31] };
                        done <= 1;
                        state <= 0;
                    end
                    else begin
                        bit_count <= bit_count + 1'b1;
                        state <= 1;
                    end
                end
                default : state <= 0;
            endcase
        end
    end
endmodule
