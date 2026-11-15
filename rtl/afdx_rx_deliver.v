// 接收交付控制模块：从交付描述符队列读取报文头并完成重组端握手，随后连续读取接收环形缓存。
// downstream_ready 仅授权报文头接收，downstream_prepared 仅启动字节流读取，
// 两条路径相互独立，不进入同一宽使能优先链。
module afdx_rx_deliver #(
    parameter RX_RING_AW = 12,
    RX_DQ_AW             = 5
) (
    input  wire                     clk, reset,
    input  wire [RX_DQ_AW:0]        dq_count,
    output wire [RX_DQ_AW - 1:0]    dq_ra,
    input  wire [RX_RING_AW + 60:0] dq_q,
    output reg                      dq_pop,
    (* preserve = 1, dont_merge = 1 *)
    output reg                      ring_a_re, ring_b_re,
    (* preserve = 1, dont_merge = 1 *)
    output reg  [RX_RING_AW - 1:0]  ring_a_ra, ring_b_ra,
    input  wire [7:0]               ring_a_q, ring_b_q,
    output reg  [RX_RING_AW:0]      read_ptr_a, read_ptr_b,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *)
    output reg                      d_valid,
    output reg  [7:0]               d_data,
    output reg                      d_last,
    output reg  [11:0]              d_vl,
    output reg  [15:0]              d_sport, d_dport,
    output reg                      d_net,
    input  wire                     downstream_ready, downstream_prepared,
    output reg                      d_frag,
    output reg  [3:0]               d_slot,
    output reg                      d_start, d_empty
);

    (* preserve = 1, dont_merge = 1 *) reg [RX_DQ_AW-1:0] rd_ptr;
    assign dq_ra = rd_ptr;
    // dq_req 表示本地接收通道处于空闲可取帧状态（而非延迟型 downstream_ready 信用）：
    // F0 授权 -> F1 读取并弹出 DQ 队头 -> F2 预计算报文长度分类。
    (* preserve = 1, dont_merge = 1 *) reg dq_req, dq_valid;
    (* preserve = 1, dont_merge = 1 *) reg fetch_eligible, fetch_command, head_prepare;
    (* preserve = 1, dont_merge = 1 *) reg [3:0] capture_header;
    wire fetch_fire = fetch_eligible && !fetch_command && downstream_ready;
    wire header_accept = dq_valid && downstream_ready;
    reg head_empty, head_single, head_more;
    reg issuing, waiting_prepared;
    (* preserve = 1, dont_merge = 1 *) reg read_token;
    reg [10:0] left;
    reg [2:0] valid_pipe, last_pipe;
    reg [7:0] data_a, data_b;

    // 用四个本地锁存令牌替代原本的宽位 HEAD 状态使能，省去中间缓存拷贝，
    // 捕获字段直接构成当前持有的输出报文头。
    always @(posedge clk) begin
        if (reset) begin
            d_sport <= 0;
            d_net <= 0;
            d_frag <= 0;
            d_slot <= 0;
        end
        else if (capture_header[0]) begin
            d_sport <= dq_q[31:16];
            d_net <= dq_q[RX_RING_AW+55];
            d_frag <= dq_q[RX_RING_AW+60];
            d_slot <= dq_q[RX_RING_AW+59:RX_RING_AW+56];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            d_dport <= 0;
            d_vl[7:0] <= 0;
        end
        else if (capture_header[1]) begin
            d_dport <= dq_q[15:0];
            d_vl[7:0] <= dq_q[39:32];
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            d_vl[11:8] <= 0;
            left <= 0;
        end
        else begin
            if (capture_header[2]) begin
                d_vl[11:8] <= dq_q[43:40];
                left <= dq_q[54:44];
            end
            else if ((read_token && !head_empty) || issuing) left <= left - 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            ring_a_ra <= 0;
            ring_b_ra <= 0;
        end
        else if (capture_header[3]) begin
            ring_a_ra <= dq_q[RX_RING_AW+54:55];
            ring_b_ra <= dq_q[RX_RING_AW+54:55];
        end
        else if (issuing) begin
            ring_a_ra <= ring_a_ra + 1'b1;
            ring_b_ra <= ring_b_ra + 1'b1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            dq_req <= 1;
            dq_valid <= 0;
            dq_pop <= 0;
            rd_ptr <= 0;
            fetch_eligible <= 0;
            fetch_command <= 0;
            head_prepare <= 0;
            capture_header <= 0;
            head_empty <= 0;
            head_single <= 0;
            head_more <= 0;
            d_start <= 0;
            d_empty <= 0;
            waiting_prepared <= 0;
            read_token <= 0;
            issuing <= 0;
            ring_a_re <= 0;
            ring_b_re <= 0;
            read_ptr_a <= 0;
            read_ptr_b <= 0;
            valid_pipe <= 0;
            last_pipe <= 0;
            data_a <= 0;
            data_b <= 0;
            d_valid <= 0;
            d_last <= 0;
            d_data <= 0;
        end
        else begin
            // 仅本模块会消耗 dq_count；一旦置起 fetch_eligible，
            // 在完成队头捕获前不会有其他读取方使非空队头失效。
            fetch_eligible <= dq_req && !fetch_command && !head_prepare && !dq_valid && dq_count != 0;
            fetch_command <= fetch_fire;
            capture_header <= {4{fetch_fire}};
            head_prepare <= fetch_command;
            dq_pop <= fetch_command;
            if (fetch_command) begin
                rd_ptr <= rd_ptr + 1'b1;
                dq_req <= 0;
            end
            if (head_prepare) begin
                head_empty <= left == 0;
                head_single <= left == 1;
                head_more <= left > 1;
                dq_valid <= 1;
            end

            // H0 拍消耗当拍 downstream_ready 并立即拉高 d_start；
            // H1 拍对齐原 D_IDLE/D_QUIET 接收沿，无额外信用延迟。
            d_start <= header_accept;
            d_empty <= header_accept && head_empty;
            if (header_accept) begin
                dq_valid <= 0;
                waiting_prepared <= 1;
            end
            read_token <= 0;
            if (waiting_prepared && downstream_prepared) begin
                waiting_prepared <= 0;
                read_token <= 1;
            end

            // R0 准备完成令牌 -> R1 发出读命令 -> R2 读出物理环形缓存数据。
            // 此时报文头元数据已归属本帧，后续字节流水不受 downstream_ready 或报文头条件门控；
            // 空报文不发起环形缓存读请求，也无需等待尾拍释放。
            ring_a_re <= 0;
            ring_b_re <= 0;
            valid_pipe <= {valid_pipe[1:0], 1'b0};
            last_pipe <= {last_pipe[1:0], 1'b0};
            if (read_token) begin
                ring_a_re <= !d_net && !head_empty;
                ring_b_re <= d_net && !head_empty;
                valid_pipe[0] <= !head_empty;
                last_pipe[0] <= head_single;
                issuing <= head_more;
                if (head_empty) dq_req <= 1;
            end
            else if (issuing) begin
                ring_a_re <= !d_net;
                ring_b_re <= d_net;
                valid_pipe[0] <= 1;
                last_pipe[0] <= left == 1;
                if (left == 1) issuing <= 0;
            end
            data_a <= ring_a_q;
            data_b <= ring_b_q;
            if (ring_a_re) read_ptr_a <= read_ptr_a + 1'b1;
            if (ring_b_re) read_ptr_b <= read_ptr_b + 1'b1;
            d_valid <= valid_pipe[2];
            d_last <= valid_pipe[2] && last_pipe[2];
            if (valid_pipe[2]) d_data <= d_net ? data_b : data_a;
            if (valid_pipe[2] && last_pipe[2]) dq_req <= 1;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk)
        if (!reset) begin
            if (fetch_command && (issuing || waiting_prepared || read_token || |valid_pipe || d_valid)) begin
                $display("[RX_ASSERT] queue header overwrote an active byte stream");
                $finish_and_return(1);
            end
            if (header_accept && (waiting_prepared || read_token || issuing)) begin
                $display("[RX_ASSERT] duplicate delivery ownership");
                $finish_and_return(1);
            end
            if (read_token && head_empty && (ring_a_re || ring_b_re)) begin
                $display("[RX_ASSERT] empty delivery inherited a ring read");
                $finish_and_return(1);
            end
        end
`endif

endmodule
