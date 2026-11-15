// AFDX 接收过滤与冗余管理引擎：判定接收帧是否允许交付应用，并在双网间执行重复帧去重。
// 接收 A/B 两路解析器提交的完整帧描述符，校验通过后写入交付队列交由 afdx_rx_deliver 输出。
//   完整性检查（IC）：按帧序号判断同一网络上的接收帧是否连续
//   冗余管理（RM）  ：对双网到达的同一帧仅保留先到的一份
//   虚拟链路（VL）  ：将一组报文映射至同一接收配置表项
module afdx_rx_engine #(
    parameter RX_RING_AW = 12,
    RX_DQ_AW             = 5,
    LOCAL_MAP_READ       = 0,
    REGISTERED_TIME_TICK = 0,
    LOCAL_QUEUE_WRITE    = 0,
    DESC_COPIES          = 1,
    CORE_ENABLE_PREDICT  = 0
) (
    // enable 为高时允许引擎处理帧，now_c 为粗粒度时间基准，initialized 为高表示状态表清零完成。
    input  wire                          clk, reset, enable,
    // REGISTERED_TIME_TICK 为 1 时，now_c 最高位（第 16 位）携带同拍跳变脉冲；默认端口位宽与位置不变。
    input  wire [15 + REGISTERED_TIME_TICK:0] now_c,
    output reg                           initialized,

    // desc_a/b_* 传入完整帧描述符，take_a/b 确认取走；resolve_a/b 有效时，commit_a/b 决定保留或释放缓存。
    input  wire [DESC_COPIES - 1:0]      desc_a_valid, desc_b_valid,
    input  wire [RX_RING_AW + 208:0]     desc_a, desc_b,
    output reg                           take_a, take_b, resolve_a, resolve_b, commit_a, commit_b,

    // map_* 将线路 VL 编号映射为配置索引；cfg_* 读取接收配置，state_* 读写该 VL 的接收状态。
    output wire [DESC_COPIES - 1:0]      map_re,
    output wire [DESC_COPIES * 16 - 1:0] map_ra,
    input  wire [12:0]                   map_q,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *)
    output reg                           cfg_re,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *)
    output reg  [11:0]                   cfg_ra,
    input  wire [31:0]                   cfg_q,
    (* preserve = 1, dont_merge = 1 *)
    output reg                           state_re, state_we,
    (* preserve = 1, dont_merge = 1 *)
    output reg  [11:0]                   state_ra, state_wa,
    (* preserve = 1, dont_merge = 1, maxfan = 32 *)
    output reg  [42:0]                   state_wd,
    input  wire [42:0]                   state_q,

    // dq_we 为高时将 dq_wd 写入交付队列 dq_wa；dq_pop 表示下游读走一项，dq_count 为当前队列项数。
    input  wire                          dq_pop,
    (* preserve = 1, dont_merge = 1 *)
    output reg  [(LOCAL_QUEUE_WRITE ? 32 * ((RX_RING_AW + 84) / 24) : 1) - 1:0] dq_we,
    output reg  [RX_DQ_AW - 1:0]         dq_wa,
    output reg  [RX_RING_AW + 60:0]      dq_wd,
    input  wire                          reassembly_result_valid, reassembly_ok,
    input  wire [3:0]                    reassembly_slot,
    output reg                           reassembly_query, reassembly_cancel, reassembly_reserve,
    (* preserve = 1, dont_merge = 1 *)
    output reg  [1:0]                    reassembly_query_bank, reassembly_cancel_bank, reassembly_reserve_bank,
    output wire [125:0]                  reassembly_meta,
    output wire [11:0]                   reassembly_vl,
    output wire [10:0]                   reassembly_length,
    output wire [15:0]                   reassembly_sport, reassembly_dport,
    output wire                          reassembly_net,
    output reg  [RX_DQ_AW:0]             dq_count,

    // ev_a/b 上报各网的校验失败或队列满事件；ev_rm_drop 表示冗余丢帧，ev_deliver 表示报文被接纳交付。
    output reg  [7:0]                    ev_a, ev_b,
    output reg                           ev_rm_drop, ev_deliver,

    // cfg_ok 为高时表示当前无在途处理帧，允许外部写入接收配置。
    output wire [DESC_COPIES - 1:0]      cfg_ok,
    // 仅限 afdx_rx_core 内部使用的时钟沿后 init_done 预测信号：在引擎退出 INIT 状态的时钟沿前
    // 始终保持为低；单独例化本模块时默认直接使用当拍 enable。
    input  wire                          core_enable_next
);

    // ModelSim 要求信号先声明后引用；综合分支保持原声明位置以固定网表与布局锚点。
