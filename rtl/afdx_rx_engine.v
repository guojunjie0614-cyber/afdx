// 串行执行接收映射、配置、完整性检查和双网冗余判定。
// 接收两网完好帧描述，驱动状态RAM和交付描述队列。
// 完整性状态按网独立维护；空闲逐项老化，配置写与表操作互斥。
// 公共引擎：清状态表、查映射/配置、完整性、冗余判定、写回；空闲时逐项老化。
// 只驱动 rx_dq 写口及项数；读口、读指针和两级选择均归 rx_deliver。
module afdx_rx_engine #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5) (
    input wire clk, reset, enable,
    input wire [15:0] now_c,
    output reg initialized,
    input wire desc_a_valid, desc_b_valid,
    input wire [RX_RING_AW + 82:0] desc_a, desc_b,
    output reg take_a, take_b, resolve_a, resolve_b, commit_a, commit_b,
    output reg map_re,
    output reg [15:0] map_ra,
    input wire [12:0] map_q,
    output reg cfg_re,
    output reg [11:0] cfg_ra,
    input wire [31:0] cfg_q,
    output reg state_re, state_we,
    output reg [11:0] state_ra, state_wa,
    output reg [43:0] state_wd,
    input wire [43:0] state_q,
    input wire dq_pop,
    output reg dq_we,
    output reg [RX_DQ_AW - 1:0] dq_wa,
    output reg [RX_RING_AW + 55:0] dq_wd,
    output reg [RX_DQ_AW:0] dq_count,
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,
    output wire cfg_ok);
    localparam INIT = 0, IDLE = 1, FRAME = 2, AGE = 3, DQ_DEPTH = (1 << RX_DQ_AW), DQ_WIDTH = RX_RING_AW + 56;
    reg [1:0] op;
    assign cfg_ok = enable && (op == IDLE || op == AGE) && ! desc_a_valid && ! desc_b_valid;
    reg [3:0] phase;
    reg [11:0] init_ptr, age_ptr, op_idx;
    reg init_flush, op_net, state_changed, deliver_allowed;
    reg [RX_RING_AW + 82:0] current_desc;
    reg [12:0] saved_map;
    reg [31:0] saved_cfg;
    reg [43:0] saved_state;
    reg [15:0] now_q, now_previous, age_time, elapsed;
    reg [7:0] next_sn, second_sn;
    reg [8:0] raw_distance, forward_distance;
    reg [2:0] result;
    wire [15:0] arrival = current_desc[15:0];
    wire [7:0] sn = current_desc[RX_RING_AW + 66:RX_RING_AW + 59];
    wire [10:0] length = current_desc[RX_RING_AW + 26:RX_RING_AW + 16];
    wire [7:0] psn = op_net ? saved_state[32:25] : saved_state[41:34];
    wire psn_valid = op_net ? saved_state[33] : saved_state[42];
    reg [RX_DQ_AW - 1:0] wr_ptr;
    wire dq_put = op == FRAME && phase == 9 && deliver_allowed && dq_count < DQ_DEPTH;
    wire [DQ_WIDTH - 1:0] dq_input = { op_net, current_desc[RX_RING_AW + 15:16], length, op_idx,
        current_desc[RX_RING_AW + 58:RX_RING_AW + 43], current_desc[RX_RING_AW + 42:RX_RING_AW + 27] };
    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 0;
            dq_count <= 0;
            dq_we <= 0;
            dq_wa <= 0;
            dq_wd <= 0;
        end
        else begin
            dq_we <= dq_put;
            if (dq_put) begin
                dq_wa <= wr_ptr;
                dq_wd <= dq_input;
                wr_ptr <= wr_ptr + 1'b1;
            end
            // 项数在外壳寄存器组实际写入这拍增加，读端下一拍才看见新项。
            case ({ dq_we, dq_pop })
                2'b10 : dq_count <= dq_count + 1'b1;
                2'b01 : dq_count <= dq_count - 1'b1;
                default :;
            endcase
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            op <= INIT;
            phase <= 0;
            initialized <= 0;
            init_ptr <= 0;
            init_flush <= 0;
            age_ptr <= 0;
            op_idx <= 0;
            op_net <= 0;
            take_a <= 0;
            take_b <= 0;
            resolve_a <= 0;
            resolve_b <= 0;
            commit_a <= 0;
            commit_b <= 0;
            map_re <= 0;
            map_ra <= 0;
            cfg_re <= 0;
            cfg_ra <= 0;
            state_re <= 0;
            state_we <= 0;
            state_ra <= 0;
            state_wa <= 0;
            state_wd <= 0;
            current_desc <= 0;
            saved_map <= 0;
            saved_cfg <= 0;
            saved_state <= 0;
            state_changed <= 0;
            deliver_allowed <= 0;
            now_q <= 0;
            now_previous <= 0;
            age_time <= 0;
            elapsed <= 0;
            next_sn <= 0;
            second_sn <= 0;
            raw_distance <= 0;
            forward_distance <= 0;
            result <= 0;
            ev_a <= 0;
            ev_b <= 0;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
        end
        else begin
            now_q <= now_c;
            now_previous <= now_c;
            take_a <= 0;
            take_b <= 0;
            resolve_a <= 0;
            resolve_b <= 0;
            commit_a <= 0;
            commit_b <= 0;
            map_re <= 0;
            cfg_re <= 0;
            state_re <= 0;
            state_we <= 0;
            ev_a <= 0;
            ev_b <= 0;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
            case (op)
                INIT : if (! init_flush) begin
                    state_we <= 1;
                    state_wa <= init_ptr;
                    state_wd <= 0;
                    init_ptr <= init_ptr + 1'b1;
                    if (init_ptr == 4095) init_flush <= 1;
                end
                else begin
                    initialized <= 1;
                    op <= IDLE;
                end
                IDLE : if (enable) begin
                    if (desc_a_valid || desc_b_valid) begin
                        // 同拍描述先 A；老化最多占六拍，小于允许不定先后的16拍窗口。
                        op_net <= ! desc_a_valid;
                        current_desc <= desc_a_valid ? desc_a : desc_b;
                        map_ra <= desc_a_valid ? desc_a[RX_RING_AW + 82:RX_RING_AW + 67] : desc_b[RX_RING_AW + 82:RX_RING_AW + 67];
                        map_re <= 1;
                        take_a <= desc_a_valid;
                        take_b <= ! desc_a_valid;
                        state_changed <= 0;
                        deliver_allowed <= 0;
                        op <= FRAME;
                        phase <= 0;
                    end
                    else if (now_c != now_previous) begin
                        state_re <= 1;
                        state_ra <= age_ptr;
                        op_idx <= age_ptr;
                        age_ptr <= age_ptr + 1'b1;
                        age_time <= now_c;
                        op <= AGE;
                        phase <= 0;
                    end
                end
                FRAME : begin
                    phase <= phase + 1'b1;
                    case (phase)
                        1 : saved_map <= map_q;
                        2 : if (! saved_map[12]) begin
                            result <= 1;
                            phase <= 11;
                        end
                        else begin
                            op_idx <= saved_map[11:0];
                            cfg_re <= 1;
                            cfg_ra <= saved_map[11:0];
                            state_re <= 1;
                            state_ra <= saved_map[11:0];
                        end
                        4 : begin
                            saved_cfg <= cfg_q;
                            saved_state <= state_q;
                        end
                        5 : begin
                            if (! saved_cfg[0] || ! (op_net ? saved_cfg[2] : saved_cfg[1]) || length > saved_cfg[27:17]) begin
                                result <= 2;
                                phase <= 11;
                            end
                            next_sn <= psn == 255 ? 8'd1 : psn + 1'b1;
                            elapsed <= arrival - saved_state[15:0];
                            raw_distance <= { 1'b0, sn } - { 1'b0, saved_state[23:16] };
                        end
                        6 : begin
                            second_sn <= next_sn == 255 ? 8'd1 : next_sn + 1'b1;
                            forward_distance <= raw_distance[8] ? raw_distance + 9'd255 : raw_distance;
                        end
                        7 : if (saved_cfg[3]) begin
                            state_changed <= 1;
                            if (op_net) begin
                                saved_state[33] <= 1;
                                saved_state[32:25] <= sn;
                            end
                            else begin
                                saved_state[42] <= 1;
                                saved_state[41:34] <= sn;
                            end
                            if (psn_valid && sn != 0 && sn != next_sn && sn != second_sn) begin
                                result <= 3;
                                phase <= 10;
                            end
                        end
                        8 : begin
                            if (! saved_cfg[4] || ! saved_state[24] || elapsed > saved_cfg[16:5]) deliver_allowed <= 1;
                            else if (sn == saved_state[23:16]) deliver_allowed <= 0;
                            else if (sn == 0 || saved_state[23:16] == 0) deliver_allowed <= 1;
                            else deliver_allowed <= forward_distance >= 1 && forward_distance <= 127;
                        end
                        9 : begin
                            if (! deliver_allowed) result <= 4;
                            else if (dq_count == DQ_DEPTH) result <= 5;
                            else begin
                                result <= 0;
                                if (saved_cfg[4]) begin
                                    saved_state[24] <= 1;
                                    saved_state[23:16] <= sn;
                                    saved_state[15:0] <= arrival;
                                    state_changed <= 1;
                                end
                            end
                        end
                        10 : if (state_changed) begin
                            state_we <= 1;
                            state_wa <= op_idx;
                            state_wd <= saved_state;
                        end
                        11 : begin
                            resolve_a <= ! op_net;
                            resolve_b <= op_net;
                            commit_a <= ! op_net && result == 0;
                            commit_b <= op_net && result == 0;
                            case (result)
                                0 : ev_deliver <= 1;
                                1 : if (op_net) ev_b <= 8'h10;
                                else ev_a <= 8'h10;
                                2 : if (op_net) ev_b <= 8'h20;
                                else ev_a <= 8'h20;
                                3 : if (op_net) ev_b <= 8'h40;
                                else ev_a <= 8'h40;
                                4 : ev_rm_drop <= 1;
                                5 : if (op_net) ev_b <= 8'h80;
                                else ev_a <= 8'h80;
                                default :;
                            endcase
                            op <= IDLE;
                        end
                        default :;
                    endcase
                end
                AGE : begin
                    // 每步只读一项；帧描述出现即让路，错过的粗时钟变化不补做。
                    if (desc_a_valid || desc_b_valid) op <= IDLE;
                    else begin
                        phase <= phase + 1'b1;
                        case (phase)
                            1 : saved_state <= state_q;
                            2 : elapsed <= age_time - saved_state[15:0];
                            3 : begin
                                if (saved_state[24] && elapsed > 16'h4000) begin
                                    state_we <= 1;
                                    state_wa <= op_idx;
                                    state_wd <= { saved_state[43:25], 1'b0, saved_state[23:0] };
                                end
                                op <= IDLE;
                            end
                            default :;
                        endcase
                    end
                end
                default : op <= INIT;
            endcase
        end
    end
endmodule
