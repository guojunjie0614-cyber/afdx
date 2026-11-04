// 本模块决定收到的帧能否交给应用，并去掉双网送来的重复帧。
// 两路解析器提交完整帧的信息，检查通过后通知 afdx_rx_deliver。
// 本模块对应赛题的虚拟链路过滤、完整性检查和冗余管理。
// 完整性检查（Integrity Checking）按序号判断同一路网络上的帧是否连续。
// 冗余管理（Redundancy Management）在两路网络送来的同一帧中只保留先到的一份。
// 虚拟链路（Virtual Link，VL）把一组消息归到同一个配置项。
module afdx_rx_engine #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5, LOCAL_MAP_READ = 0, REGISTERED_TIME_TICK = 0, LOCAL_QUEUE_WRITE = 0, DESC_COPIES = 1, CORE_ENABLE_PREDICT = 0) (

    // enable 为高时允许处理帧，now_c 给出粗粒度时间。
    // initialized 为高表示接收状态表已初始化。
    input wire clk, reset, enable,
    // 参数为 1 时，bit 16 携带同拍变化脉冲；默认端口宽度和位置不变。
    input wire [15 + REGISTERED_TIME_TICK:0] now_c,
    output reg initialized,

    // desc_a/b_* 提供完整帧的信息，take 表示已取走这些信息。
    // resolve 为高时，commit 决定保留还是释放本帧缓存。
    input wire [DESC_COPIES - 1:0] desc_a_valid, desc_b_valid,
    input wire [RX_RING_AW + 208:0] desc_a, desc_b,
    output reg take_a, take_b, resolve_a, resolve_b, commit_a, commit_b,

    // map_* 把线路上的虚拟链路编号换成配置索引。
    // cfg_* 读取接收限制，state_* 读写该链路的接收状态。
    output wire [DESC_COPIES - 1:0] map_re,
    output wire [DESC_COPIES * 16 - 1:0] map_ra,
    input wire [12:0] map_q,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg cfg_re,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [11:0] cfg_ra,
    input wire [31:0] cfg_q,
    (* preserve = 1, dont_merge = 1 *) output reg state_re, state_we,
    (* preserve = 1, dont_merge = 1 *) output reg [11:0] state_ra, state_wa,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [42:0] state_wd,
    input wire [42:0] state_q,

    // dq_we 为高时，dq_wd 是写入 dq_wa 的交付信息。
    // dq_pop 表示读走一项，dq_count 表示已写入的项数。
    input wire dq_pop,
    (* preserve = 1, dont_merge = 1 *)
    output reg [(LOCAL_QUEUE_WRITE ? 32 * ((RX_RING_AW + 84) / 24) : 1) - 1:0] dq_we,
    output reg [RX_DQ_AW - 1:0] dq_wa,
    output reg [RX_RING_AW + 60:0] dq_wd,
    input wire reassembly_result_valid, reassembly_ok, input wire [3:0] reassembly_slot,
    output reg reassembly_query, reassembly_cancel, reassembly_reserve,
    (* preserve = 1, dont_merge = 1 *) output reg [1:0] reassembly_query_bank, reassembly_cancel_bank, reassembly_reserve_bank,
    output wire [125:0] reassembly_meta,
    output wire [11:0] reassembly_vl, output wire [10:0] reassembly_length,
    output wire [15:0] reassembly_sport, reassembly_dport, output wire reassembly_net,
    output reg [RX_DQ_AW:0] dq_count,

    // ev_a/b 报告各网的检查失败或队列满事件。
    // ev_rm_drop 表示重复帧被丢弃，ev_deliver 表示消息被接纳。
    output reg [7:0] ev_a, ev_b,
    output reg ev_rm_drop, ev_deliver,

    // cfg_ok 为高时允许外部写配置，此时没有等待处理的帧。
    output wire [DESC_COPIES - 1:0] cfg_ok,
    // Core-only prediction of the post-edge init_done. It stays low through
    // this engine's INIT exit edge; default standalone enable stays immediate.
    input wire core_enable_next);
