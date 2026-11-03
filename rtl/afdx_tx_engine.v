// 本模块是发送调度器，它轮流检查每条虚拟链路的消息队列。
// 虚拟链路（Virtual Link，VL）用于给一组消息分配带宽。
// 模块通知 afdx_tx_builder 组帧，实现赛题的发送整形功能。
// BAG（Bandwidth Allocation Gap）是带宽分配间隔。
// 同一条 VL 相邻两帧的发送起点至少相隔一个 BAG。
// 队列有消息且满足时间条件时，模块才允许这条消息开始发送。
module afdx_tx_engine #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9, LOOKAHEAD = 512, PIPELINED_ENQUEUE = 0,
        COMPLETION_LOOKAHEAD = 0) (

    // enable 为高时允许调度，now 给出当前周期数。
    // initialized 为高表示状态表已初始化完成。
    input wire clk, reset, enable,
    input wire [31:0] now,
    output reg initialized,

    // cfg_* 读取当前虚拟链路的配置。
    // state_* 读写队列长度、序号和下一次允许发送的时间。
    output reg cfg_re,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg [9:0] cfg_ra,
    input wire [31:0] cfg_q,
    output reg state_we, state_re,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg [6:0] state_wa, state_ra,
    output reg [62:0] state_wd,
    input wire [62:0] state_q,

    // mnext_* 记录同一虚拟链路中下一条消息的首页。
    // desc_* 读取队首消息的长度和端口。
    (* preserve = 1, dont_merge = 1 *) output reg mnext_we, mnext_re,
    (* preserve = 1, dont_merge = 1 *) output reg [TX_PAGE_AW - 1:0] mnext_wa, mnext_ra,
    output reg [7:0] mnext_wd,
    input wire [7:0] mnext_q,
    (* preserve = 1, dont_merge = 1 *) output reg desc_re,
    (* preserve = 1, dont_merge = 1 *) output reg [TX_PAGE_AW - 1:0] desc_ra,
    input wire [46:0] desc_q,

    // enq_valid 提交一条已存好的消息。
    // enq_ack 为高时，enq_result 给出接纳或拒绝结果。
    input wire enq_valid,
    input wire [6:0] enq_vl,
    input wire [7:0] enq_head,
    input wire [13:0] enq_len,
    output reg enq_ack,
    output reg [2:0] enq_result,

    // start_valid 为高时，t_start 是首个前导字节的实际发送周期。
    input wire start_valid,
    input wire [31:0] t_start,

    // grant_valid 为高时，把选中消息的信息交给组帧模块。
    // grant_ready 表示组帧模块可以接收下一条消息。
    input wire grant_ready,
    output reg grant_valid,
    output reg grant_a, grant_b, grant_timed,
    output reg [31:0] grant_time,
    output reg [15:0] grant_vlid, grant_sport, grant_dport,
    output reg [31:0] grant_src, grant_dst,
    output reg [10:0] grant_len,
    output reg [7:0] grant_sn, grant_page,

    output reg [7:0] grant_head,
    output reg [TX_OFF_AW-1:0] grant_offset,
    output reg [12:0] grant_ip_offset,
    output reg [13:0] grant_message_len,
    output reg [15:0] grant_ident,
    output reg grant_first, grant_more,
    output reg [6:0] grant_vl_index,
    // Optional integrated current-handshake inputs. Default callers need
    // only the original registered fragment_done interface.
    input wire completion_now,
    input wire [6:0] completion_vl,
    input wire fragment_done,
    input wire [6:0] fragment_done_vl,
    input wire [7:0] fragment_done_page,
    input wire [TX_OFF_AW-1:0] fragment_done_offset,

    // cfg_ok 为高时，发送核心可以写入外部配置。
    output wire cfg_ok);