`ifdef MODEL_TECH
    (* preserve = 1, dont_merge = 1 *) reg frame_start_q, age_start_q;
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
    localparam [3:0] INIT = 4'b0001, IDLE = 4'b0010, FRAME = 4'b0100, AGE = 4'b1000;

    // 接收虚拟链路共 4096 条，LAST_VL 为末条配置索引。
    localparam LAST_VL = 4095;

    // 帧序号在 1～255 间循环（255 之后回到 1，周期为 255）；
    // 新序号领先上一序号不超过半圈（127）时判定为有效新帧。
    localparam SN_MAX = 255, SN_FIRST = 8'd1, SN_RANGE = 9'd255, SN_HALF_RANGE = 127;

    // 距上次接纳超过该粗粒度时间阈值（每单位 4096 拍）未见新帧时，清除冗余去重记录。
    localparam AGE_LOW_BITS = 14;
    localparam [1:0] AGE_LIMIT_HIGH = 1;
    reg age_low_borrow, age_low_equal;
    reg [1:0] age_high_difference;
    // 等效 0x4000 老化阈值：将低位借位/相等标志与高两位差值并行寄存后比较。
    wire age_expired = age_low_borrow ? age_high_difference != AGE_LIMIT_HIGH
        : (age_high_difference > AGE_LIMIT_HIGH || (age_high_difference == AGE_LIMIT_HIGH && !age_low_equal));

    // 帧处理流程最后四步相位：准入预备、登记交付、状态写回、结果收尾。
    localparam [4:0] STEP_PREPARE = 5'd27, STEP_DELIVER = 5'd28, STEP_WRITE = 5'd29, STEP_FINISH = 5'd30;
    // 采用显式独热码状态编码，避免二进制状态反馈跨区扇出至全部下游逻辑；
    // 宽位操作改为由本地预译码命令驱动。
    (* preserve = 1, dont_merge = 1, syn_encoding = "user", fsm_encoding = "none" *) reg [3:0] op;

    // 分块映射表在本拍各自寄存请求，替代跨整个存储区的共享地址寄存器；
    // 独立例化本模块时仍保留原来的一拍请求接口。
    genvar map_copy;

    generate
        if (LOCAL_MAP_READ) begin : local_map
            // 仅读取已提交的帧描述符，避免空闲投机读与配置写同址相撞；各目标使用独立的有效位副本。
            for (map_copy = 0; map_copy < DESC_COPIES; map_copy = map_copy + 1) begin : target
                (* preserve = 1, dont_merge = 1 *) reg source_request;

                always @(posedge clk) begin
                    if (reset) source_request <= 0;
                    // 协议引擎忙时，挂起中的描述符仍可按映射表地址重读，并在 FRAME5 拍锁存初次返回结果；
                    // 受空闲门控的配置写总会在下次首次读之前完成，若无有效描述符则配置期间不发起投机读。
                    else source_request <= initialized && (desc_a_valid[map_copy] || desc_b_valid[map_copy]);
                end
                assign map_re[map_copy] = source_request;

                // 用本地源端地址寄存器替代各映射分块内部的首级地址寄存器，
                // 各 RAM 端口级寄存器在下一拍直接采样该地址。
                (* preserve = 1, dont_merge = 1 *) reg [15:0] source_address;
                always @(posedge clk) source_address <= desc_a_valid[map_copy]
                    ? desc_a[RX_RING_AW + 82:RX_RING_AW + 67] : desc_b[RX_RING_AW + 82:RX_RING_AW + 67];
                assign map_ra[map_copy * 16+:16] = source_address;
            end
        end
        else begin : registered_map
            // 独立例化接口保留原 enable 条件。
            wire map_start = !reset && op[1] && !frame_start_q && !age_start_q
                && enable && (desc_a_valid[0] || desc_b_valid[0]);
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

    // 每个配置副本使用独立的描述符有效位，避免同一组合逻辑 cfg_ok 信号横跨全部 RAM 分块。
    // cfg_ok 在同拍预测 IDLE/AGE 空闲态（核心内同步预测初始化许可，独立例化时仍保留组合 enable 门控）；
    // 不推迟真实配置受理沿，desc_valid 拉高当拍仍可按原协议完成写入。
    (* preserve = 1, dont_merge = 1 *) reg [DESC_COPIES - 1:0] desc_quiet_copy;
    genvar ready_copy;
    generate
        for (ready_copy = 0; ready_copy < DESC_COPIES; ready_copy = ready_copy + 1) begin : config_ready
            assign cfg_ok[ready_copy] = CORE_ENABLE_PREDICT ? desc_quiet_copy[ready_copy]
                : (enable && desc_quiet_copy[ready_copy]);
        end
    endgenerate

    // phase 将单帧检查拆分为多拍执行，op_idx 保存当前检查的配置索引。
    // saved_cfg 为当前 VL 的接收配置：
    //   [0]     ：VL 使能位；[1]/[2] 分别允许接收 A/B 网报文
    //   [3]/[4] ：分别使能完整性检查（IC）与冗余管理（RM）
    //   [16:5]  ：双网允许的最大到达时间差 SkewMax，单位 4096 拍（32.768 µs）
    //   [27:17] ：允许的最大帧长（字节）
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg [4:0] phase;
    reg [11:0] init_ptr, age_ptr;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] op_idx, dq_idx;
    reg init_flush, op_net, state_changed, deliver_allowed, age_pending;
    // desc_quiet 寄存上一拍“无待处理帧”状态，使 AGE 入口与状态装载使能不再直接串接远端 desc_valid 连线。
    (* preserve = 1, dont_merge = 1 *) reg desc_quiet;
    // 第 13 拍先行寄存第 14 拍所需的比较结论，交付判定逻辑不再串接宽位比较器。
    reg skew_expired, sn_match, zero_shortcut, forward_ok;
    reg map_missing, config_reject, sequence_reject;
    reg [RX_RING_AW + 208:0] current_desc;
    (* preserve = 1, dont_merge = 1 *) reg [RX_RING_AW + 208:0] descriptor_snapshot_a, descriptor_snapshot_b;
`ifndef MODEL_TECH
    (* preserve = 1, dont_merge = 1 *) reg frame_start_q, age_start_q;
