// 本模块决定收到的帧能否交给应用，并去掉双网送来的重复帧。
// 两路解析器提交完整帧的信息，检查通过后通知 afdx_rx_deliver。
// 本模块对应赛题的虚拟链路过滤、完整性检查和冗余管理。
// 完整性检查（Integrity Checking）按序号判断同一路网络上的帧是否连续。
// 冗余管理（Redundancy Management）在两路网络送来的同一帧中只保留先到的一份。
// 虚拟链路（Virtual Link，VL）把一组消息归到同一个配置项。
module afdx_rx_engine #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5, LOCAL_MAP_READ = 0, REGISTERED_TIME_TICK = 0, LOCAL_QUEUE_WRITE = 0, DESC_COPIES = 1) (

    // enable 为高时允许处理帧，now_c 给出粗粒度时间。
    // initialized 为高表示接收状态表已初始化。
    input wire clk, reset, enable,
    // 参数为 1 时，bit 16 携带同拍变化脉冲；默认端口宽度和位置不变。
    input wire [15 + REGISTERED_TIME_TICK:0] now_c,
    output reg initialized,

    // desc_a/b_* 提供完整帧的信息，take 表示已取走这些信息。
    // resolve 为高时，commit 决定保留还是释放本帧缓存。
    input wire [DESC_COPIES - 1:0] desc_a_valid, desc_b_valid,
    input wire [RX_RING_AW + 82:0] desc_a, desc_b,
    output reg take_a, take_b, resolve_a, resolve_b, commit_a, commit_b,

    // map_* 把线路上的虚拟链路编号换成配置索引。
    // cfg_* 读取接收限制，state_* 读写该链路的接收状态。
    output wire [DESC_COPIES - 1:0] map_re,
    output wire [DESC_COPIES * 16 - 1:0] map_ra,
    input wire [12:0] map_q,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg cfg_re,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [11:0] cfg_ra,
    input wire [31:0] cfg_q,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg state_re, state_we,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [11:0] state_ra, state_wa,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [42:0] state_wd,
    input wire [42:0] state_q,

    // dq_we 为高时，dq_wd 是写入 dq_wa 的交付信息。
    // dq_pop 表示读走一项，dq_count 表示已写入的项数。
    input wire dq_pop,
    (* preserve = 1, dont_merge = 1 *)
    output reg [(LOCAL_QUEUE_WRITE ? 32 * ((RX_RING_AW + 79) / 24) : 1) - 1:0] dq_we,
    output reg [RX_DQ_AW - 1:0] dq_wa,
    output reg [RX_RING_AW + 55:0] dq_wd,
    output reg [RX_DQ_AW:0] dq_count,

    // ev_a/b 报告各网的检查失败或队列满事件。
    // ev_rm_drop 表示重复帧被丢弃，ev_deliver 表示消息被接纳。
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,

    // cfg_ok 为高时允许外部写配置，此时没有等待处理的帧。
    output wire [DESC_COPIES - 1:0] cfg_ok);

    wire [15:0] now_c_value = now_c[15:0];

    localparam RX_ACCEPTED = 0;
    localparam RX_UNMAPPED = 1;
    localparam RX_CONFIG_REJECT = 2;
    localparam RX_BAD_SEQUENCE = 3;
    localparam RX_DUPLICATE = 4;
    localparam RX_QUEUE_FULL = 5;
    localparam [7:0] EV_NONE = 8'd0;
    localparam EV_UNMAPPED = 8'h10;
    localparam EV_CONFIG_REJECT = 8'h20;
    localparam EV_BAD_SEQUENCE = 8'h40;
    localparam EV_QUEUE_FULL = 8'h80;
    localparam DQ_DEPTH = (1 << RX_DQ_AW), DQ_WIDTH = RX_RING_AW + 56;
    localparam [1:0] INIT = 2'd0, IDLE = 2'd1, FRAME = 2'd2, AGE = 2'd3;

    // 接收虚拟链路共 4096 条，LAST_VL 是最后一条的序号。
    localparam LAST_VL = 4095;

    // 帧序号在 1–255 之间循环：255 之后回到 1，一圈共 255 个。
    // 新序号领先上一个序号不超过半圈（127）才算新帧。
    localparam SN_MAX = 255, SN_FIRST = 8'd1, SN_RANGE = 9'd255, SN_HALF_RANGE = 127;

    // 上次接纳后超过这么多个粗时间单位（每单位 4096 拍）没有新帧，就清除重复帧记录。
    localparam AGE_LOW_BITS = 14;
    localparam [1:0] AGE_LIMIT_HIGH = 1;
    reg age_low_borrow, age_low_equal;
    reg [1:0] age_high_difference;
    // 原阈值为 0x4000。低位借位/相等与高两位差并行寄存，仍在原 phase=3 写回。
    wire age_expired = age_low_borrow ? age_high_difference != AGE_LIMIT_HIGH
        : (age_high_difference > AGE_LIMIT_HIGH || (age_high_difference == AGE_LIMIT_HIGH && !age_low_equal));

    // 处理一帧时 phase 的后三步：登记交付、写回状态、报告结果。
    localparam [3:0] STEP_DELIVER = 4'd11, STEP_WRITE = 4'd12, STEP_FINISH = 4'd13;
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [1:0] op;

    // 分 bank 的映射表在本拍各自保存请求，替代一组跨整个存储区的地址寄存器。
    // 独立使用本模块时仍保持原来的一拍请求接口。
    genvar map_copy;
    generate
        if (LOCAL_MAP_READ) begin : local_map
            // 只读取已经提交的帧，避免空闲读与配置写同址相撞；每个目标使用自己的有效位副本。
            for (map_copy = 0; map_copy < DESC_COPIES; map_copy = map_copy + 1) begin : target
                assign map_re[map_copy] = !reset && op == IDLE
                    && (desc_a_valid[map_copy] || desc_b_valid[map_copy]);
                assign map_ra[map_copy * 16 +: 16] = desc_a_valid[map_copy]
                    ? desc_a[RX_RING_AW + 82:RX_RING_AW + 67] : desc_b[RX_RING_AW + 82:RX_RING_AW + 67];
            end
        end
        else begin : registered_map
            // 独立接口保留原 enable 条件。
            wire map_start = !reset && op == IDLE && enable && (desc_a_valid[0] || desc_b_valid[0]);
            wire [15:0] map_address = desc_a_valid[0] ? desc_a[RX_RING_AW + 82:RX_RING_AW + 67]
                : desc_b[RX_RING_AW + 82:RX_RING_AW + 67];
            reg request;
            reg [15:0] address;
            always @(posedge clk) begin
                if (reset) begin
                    request <= 0;
                    address <= 0;
                end
                else begin
                    request <= map_start;
                    if (map_start) address <= map_address;
                end
            end
            assign map_re = {DESC_COPIES{request}};
            assign map_ra = {DESC_COPIES{address}};
        end
    endgenerate

    // 每个配置目标使用自己的描述符有效位副本，避免同一组合 ready 横跨全部 RAM bank。
    // cfg_ok 改用上一拍的“无待处理帧”副本，不再把跨区 desc_valid 直接串入
    // 各 bank 的写选通；desc_valid 变高当拍仍可能接受写入，写读先后见 ARCH.md。
    (* preserve = 1, dont_merge = 1 *) reg [DESC_COPIES - 1:0] desc_quiet_copy;
    genvar ready_copy;
    generate
        for (ready_copy = 0; ready_copy < DESC_COPIES; ready_copy = ready_copy + 1) begin : config_ready
            assign cfg_ok[ready_copy] = enable && (op == IDLE || op == AGE)
                && desc_quiet_copy[ready_copy];
        end
    endgenerate

    // phase 把一次检查分成多拍，op_idx 保存本次检查的配置索引。
    // saved_cfg 是这条虚拟链路的接收配置：
    // saved_cfg[0] 是使能位，[1] 和 [2] 分别允许接收 A 网和 B 网的帧。
    // saved_cfg[3] 打开完整性检查，[4] 打开冗余管理。
    // saved_cfg[16:5] 是两网允许的最大到达时间差 SkewMax，单位是 4096 拍（32.768 µs）。
    // saved_cfg[27:17] 是允许的最大帧长（字节）。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg [3:0] phase;
    reg [11:0] init_ptr, age_ptr, op_idx;
    reg init_flush, op_net, state_changed, deliver_allowed, age_pending;
    // desc_quiet 保存上一拍“无待处理帧”，AGE 入口与状态装载使能不再直接串接 desc_valid 远端连线。
    (* preserve = 1, dont_merge = 1 *) reg desc_quiet;
    // phase 9 先行寄存 phase 10 的比较结论，交付判断不再串接宽比较器。
    reg skew_expired, sn_match, zero_shortcut, forward_ok;
    reg map_missing, config_reject, sequence_reject;
    reg [RX_RING_AW + 82:0] current_desc;
    reg [12:0] saved_map;
    wire [12:0] selected_map = LOCAL_MAP_READ ? map_q : saved_map;
    reg [31:0] saved_cfg;

    // saved_state[42] 表示 A 网的上一序号有效。
    // saved_state[41:34] 保存 A 网的上一序号。
    // saved_state[33] 表示 B 网的上一序号有效。
    // saved_state[32:25] 保存 B 网的上一序号。
    // saved_state[24] 表示重复帧检查记录有效。
    // saved_state[23:16] 保存最近交付的序号。
    // saved_state[15:0] 保存该帧的到达时间。
    reg [42:0] saved_state;

    // age_ptr 逐项检查旧记录，age_pending 保存尚未处理的检查请求。
    // elapsed 保存两份帧的到达时间差。
    reg [15:0] now_previous, age_time, elapsed;
    reg [7:0] next_sn, second_sn;
    reg [8:0] raw_distance, forward_distance;
    reg [2:0] result;
    wire [15:0] arrival = current_desc[15:0];
    wire [7:0] sn = current_desc[RX_RING_AW + 66:RX_RING_AW + 59];
    wire [10:0] length = current_desc[RX_RING_AW + 26:RX_RING_AW + 16];
    reg [7:0] psn;
    reg psn_valid;
    reg [RX_DQ_AW - 1:0] wr_ptr;

    // 检查通过且交付队列有空位时，才写入消息信息。
    // 队列满时不更新最近交付的序号。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg delivery_phase;
    // 提前一拍登记结果写入相位，拒绝标志仍在原判定拍取值。
    // 结果寄存器的使能和数据选择均不再直接译码远端 op/phase。
    (* preserve = 1, dont_merge = 1 *) reg result_map_phase, result_config_phase, result_sequence_phase;
    always @(posedge clk) begin
        if (reset) begin
            delivery_phase <= 0;
            result_map_phase <= 0;
            result_config_phase <= 0;
            result_sequence_phase <= 0;
        end
        else begin
            delivery_phase <= op == FRAME && phase == STEP_DELIVER - 1 && !sequence_reject;
            result_map_phase <= op == FRAME && phase == 4;
            result_config_phase <= op == FRAME && phase == 7;
            result_sequence_phase <= op == FRAME && phase == 9;
        end
    end
    // dq_room 随计数同步寄存，队列满的常数比较不再进入交付写使能锥。
    reg dq_room;
    wire dq_put = delivery_phase && deliver_allowed && dq_room;
    wire [DQ_WIDTH - 1:0] dq_input = { op_net, current_desc[RX_RING_AW + 15:16], length, op_idx,
        current_desc[RX_RING_AW + 58:RX_RING_AW + 43], current_desc[RX_RING_AW + 42:RX_RING_AW + 27] };

    // 四种相位标志互斥，写入仍分别发生在原 phase=5/8/10/11。
    always @(posedge clk) begin
        if (reset) result <= RX_ACCEPTED;
        else if (result_map_phase && map_missing) result <= RX_UNMAPPED;
        else if (result_config_phase && config_reject) result <= RX_CONFIG_REJECT;
        else if (result_sequence_phase && sequence_reject) result <= RX_BAD_SEQUENCE;
        else if (delivery_phase) begin
            if (!deliver_allowed) result <= RX_DUPLICATE;
            else if (!dq_room) result <= RX_QUEUE_FULL;
            else result <= RX_ACCEPTED;
        end
    end

    wire age_tick;
    generate
        if (REGISTERED_TIME_TICK) begin : registered_age_tick
            assign age_tick = now_c[16];
        end
        else begin : observed_age_tick
            assign age_tick = now_c_value != now_previous;
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) desc_quiet <= 0;
        else desc_quiet <= !desc_a_valid[0] && !desc_b_valid[0];
    end

    // 每副本独立寄存“上一拍无待处理帧”；复位值与 desc_valid=0 一致。
    always @(posedge clk) begin
        if (reset) desc_quiet_copy <= {DESC_COPIES{1'b1}};
        else desc_quiet_copy <= ~(desc_a_valid | desc_b_valid);
    end

    localparam DQ_WRITE_SLICES = (DQ_WIDTH + 23) / 24;
    reg dq_commit;
    genvar dq_write_copy;
    generate
        if (LOCAL_QUEUE_WRITE) begin : queue_write_banks
            for (dq_write_copy = 0; dq_write_copy < 32 * DQ_WRITE_SLICES;
                dq_write_copy = dq_write_copy + 1) begin : target
                always @(posedge clk) begin
                    if (reset) dq_we[dq_write_copy] <= 0;
                    else dq_we[dq_write_copy] <= dq_put && wr_ptr == dq_write_copy / DQ_WRITE_SLICES;
                end
            end
        end
        else begin : queue_write_scalar
            always @(posedge clk) begin
                if (reset) dq_we <= 0;
                else dq_we <= dq_put;
            end
        end
    endgenerate

    // RAM 捕获与三种修改互斥；分字段直接选择，避免 RAM 输出穿过多层整字优先级。
    // 预译码保留 FRAME/6、AGE/1 的原装载拍，不推迟 RAM 数据采样。
    // FRAME 的拒绝跳转禁止后继使能；AGE/0 的描述符有效位同时决定
    // 是否进入 AGE/1 和下一拍 desc_quiet，因此中断检查时也保持原语义。
    (* preserve = 1, dont_merge = 1 *) reg load_saved_q, write_saved_a, write_saved_b;
    always @(posedge clk) begin
        if (reset) begin
            load_saved_q <= 0;
            write_saved_a <= 0;
            write_saved_b <= 0;
        end
        else begin
            load_saved_q <= (op == FRAME && phase == 5 && !map_missing)
                || (op == AGE && phase == 0 && !desc_a_valid[0] && !desc_b_valid[0]);
            write_saved_a <= op == FRAME && phase == 8 && !config_reject && saved_cfg[3] && !op_net;
            write_saved_b <= op == FRAME && phase == 8 && !config_reject && saved_cfg[3] && op_net;
        end
    end
    wire write_saved_rm = delivery_phase && deliver_allowed && dq_room && saved_cfg[4];
    always @(posedge clk) begin
        if (reset) saved_state <= 0;
        else begin
            if (load_saved_q || write_saved_a)
                saved_state[42:34] <= ({9{load_saved_q}} & state_q[42:34])
                    | ({9{write_saved_a}} & {1'b1, sn});
            if (load_saved_q || write_saved_b)
                saved_state[33:25] <= ({9{load_saved_q}} & state_q[33:25])
                    | ({9{write_saved_b}} & {1'b1, sn});
            if (load_saved_q || write_saved_rm)
                saved_state[24:0] <= ({25{load_saved_q}} & state_q[24:0])
                    | ({25{write_saved_rm}} & {1'b1, sn, arrival});
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            age_low_borrow <= 0;
            age_low_equal <= 0;
            age_high_difference <= 0;
        end
        else begin
            age_low_borrow <= age_time[AGE_LOW_BITS - 1:0] < saved_state[AGE_LOW_BITS - 1:0];
            age_low_equal <= age_time[AGE_LOW_BITS - 1:0] == saved_state[AGE_LOW_BITS - 1:0];
            age_high_difference <= age_time[15:AGE_LOW_BITS] - saved_state[15:AGE_LOW_BITS];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            wr_ptr <= 0;
            dq_count <= 0;
            dq_commit <= 0;
            dq_wa <= 0;
            dq_wd <= 0;
            dq_room <= 1;
        end
        else begin
            dq_commit <= dq_put;
            if (dq_put) begin
                dq_wa <= wr_ptr;
                dq_wd <= dq_input;
                wr_ptr <= wr_ptr + 1'b1;
            end
            // dq_count 在消息信息实际写入的那一拍增加，dq_room 同步记录是否还有空位。
            case ({ dq_commit, dq_pop })
                2'b10 : begin
                    dq_count <= dq_count + 1'b1;
                    dq_room <= dq_count < DQ_DEPTH - 1;
                end
                2'b01 : begin
                    dq_count <= dq_count - 1'b1;
                    dq_room <= 1;
                end
                default : ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            op <= INIT;
            phase <= 0;
            map_missing <= 0;
            config_reject <= 0;
            sequence_reject <= 0;
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

            state_changed <= 0;
            deliver_allowed <= 0;
            skew_expired <= 0;
            sn_match <= 0;
            zero_shortcut <= 0;
            forward_ok <= 0;
            now_previous <= 0;
            age_time <= 0;
            elapsed <= 0;
            next_sn <= 0;
            psn <= 0;
            psn_valid <= 0;
            second_sn <= 0;
            raw_distance <= 0;
            forward_distance <= 0;
            ev_a <= EV_NONE;
            ev_b <= EV_NONE;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
        end
        else begin
            now_previous <= now_c_value;
            // 时间基准直接给出同拍变化脉冲；独立模块保持外部 now_c_value 比较语义。
            if (age_tick) age_pending <= 1;
            take_a <= 0;
            take_b <= 0;
            resolve_a <= 0;
            resolve_b <= 0;
            commit_a <= 0;
            commit_b <= 0;
            cfg_re <= 0;
            state_re <= 0;
            state_we <= 0;
            ev_a <= EV_NONE;
            ev_b <= EV_NONE;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
            // 按 ARINC 664 P7，先检查各网序号，再去掉双网重复帧。
            case (op)

                // INIT：把 4096 项接收状态置零，写完后转 IDLE。
                INIT : if ( ! init_flush) begin
                    state_we <= 1;
                    state_wa <= init_ptr;
                    state_wd <= 0;
                    init_ptr <= init_ptr + 1'b1;
                    if (init_ptr == LAST_VL) init_flush <= 1;
                end
                else begin
                    initialized <= 1;
                    op <= IDLE;
                end

                // IDLE：有帧时转 FRAME；无帧且需检查旧记录时转 AGE。
                IDLE : if (enable) begin
                    if (desc_quiet && (age_pending || age_tick)) begin
                        state_re <= 1;
                        state_ra <= age_ptr;
                        op_idx <= age_ptr;
                        age_time <= now_c_value;
                        op <= AGE;
                        phase <= 0;
                    end
                    if (desc_a_valid[0] || desc_b_valid[0]) begin
                        // 两网同时提交时先处理 A 网。
                        op_net <= ! desc_a_valid[0];
                        current_desc <= desc_a_valid[0] ? desc_a : desc_b;
                        take_a <= desc_a_valid[0];
                        take_b <= ! desc_a_valid[0];
                        state_changed <= 0;
                        deliver_allowed <= 0;
                        op <= FRAME;
                        phase <= 0;
                    end
                end

                // FRAME：查配置并检查帧，写回结果后转 IDLE。
                // phase=0..2：等待映射表流水线返回。
                // phase=3：分 bank 接口在表内寄存结果；独立接口保存编号映射，下一拍转 4。
                // phase=4：有效映射触发配置读取，否则转 13。
                // phase=5：等待同步读取，下一拍转 6。
                // phase=6：保存配置和状态，下一拍转 7。
                // phase=7：检查网络和长度，失败转 13，否则转 8。
                // phase=8：计算到达时间差和序号距离，下一拍转 9。
                // phase=9：检查本网络序号，失败转 12，否则转 10。
                // phase=10：判断是否为重复帧，下一拍转 11。
                // phase=11：检查交付队列容量并保存决定，下一拍转 12。
                // phase=12：写回改变的接收状态，下一拍转 13。
                // phase=13：报告本帧处理结果，主状态转 IDLE。
                FRAME : begin
                    phase <= phase + 1'b1;
                    case (phase)

                        3 : if (!LOCAL_MAP_READ) saved_map <= map_q;

                        4 : begin
                            // 无效映射只撤销读使能；地址先保存，避免有效位串入宽地址选择器。
                            cfg_ra <= selected_map[11:0];
                            state_ra <= selected_map[11:0];
                            map_missing <= !selected_map[12];
                            op_idx <= selected_map[11:0];
                            if (selected_map[12]) begin
                                cfg_re <= 1;
                                state_re <= 1;
                            end
                        end

                        5 : if (map_missing) begin
                            phase <= STEP_FINISH;
                        end

                        6 : begin
                            saved_cfg <= cfg_q;

                            // 与状态字同拍选择旧序号；下一拍递增不再串接两网选择器。
                            psn <= op_net ? state_q[32:25] : state_q[41:34];
                            psn_valid <= op_net ? state_q[33] : state_q[42];
                        end

                        7 : begin
                            config_reject <= !saved_cfg[0] || !(op_net ? saved_cfg[2] : saved_cfg[1])
                                || length > saved_cfg[27:17];
                            next_sn <= psn == SN_MAX ? SN_FIRST : psn + 1'b1;
                            elapsed <= arrival - saved_state[15:0];
                            raw_distance <= { 1'b0, sn } - { 1'b0, saved_state[23:16] };
                        end

                        8 : begin
                            if (config_reject) begin
                                phase <= STEP_FINISH;
                            end
                            // 旧记录会在半个计数周期前失效，因此可以取时间差的绝对值。
                            // 即使后到的帧先处理，这个差值仍代表两帧的到达间隔。
                            if (elapsed[15]) elapsed <= - elapsed;
                            second_sn <= next_sn == SN_MAX ? SN_FIRST : next_sn + 1'b1;
                            forward_distance <= raw_distance[8] ? raw_distance + SN_RANGE : raw_distance;
                        end

                        // 序号为零、紧接上一序号或只跳过一个序号时，完整性检查通过。
                        // 无论是否通过，本网络都记录此次收到的序号。
                        9 : begin
                            sequence_reject <= saved_cfg[3] && psn_valid && sn != 0
                                && sn != next_sn && sn != second_sn;
                            if (saved_cfg[3]) state_changed <= 1;
                            // 交付判断的比较项在本拍并行寄存，下一拍只剩本地标志选择。
                            skew_expired <= elapsed > saved_cfg[16:5];
                            sn_match <= sn == saved_state[23:16];
                            zero_shortcut <= sn == 0 || saved_state[23:16] == 0;
                            forward_ok <= forward_distance >= 1
                                && forward_distance <= SN_HALF_RANGE;
                        end

                        // SkewMax 是两网同一帧允许的最大到达时间差。
                        // 在此时间范围内，已交付过的同序号帧不能再次交付。
                        // 其他序号按模 255 的前向距离判断新旧。
                        10 : begin
                            if (sequence_reject) begin
                                phase <= STEP_WRITE;
                            end
                            if ( ! saved_cfg[4] || ! saved_state[24] || skew_expired) deliver_allowed <= 1;
                            else if (sn_match) deliver_allowed <= 0;
                            else if (zero_shortcut) deliver_allowed <= 1;
                            else deliver_allowed <= forward_ok;
                        end

                        STEP_DELIVER : begin
                            if (deliver_allowed && dq_room && saved_cfg[4]) state_changed <= 1;
                        end

                        STEP_WRITE : begin
                            if (state_changed) state_we <= 1;
                            state_wa <= op_idx;
                            state_wd <= saved_state;
                        end

                        STEP_FINISH : begin
                            resolve_a <= ! op_net;
                            resolve_b <= op_net;
                            commit_a <= ! op_net && result == RX_ACCEPTED;
                            commit_b <= op_net && result == RX_ACCEPTED;
                            case (result)
                                RX_ACCEPTED : ev_deliver <= 1;
                                RX_UNMAPPED : if (op_net) ev_b <= EV_UNMAPPED;
                                else ev_a <= EV_UNMAPPED;
                                RX_CONFIG_REJECT : if (op_net) ev_b <= EV_CONFIG_REJECT;
                                else ev_a <= EV_CONFIG_REJECT;
                                RX_BAD_SEQUENCE : if (op_net) ev_b <= EV_BAD_SEQUENCE;
                                else ev_a <= EV_BAD_SEQUENCE;
                                RX_DUPLICATE : ev_rm_drop <= 1;
                                RX_QUEUE_FULL : if (op_net) ev_b <= EV_QUEUE_FULL;
                                else ev_a <= EV_QUEUE_FULL;
                                default : ;
                            endcase
                            op <= IDLE;
                        end

                        default : ;
                    endcase
                end

                // AGE：使过期记录失效后转 IDLE；新帧到来时立即转 IDLE。
                // phase=1：保存待检查的状态，下一拍转 2。
                // phase=2：计算记录已保存多久，下一拍转 3。
                // phase=3：使过期记录失效，主状态转 IDLE。
                AGE : begin
                    // 有新帧到来时，模块放下这次检查先去处理帧，之后再重新检查这一项。
                    // 记录保存超过 0x4000 个计时单位（约 0.54 秒）就失效。
                    if (desc_a_valid[0] || desc_b_valid[0]) op <= IDLE;
                    else begin
                        phase <= phase + 1'b1;
                        case (phase)
                            1 : ;
                            2 : ; // 分段时间差在独立寄存器中完成。
                            3 : begin
                                age_ptr <= age_ptr + 1'b1;
                                age_pending <= now_c_value != now_previous;
                                state_wa <= op_idx;
                                state_wd <= { saved_state[42:25], 1'b0, saved_state[23:0] };
                                if (saved_state[24] && age_expired) state_we <= 1;
                                op <= IDLE;
                            end
                            default : ;
                        endcase
                    end
                end

                default : op <= INIT;
            endcase
        end
    end

endmodule