`ifdef MODEL_TECH
    reg [31:0] words[0:5];
`endif

    // 缓存端提前一拍提出请求，本拍采样后仍在原来的周期进入调度器。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg enq_sampled;
    reg [6:0] enq_vl_sampled;
    reg [7:0] enq_head_sampled;
    reg [13:0] enq_len_sampled;
    wire enq_valid_local = PIPELINED_ENQUEUE ? enq_sampled : enq_valid;
    wire [6:0] enq_vl_local = PIPELINED_ENQUEUE ? enq_vl_sampled : enq_vl;
    wire [7:0] enq_head_local = PIPELINED_ENQUEUE ? enq_head_sampled : enq_head;
    wire [13:0] enq_len_local = PIPELINED_ENQUEUE ? enq_len_sampled : enq_len;
    always @(posedge clk) begin
        if (reset) begin
            enq_sampled <= 0;
            enq_vl_sampled <= 0;
            enq_head_sampled <= 0;
            enq_len_sampled <= 0;
        end
        else begin
            enq_sampled <= enq_valid && !enq_ack;
            enq_vl_sampled <= enq_vl;
            enq_head_sampled <= enq_head;
            enq_len_sampled <= enq_len;
        end
    end

    localparam [2:0] ENQ_ACCEPTED = 3'd0;
    localparam [2:0] ENQ_DISABLED = 3'd1;
    localparam [2:0] ENQ_FULL = 3'd2;
    localparam [2:0] ENQ_TOO_LONG = 3'd3;
    localparam [2:0] INIT = 3'd0, IDLE = 3'd1, ENQ = 3'd2, GRANT = 3'd3, START = 3'd4;

    // 发送虚拟链路共 128 条，LAST_VL 是最后一条的序号。
    // 连续扫描满 SCAN_QUOTA 条后，先让等待中的新消息入队。
    localparam LAST_VL = 127;
    localparam [4:0] SCAN_QUOTA = 5'd16;

    // 帧序号用到 255 后回到 1；0 只用于复位后的第一帧。
    localparam SN_MAX = 255, SN_FIRST = 8'd1;

    // op 选择本次表操作，phase 记录操作进行到哪一拍。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg [2:0] op;
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg [3:0] phase;

    // scan_issue 是下一条要检查的虚拟链路，scan_commit 是已检查的位置。
    // candidate_vl 保存候选项，pend_vl 保存已选中但尚未发送的项。
    reg [6:0] init_ptr, scan_issue, scan_commit, op_vl, candidate_vl, pend_vl;
    reg init_flush, candidate, pend_valid, ack_pending, enq_seen, scan_phase;
    (* preserve = 1, dont_merge = 1 *) reg [31:0] now_q;
    reg [31:0] ack_time, pend_bag, new_time, difference, soon_difference;
    reg [7:0] op_head;
    reg [13:0] op_len;

    // saved_state[62] 表示下一次发送时间有效。
    // saved_state[61:30] 保存下一次允许发送的周期。
    // saved_state[29:22] 保存下一帧的序号。
    // saved_state[21:16] 保存排队消息数。
    // saved_state[15:8] 保存队首消息的首页。
    // saved_state[7:0] 保存队尾消息的首页。
    reg [62:0] saved_state;
    reg [46:0] saved_desc;
    reg [7:0] saved_next;
    // A message remains the queue head until its last grant.  Its head page
    // stays allocated so desc/mnext remain valid while other VLs run.
    reg [127:0] fragment_active, fragment_busy;
    // Separate single-writer tables permit RAM inference. Only the two
    // validity bitmaps reset; stale table contents are ignored on first grant.
    wire [141:0] context_meta;
    wire [26:0] context_progress;
    wire [TX_OFF_AW+7:0] context_pointer;
    reg context_active;
    wire [15:0] context_ident, context_vlid, context_sport, context_dport;
    wire [11:0] context_budget;
    wire [31:0] context_src, context_dst;
    wire [1:0] context_networks;
    assign {context_ident, context_budget, context_src, context_dst,
            context_vlid, context_sport, context_dport, context_networks} = context_meta;
    reg [141:0] work_meta;
    reg [26:0] work_next_progress;
    reg [TX_OFF_AW+7:0] work_pointer;
    reg [12:0] work_offset;
    wire [15:0] work_ident, work_vlid, work_sport, work_dport;
    wire [11:0] work_saved_budget;
    wire [31:0] work_src, work_dst;
    wire [1:0] work_networks;
    assign {work_ident, work_saved_budget, work_src, work_dst,
            work_vlid, work_sport, work_dport, work_networks} = work_meta;
    reg [15:0] next_ident;
    reg work_first, work_last;
    reg [13:0] work_remaining, work_total;
    reg [11:0] work_budget;
    reg [10:0] work_ip_data, work_app_len;
    wire [11:0] configured_budget = {1'b0, words[0][19:9]} + 12'd8;
    wire [11:0] capped_budget = configured_budget > 12'd1479 ? 12'd1479 : configured_budget;
    wire [11:0] aligned_budget = {work_budget[11:3],3'b000};
    wire [11:0] selected_ip_data = work_total <= work_budget ? work_total[11:0] : aligned_budget;
    reg [62:0] state_after_send;

    // RAM reads begin at GRANT phase 0. Active selection is independently
    // banked at phases 1/2 and is ready before dimensions consume it at 5.
    wire context_read = !reset && op == GRANT && phase == 0;
    (* preserve = 1, dont_merge = 1 *) reg context_write;
    (* preserve = 1, dont_merge = 1 *) reg enqueue_commit, start_commit;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] grant_load;
    (* preserve = 1, dont_merge = 1 *) reg ident_increment;
    (* preserve = 1, dont_merge = 1 *) reg [6:0] progress_write_address;
    always @(posedge clk) begin
        if (reset) begin
            context_write <= 0; enqueue_commit <= 0; start_commit <= 0;
            grant_load <= 0; ident_increment <= 0; progress_write_address <= 0;
        end else begin
            context_write <= op == GRANT && phase == 7;
            enqueue_commit <= op == ENQ && phase == 3;
            start_commit <= op == START && phase == 1;
            ident_increment <= op == GRANT && phase == 7 && work_first;
            progress_write_address <= op_vl;
            grant_load <= {8{op == GRANT && phase == 7}};
        end
    end
    afdx_ram_sdp #(.WIDTH(27), .DEPTH(128)) fragment_progress (
        .clk(clk), .write_enable(context_write),
        .write_address(progress_write_address), .write_data(work_next_progress),
        .read_enable(context_read), .read_address(op_vl), .read_data(context_progress));
    // The scheduler cannot reach another GRANT phase-0 pointer read until
    // after this local commit. Busy clears on the original completion edge.
    (* preserve=1, dont_merge=1 *) reg pointer_commit;
    reg [6:0] pointer_address;
    reg [TX_OFF_AW+7:0] pointer_data;
    always @(posedge clk) begin
        if (reset) pointer_commit <= 0;
        else pointer_commit <= fragment_done;
        pointer_address <= fragment_done_vl;
        pointer_data <= {fragment_done_page,fragment_done_offset};
    end
    afdx_ram_sdp #(.WIDTH(TX_OFF_AW+8), .DEPTH(128)) fragment_pointer (
        .clk(clk), .write_enable(pointer_commit),
        .write_address(pointer_address), .write_data(pointer_data),
        .read_enable(context_read), .read_address(op_vl), .read_data(context_pointer));

    // words 暂存当前选中虚拟链路的六个配置字。
    // 配置字 0 的 [0] 是使能位，[1] 和 [2] 分别允许从 A 网和 B 网发送。
    // 配置字 0 的 [8:3] 是最多排队的消息数，[19:9] 是允许的最大消息长度（字节）。