`endif
    reg [15:0] age_time_snapshot;
    reg [11:0] age_pointer_snapshot;
    wire start_age = op[1] && !frame_start_q && !age_start_q && enable && desc_quiet
        && (age_pending || age_tick) && !desc_a_valid[0] && !desc_b_valid[0];
    reg frame_fragmented, frame_later;
    wire start_frame = op[1] && !frame_start_q && !age_start_q && enable && (desc_a_valid[0] || desc_b_valid[0]);
    localparam DESC_WIDTH = RX_RING_AW + 209, DESC_GROUPS = (DESC_WIDTH + 23) / 24;
    (* preserve = 1, dont_merge = 1 *) reg [1:0] fragment_snapshot_a, fragment_snapshot_b;
    always @(posedge clk) begin
        descriptor_snapshot_a <= desc_a;
        descriptor_snapshot_b <= desc_b;
        // 在描述符快照捕获沿同步完成单网分片标志归约，下一拍只需二选一本地寄存标志。
        fragment_snapshot_a <= {|desc_a[RX_RING_AW+128:RX_RING_AW+116],
            |desc_a[RX_RING_AW+128:RX_RING_AW+115]};
        fragment_snapshot_b <= {|desc_b[RX_RING_AW+128:RX_RING_AW+116],
            |desc_b[RX_RING_AW+128:RX_RING_AW+115]};
        age_time_snapshot <= now_c_value;
        age_pointer_snapshot <= age_ptr;
        if (reset) begin
            frame_start_q <= 0;
            age_start_q <= 0;
            frame_fragmented <= 0;
            frame_later <= 0;
        end
        else begin
            frame_start_q <= start_frame;
            age_start_q <= start_age;
            if (frame_start_q) begin
                frame_fragmented <= op_net ? fragment_snapshot_b[0] : fragment_snapshot_a[0];
                frame_later <= op_net ? fragment_snapshot_b[1] : fragment_snapshot_a[1];
            end
        end
    end
    genvar descriptor_group;
    generate
        for (descriptor_group = 0; descriptor_group < DESC_GROUPS;
                descriptor_group = descriptor_group + 1) begin : frame_capture
            localparam GROUP_WIDTH = (DESC_WIDTH - descriptor_group * 24 >= 24)
                ? 24 : DESC_WIDTH - descriptor_group * 24;
            (* preserve = 1, dont_merge = 1 *) reg load, selected_net;
            always @(posedge clk) begin
                selected_net <= !desc_a_valid[0];
                if (reset) begin
                    load <= 0;
                    current_desc[descriptor_group*24+:GROUP_WIDTH] <= 0;
                end
                else begin
                    load <= start_frame;
                    if (load) current_desc[descriptor_group*24+:GROUP_WIDTH] <= selected_net
                        ? descriptor_snapshot_b[descriptor_group*24+:GROUP_WIDTH]
                        : descriptor_snapshot_a[descriptor_group*24+:GROUP_WIDTH];
                end
            end
        end
    endgenerate

    // 仅在第 5 拍（phase == 5）锁存一次映射表读回数据；后续请求统一使用该本地帧快照，
    // 不再直接引用远端 RAM 输出。
    (* preserve = 1, dont_merge = 1 *) reg [12:0] saved_map;
    wire [12:0] selected_map = saved_map;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] query_vl;
    always @(posedge clk) query_vl <= selected_map[11:0];
    reg [31:0] saved_cfg;

    // saved_state 位域定义：
    //   [42]    ：A 网上一序号有效标志，[41:34] 为 A 网上一序号
    //   [33]    ：B 网上一序号有效标志，[32:25] 为 B 网上一序号
    //   [24]    ：冗余去重历史有效标志，[23:16] 为最近交付序号，[15:0] 为该帧到达时刻
    reg [42:0] saved_state;

    // age_ptr 轮询扫描历史记录，age_pending 锁存待处理的老化检查请求；elapsed 为双网同帧到达时间差。
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

    // 检查通过且交付队列未满时写入交付信息；队列满时不更新最近交付序号。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg delivery_phase;
    // 提前一拍寄存结果写入相位，拒绝标志仍在原判定拍取值；
    // 结果寄存器使能与数据选择均不再直接译码远端 op/phase。
    (* preserve = 1, dont_merge = 1 *) reg result_map_phase, result_config_phase, result_sequence_phase;
    (* preserve = 1, dont_merge = 1 *)
    reg map_capture_command, frame_ram_command, state_write_command, age_write_command;
    (* preserve = 1, dont_merge = 1 *) reg queue_command, write_saved_rm, admission_room;
    (* preserve = 1, dont_merge = 1 *) reg [4:0] frame_work_commands;
    always @(posedge clk) begin
        if (reset) frame_work_commands <= 0;
        else begin
            frame_work_commands[0] <= op[2] && phase == 9;
            frame_work_commands[1] <= op[2] && phase == 10;
            frame_work_commands[2] <= op[2] && phase == 11;
            frame_work_commands[3] <= op[2] && phase == 12 && !config_reject;
            frame_work_commands[4] <= op[2] && phase == 13;
        end
    end

    // 在 FRAME26 拍精确预测 FRAME27 拍可见的队列余量（计入 FRAME26 当拍弹出，
    // 而 FRAME27 当拍弹出按原时序不参与该旧值判据）。
    wire dq_room_next = dq_commit && !dq_pop ? dq_count < DQ_DEPTH - 1 :
        dq_pop && !dq_commit ? 1'b1 : dq_room;
    (* preserve = 1, dont_merge = 1 *) reg legacy_permission, fragment_permission;
    wire prepare_permission = op[2] && phase == STEP_PREPARE - 1
        && !sequence_reject && deliver_allowed && dq_room_next;
    always @(posedge clk) begin
        if (reset) begin
            legacy_permission <= 0;
            fragment_permission <= 0;
        end
        else begin
            legacy_permission <= prepare_permission && !fragmented;
            fragment_permission <= prepare_permission && fragmented;
        end
    end
    wire fragment_accept = fragment_permission && reassembly_result_valid && reassembly_ok;
    wire admission_next = legacy_permission || fragment_accept;
    always @(posedge clk) begin
        if (reset) begin
            map_capture_command <= 0;
            frame_ram_command <= 0;
            state_write_command <= 0;
            age_write_command <= 0;
            reassembly_query <= 0;
            reassembly_cancel <= 0;
            reassembly_reserve <= 0;
            reassembly_query_bank <= 0;
            reassembly_cancel_bank <= 0;
            reassembly_reserve_bank <= 0;
            queue_command <= 0;
            write_saved_rm <= 0;
            admission_room <= 0;
        end
        else begin
            map_capture_command <= op[2] && phase == 4;
            frame_ram_command <= op[2] && phase == 5;
            state_write_command <= op[2] && (phase == STEP_WRITE - 1 || (phase == 14 && sequence_reject));
            age_write_command <= op[3] && phase == 4;
            reassembly_query <= frame_ram_command && selected_map[12] && fragmented;
            reassembly_query_bank <= {2{frame_ram_command && selected_map[12] && fragmented}};
            reassembly_cancel <= op[2] && (phase == STEP_FINISH - 1 ||
                (phase == 7 && map_missing) || (phase == 12 && config_reject));
            reassembly_cancel_bank <= {2{op[2] && (phase == STEP_FINISH - 1 ||
                (phase == 7 && map_missing) || (phase == 12 && config_reject))}};
            queue_command <= admission_next;
            reassembly_reserve <= fragment_accept;
            reassembly_reserve_bank <= {2{fragment_accept}};
            write_saved_rm <= admission_next && saved_cfg[4];
            admission_room <= admission_next;
        end
    end

    always @(posedge clk) begin
        if (reset) saved_map <= 0;
        else if (map_capture_command) saved_map <= map_q;
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

    // dq_room 随队列计数同步寄存，使队列满比较逻辑脱离交付写使能路径。
`ifndef MODEL_TECH
    reg dq_room;
