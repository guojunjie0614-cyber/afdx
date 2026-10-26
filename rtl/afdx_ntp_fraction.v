// 本模块把纳秒与网络时间戳的小数部分互相换算。
// afdx_rtc 提供待换算的数值，并在 done 有效时取走结果。
// 本模块用于赛题的时钟同步。
// NTP（Network Time Protocol，网络时间协议）用 32 位小数表示不足一秒的时间。
module afdx_ntp_fraction (

    // 空闲时 start 为高才启动换算。
    // to_nanoseconds 为高表示小数转纳秒，为低表示纳秒转小数。
    input wire clk, reset, start, to_nanoseconds,

    // value 提供输入值，done 为高的一拍表示 result 有效。
    input wire [31:0] value,
    output reg done,
    output reg [31:0] result);

    // state 的取值。
    localparam STEP_IDLE = 0, STEP_ADD = 1, STEP_SHIFT = 2;

    // 一秒的纳秒数。
    localparam NS_PER_SECOND = 32'd1000000000;

    // STEP_IDLE：等待 start，为高时保存输入并转 STEP_ADD。
    // STEP_ADD：完成本轮加减，下一拍转 STEP_SHIFT。
    // STEP_SHIFT：移位并保存结果；未满 32 轮转 STEP_ADD，完成后转 STEP_IDLE。
    reg [1:0] state;
    reg inverse;
    reg [4:0] bit_count;

    // remainder 保存余数，work 保存待处理位或计算出的商。
    // trial 保存本轮加减结果，供下一拍移位使用。
    reg [30:0] remainder;
    reg [31:0] work, trial;

    // 换算按 RFC 4330 的时间戳格式进行，小数转纳秒时四舍五入。
    always @(posedge clk) begin
        if (reset) begin
            state <= STEP_IDLE;
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

                STEP_IDLE : if (start) begin
                    inverse <= to_nanoseconds;
                    bit_count <= 0;
                    remainder <= to_nanoseconds ? 31'd0 : value[30:0];
                    work <= to_nanoseconds ? value : 0;
                    state <= STEP_ADD;
                end

                STEP_ADD : begin
                    if (inverse) trial <= { 1'b0, remainder } + (work[0] ? NS_PER_SECOND : 32'd0);
                    else trial <= { remainder, 1'b0 } - NS_PER_SECOND;
                    state <= STEP_SHIFT;
                end

                STEP_SHIFT : begin
                    if (inverse) begin
                        remainder <= trial[31:1];
                        work <= { 1'b0, work[31:1] };
                    end
                    else begin
                        remainder <= trial[31] ? { remainder[29:0], 1'b0 } : trial[30:0];
                        work <= { work[30:0], ! trial[31] };
                    end
                    if (bit_count == 31) begin
                        // 小数转纳秒时，根据最低位对结果四舍五入。
                        result <= inverse ? { 1'b0, trial[31:1] } + { 31'b0, trial[0] } : { work[30:0], ! trial[31] };
                        done <= 1;
                        state <= STEP_IDLE;
                    end
                    else begin
                        bit_count <= bit_count + 1'b1;
                        state <= STEP_ADD;
                    end
                end

                default : state <= STEP_IDLE;
            endcase
        end
    end

endmodule
