// 轮询发送VL并按BAG、提前查看窗口及等待授权选择消息。
// 读取VL配置/状态和消息描述，向组帧器发出授权。
// 已授权但未起发的VL保持pending，防止同一VL重复授权。
// 唯一 VL 状态表主人：清表、起始确认、入队、授权和两拍一个地址的扫描。
module afdx_tx_engine #(
    parameter TX_PAGE_AW = 8, LOOKAHEAD = 512) (
    // clk/reset 为同步控制；enable 允许调度，now 为周期计时，initialized 表示状态清表完成。
    input wire clk, reset, enable,
    input wire [31:0] now,
    output reg initialized,
    // cfg_* 只读 VL 配置；state_* 独占 VL 队列、序号和 BAG 时间状态的读写。
    output reg cfg_re,
    output reg [9:0] cfg_ra,
    input wire [31:0] cfg_q,
    output reg state_we, state_re,
    output reg [6:0] state_wa, state_ra,
    output reg [62:0] state_wd,
    input wire [62:0] state_q,
    // mnext_* 连接同一 VL 的消息首页；desc_* 读取队头消息长度和端口。
    output reg mnext_we, mnext_re,
    output reg [TX_PAGE_AW - 1:0] mnext_wa, mnext_ra,
    output reg [7:0] mnext_wd,
    input wire [7:0] mnext_q,
    output reg desc_re,
    output reg [TX_PAGE_AW - 1:0] desc_ra,
    input wire [43:0] desc_q,
    // enq_* 提交已收完消息，enq_ack/result 报告是否入队及拒绝原因。
    input wire enq_valid,
    input wire [6:0] enq_vl,
    input wire [7:0] enq_head,
    input wire [10:0] enq_len,
    output reg enq_ack,
    output reg [2:0] enq_result,
    // start_valid/t_start 确认实际首前导时刻，用于更新该 VL 下一 BAG 到期时间。
    input wire start_valid,
    input wire [31:0] t_start,
    // grant_* 向组帧器交付网络、发出时刻、地址、端口、长度、SN 和首页。
    input wire grant_ready,
    output reg grant_valid,
    output reg grant_a, grant_b, grant_timed,
    output reg [31:0] grant_time,
    output reg [15:0] grant_vlid, grant_sport, grant_dport,
    output reg [31:0] grant_src, grant_dst,
    output reg [10:0] grant_len,
    output reg [7:0] grant_sn, grant_page,
    // cfg_ok 表示当前无冲突的配置写窗口，由外壳与 cfg_we 联合使用。
    output wire cfg_ok);
    localparam INIT = 0, IDLE = 1, ENQ = 2, GRANT = 3, START = 4;
    // op 管理互斥的表操作；phase 按同步 RAM 的读延迟推进一次操作。
    reg [2:0] op;
    reg [3:0] phase;
    // scan_issue/commit 跟踪轮询流水；candidate 是候选 VL，pend_vl 是已授权但尚未起帧的 VL。
    reg [6:0] init_ptr, scan_issue, scan_commit, op_vl, candidate_vl, pend_vl;
    reg init_flush, candidate, pend_valid, ack_pending, enq_seen, scan_phase;
    reg [31:0] now_q, ack_time, pend_bag, new_time, difference, soon_difference;
    reg [7:0] op_head;
    reg [10:0] op_len;
    // 状态位：62=定时有效，61:30=下次起发时间，29:22=SN，21:16=队长，15:8=头，7:0=尾。
    reg [62:0] saved_state;
    reg [43:0] saved_desc;
    reg [7:0] saved_next;
    // 六个字仅暂存当前授权的配置，不是逐 VL 的寄存器表。
    reg [31:0] words[0:5];
    reg [4:0] scan_valid;
    reg [6:0] scan_vl0, scan_vl1, scan_vl2, scan_vl3, scan_vl4;
    reg [62:0] scan_s0, scan_s1, scan_s2;
    reg [31:0] scan_d, scan_soon;
    reg scan_due;
    // quota 在扫描和新消息入队之间分配机会；ack_pending 保存实际起帧通知。
    reg [4:0] quota;
    wire want_enq = enq_valid && ! enq_seen && (candidate || quota >= 16);
    wire want_grant = candidate && grant_ready && ! pend_valid;
    assign cfg_ok = enable && op == IDLE && ! want_enq && ! want_grant;
    wire scanning = enable && op == IDLE && ! candidate && ! ack_pending && ! want_enq;
    task invalidate_scan;
        begin
            // 打断时所有在途结果作废，回到第一条尚未完成判断的 VL。
            scan_valid <= 0;
            scan_issue <= scan_commit;
            scan_phase <= 0;
        end
    endtask
    always @(posedge clk) begin
        if (reset) begin
            op <= INIT;
            phase <= 0;
            initialized <= 0;
            init_ptr <= 0;
            init_flush <= 0;
            cfg_re <= 0;
            cfg_ra <= 0;
            state_we <= 0;
            state_re <= 0;
            state_wa <= 0;
            state_ra <= 0;
            state_wd <= 0;
            mnext_we <= 0;
            mnext_re <= 0;
            mnext_wa <= 0;
            mnext_ra <= 0;
            mnext_wd <= 0;
            desc_re <= 0;
            desc_ra <= 0;
            enq_ack <= 0;
            enq_result <= 0;
            grant_valid <= 0;
            grant_a <= 0;
            grant_b <= 0;
            grant_timed <= 0;
            grant_time <= 0;
            grant_vlid <= 0;
            grant_sport <= 0;
            grant_dport <= 0;
            grant_src <= 0;
            grant_dst <= 0;
            grant_len <= 0;
            grant_sn <= 0;
            grant_page <= 0;
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
            scan_issue <= 0;
            scan_commit <= 0;
            scan_phase <= 0;
            scan_valid <= 0;
            quota <= 16;
            scan_vl0 <= 0;
            scan_vl1 <= 0;
            scan_vl2 <= 0;
            scan_vl3 <= 0;
            scan_vl4 <= 0;
            scan_s0 <= 0;
            scan_s1 <= 0;
            scan_s2 <= 0;
            scan_d <= 0;
            scan_soon <= 0;
            scan_due <= 0;
        end
        else begin
            now_q <= now;
            state_we <= 0;
            state_re <= 0;
            cfg_re <= 0;
            mnext_we <= 0;
            mnext_re <= 0;
            desc_re <= 0;
            enq_ack <= 0;
            grant_valid <= 0;
            if (! enq_valid) enq_seen <= 0;
            if (start_valid) begin
                ack_pending <= 1;
                ack_time <= t_start;
            end
            scan_valid <= { scan_valid[3:0], 1'b0 };
            scan_vl1 <= scan_vl0;
            scan_vl2 <= scan_vl1;
            scan_vl3 <= scan_vl2;
            scan_vl4 <= scan_vl3;
            if (scan_valid[1]) scan_s0 <= state_q;
            if (scan_valid[2]) begin
                scan_s1 <= scan_s0;
                scan_d <= now_q - scan_s0[61:30];
            end
            if (scan_valid[3]) begin
                scan_s2 <= scan_s1;
                scan_soon <= scan_d + LOOKAHEAD;
                scan_due <= ! scan_d[31];
            end
            // ARINC 664 P7 带宽分配间隔（BAG）：只挑选已有消息且到期或进入 LOOKAHEAD 的 VL。
            if (scanning && scan_valid[4]) begin
                scan_commit <= scan_vl4 + 1'b1;
                if (quota < 16) quota <= quota + 1'b1;
                if (scan_s2[21:16] != 0 && (! scan_s2[62] || ! scan_soon[31]) && ! (pend_valid && scan_vl4 == pend_vl)) begin
                    candidate <= 1;
                    candidate_vl <= scan_vl4;
                    scan_valid <= 0;
                    scan_issue <= scan_vl4 + 1'b1;
                    scan_phase <= 0;
                end
                else if (scan_s2[21:16] == 0 && scan_s2[62] && scan_due && ! (pend_valid && scan_vl4 == pend_vl)) begin
                    state_we <= 1;
                    state_wa <= scan_vl4;
                    state_wd <= { 1'b0, scan_s2[61:0] };
                end
            end
            // 表操作仲裁：实际起帧确认优先，其次入队/授权；打断时丢弃在途扫描结果。
            case (op)
                // INIT：逐项清 128 个 VL 状态，最后写入落地后转 IDLE。
                INIT : begin
                    if (! init_flush) begin
                        state_we <= 1;
                        state_wa <= init_ptr;
                        state_wd <= 0;
                        init_ptr <= init_ptr + 1'b1;
                        if (init_ptr == 127) init_flush <= 1;
                    end
                    else begin
                        initialized <= 1;
                        op <= IDLE;
                    end
                end
                // IDLE：等待使能；按优先级转 START/ENQ/GRANT，否则每两拍发一个扫描读。
                IDLE : if (enable) begin
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
                        op_vl <= enq_vl;
                        op_head <= enq_head;
                        op_len <= enq_len;
                        cfg_re <= 1;
                        cfg_ra <= { enq_vl, 3'b000 };
                        state_re <= 1;
                        state_ra <= enq_vl;
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
                    else if (! candidate) begin
                        scan_phase <= ! scan_phase;
                        if (! scan_phase && ! (scan_valid[4] && scan_s2[21:16] != 0 && (! scan_s2[62] || ! scan_soon[31]) && ! (pend_valid && scan_vl4 == pend_vl))) begin
                            state_re <= 1;
                            state_ra <= scan_issue;
                            scan_vl0 <= scan_issue;
                            scan_valid[0] <= 1;
                            scan_issue <= scan_issue + 1'b1;
                        end
                    end
                end
                // ENQ：phase 1 取配置/状态，2–3 算到期窗口，4 检查限制、接链并返回 IDLE。
                ENQ : begin
                    phase <= phase + 1'b1;
                    case (phase)
                        1 : begin
                            saved_state <= state_q;
                            words[0] <= cfg_q;
                        end
                        2 : difference <= now_q - saved_state[61:30];
                        3 : soon_difference <= difference + LOOKAHEAD;
                        4 : begin
                            enq_ack <= 1;
                            op <= IDLE;
                            if (! words[0] [0] || words[0] [2:1] == 0) enq_result <= 1;
                            else if (op_len > words[0] [19:9]) enq_result <= 3;
                            else if (saved_state[21:16] >= words[0] [8:3]) enq_result <= 2;
                            else begin
                                enq_result <= 0;
                                state_we <= 1;
                                state_wa <= op_vl;
                                state_wd <= { saved_state[62:22], saved_state[21:16] + 6'd1,
                                    saved_state[21:16] == 0 ? op_head : saved_state[15:8], op_head };
                                if (saved_state[21:16] != 0) begin
                                    mnext_we <= 1;
                                    mnext_wa <= saved_state[7:0];
                                    mnext_wd <= op_head;
                                end
                                if (! candidate && ! (pend_valid && op_vl == pend_vl) && (! saved_state[62] || ! soon_difference[31])) begin
                                    candidate <= 1;
                                    candidate_vl <= op_vl;
                                end
                            end
                        end
                        default :;
                    endcase
                end
                // GRANT：phase 0–6 读六个配置字及队头描述，7 授权并出队，锁住该 VL 后回 IDLE。
                GRANT : begin
                    phase <= phase + 1'b1;
                    if (phase < 5) begin
                        cfg_re <= 1;
                        cfg_ra <= { op_vl, phase[2:0] + 3'd1 };
                    end
                    case (phase)
                        1 : begin
                            words[0] <= cfg_q;
                            saved_state <= state_q;
                        end
                        2 : begin
                            words[1] <= cfg_q;
                            desc_re <= 1;
                            desc_ra <= saved_state[15:8];
                            mnext_re <= 1;
                            mnext_ra <= saved_state[15:8];
                        end
                        3 : words[2] <= cfg_q;
                        4 : begin
                            words[3] <= cfg_q;
                            saved_desc <= desc_q;
                            saved_next <= mnext_q;
                        end
                        5 : words[4] <= cfg_q;
                        6 : words[5] <= cfg_q;
                        7 : begin
                            grant_valid <= 1;
                            grant_a <= words[0] [1];
                            grant_b <= words[0] [2];
                            grant_vlid <= words[2] [15:0];
                            grant_src <= words[3];
                            grant_dst <= words[4];
                            grant_len <= saved_desc[43:33];
                            grant_sport <= saved_desc[32] ? saved_desc[31:16] : words[5] [31:16];
                            grant_dport <= saved_desc[32] ? saved_desc[15:0] : words[5] [15:0];
                            grant_sn <= saved_state[29:22];
                            grant_page <= saved_state[15:8];
                            grant_timed <= saved_state[62];
                            grant_time <= saved_state[61:30];
                            state_we <= 1;
                            state_wa <= op_vl;
                            state_wd <= { saved_state[62:30], saved_state[29:22] == 255 ? 8'd1 : saved_state[29:22] + 8'd1,
                                saved_state[21:16] - 6'd1, saved_next, saved_state[7:0] };
                            // 授权到实际起帧之间禁止再次选中同一 VL。
                            pend_valid <= 1;
                            pend_vl <= op_vl;
                            pend_bag <= words[1];
                            candidate <= 0;
                            op <= IDLE;
                        end
                        default :;
                    endcase
                end
                // START：phase 1 取状态，2 写入实际起发时间+BAG 并解除 pending，回 IDLE。
                START : begin
                    phase <= phase + 1'b1;
                    case (phase)
                        1 : saved_state <= state_q;
                        2 : begin
                            state_we <= 1;
                            state_wa <= op_vl;
                            state_wd <= { 1'b1, new_time, saved_state[29:0] };
                            pend_valid <= 0;
                            op <= IDLE;
                        end
                        default :;
                    endcase
                end
                default : op <= INIT;
            endcase
        end
    end
endmodule