`ifdef MODEL_TECH
    (* preserve=1, dont_merge=1 *) reg frame_start_q, age_start_q;
    reg dq_room;
    wire fragmented;
    wire age_tick;
    reg dq_commit;
`endif

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
    localparam DQ_DEPTH = (1 << RX_DQ_AW), DQ_WIDTH = RX_RING_AW + 61;
    localparam [3:0] INIT=4'b0001, IDLE=4'b0010, FRAME=4'b0100, AGE=4'b1000;

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
    localparam [4:0] STEP_PREPARE=5'd27, STEP_DELIVER=5'd28, STEP_WRITE=5'd29, STEP_FINISH=5'd30;
    // Explicit one-hot ownership avoids replicated binary state feedback
    // crossing all consumers. Wide actions use local predecoded commands.
    (* preserve=1, dont_merge=1, syn_encoding="user", fsm_encoding="none" *) reg [3:0] op;

    // 分 bank 的映射表在本拍各自保存请求，替代一组跨整个存储区的地址寄存器。
    // 独立使用本模块时仍保持原来的一拍请求接口。
    genvar map_copy;
    generate
        if (LOCAL_MAP_READ) begin : local_map
            // 只读取已经提交的帧，避免空闲读与配置写同址相撞；每个目标使用自己的有效位副本。
            for (map_copy = 0; map_copy < DESC_COPIES; map_copy = map_copy + 1) begin : target
                (* preserve=1, dont_merge=1 *) reg source_request;
                always @(posedge clk) begin
                    if(reset) source_request<=0;
                    // Outstanding descriptors may reread their map while the
                    // engine is busy. FRAME5 still captures the initial return.
                    // Quiet-gated config writes finish before the first read;
                    // no descriptor means no speculative read during config.
                    else source_request<=initialized && (desc_a_valid[map_copy] || desc_b_valid[map_copy]);
                end
                assign map_re[map_copy]=source_request;
                // This replaces the first address register inside each map
                // bank. The remaining RAM-port stage consumes it next clock.
                (* preserve=1, dont_merge=1 *) reg [15:0] source_address;
                always @(posedge clk) source_address<=desc_a_valid[map_copy]
                    ? desc_a[RX_RING_AW + 82:RX_RING_AW + 67] : desc_b[RX_RING_AW + 82:RX_RING_AW + 67];
                assign map_ra[map_copy * 16 +: 16]=source_address;
            end
        end
        else begin : registered_map
            // 独立接口保留原 enable 条件。
            wire map_start = !reset && op[1] && !frame_start_q && !age_start_q && enable && (desc_a_valid[0] || desc_b_valid[0]);
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
    // cfg_ok 同拍预测 idle/AGE + quiet；core 连同初始化许可一起预测，独立接口保留组合 enable。
    // 不延后真实受理拍；desc_valid 变高当拍仍可能接受原协议允许的写入。
    (* preserve = 1, dont_merge = 1 *) reg [DESC_COPIES - 1:0] desc_quiet_copy;
    genvar ready_copy;
    generate
        for (ready_copy = 0; ready_copy < DESC_COPIES; ready_copy = ready_copy + 1) begin : config_ready
            assign cfg_ok[ready_copy]=CORE_ENABLE_PREDICT ? desc_quiet_copy[ready_copy]
                : (enable && desc_quiet_copy[ready_copy]);
        end
    endgenerate

    // phase 把一次检查分成多拍，op_idx 保存本次检查的配置索引。
    // saved_cfg 是这条虚拟链路的接收配置：
    // saved_cfg[0] 是使能位，[1] 和 [2] 分别允许接收 A 网和 B 网的帧。
    // saved_cfg[3] 打开完整性检查，[4] 打开冗余管理。
    // saved_cfg[16:5] 是两网允许的最大到达时间差 SkewMax，单位是 4096 拍（32.768 µs）。
    // saved_cfg[27:17] 是允许的最大帧长（字节）。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg [4:0] phase;
    reg [11:0] init_ptr, age_ptr;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] op_idx, dq_idx;
    reg init_flush, op_net, state_changed, deliver_allowed, age_pending;
    // desc_quiet 保存上一拍“无待处理帧”，AGE 入口与状态装载使能不再直接串接 desc_valid 远端连线。
    (* preserve = 1, dont_merge = 1 *) reg desc_quiet;
    // phase 13 先行寄存 phase 14 的比较结论，交付判断不再串接宽比较器。
    reg skew_expired, sn_match, zero_shortcut, forward_ok;
    reg map_missing, config_reject, sequence_reject;
    reg [RX_RING_AW + 208:0] current_desc;
    (* preserve=1, dont_merge=1 *) reg [RX_RING_AW + 208:0] descriptor_snapshot_a, descriptor_snapshot_b;
