// 本模块把检查通过的消息从接收缓存逐字节读出。
// afdx_rx_engine 提供消息位置，读出的内容交给 afdx_svc。
// 本模块完成赛题的接收消息交付，并释放已读完的缓存空间。
module afdx_rx_deliver #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 5) (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // dq_count 表示等待交付的消息数，dq_entries 保存这些消息的信息。
    // 保存队首消息后，dq_pop 输出一拍，通知队列移除该项。
    input wire [RX_DQ_AW:0] dq_count,
    input wire [32 * (RX_RING_AW + 56) - 1:0] dq_entries,
    output reg dq_pop,

    // ring_a/b_* 从选中网络的缓存读字节。
    // read_ptr_a/b 通知解析器哪些空间已读完，可以重新使用。
    output reg ring_a_re, ring_b_re,
    output reg [RX_RING_AW - 1:0] ring_a_ra, ring_b_ra,
    input wire [7:0] ring_a_q, ring_b_q,
    output reg [RX_RING_AW:0] read_ptr_a, read_ptr_b,

    // d_valid 为高时，接收方必须取走本拍 d_data，d_last 标记末字节。
    // 虚拟链路索引、端口和来源网络在整条消息期间保持不变。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg d_valid,
    output reg [7:0] d_data,
    output reg d_last,
    output reg [11:0] d_vl,
    output reg [15:0] d_sport, d_dport,
    output reg d_net);

    localparam DQ_WIDTH = RX_RING_AW + 56;

    // head_phase 的取值：取出队首消息信息的三步。
    localparam HEAD_IDLE = 0, HEAD_SELECT = 1, HEAD_RELEASE = 2;

    // rd_ptr 指向下一条消息。
    // 消息信息分两级选择，以减少一拍内的选择层数。
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [RX_DQ_AW - 1:0] rd_ptr;
    wire [4:0] read_index = rd_ptr;

    // HEAD_IDLE：有消息且收到读请求时选择组内项，然后转 HEAD_SELECT。
    // HEAD_SELECT：选出完整队首信息并移除该项，然后转 HEAD_RELEASE。
    // HEAD_RELEASE：等待 dq_req 撤销，然后转 HEAD_IDLE。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg [1:0] head_phase;
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [1:0] head_bank;
    wire [DQ_WIDTH - 1:0] group0, group1, group2, group3;
    reg [DQ_WIDTH - 1:0] dq_data;
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg dq_req, dq_valid;

    // issuing/left 控制连续读取和剩余字节数。
    // valid_pipe/last_pipe 将有效与末字节标记对齐到读出数据。
    reg issuing;
    reg [10:0] left;
    reg [2:0] valid_pipe, last_pipe;
    reg [7:0] data_a, data_b;

    // 每 8 个消息信息位独立保存读指针，避免组内译码驱动整片队列。
    // 副本和 rd_ptr 同拍复位、递增；选择仍在请求拍完成，不增加交付延迟。
    genvar queue_bit;
    generate
        for (queue_bit = 0; queue_bit < DQ_WIDTH; queue_bit = queue_bit + 8) begin : queue_bank0
            localparam WIDTH = DQ_WIDTH - queue_bit < 8 ? DQ_WIDTH - queue_bit : 8;
            (* preserve = 1, dont_merge = 1 *) reg [RX_DQ_AW - 1:0] local_rd_ptr;
            wire [4:0] local_index = local_rd_ptr;
            reg [WIDTH - 1:0] selected;
            assign group0[queue_bit +: WIDTH] = selected;
            always @(posedge clk) begin
                if (reset) begin
                    local_rd_ptr <= 0;
                    selected <= 0;
                end
                else begin
                    if (head_phase == HEAD_SELECT) local_rd_ptr <= local_rd_ptr + 1'b1;
                    case (local_index[2:0])
                        3'd0: selected <= dq_entries[0 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd1: selected <= dq_entries[1 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd2: selected <= dq_entries[2 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd3: selected <= dq_entries[3 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd4: selected <= dq_entries[4 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd5: selected <= dq_entries[5 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd6: selected <= dq_entries[6 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd7: selected <= dq_entries[7 * DQ_WIDTH + queue_bit +: WIDTH];
                    endcase
                end
            end
        end
        for (queue_bit = 0; queue_bit < DQ_WIDTH; queue_bit = queue_bit + 8) begin : queue_bank1
            localparam WIDTH = DQ_WIDTH - queue_bit < 8 ? DQ_WIDTH - queue_bit : 8;
            (* preserve = 1, dont_merge = 1 *) reg [RX_DQ_AW - 1:0] local_rd_ptr;
            wire [4:0] local_index = local_rd_ptr;
            reg [WIDTH - 1:0] selected;
            assign group1[queue_bit +: WIDTH] = selected;
            always @(posedge clk) begin
                if (reset) begin
                    local_rd_ptr <= 0;
                    selected <= 0;
                end
                else begin
                    if (head_phase == HEAD_SELECT) local_rd_ptr <= local_rd_ptr + 1'b1;
                    case (local_index[2:0])
                        3'd0: selected <= dq_entries[8 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd1: selected <= dq_entries[9 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd2: selected <= dq_entries[10 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd3: selected <= dq_entries[11 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd4: selected <= dq_entries[12 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd5: selected <= dq_entries[13 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd6: selected <= dq_entries[14 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd7: selected <= dq_entries[15 * DQ_WIDTH + queue_bit +: WIDTH];
                    endcase
                end
            end
        end
        for (queue_bit = 0; queue_bit < DQ_WIDTH; queue_bit = queue_bit + 8) begin : queue_bank2
            localparam WIDTH = DQ_WIDTH - queue_bit < 8 ? DQ_WIDTH - queue_bit : 8;
            (* preserve = 1, dont_merge = 1 *) reg [RX_DQ_AW - 1:0] local_rd_ptr;
            wire [4:0] local_index = local_rd_ptr;
            reg [WIDTH - 1:0] selected;
            assign group2[queue_bit +: WIDTH] = selected;
            always @(posedge clk) begin
                if (reset) begin
                    local_rd_ptr <= 0;
                    selected <= 0;
                end
                else begin
                    if (head_phase == HEAD_SELECT) local_rd_ptr <= local_rd_ptr + 1'b1;
                    case (local_index[2:0])
                        3'd0: selected <= dq_entries[16 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd1: selected <= dq_entries[17 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd2: selected <= dq_entries[18 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd3: selected <= dq_entries[19 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd4: selected <= dq_entries[20 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd5: selected <= dq_entries[21 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd6: selected <= dq_entries[22 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd7: selected <= dq_entries[23 * DQ_WIDTH + queue_bit +: WIDTH];
                    endcase
                end
            end
        end
        for (queue_bit = 0; queue_bit < DQ_WIDTH; queue_bit = queue_bit + 8) begin : queue_bank3
            localparam WIDTH = DQ_WIDTH - queue_bit < 8 ? DQ_WIDTH - queue_bit : 8;
            (* preserve = 1, dont_merge = 1 *) reg [RX_DQ_AW - 1:0] local_rd_ptr;
            wire [4:0] local_index = local_rd_ptr;
            reg [WIDTH - 1:0] selected;
            assign group3[queue_bit +: WIDTH] = selected;
            always @(posedge clk) begin
                if (reset) begin
                    local_rd_ptr <= 0;
                    selected <= 0;
                end
                else begin
                    if (head_phase == HEAD_SELECT) local_rd_ptr <= local_rd_ptr + 1'b1;
                    case (local_index[2:0])
                        3'd0: selected <= dq_entries[24 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd1: selected <= dq_entries[25 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd2: selected <= dq_entries[26 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd3: selected <= dq_entries[27 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd4: selected <= dq_entries[28 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd5: selected <= dq_entries[29 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd6: selected <= dq_entries[30 * DQ_WIDTH + queue_bit +: WIDTH];
                        3'd7: selected <= dq_entries[31 * DQ_WIDTH + queue_bit +: WIDTH];
                    endcase
                end
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (reset) begin
            dq_req <= 1;
            dq_valid <= 0;
            dq_pop <= 0;
            rd_ptr <= 0;
            head_phase <= HEAD_IDLE;
            head_bank <= 0;
            dq_data <= 0;
            ring_a_re <= 0;
            ring_b_re <= 0;
            ring_a_ra <= 0;
            ring_b_ra <= 0;
            read_ptr_a <= 0;
            read_ptr_b <= 0;
            d_valid <= 0;
            d_data <= 0;
            d_last <= 0;
            d_vl <= 0;
            d_sport <= 0;
            d_dport <= 0;
            d_net <= 0;
            issuing <= 0;
            left <= 0;
            valid_pipe <= 0;
            last_pipe <= 0;
            data_a <= 0;
            data_b <= 0;
        end
        else begin
            dq_valid <= 0;
            dq_pop <= 0;
            case (head_phase)

                HEAD_IDLE : if (dq_req && dq_count != 0) begin
                    // 先在四组内分别选一项，下一拍再从四组结果中选出一项。

                    head_bank <= read_index[4:3];
                    head_phase <= HEAD_SELECT;
                end

                HEAD_SELECT : begin
                    case (head_bank)
                        0 : dq_data <= group0;
                        1 : dq_data <= group1;
                        2 : dq_data <= group2;
                        3 : dq_data <= group3;
                    endcase
                    dq_valid <= 1;
                    dq_pop <= 1;
                    rd_ptr <= rd_ptr + 1'b1;
                    head_phase <= HEAD_RELEASE;
                end

                HEAD_RELEASE : if ( ! dq_req) head_phase <= HEAD_IDLE;

                default : head_phase <= HEAD_IDLE;
            endcase
            ring_a_re <= 0;
            ring_b_re <= 0;
            valid_pipe <= { valid_pipe[1:0], 1'b0 };
            last_pipe <= { last_pipe[1:0], 1'b0 };
            // 两网读结果分别寄存后再选一路，实际读出时推进读指针。
            data_a <= ring_a_q;
            data_b <= ring_b_q;
            if (ring_a_re) read_ptr_a <= read_ptr_a + 1'b1;
            if (ring_b_re) read_ptr_b <= read_ptr_b + 1'b1;
            d_valid <= valid_pipe[2];
            d_last <= valid_pipe[2] && last_pipe[2];
            if (valid_pipe[2]) d_data <= d_net ? data_b : data_a;
            if (valid_pipe[2] && last_pipe[2]) dq_req <= 1;
            // 接纳消息信息后，每拍读一个字节，发完末字节后才取下一条消息。
            if (dq_valid && dq_req) begin
                dq_req <= 0;
                d_net <= dq_data[RX_RING_AW + 55];
                d_vl <= dq_data[43:32];
                d_sport <= dq_data[31:16];
                d_dport <= dq_data[15:0];
                ring_a_ra <= dq_data[RX_RING_AW + 54:55];
                ring_b_ra <= dq_data[RX_RING_AW + 54:55];
                ring_a_re <= ! dq_data[RX_RING_AW + 55];
                ring_b_re <= dq_data[RX_RING_AW + 55];
                valid_pipe[0] <= 1;
                last_pipe[0] <= dq_data[54:44] == 1;
                left <= dq_data[54:44] - 1'b1;
                issuing <= dq_data[54:44] > 1;
            end
            else if (issuing) begin
                ring_a_re <= ! d_net;
                ring_b_re <= d_net;
                ring_a_ra <= ring_a_ra + 1'b1;
                ring_b_ra <= ring_b_ra + 1'b1;
                valid_pipe[0] <= 1;
                last_pipe[0] <= left == 1;
                left <= left - 1'b1;
                if (left == 1) issuing <= 0;
            end
        end
    end

endmodule