`endif
    wire [125:0] frag_meta = current_desc[RX_RING_AW + 208:RX_RING_AW + 83];
`ifndef MODEL_TECH
    wire fragmented = frame_fragmented;
`else
    assign fragmented = frame_fragmented;
`endif
    // FRAME6 拍寄存发出重组查询，对应外部 Q0（FRAME7）；经 19 拍于 Query19（FRAME26）返回，
    // FRAME27 拍寄存准入判决，FRAME28 原子接纳，FRAME29 写入重组分块与 DQ，FRAME30 收尾结束。
    assign reassembly_meta = frag_meta;
    assign reassembly_vl = query_vl;
    assign reassembly_length = length;
    assign reassembly_sport = current_desc[RX_RING_AW + 58:RX_RING_AW + 43];
    assign reassembly_dport = current_desc[RX_RING_AW + 42:RX_RING_AW + 27];
    assign reassembly_net = op_net;
    wire dq_put = queue_command;
    wire [DQ_WIDTH - 1:0] dq_input = {fragmented, reassembly_slot, op_net,
        current_desc[RX_RING_AW + 15:16], length, dq_idx,
        current_desc[RX_RING_AW + 58:RX_RING_AW + 43],
        current_desc[RX_RING_AW + 42:RX_RING_AW + 27]};

    // 各相位标志互斥；检查结果分别于 phase == 7/12/14/28 登记。
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

    // 在本拍预测同一时钟沿更新后的工作模式与空闲态（独立例化时 cfg_ok 仍保留组合 enable 门控）；
    // 核心 init_done 本身在引擎退出 INIT 的时钟沿仍保持为低，确保该分支不会误授权核心配置写。
    wire cfg_mode_next = (op[1] && !frame_start_q) || op[3] ||
        (op[2] && phase == STEP_FINISH) || (!CORE_ENABLE_PREDICT && op[0] && init_flush);
    always @(posedge clk) begin
        if (reset) desc_quiet_copy <= 0;
        else desc_quiet_copy <= {DESC_COPIES{cfg_mode_next && (!CORE_ENABLE_PREDICT || core_enable_next)}}
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

    // RAM 捕获与三种字段更新互斥，按字段直接选通，避免 RAM 输出穿过多层整字优先级：
    // FRAME 第 10 拍、AGE 第 3 拍装载（吸收局部读命令、RAM、局部返回三级）；
    // FRAME 拒绝后不装载；AGE 第 2 拍若被新帧抢占则取消下一拍装载。
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
            dq_commit <= dq_put;
            dq_room <= dq_room_next;
            dq_wa <= wr_ptr;
            dq_wd <= dq_input;
            if (dq_put) wr_ptr <= wr_ptr + 1'b1;
            // dq_count 在描述符实际写入交付队列的当拍更新，dq_room 同步指示是否仍有空位。
            case ({dq_commit, dq_pop})
                2'b10: begin
                    dq_count <= dq_count + 1'b1;
                end
                2'b01: begin
                    dq_count <= dq_count - 1'b1;
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            cfg_re <= 0;
            state_re <= 0;
            state_we <= 0;
        end
        else begin
            cfg_re <= frame_ram_command && selected_map[12];
            state_re <= (frame_ram_command && selected_map[12]) || start_age;
            state_we <= (op[0] && !init_flush) || (state_write_command && state_changed)
                || (age_write_command && op[3] && saved_state[24]
                    && age_expired && !desc_a_valid[0] && !desc_b_valid[0]);
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
            // 地址与写数据随拍自由推进，仅靠 state_we 脉冲控制实际写入；
            // 老化抢占不再跨区门控这些宽位数据寄存器的使能端。
            cfg_ra <= selected_map[11:0];
            state_ra <= frame_ram_command ? selected_map[11:0] : age_ptr;
            state_wa <= op[0] ? init_ptr : op_idx;
            state_wd <= op[0] ? 43'b0 : op[3] ? {saved_state[42:25], 1'b0, saved_state[23:0]} : saved_state;
            // 时间基准直接提供同拍跳变脉冲；独立例化时保持对外部 now_c_value 的变化沿检测语义。
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
            // 本地工作命令同时携带操作码与相位译码信息，
            // 宽位数据字段的保持路径不再引入二进制相位或全局模式译码。
            if (frame_ram_command) begin
                map_missing <= !selected_map[12];
                op_idx <= selected_map[11:0];
                dq_idx <= selected_map[11:0];
            end
            if (age_start_q) begin
                op_idx <= age_pointer_snapshot;
                age_time <= age_time_snapshot;
            end
            if (frame_work_commands[0]) begin
                saved_cfg <= cfg_q;
                psn <= op_net ? state_q[32:25] : state_q[41:34];
                psn_valid <= op_net ? state_q[33] : state_q[42];
            end
            if (frame_work_commands[1]) begin
                config_reject <= !saved_cfg[0] || !(op_net ? saved_cfg[2] : saved_cfg[1])
                    || (frame_later
                        ? {1'b0, length} > ({1'b0, saved_cfg[27:17]} + 12'd8)
                        : length > saved_cfg[27:17]);
                next_sn <= psn == SN_MAX ? SN_FIRST : psn + 1'b1;
                elapsed <= arrival - saved_state[15:0];
                raw_distance <= {1'b0, sn} - {1'b0, saved_state[23:16]};
            end
            if (frame_work_commands[2]) begin
                if (elapsed[15]) elapsed <= -elapsed;
                second_sn <= next_sn == SN_MAX ? SN_FIRST : next_sn + 1'b1;
                forward_distance <= raw_distance[8] ? raw_distance + SN_RANGE : raw_distance;
            end
            if (frame_work_commands[3]) begin
                sequence_reject <= saved_cfg[3] && psn_valid && sn != 0 && sn != next_sn && sn != second_sn;
                if (saved_cfg[3]) state_changed <= 1;
                skew_expired <= elapsed > saved_cfg[16:5];
                sn_match <= sn == saved_state[23:16];
                zero_shortcut <= sn == 0 || saved_state[23:16] == 0;
                forward_ok <= forward_distance >= 1 && forward_distance <= SN_HALF_RANGE;
            end
            if (frame_work_commands[4]) begin
                if (!saved_cfg[4] || !saved_state[24] || skew_expired) deliver_allowed <= 1;
                else if (sn_match) deliver_allowed <= 0;
                else if (zero_shortcut) deliver_allowed <= 1;
                else deliver_allowed <= forward_ok;
            end
            case (1'b1)

                // INIT：将 4096 项 VL 接收状态清零，写完后转入 IDLE。
                op[0]: if (!init_flush) begin
                    init_ptr <= init_ptr + 1'b1;
                    if (init_ptr == LAST_VL) init_flush <= 1;
                end
                else begin
                    initialized <= 1;
                    op <= IDLE;
                end

                // IDLE：有待处理帧时转入 FRAME；无待处理帧且需老化扫描时转入 AGE。
                op[1]: if (frame_start_q) begin
                    op <= FRAME;
                    phase <= 1;
                end
                else if (age_start_q) begin
                    if (desc_a_valid[0] || desc_b_valid[0]) op <= IDLE;
                    else begin
                        op <= AGE;
                        phase <= 1;
                    end
                end
                else if (start_frame) begin
                    // 双网同拍提交描述符时优先处理 A 网。
                    op_net <= !desc_a_valid[0];
                    take_a <= desc_a_valid[0];
                    take_b <= !desc_a_valid[0];
                    state_changed <= 0;
                    deliver_allowed <= 0;
                    op <= IDLE;
                    phase <= 0;
                end

                // FRAME 主处理流程每拍逐相推进，不依赖空闲使能门控：
                //   第 5 拍锁存映射表快照；第 6 拍发起配置/状态读取与寄存重组查询；
                //   第 7 拍对应外部 Q0；第 10 拍接收本地 RAM 返回；第 11～12 拍完成长度与差值计算；
                //   第 13 拍完成完整性检查；第 14 拍完成冗余管理判决；第 26 拍收回重组查询结果；
                //   第 27 拍寄存准入判决；第 28 拍原子接纳；第 29 拍写入物理分块与 DQ；第 30 拍收尾结束。
                op[2]: begin
                    phase <= phase + 1'b1;
                    case (phase)

                        7: if (map_missing) phase <= STEP_FINISH;
                        12: if (config_reject) phase <= STEP_FINISH;
                        14: if (sequence_reject) phase <= STEP_WRITE;

                        STEP_DELIVER: begin
                            if (deliver_allowed && admission_room && saved_cfg[4]) state_changed <= 1;
                        end

                        STEP_WRITE: ; // 由本地命令脉冲直接控制 state_we 写入。

                        STEP_FINISH: begin
                            resolve_a <= !op_net;
                            resolve_b <= op_net;
                            commit_a <= !op_net && result == RX_ACCEPTED;
                            commit_b <= op_net && result == RX_ACCEPTED;
                            case (result)
                                RX_ACCEPTED: ev_deliver <= 1;
                                RX_UNMAPPED:
                                    if (op_net) ev_b <= EV_UNMAPPED;
                                    else ev_a <= EV_UNMAPPED;
                                RX_CONFIG_REJECT:
                                    if (op_net) ev_b <= EV_CONFIG_REJECT;
                                    else ev_a <= EV_CONFIG_REJECT;
                                RX_BAD_SEQUENCE:
                                    if (op_net) ev_b <= EV_BAD_SEQUENCE;
                                    else ev_a <= EV_BAD_SEQUENCE;
                                RX_DUPLICATE: ev_rm_drop <= 1;
                                RX_QUEUE_FULL:
                                    if (op_net) ev_b <= EV_QUEUE_FULL;
                                    else ev_a <= EV_QUEUE_FULL;
                                default: ;
                            endcase
                            op <= IDLE;
                        end

                        default: ;
                    endcase
                end

                // AGE：使过期去重记录失效后回到 IDLE；新帧到来时立即抢占并回到 IDLE。
                //   phase == 3：锁存局部 RAM 返回；phase == 4：分段计算时间差；
                //   phase == 5：写回清除过期记录，主状态机返回 IDLE。
                op[3]: begin
                    // 若检查期间有新帧到达，先中止本次老化并让出通道处理新帧，稍后重新检查该项；
                    // 去重记录超过 0x4000 个粗计时单位（约 0.54 秒）即判定过期。
                    if (desc_a_valid[0] || desc_b_valid[0]) op <= IDLE;
                    else begin
                        phase <= phase + 1'b1;
                        case (phase)
                            1: ;
                            2: ; // 分段老化时间差比较已在独立寄存器中完成。
                            5: begin
                                age_ptr <= age_ptr + 1'b1;
                                age_pending <= age_tick;
                                op <= IDLE;
                            end
                            default: ;
                        endcase
                    end
                end

                default: op <= INIT;
            endcase
        end
    end

endmodule