`ifndef MODEL_TECH
    (* preserve=1, dont_merge=1 *) reg frame_start_q, age_start_q;
`endif
    reg [15:0] age_time_snapshot;
    reg [11:0] age_pointer_snapshot;
    wire start_age=op[1] && !frame_start_q && !age_start_q && enable && desc_quiet
        && (age_pending || age_tick) && !desc_a_valid[0] && !desc_b_valid[0];
    reg frame_fragmented, frame_later;
    wire start_frame=op[1] && !frame_start_q && !age_start_q && enable && (desc_a_valid[0] || desc_b_valid[0]);
    localparam DESC_WIDTH=RX_RING_AW+209, DESC_GROUPS=(DESC_WIDTH+23)/24;
    (* preserve=1, dont_merge=1 *) reg [1:0] fragment_snapshot_a, fragment_snapshot_b;
    always @(posedge clk) begin
        descriptor_snapshot_a<=desc_a;descriptor_snapshot_b<=desc_b;
        // Reduce each network before selecting it, on the descriptor snapshot
        // edge. The following edge selects only two locally registered flags.
        fragment_snapshot_a<={|desc_a[RX_RING_AW+128:RX_RING_AW+116],
            |desc_a[RX_RING_AW+128:RX_RING_AW+115]};
        fragment_snapshot_b<={|desc_b[RX_RING_AW+128:RX_RING_AW+116],
            |desc_b[RX_RING_AW+128:RX_RING_AW+115]};
        age_time_snapshot<=now_c_value;age_pointer_snapshot<=age_ptr;
        if(reset) begin frame_start_q<=0;age_start_q<=0;frame_fragmented<=0;frame_later<=0;end
        else begin
            frame_start_q<=start_frame;age_start_q<=start_age;
            if(frame_start_q) begin
                frame_fragmented<=op_net ? fragment_snapshot_b[0] : fragment_snapshot_a[0];
                frame_later<=op_net ? fragment_snapshot_b[1] : fragment_snapshot_a[1];
            end
        end
    end
    genvar descriptor_group;
    generate for(descriptor_group=0;descriptor_group<DESC_GROUPS;descriptor_group=descriptor_group+1) begin:frame_capture
        localparam GROUP_WIDTH=(DESC_WIDTH-descriptor_group*24>=24) ? 24 : DESC_WIDTH-descriptor_group*24;
        (* preserve=1, dont_merge=1 *) reg load, selected_net;
        always @(posedge clk) begin
            selected_net<=!desc_a_valid[0];
            if(reset) begin load<=0;current_desc[descriptor_group*24+:GROUP_WIDTH]<=0;end
            else begin
                load<=start_frame;
                if(load) current_desc[descriptor_group*24+:GROUP_WIDTH]<=selected_net
                    ? descriptor_snapshot_b[descriptor_group*24+:GROUP_WIDTH]
                    : descriptor_snapshot_a[descriptor_group*24+:GROUP_WIDTH];
            end
        end
    end endgenerate
    // Capture the returned map once at phase 5. Its local frame snapshot,
    // rather than the remote RAM output, drives all subsequent requests.
    (* preserve = 1, dont_merge = 1 *) reg [12:0] saved_map;
    wire [12:0] selected_map = saved_map;
    (* preserve=1, dont_merge=1 *) reg [11:0] query_vl;
    always @(posedge clk) query_vl<=selected_map[11:0];
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
    (* preserve = 1, dont_merge = 1 *) reg [15:0] now_previous;
    reg [15:0] age_time, elapsed;
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
    (* preserve=1, dont_merge=1 *) reg map_capture_command, frame_ram_command, state_write_command, age_write_command;
    (* preserve=1, dont_merge=1 *) reg queue_command, write_saved_rm, admission_room;
    (* preserve=1, dont_merge=1 *) reg [4:0] frame_work_commands;
    always @(posedge clk) begin
        if(reset) frame_work_commands<=0;
        else begin
            frame_work_commands[0]<=op[2] && phase==9;
            frame_work_commands[1]<=op[2] && phase==10;
            frame_work_commands[2]<=op[2] && phase==11;
            frame_work_commands[3]<=op[2] && phase==12 && !config_reject;
            frame_work_commands[4]<=op[2] && phase==13;
        end
    end
    // FRAME26 predicts exactly the room value visible at FRAME27, including
    // a pop on FRAME26. A pop on FRAME27 still cannot change that old-value test.
    wire dq_room_next=dq_commit && !dq_pop ? dq_count<DQ_DEPTH-1 :
        dq_pop && !dq_commit ? 1'b1 : dq_room;
    (* preserve=1, dont_merge=1 *) reg legacy_permission, fragment_permission;
    wire prepare_permission=op[2] && phase==STEP_PREPARE-1 && !sequence_reject && deliver_allowed && dq_room_next;
    always @(posedge clk) begin
        if(reset) begin legacy_permission<=0;fragment_permission<=0;end
        else begin
            legacy_permission<=prepare_permission && !fragmented;
            fragment_permission<=prepare_permission && fragmented;
        end
    end
    wire fragment_accept=fragment_permission && reassembly_result_valid && reassembly_ok;
    wire admission_next=legacy_permission || fragment_accept;
    always @(posedge clk) begin
        if(reset) begin
            map_capture_command<=0;frame_ram_command<=0;state_write_command<=0;age_write_command<=0;
            reassembly_query<=0;reassembly_cancel<=0;reassembly_reserve<=0;
            reassembly_query_bank<=0;reassembly_cancel_bank<=0;reassembly_reserve_bank<=0;
            queue_command<=0;write_saved_rm<=0;admission_room<=0;
        end else begin
            map_capture_command<=op[2] && phase==4;
            frame_ram_command<=op[2] && phase==5;
            state_write_command<=op[2] && (phase==STEP_WRITE-1 || (phase==14 && sequence_reject));
            age_write_command<=op[3] && phase==4;
            reassembly_query<=frame_ram_command && selected_map[12] && fragmented;
            reassembly_query_bank<={2{frame_ram_command && selected_map[12] && fragmented}};
            reassembly_cancel<=op[2] && (phase==STEP_FINISH-1 ||
                (phase==7 && map_missing) || (phase==12 && config_reject));
            reassembly_cancel_bank<={2{op[2] && (phase==STEP_FINISH-1 ||
                (phase==7 && map_missing) || (phase==12 && config_reject))}};
            queue_command<=admission_next;
            reassembly_reserve<=fragment_accept;
            reassembly_reserve_bank<={2{fragment_accept}};
            write_saved_rm<=admission_next && saved_cfg[4];
            admission_room<=admission_next;
        end
    end
    always @(posedge clk) begin
        if(reset) saved_map<=0;
        else if(map_capture_command) saved_map<=map_q;
    end
    always @(posedge clk) begin
        if (reset) begin
            delivery_phase <= 0;
            result_map_phase <= 0;
            result_config_phase <= 0;
            result_sequence_phase <= 0;
        end
        else begin
            delivery_phase <= op[2] && phase == STEP_DELIVER - 1 && !sequence_reject;
            result_map_phase <= op[2] && phase == 6;
            result_config_phase <= op[2] && phase == 11;
            result_sequence_phase <= op[2] && phase == 13;
        end
    end
    // dq_room 随计数同步寄存，队列满的常数比较不再进入交付写使能锥。
