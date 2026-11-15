// 本模块把纳秒与网络时间戳的小数部分互相换算。
// 默认接口保留原 64 拍换算；LOCAL_CAPTURE=1 时启用本地输入捕获，done 延后一拍。
module afdx_ntp_fraction #(parameter LOCAL_CAPTURE = 0) (
    // 仅在空闲态受理 start 请求，忙期间的其余触发脉冲一律忽略。
    input  wire        clk, reset, start, to_nanoseconds,
    input  wire [31:0] value,
    output reg         done,
    output reg  [31:0] result
);

    localparam STEP_IDLE = 0, STEP_ADD = 1, STEP_SHIFT = 2, STEP_PREP = 3;
    localparam NS_PER_SECOND = 32'd1000000000;
    reg [1:0] state;
    reg inverse;
    reg [4:0] bit_count;
    reg [30:0] remainder;
    reg [31:0] work, trial;

    generate
        if (LOCAL_CAPTURE) begin : local_capture
            // 原状态机在 E0 启动后最早可在 E65 受理下一次 start；本实现末次移位
            // 同样在 E65 拍完成，可在同一时钟沿捕获下一条命令（旧结果与新模式分别采用独立非阻塞赋值更新）。
            wire last_shift = state == STEP_SHIFT && bit_count == 31;
            wire accept = start && (state == STEP_IDLE || last_shift);
            wire [31:0] shifted_work = inverse ? {1'b0, work[31:1]} : {work[30:0], !trial[31]};
            wire [30:0] shifted_remainder = inverse ? trial[31:1] :
                (trial[31] ? {remainder[29:0], 1'b0} : trial[30:0]);
            genvar lane;
            for (lane = 0; lane < 8; lane = lane + 1) begin : byte_control
                localparam BYTE_INDEX = lane % 4;
                localparam WIDTH = (lane == 7) ? 7 : 8;
                (* preserve=1,dont_merge=1 *) reg start_local, shift_local, mode_local;
                (* preserve=1,dont_merge=1 *) reg [WIDTH-1:0] value_local;
                always @(posedge clk) begin
                    if (reset) begin
                        start_local <= 0;
                        shift_local <= 0;
                        mode_local  <= 0;
                        value_local <= 0;
                    end
                    else begin
                        start_local <= accept;
                        shift_local <= state == STEP_ADD;
                        value_local <= value[BYTE_INDEX*8+:WIDTH];
                        if (accept) mode_local <= to_nanoseconds;
                    end
                end
                if (lane < 4) begin : work_byte
                    always @(posedge clk) begin
                        if (reset)
                            work[BYTE_INDEX*8+:8] <= 0;
                        else if (start_local)
                            work[BYTE_INDEX*8+:8] <= mode_local ? value_local : 8'b0;
                        else if (shift_local)
                            work[BYTE_INDEX*8+:8] <= shifted_work[BYTE_INDEX*8+:8];
                    end
                end
                else begin : remainder_byte
                    always @(posedge clk) begin
                        if (reset)
                            remainder[BYTE_INDEX*8+:WIDTH] <= 0;
                        else if (start_local)
                            remainder[BYTE_INDEX*8+:WIDTH] <= mode_local ? {WIDTH{1'b0}} : value_local;
                        else if (shift_local)
                            remainder[BYTE_INDEX*8+:WIDTH] <= shifted_remainder[BYTE_INDEX*8+:WIDTH];
                    end
                end
            end
            always @(posedge clk) begin
                if (reset) begin
                    state     <= STEP_IDLE;
                    inverse   <= 0;
                    bit_count <= 0;
                    trial     <= 0;
                    done      <= 0;
                    result    <= 0;
                end
                else begin
                    done <= 0;
                    case (state)
                        STEP_IDLE : ;
                        STEP_PREP : state <= STEP_ADD;
                        STEP_ADD : begin
                            if (inverse) trial <= {1'b0, remainder} + (work[0] ? NS_PER_SECOND : 32'd0);
                            else trial <= {remainder, 1'b0} - NS_PER_SECOND;
                            state <= STEP_SHIFT;
                        end
                        STEP_SHIFT : begin
                            if (bit_count == 31) begin
                                result <= inverse
                                    ? {1'b0, trial[31:1]} + {31'b0, trial[0]}
                                    : {work[30:0], !trial[31]};
                                done  <= 1;
                                state <= STEP_IDLE;
                            end
                            else begin
                                bit_count <= bit_count + 1'b1;
                                state     <= STEP_ADD;
                            end
                        end
                        default : state <= STEP_IDLE;
                    endcase
                    if (accept) begin
                        inverse   <= to_nanoseconds;
                        bit_count <= 0;
                        state     <= STEP_PREP;
                    end
                end
            end
        end
        else begin : legacy_capture
            // 为独立调用场景保留原有的算法结构与周期节拍时序。
            always @(posedge clk) begin
                if (reset) begin
                    state     <= STEP_IDLE;
                    inverse   <= 0;
                    bit_count <= 0;
                    remainder <= 0;
                    work      <= 0;
                    trial     <= 0;
                    done      <= 0;
                    result    <= 0;
                end
                else begin
                    done <= 0;
                    case (state)
                        STEP_IDLE : if (start) begin
                            inverse   <= to_nanoseconds;
                            bit_count <= 0;
                            remainder <= to_nanoseconds ? 31'd0 : value[30:0];
                            work      <= to_nanoseconds ? value : 0;
                            state     <= STEP_ADD;
                        end
                        STEP_ADD : begin
                            if (inverse) trial <= {1'b0, remainder} + (work[0] ? NS_PER_SECOND : 32'd0);
                            else trial <= {remainder, 1'b0} - NS_PER_SECOND;
                            state <= STEP_SHIFT;
                        end
                        STEP_SHIFT : begin
                            if (inverse) begin
                                remainder <= trial[31:1];
                                work      <= {1'b0, work[31:1]};
                            end
                            else begin
                                remainder <= trial[31] ? {remainder[29:0], 1'b0} : trial[30:0];
                                work      <= {work[30:0], !trial[31]};
                            end
                            if (bit_count == 31) begin
                                result <= inverse
                                    ? {1'b0, trial[31:1]} + {31'b0, trial[0]}
                                    : {work[30:0], !trial[31]};
                                done  <= 1;
                                state <= STEP_IDLE;
                            end
                            else begin
                                bit_count <= bit_count + 1'b1;
                                state     <= STEP_ADD;
                            end
                        end
                        default : state <= STEP_IDLE;
                    endcase
                end
            end
        end
    endgenerate
endmodule
