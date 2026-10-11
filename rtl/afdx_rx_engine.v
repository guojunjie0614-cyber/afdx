// 本模块决定收到的帧能否交给应用，并去掉双网送来的重复帧。
// 两路解析器提交完整帧的信息，检查通过后通知 afdx_rx_deliver。
// 本模块对应赛题的虚拟链路过滤、完整性检查和冗余管理。
// 完整性检查（Integrity Checking）按序号判断同一路网络上的帧是否连续。
// 冗余管理（Redundancy Management）在两路网络送来的同一帧中只保留先到的一份。
// 虚拟链路（Virtual Link，VL）把一组消息归到同一个配置项。
module afdx_rx_engine #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5) (
    // enable 为高时允许处理帧，now_c 给出粗粒度时间。
    // initialized 为高表示接收状态表已初始化。
    input wire clk, reset, enable,
    input wire [15:0] now_c,
    output reg initialized,
    // desc_a/b_* 提供完整帧的信息，take 表示已取走这些信息。
    // resolve 为高时，commit 决定保留还是释放本帧缓存。
    input wire desc_a_valid, desc_b_valid,
    input wire [RX_RING_AW + 82:0] desc_a, desc_b,
    output reg take_a, take_b, resolve_a, resolve_b, commit_a, commit_b,
    // map_* 把线路上的虚拟链路编号换成配置索引。
    // cfg_* 读取接收限制，state_* 读写该链路的接收状态。
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
    // dq_we 为高时，dq_wd 是写入 dq_wa 的交付信息。
    // dq_pop 表示读走一项，dq_count 表示已写入的项数。
    input wire dq_pop,
    output reg dq_we,
    output reg [RX_DQ_AW - 1:0] dq_wa,
    output reg [RX_RING_AW + 55:0] dq_wd,
    output reg [RX_DQ_AW:0] dq_count,
    // ev_a/b 报告各网的检查失败或队列满事件。
    // ev_rm_drop 表示重复帧被丢弃，ev_deliver 表示消息被接纳。
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,
    // cfg_ok 为高时允许外部写配置，此时没有等待处理的帧。
    output wire cfg_ok);
    localparam INIT = 0, IDLE = 1, FRAME = 2, AGE = 3, DQ_DEPTH = (1 << RX_DQ_AW), DQ_WIDTH = RX_RING_AW + 56;
    reg [1:0] op;
    assign cfg_ok = enable && (op == IDLE || op == AGE) && ! desc_a_valid && ! desc_b_valid;
    // phase 把一次检查分成多拍，op_idx 保存本次检查的配置索引。
    // saved_cfg 是这条虚拟链路的接收配置：
    // saved_cfg[0] 是使能位，[1] 和 [2] 分别允许接收 A 网和 B 网的帧。
    // saved_cfg[3] 打开完整性检查，[4] 打开冗余管理。
    // saved_cfg[16:5] 是两网允许的最大到达时间差 SkewMax，单位是 4096 拍（32.768 µs）。
    // saved_cfg[27:17] 是允许的最大帧长（字节）。
    reg [3:0] phase;
    reg [11:0] init_ptr, age_ptr, op_idx;
    reg init_flush, op_net, state_changed, deliver_allowed, age_pending;
    reg [RX_RING_AW + 82:0] current_desc;
    reg [12:0] saved_map;
    reg [31:0] saved_cfg;
    // saved_state[42] 表示 A 网的上一序号有效。
    // saved_state[41:34] 保存 A 网的上一序号。
    // saved_state[33] 表示 B 网的上一序号有效。
    // saved_state[32:25] 保存 B 网的上一序号。
    // saved_state[24] 表示重复帧检查记录有效。
    // saved_state[23:16] 保存最近交付的序号。
    // saved_state[15:0] 保存该帧的到达时间。
    reg [43:0] saved_state;
    // age_ptr 逐项检查旧记录，age_pending 保存尚未处理的检查请求。
    // elapsed 保存两份帧的到达时间差。
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
    // 检查通过且交付队列有空位时，才写入消息信息。
    // 队列满时不更新最近交付的序号。
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
            // dq_count 在消息信息实际写入的那一拍增加。
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
            age_pending <= 0;
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
            // 模块忙时记住过期检查请求，检查完一项后才推进地址。
            if (now_c != now_previous) age_pending <= 1;
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
            // 按 ARINC 664 P7，先检查各网序号，再去掉双网重复帧。
            case (op)
                // INIT：把 4096 项接收状态置零，写完后转 IDLE。
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
                // IDLE：有帧时转 FRAME；无帧且需检查旧记录时转 AGE。
                IDLE : if (enable) begin
                    if (desc_a_valid || desc_b_valid) begin
                        // 两网同时提交时先处理 A 网。
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
                    else if (age_pending || now_c != now_previous) begin
                        state_re <= 1;
                        state_ra <= age_ptr;
                        op_idx <= age_ptr;
                        age_time <= now_c;
                        op <= AGE;
                        phase <= 0;
                    end
                end
                // FRAME：查配置并检查帧，写回结果后转 IDLE。
                // phase=1：保存编号映射，下一拍转 2。
                // phase=2：有效映射触发配置读取，否则转 11。
                // phase=3：等待同步读取，下一拍转 4。
                // phase=4：保存配置和状态，下一拍转 5。
                // phase=5：检查网络和长度，失败转 11，否则转 6。
                // phase=6：计算到达时间差和序号距离，下一拍转 7。
                // phase=7：检查本网络序号，失败转 10，否则转 8。
                // phase=8：判断是否为重复帧，下一拍转 9。
                // phase=9：检查交付队列容量并保存决定，下一拍转 10。
                // phase=10：写回改变的接收状态，下一拍转 11。
                // phase=11：报告本帧处理结果，主状态转 IDLE。
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
                            // 旧记录会在半个计数周期前失效，因此可以取时间差的绝对值。
                            // 即使后到的帧先处理，这个差值仍代表两帧的到达间隔。
                            if (elapsed[15]) elapsed <= -elapsed;
                            second_sn <= next_sn == 255 ? 8'd1 : next_sn + 1'b1;
                            forward_distance <= raw_distance[8] ? raw_distance + 9'd255 : raw_distance;
                        end
                        // 序号为零、紧接上一序号或只跳过一个序号时，完整性检查通过。
                        // 无论是否通过，本网络都记录此次收到的序号。
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
                        // SkewMax 是两网同一帧允许的最大到达时间差。
                        // 在此时间范围内，已交付过的同序号帧不能再次交付。
                        // 其他序号按模 255 的前向距离判断新旧。
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
                // AGE：使过期记录失效后转 IDLE；新帧到来时立即转 IDLE。
                // phase=1：保存待检查的状态，下一拍转 2。
                // phase=2：计算记录已保存多久，下一拍转 3。
                // phase=3：使过期记录失效，主状态转 IDLE。
                AGE : begin
                    // 有新帧到来时，模块放下这次检查先去处理帧，之后再重新检查这一项。
                    // 记录保存超过 0x4000 个计时单位（约 0.54 秒）就失效。
                    if (desc_a_valid || desc_b_valid) op <= IDLE;
                    else begin
                        phase <= phase + 1'b1;
                        case (phase)
                            1 : saved_state <= state_q;
                            2 : elapsed <= age_time - saved_state[15:0];
                            3 : begin
                                age_ptr <= age_ptr + 1'b1;
                                age_pending <= now_c != now_previous;
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