`ifndef MODEL_TECH
    reg dq_room;
`endif
    wire [125:0] frag_meta = current_desc[RX_RING_AW + 208:RX_RING_AW + 83];
`ifndef MODEL_TECH
    wire fragmented = frame_fragmented;
`else
    assign fragmented = frame_fragmented;
`endif
    // FRAME6 registers query; external Q0 is FRAME7. Query19 returns at
    // FRAME26, decision registers at 27, atomic acceptance28/write29/finish30.
    assign reassembly_meta = frag_meta;
    assign reassembly_vl = query_vl;
    assign reassembly_length = length;
    assign reassembly_sport = current_desc[RX_RING_AW + 58:RX_RING_AW + 43];
    assign reassembly_dport = current_desc[RX_RING_AW + 42:RX_RING_AW + 27];
    assign reassembly_net = op_net;
    wire dq_put=queue_command;
    wire [DQ_WIDTH - 1:0] dq_input = { fragmented, reassembly_slot, op_net, current_desc[RX_RING_AW + 15:16], length, dq_idx,
        current_desc[RX_RING_AW + 58:RX_RING_AW + 43], current_desc[RX_RING_AW + 42:RX_RING_AW + 27] };

    // 相位标志互斥；结果分别在 phase=7/12/14/28 登记。
    always @(posedge clk) begin
        if (reset) result <= RX_ACCEPTED;
        else if (result_map_phase && map_missing) result <= RX_UNMAPPED;
        else if (result_config_phase && config_reject) result <= RX_CONFIG_REJECT;
        else if (result_sequence_phase && sequence_reject) result <= RX_BAD_SEQUENCE;
        else if (delivery_phase) begin
            if (!deliver_allowed) result <= RX_DUPLICATE;
            else if (!admission_room) result <= RX_QUEUE_FULL;
            else result <= RX_ACCEPTED;
        end
    end

`ifndef MODEL_TECH
    wire age_tick;