`ifndef MODEL_TECH
    reg [31:0] words[0:5];
`endif
    // 配置和状态在 ENQ 的 phase=1 保存，phase=3 预计算，phase=4 只消费本地标志。
    // 长度比较也提前寄存，避免配置字 [19:9] 经拒绝优先级链驱动写使能。
    (* preserve = 1, dont_merge = 1 *) reg enq_disabled_q, enq_too_long_q, q_full_q, mnext_wr_q;
    // Sixteen local eight-way reads terminate replicated three-bit indices.
    // Busy can only clear while ENQ/SCAN runs, so an older bit is conservative.
    (* preserve = 1, dont_merge = 1 *) reg [15:0] enq_busy_banks, scan_busy_banks, active_banks;
    (* preserve = 1, dont_merge = 1 *) reg [3:0] enq_busy_bank, scan_busy_bank, active_bank;
    (* preserve = 1, dont_merge = 1 *) reg enq_busy_q, enq_pending_q;
    // cfg_re/地址先寄存，下一拍 RAM 更新 cfg_q，再下一拍才采样配置字。
    // 只把采样使能提前一相位译码；连续读取时 cfg_q 每拍变化，数据采样拍不能后移。
    genvar cfg_word;
    generate
        for (cfg_word = 0; cfg_word < 6; cfg_word = cfg_word + 1) begin : config_word
            (* preserve = 1, dont_merge = 1 *) reg capture;
            always @(posedge clk) begin
                if (reset) capture <= 0;
                else begin
                    capture <= (cfg_word == 0 ? (op == ENQ || op == GRANT) : op == GRANT)
                        && phase == cfg_word;
                    if (capture) words[cfg_word] <= cfg_q;
                end
            end
        end
    endgenerate
    reg [4:0] scan_valid;
    reg [6:0] scan_vl0, scan_vl1, scan_vl2, scan_vl3, scan_vl4;

    // 轮询分几拍完成：scan_vl0 到 scan_vl4 是各拍正在检查的虚拟链路编号，
    // scan_s0 到 scan_s2 是读出的状态逐拍传递的副本。
    // scan_d 是当前时间减去下次允许发送时间的差，加上 LOOKAHEAD 后的最高位
    // 为 0，表示这条虚拟链路已到期或即将到期。
    reg [62:0] scan_s0, scan_s1, scan_s2;
    reg [31:0] scan_d;
    // enable_q 是 init_done 的本地副本，第四拍寄存准入与清除结论，
    // 远端使能只进一次寄存器，不再穿过扫描判断的组合锥。
    (* preserve = 1, dont_merge = 1 *) reg enable_q;
    reg scan_eligible_r, scan_cleanup_r;
    (* preserve = 1, dont_merge = 1 *) reg scan_blocked_q;
    // grant_ready_q 是组帧空闲标志的本地副本，grant 许可由组帧侧自查 pending，晚一拍安全。
    (* preserve = 1, dont_merge = 1 *) reg grant_ready_q;

    // quota 限制连续扫描次数，让新消息也能及时加入队列。
    // ack_pending 表示还有一个实际发送时间需要写回。
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [4:0] quota;
    wire want_enq = enq_valid_local && ! enq_seen && (candidate || quota >= SCAN_QUOTA);
    wire want_grant = candidate && grant_ready_q && ! pend_valid;

    // cfg_ok 沿用原 enable 时序；调度内部使用本地副本 enable_q。
    assign cfg_ok = enable && op == IDLE && ! want_enq && ! want_grant;
    wire scanning = enable_q && op == IDLE && ! candidate && ! ack_pending && ! want_enq;

    // 状态字的加减先并行寄存，提交拍只选择已经算好的整字。
    reg [62:0] state_after_enqueue;
    always @(posedge clk) begin
        if (reset) begin
            state_after_enqueue <= 0;
            state_after_send <= 0;
        end
        else begin
            state_after_enqueue <= {saved_state[62:22], saved_state[21:16] + 6'd1,
                saved_state[21:16] == 0 ? op_head : saved_state[15:8], op_head};
            // work_last is settled at phase 6, before phase-8 publication.
            // Select the final/continuing queue fields here so state_wd has
            // only the operation mux, and remove the duplicate wide snapshot.
            state_after_send <= {saved_state[62:30],
                saved_state[29:22] == SN_MAX ? SN_FIRST : saved_state[29:22] + 8'd1,
                work_last ? saved_state[21:16] - 6'd1 : saved_state[21:16],
                work_last ? saved_next : saved_state[15:8], saved_state[7:0]};
        end
    end

    // 各操作的写入内容始终预备，写脉冲独立决定提交；宽数据不经过扫描准入或 phase 使能链。
    always @(posedge clk) begin
        if (reset) state_wd <= 0;
        else case (op)
            INIT : state_wd <= 0;
            IDLE : state_wd <= {1'b0, scan_s2[61:0]};
            ENQ : state_wd <= state_after_enqueue;
            GRANT : state_wd <= state_after_send;
            START : state_wd <= {1'b1, new_time, saved_state[29:0]};
            default : state_wd <= 0;
        endcase
    end

    task invalidate_scan;
        begin
            // 操作被打断后，从第一条尚未完成检查的虚拟链路重新扫描。
            scan_valid <= 0;
            scan_issue <= scan_commit;
            scan_phase <= 0;
        end
    endtask

    // 第四拍已知队列状态和待发送链路，把准入与清除结论一并寄存。
    // 第五拍只使用已寄存的单比特结论，不再重组合六个条件。
    wire scan_due_w = ! scan_d[31];
    wire scan_has_data_w = scan_s1[21:16] != 0;
    wire scan_unrestricted_w = ! scan_s1[62];
    wire scan_blocked_w = scan_blocked_q;
    wire [31:0] scan_soon_w = scan_d + LOOKAHEAD;

    genvar busy_bank_index, bitmap_row, meta_group;
    generate
        for (busy_bank_index = 0; busy_bank_index < 16; busy_bank_index = busy_bank_index + 1) begin : busy_bank_lookup
            wire [7:0] local_busy = fragment_busy[busy_bank_index * 8 +: 8];
            wire [7:0] local_active = fragment_active[busy_bank_index * 8 +: 8];
            (* preserve = 1, dont_merge = 1 *) reg [2:0] op_index, scan_index;
            (* preserve = 1, dont_merge = 1 *) reg write_bank;
            wire complete_bank;
            wire [2:0] complete_index;
            if (COMPLETION_LOOKAHEAD) begin : completion_local
                (* preserve=1,dont_merge=1 *) reg command;
                (* preserve=1,dont_merge=1 *) reg [2:0] index;
                always @(posedge clk)begin
                    if(reset)command<=0;
                    else command<=completion_now && completion_vl[6:3]==busy_bank_index;
                    index<=completion_vl[2:0];
                end
                assign complete_bank=command;
                assign complete_index=index;
`ifdef AFDX_CE_DIV
                // F0 local capture equals builder's original F0 publication;
                // both predicates must request exactly the same F1 busy clear.
                always @(negedge clk)if(!reset &&
                    ((command !== (fragment_done && fragment_done_vl[6:3]==busy_bank_index)) ||
                    (command && index !== fragment_done_vl[2:0])))
                    $fatal(1,"completion bank command differs from registered completion");
`endif
            end else begin : completion_compatible
                assign complete_bank=fragment_done && fragment_done_vl[6:3]==busy_bank_index;
                assign complete_index=fragment_done_vl[2:0];
            end
            always @(posedge clk) begin
                op_index <= op_vl[2:0];
                scan_index <= scan_vl0[2:0];
                if (reset) begin
                    enq_busy_banks[busy_bank_index] <= 0;
                    scan_busy_banks[busy_bank_index] <= 0;
                    active_banks[busy_bank_index] <= 0;
                    write_bank <= 0;
                end else begin
                    write_bank <= op == GRANT && phase == 6 && op_vl[6:3] == busy_bank_index;
                    if (op == ENQ && phase == 1)
                        enq_busy_banks[busy_bank_index] <= local_busy[op_index];
                    if (scan_valid[1])
                        scan_busy_banks[busy_bank_index] <= local_busy[scan_index];
                    if (op == GRANT && phase == 1)
                        active_banks[busy_bank_index] <= local_active[op_index];
                end
            end
            for (bitmap_row = 0; bitmap_row < 8; bitmap_row = bitmap_row + 1) begin : row
                localparam VL = busy_bank_index * 8 + bitmap_row;
                (* preserve = 1, dont_merge = 1 *) reg commit_row;
                always @(posedge clk) begin
                    if (reset) begin
                        commit_row <= 0;
                        fragment_active[VL] <= 0;
                        fragment_busy[VL] <= 0;
                    end else begin
                        commit_row <= write_bank && op_index == bitmap_row;
                        if (complete_bank && complete_index == bitmap_row) fragment_busy[VL] <= 0;
                        if (commit_row) begin
                            fragment_busy[VL] <= 1;
                            fragment_active[VL] <= !work_last;
                        end
                    end
                end
            end
        end
        // Each independently inferred RAM owns a <=32-bit local write enable.
        // The helper retains write-data isolation inside the RAM module.
        for (meta_group = 0; meta_group < 5; meta_group = meta_group + 1) begin : metadata_word
            localparam WORD_WIDTH = meta_group == 4 ? 14 : 32;
            (* preserve = 1, dont_merge = 1 *) reg capture, first_q, write_command;
            (* preserve = 1, dont_merge = 1 *) reg [6:0] address_q;
            wire [141:0] initial_meta = {
                next_ident, work_budget, words[3], words[4], words[2][15:0],
                saved_desc[32] ? saved_desc[31:16] : words[5][31:16],
                saved_desc[32] ? saved_desc[15:0] : words[5][15:0], words[0][2:1]};
            always @(posedge clk) begin
                first_q <= work_first;
                address_q <= op_vl;
                if (reset) begin
                    capture <= 0; write_command <= 0;
                    work_meta[meta_group * 32 +: WORD_WIDTH] <= 0;
                end else begin
                    capture <= op == GRANT && phase == 6;
                    write_command <= op == GRANT && phase == 7 && work_first;
                    if (capture)
                        work_meta[meta_group * 32 +: WORD_WIDTH] <= first_q
                            ? initial_meta[meta_group * 32 +: WORD_WIDTH]
                            : context_meta[meta_group * 32 +: WORD_WIDTH];
                end
            end
            afdx_ram_sdp #(.WIDTH(WORD_WIDTH), .DEPTH(128)) fragment_meta (
                .clk(clk), .write_enable(write_command), .write_address(address_q),
                .write_data(work_meta[meta_group * 32 +: WORD_WIDTH]),
                .read_enable(context_read), .read_address(op_vl),
                .read_data(context_meta[meta_group * 32 +: WORD_WIDTH]));
        end
    endgenerate
    always @(posedge clk) begin
        if (reset) begin active_bank <= 0; context_active <= 0; end
        else begin
            if (op == GRANT && phase == 1) active_bank <= op_vl[6:3];
            if (op == GRANT && phase == 2) context_active <= active_banks[active_bank];
        end
    end

    // Addresses and write decisions are prepared independently of the wide
    // data registers. Each operation still retires on its original edge.
    always @(posedge clk) begin
        if (reset) begin state_wa <= 0; state_we <= 0; end
        else begin
            case (op)
                INIT: state_wa <= init_ptr;
                IDLE: state_wa <= scan_vl4;
                default: state_wa <= op_vl;
            endcase
            state_we <= (op == INIT && !init_flush)
                || (scanning && scan_valid[4] && scan_cleanup_r)
                || (enqueue_commit && !enq_disabled_q && !enq_too_long_q && !q_full_q)
                || context_write || start_commit;
        end
    end
    always @(posedge clk) begin
        if (reset) next_ident <= 0;
        else if (ident_increment) next_ident <= next_ident + 16'd1;
    end
    always @(posedge clk) begin
        if (reset) begin
            grant_a <= 0; grant_b <= 0; grant_timed <= 0; grant_first <= 0;
            grant_more <= 0; grant_len <= 0; grant_sn <= 0; grant_vl_index <= 0;
        end else if (grant_load[0]) begin
            grant_a <= work_networks[0]; grant_b <= work_networks[1];
            grant_timed <= saved_state[62]; grant_first <= work_first; grant_more <= !work_last;
            grant_len <= work_app_len; grant_sn <= saved_state[29:22]; grant_vl_index <= op_vl;
        end
    end
    always @(posedge clk) if (reset) grant_time <= 0;
        else if (grant_load[1]) grant_time <= saved_state[61:30];
    always @(posedge clk) if (reset) grant_src <= 0;
        else if (grant_load[2]) grant_src <= work_src;
    always @(posedge clk) if (reset) grant_dst <= 0;
        else if (grant_load[3]) grant_dst <= work_dst;
    always @(posedge clk) begin
        if (reset) begin grant_vlid <= 0; grant_sport <= 0; end
        else if (grant_load[4]) begin grant_vlid <= work_vlid; grant_sport <= work_sport; end
    end
    always @(posedge clk) begin
        if (reset) begin grant_dport <= 0; grant_ident <= 0; end
        else if (grant_load[5]) begin grant_dport <= work_dport; grant_ident <= work_ident; end
    end
    always @(posedge clk) begin
        if (reset) begin grant_head <= 0; grant_page <= 0; grant_offset <= 0; end
        else if (grant_load[6]) begin
            grant_head <= saved_state[15:8]; grant_page <= work_pointer[TX_OFF_AW+7:TX_OFF_AW];
            grant_offset <= work_pointer[TX_OFF_AW-1:0];
        end
    end
    always @(posedge clk) begin
        if (reset) begin grant_ip_offset <= 0; grant_message_len <= 0; end
        else if (grant_load[7]) begin grant_ip_offset <= work_offset; grant_message_len <= saved_desc[46:33]; end
    end

    always @(posedge clk) begin
        if (reset) begin
            op <= INIT;
            phase <= 0;
            initialized <= 0;
            init_ptr <= 0;
            init_flush <= 0;
            cfg_re <= 0;
            cfg_ra <= 0;
            state_re <= 0;
            state_ra <= 0;

            mnext_we <= 0;
            mnext_re <= 0;
            mnext_wa <= 0;
            mnext_ra <= 0;
            mnext_wd <= 0;
            desc_re <= 0;
            desc_ra <= 0;
            enq_ack <= 0;
            enq_result <= ENQ_ACCEPTED;
            grant_valid <= 0;
            work_first <= 0; work_last <= 0; work_remaining <= 0;
            work_total <= 0; work_budget <= 0; work_ip_data <= 0; work_app_len <= 0;
            work_next_progress <= 0; work_pointer <= 0; work_offset <= 0;
            candidate <= 0;
            candidate_vl <= 0;
            pend_valid <= 0;
            pend_vl <= 0;
            pend_bag <= 0;
            ack_pending <= 0;
            ack_time <= 0;
            enq_seen <= 0;
            now_q <= 0;
            new_time <= 0;
            difference <= 0;
            soon_difference <= 0;
            op_vl <= 0;
            op_head <= 0;
            op_len <= 0;
            saved_state <= 0;
            saved_desc <= 0;
            saved_next <= 0;
            enq_disabled_q <= 0;
            enq_too_long_q <= 0;
            q_full_q <= 0;
            mnext_wr_q <= 0;
            enq_busy_q <= 0;
            enq_pending_q <= 0;
            enq_busy_bank <= 0;
            scan_busy_bank <= 0;
            scan_blocked_q <= 0;
            scan_issue <= 0;
            scan_commit <= 0;
            scan_phase <= 0;
            scan_valid <= 0;
            quota <= SCAN_QUOTA;
            scan_vl0 <= 0;
            scan_vl1 <= 0;
            scan_vl2 <= 0;
            scan_vl3 <= 0;
            scan_vl4 <= 0;
            scan_s0 <= 0;
            scan_s1 <= 0;
            scan_s2 <= 0;
            scan_d <= 0;
            enable_q <= 0;
            grant_ready_q <= 0;
            scan_eligible_r <= 0;
            scan_cleanup_r <= 0;
        end
        else begin
            now_q <= now;
            enable_q <= enable;
            grant_ready_q <= grant_ready;
            state_re <= 0;
            cfg_re <= 0;
            mnext_we <= 0;
            mnext_re <= 0;
            desc_re <= 0;
            enq_ack <= 0;
            // 许可保持到组帧模块确认接收：晚一拍的本地 ready 副本可能错过真实忙态。
            grant_valid <= grant_valid && ! grant_ready;
            if ( ! enq_valid_local) enq_seen <= 0;
            if (start_valid) begin
                ack_pending <= 1;
                ack_time <= t_start;
            end
            scan_valid <= { scan_valid[3:0], 1'b0 };
            scan_vl1 <= scan_vl0;
            scan_vl2 <= scan_vl1;
            scan_vl3 <= scan_vl2;
            scan_vl4 <= scan_vl3;
            if (scan_valid[1]) begin
                scan_s0 <= state_q;
                scan_busy_bank <= scan_vl1[6:3];
            end
            if (scan_valid[2]) begin
                scan_s1 <= scan_s0;
                scan_d <= now_q - scan_s0[61:30];
                // Align the local bitmap result with scan_vl3 / scan_s1.
                scan_blocked_q <= (pend_valid && scan_vl2 == pend_vl)
                    || scan_busy_banks[scan_busy_bank];
            end
            if (scan_valid[3]) begin
                scan_s2 <= scan_s1;
                scan_eligible_r <= scan_has_data_w && (scan_unrestricted_w || ! scan_soon_w[31])
                    && ! scan_blocked_w;
                scan_cleanup_r <= ! scan_has_data_w && ! scan_unrestricted_w && scan_due_w
                    && ! scan_blocked_w;
            end
            // 模块只选择有排队消息且已到期或即将到期的虚拟链路。
            // LOOKAHEAD 指定提前准备组帧的周期数，实际发送仍要等到期。
            if (scanning && scan_valid[4]) begin
                scan_commit <= scan_vl4 + 1'b1;
                if (quota < SCAN_QUOTA) quota <= quota + 1'b1;
                if (scan_eligible_r) begin
                    candidate <= 1;
                    candidate_vl <= scan_vl4;
                    scan_valid <= 0;
                    scan_issue <= scan_vl4 + 1'b1;
                    scan_phase <= 0;
                end
            end
            // 先处理实际发送时间，再处理入队和选帧请求。
            case (op)

                // INIT：初始化全部状态，最后一次写入完成后转 IDLE。
                INIT : begin
                    if ( ! init_flush) begin
                        init_ptr <= init_ptr + 1'b1;
                        if (init_ptr == LAST_VL) init_flush <= 1;
                    end
                    else begin
                        initialized <= 1;
                        op <= IDLE;
                    end
                end

                // IDLE：按请求转 START、ENQ 或 GRANT；无请求时轮询队列。
                IDLE : if (enable_q) begin
                    if (ack_pending) begin
                        invalidate_scan;
                        op <= START;
                        phase <= 0;
                        op_vl <= pend_vl;
                        state_re <= 1;
                        state_ra <= pend_vl;
                        new_time <= ack_time + pend_bag;
                        ack_pending <= 0;
                    end
                    else if (want_enq) begin
                        invalidate_scan;
                        op <= ENQ;
                        phase <= 0;
                        op_vl <= enq_vl_local;
                        op_head <= enq_head_local;
                        op_len <= enq_len_local;
                        cfg_re <= 1;
                        cfg_ra <= { enq_vl_local, 3'b000 };
                        state_re <= 1;
                        state_ra <= enq_vl_local;
                        enq_seen <= 1;
                        quota <= 0;
                    end
                    else if (want_grant) begin
                        invalidate_scan;
                        op <= GRANT;
                        phase <= 0;
                        op_vl <= candidate_vl;
                        cfg_re <= 1;
                        cfg_ra <= { candidate_vl, 3'b000 };
                        state_re <= 1;
                        state_ra <= candidate_vl;
                    end
                    else if ( ! candidate) begin
                        scan_phase <= ! scan_phase;
                        if ( ! scan_phase && ! (scan_valid[4] && scan_eligible_r)) begin
                            state_re <= 1;
                            state_ra <= scan_issue;
                            scan_vl0 <= scan_issue;
                            scan_valid[0] <= 1;
                            scan_issue <= scan_issue + 1'b1;
                        end
                    end
                end

                // ENQ：检查配置并把消息加入队尾，返回结果后转 IDLE。
                // phase=1：保存配置和状态，下一拍转 2。
                // phase=2：计算距到期时间的差，下一拍转 3。
                // phase=3：检查提前准备范围，并寄存入队条件，下一拍转 4。
                // phase=4：接纳或拒绝消息，随后主状态转 IDLE。
                // enq_result 为 1 表示虚拟链路未启用，为 2 表示队列已满，为 3 表示消息过长。
                ENQ : begin
                    phase <= phase + 1'b1;
                    case (phase)

                        1 : begin
                            saved_state <= state_q;
                            enq_busy_bank <= op_vl[6:3];
                            enq_pending_q <= pend_valid && op_vl == pend_vl;
                        end

                        2 : begin
                            difference <= now_q - saved_state[61:30];
                            enq_busy_q <= enq_busy_banks[enq_busy_bank];
                        end

                        3 : begin
                            soon_difference <= difference + LOOKAHEAD;
                            enq_disabled_q <= ! words[0] [0] || words[0] [2:1] == 0;
                            enq_too_long_q <= (op_len <= 14'd1471 && op_len > {3'b000,words[0][19:9]})
                                || (op_len > 14'd1471 && words[0][19:9] < 11'd8);
                            q_full_q <= saved_state[21:16] >= words[0] [8:3];
                            mnext_wr_q <= saved_state[21:16] != 0;
                        end

                        4 : begin
                            enq_ack <= 1;
                            op <= IDLE;
                            if (enq_disabled_q) enq_result <= ENQ_DISABLED;
                            else if (enq_too_long_q) enq_result <= ENQ_TOO_LONG;
                            else if (q_full_q) enq_result <= ENQ_FULL;
                            else begin
                                enq_result <= ENQ_ACCEPTED;
                                if (mnext_wr_q) begin
                                    mnext_we <= 1;
                                    mnext_wa <= saved_state[7:0];
                                    mnext_wd <= op_head;
                                end
                                if ( ! candidate && ! enq_pending_q && ! enq_busy_q && ( ! saved_state[62]
                                    || ! soon_difference[31])) begin
                                    candidate <= 1;
                                    candidate_vl <= op_vl;
                                end
                            end
                        end

                        default : ;
                    endcase
                end

                // GRANT：读取配置和队首消息，通知组帧模块后转 IDLE。
                // phase=0：启动后续配置字读取，下一拍转 1。
                // phase=1：保存配置字 0 和队列状态，下一拍转 2。
                // phase=2：保存配置字 1 并读队首消息，下一拍转 3。
                // phase=3：保存配置字 2，下一拍转 4。
                // phase=4：保存配置字 3 和消息信息，下一拍转 5。
                // phase=0 also synchronously reads the selected context tables.
                // phase=5 selects the working length/budget from that snapshot.
                // phase=6 computes this fragment's dimensions.
                // phase=7 registers the complete packet metadata and next progress.
                // phase=8 commits the grant and the precomputed context state.
                GRANT : begin
                    phase <= phase + 1'b1;
                    if (phase < 5) begin
                        cfg_re <= 1;
                        cfg_ra <= { op_vl, phase[2:0] + 3'd1 };
                    end
                    case (phase)

                        1 : begin
                            saved_state <= state_q;
                        end

                        2 : begin
                            desc_re <= 1;
                            desc_ra <= saved_state[15:8];
                            mnext_re <= 1;
                            mnext_ra <= saved_state[15:8];
                        end

                        4 : begin
                            saved_desc <= desc_q;
                            saved_next <= mnext_q;
                        end

                        5 : begin
                            work_first <= !context_active;
                            work_remaining <= context_active ? context_progress[26:13] : saved_desc[46:33];
                            work_total <= context_active ? context_progress[26:13] : saved_desc[46:33] + 14'd8;
                            work_budget <= context_active ? context_budget : capped_budget;
                            work_offset <= context_active ? context_progress[12:0] : 13'd0;
                        end
                        6 : begin
                            work_last <= work_total <= work_budget;
                            work_ip_data <= selected_ip_data[10:0];
                            work_app_len <= selected_ip_data[10:0] - (work_first ? 11'd8 : 11'd0);
                        end
                        7 : begin
                            work_pointer <= work_first ? {saved_state[15:8], {TX_OFF_AW{1'b0}}} : context_pointer;
                            work_next_progress <= {
                                work_remaining - {3'b000, work_app_len},
                                work_offset + {5'b00000, work_ip_data[10:3]}};
                        end
                        8 : begin
                            grant_valid <= 1;

                            // 当前消息开始发送前，同一虚拟链路不能再次被选中。
                            pend_valid <= 1;
                            pend_vl <= op_vl;
                            pend_bag <= words[1];
                            candidate <= 0;
                            op <= IDLE;
                        end

                        default : ;
                    endcase
                end

                // START：按实际发送时间更新下一次到期时间，然后转 IDLE。
                // phase=1：保存当前状态，下一拍转 2。
                // phase=2：写入下一次允许发送时间，主状态转 IDLE。
                START : begin
                    phase <= phase + 1'b1;
                    case (phase)
                        1 : saved_state <= state_q;
                        2 : begin
                            pend_valid <= 0;
                            op <= IDLE;
                        end
                        default : ;
                    endcase
                end

                default : op <= INIT;
            endcase
        end
    end

endmodule