`endif
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

    // Predict the SAME edge's updated mode and quiet state. Standalone CE
    // remains combinational. Core init_done is itself predictable and remains
    // low on engine INIT exit, so that branch cannot grant a core config write.
    wire cfg_mode_next=(op[1] && !frame_start_q) || op[3] ||
        (op[2] && phase==STEP_FINISH) || (!CORE_ENABLE_PREDICT && op[0] && init_flush);
    always @(posedge clk) begin
        if(reset) desc_quiet_copy<=0;
        else desc_quiet_copy<={DESC_COPIES{cfg_mode_next && (!CORE_ENABLE_PREDICT || core_enable_next)}}
            & ~(desc_a_valid | desc_b_valid);
    end

    localparam DQ_WRITE_SLICES = (DQ_WIDTH + 23) / 24;
`ifndef MODEL_TECH
    reg dq_commit;
`endif
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
    // FRAME/10、AGE/3 装载：吸收局部读命令、RAM、局部返回三级。
    // FRAME 拒绝后不装载；AGE/2 若被新帧中断则不产生下一拍装载。
    (* preserve = 1, dont_merge = 1 *) reg load_saved_q, write_saved_a, write_saved_b;
    always @(posedge clk) begin
        if (reset) begin
            load_saved_q <= 0;
            write_saved_a <= 0;
            write_saved_b <= 0;
        end
        else begin
            load_saved_q <= (op[2] && phase == 9 && !map_missing)
                || (op[3] && phase == 2 && !desc_a_valid[0] && !desc_b_valid[0]);
            write_saved_a <= op[2] && phase == 12 && !config_reject && saved_cfg[3] && !op_net;
            write_saved_b <= op[2] && phase == 12 && !config_reject && saved_cfg[3] && op_net;
        end
    end
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
            dq_commit<=dq_put;dq_room<=dq_room_next;
            dq_wa<=wr_ptr;dq_wd<=dq_input;
            if(dq_put) wr_ptr<=wr_ptr+1'b1;
            // dq_count 在消息信息实际写入的那一拍增加，dq_room 同步记录是否还有空位。
            case ({ dq_commit, dq_pop })
                2'b10 : begin
                    dq_count <= dq_count + 1'b1;
                end
                2'b01 : begin
                    dq_count <= dq_count - 1'b1;
                end
                default : ;
            endcase
        end
    end

    always @(posedge clk) begin
        if(reset) begin cfg_re<=0;state_re<=0;state_we<=0;end
        else begin
            cfg_re<=frame_ram_command && selected_map[12];
            state_re<=(frame_ram_command && selected_map[12]) || start_age;
            state_we<=(op[0] && !init_flush) || (state_write_command && state_changed) ||
                (age_write_command && op[3] && saved_state[24] && age_expired && !desc_a_valid[0] && !desc_b_valid[0]);
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
            dq_idx <= 0;
            op_net <= 0;
            take_a <= 0;
            take_b <= 0;
            resolve_a <= 0;
            resolve_b <= 0;
            commit_a <= 0;
            commit_b <= 0;
            cfg_ra <= 0;
            state_ra <= 0;
            state_wa <= 0;
            state_wd <= 0;
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
            // Address/data run freely; only state_we authorizes a write. AGE
            // preemption no longer enables these wide registers remotely.
            cfg_ra<=selected_map[11:0];
            state_ra<=frame_ram_command ? selected_map[11:0] : age_ptr;
            state_wa<=op[0] ? init_ptr : op_idx;
            state_wd<=op[0] ? 43'b0 : op[3] ? {saved_state[42:25],1'b0,saved_state[23:0]} : saved_state;
            // 时间基准直接给出同拍变化脉冲；独立模块保持外部 now_c_value 比较语义。
            if (age_tick) age_pending <= 1;
            take_a <= 0;
            take_b <= 0;
            resolve_a <= 0;
            resolve_b <= 0;
            commit_a <= 0;
            commit_b <= 0;
            ev_a <= EV_NONE;
            ev_b <= EV_NONE;
            ev_rm_drop <= 0;
            ev_deliver <= 0;
            // Local work commands carry both operation and phase. The wide
            // fields no longer put binary/global mode decoding on their holds.
            if(frame_ram_command) begin map_missing<=!selected_map[12];op_idx<=selected_map[11:0];dq_idx<=selected_map[11:0];end
            if(age_start_q) begin op_idx<=age_pointer_snapshot;age_time<=age_time_snapshot;end
            if(frame_work_commands[0]) begin
                saved_cfg<=cfg_q;psn<=op_net ? state_q[32:25] : state_q[41:34];
                psn_valid<=op_net ? state_q[33] : state_q[42];
            end
            if(frame_work_commands[1]) begin
                config_reject<=!saved_cfg[0] || !(op_net ? saved_cfg[2] : saved_cfg[1]) ||
                    (frame_later ? {1'b0,length}>({1'b0,saved_cfg[27:17]}+12'd8) : length>saved_cfg[27:17]);
                next_sn<=psn==SN_MAX ? SN_FIRST : psn+1'b1;
                elapsed<=arrival-saved_state[15:0];raw_distance<={1'b0,sn}-{1'b0,saved_state[23:16]};
            end
            if(frame_work_commands[2]) begin
                if(elapsed[15]) elapsed<=-elapsed;
                second_sn<=next_sn==SN_MAX ? SN_FIRST : next_sn+1'b1;
                forward_distance<=raw_distance[8] ? raw_distance+SN_RANGE : raw_distance;
            end
            if(frame_work_commands[3]) begin
                sequence_reject<=saved_cfg[3] && psn_valid && sn!=0 && sn!=next_sn && sn!=second_sn;
                if(saved_cfg[3]) state_changed<=1;
                skew_expired<=elapsed>saved_cfg[16:5];sn_match<=sn==saved_state[23:16];
                zero_shortcut<=sn==0 || saved_state[23:16]==0;
                forward_ok<=forward_distance>=1 && forward_distance<=SN_HALF_RANGE;
            end
            if(frame_work_commands[4]) begin
                if(!saved_cfg[4] || !saved_state[24] || skew_expired) deliver_allowed<=1;
                else if(sn_match) deliver_allowed<=0;
                else if(zero_shortcut) deliver_allowed<=1;
                else deliver_allowed<=forward_ok;
            end
            case (1'b1)

                // INIT：把 4096 项接收状态置零，写完后转 IDLE。
                op[0] : if ( ! init_flush) begin
                    init_ptr <= init_ptr + 1'b1;
                    if (init_ptr == LAST_VL) init_flush <= 1;
                end
                else begin
                    initialized <= 1;
                    op <= IDLE;
                end

                // IDLE：有帧时转 FRAME；无帧且需检查旧记录时转 AGE。
                op[1] : if(frame_start_q) begin
                    op<=FRAME;phase<=1;
                end else if(age_start_q) begin
                    if(desc_a_valid[0] || desc_b_valid[0]) op<=IDLE;
                    else begin op<=AGE;phase<=1;end
                end else if(start_frame) begin
                        // 两网同时提交时先处理 A 网。
                        op_net <= ! desc_a_valid[0];
                        take_a <= desc_a_valid[0];
                        take_b <= ! desc_a_valid[0];
                        state_changed <= 0;
                        deliver_allowed <= 0;
                        op <= IDLE;
                        phase <= 0;
                end

                // FRAME runs on every clock, independent of idle enable.
                // 5 map snapshot; 6 cfg/state and registered query;
                // external Q0=7; 10 local RAM return; 11/12 arithmetic;
                // 13 IC; 14 RM; query result26; decision27;
                // 28 atomic admission; 29 physical bank/DQ writes; 30 finish.
                op[2] : begin
                    phase <= phase + 1'b1;
                    case (phase)

                        7 : if(map_missing) phase<=STEP_FINISH;
                        12 : if(config_reject) phase<=STEP_FINISH;
                        14 : if(sequence_reject) phase<=STEP_WRITE;

                        STEP_DELIVER : begin
                            if (deliver_allowed && admission_room && saved_cfg[4]) state_changed <= 1;
                        end

                        STEP_WRITE : ; // local command owns state_we

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
                // phase=3：保存局部 RAM 返回；phase=4：分段时间差。
                // phase=5：使过期记录失效，主状态转 IDLE。
                op[3] : begin
                    // 有新帧到来时，模块放下这次检查先去处理帧，之后再重新检查这一项。
                    // 记录保存超过 0x4000 个计时单位（约 0.54 秒）就失效。
                    if (desc_a_valid[0] || desc_b_valid[0]) op <= IDLE;
                    else begin
                        phase <= phase + 1'b1;
                        case (phase)
                            1 : ;
                            2 : ; // 分段时间差在独立寄存器中完成。
                            5 : begin
                                age_ptr <= age_ptr + 1'b1;
                                age_pending <= age_tick;
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
