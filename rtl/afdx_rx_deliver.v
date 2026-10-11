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
    output reg d_valid,
    output reg [7:0] d_data,
    output reg d_last,
    output reg [11:0] d_vl,
    output reg [15:0] d_sport, d_dport,
    output reg d_net);
    localparam DQ_WIDTH = RX_RING_AW + 56;
    // rd_ptr 指向下一条消息。
    // 消息信息分两级选择，以减少一拍内的选择层数。
    reg [RX_DQ_AW - 1:0] rd_ptr;
    wire [4:0] read_index = rd_ptr;
    // head_phase=0：有消息且收到读请求时选择组内项，然后转 1。
    // head_phase=1：选出完整队首信息并移除该项，然后转 2。
    // head_phase=2：等待 dq_req 撤销，然后转 0。
    reg [1:0] head_phase;
    reg [1:0] head_bank;
    reg [DQ_WIDTH - 1:0] group0, group1, group2, group3, dq_data;
    reg dq_req, dq_valid;
    // issuing/left 控制连续读取和剩余字节数。
    // valid_pipe/last_pipe 将有效与末字节标记对齐到读出数据。
    reg issuing;
    reg [10:0] left;
    reg [2:0] valid_pipe, last_pipe;
    reg [7:0] data_a, data_b;
    always @(posedge clk) begin
        if (reset) begin
            dq_req <= 1;
            dq_valid <= 0;
            dq_pop <= 0;
            rd_ptr <= 0;
            head_phase <= 0;
            head_bank <= 0;
            group0 <= 0;
            group1 <= 0;
            group2 <= 0;
            group3 <= 0;
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
                0 : if (dq_req && dq_count != 0) begin
                    // 先在四组内分别选一项，下一拍再从四组结果中选出一项。
                    case (read_index[2:0])
                        0 : begin
                            group0 <= dq_entries[1 * DQ_WIDTH - 1:0 * DQ_WIDTH];
                            group1 <= dq_entries[9 * DQ_WIDTH - 1:8 * DQ_WIDTH];
                            group2 <= dq_entries[17 * DQ_WIDTH - 1:16 * DQ_WIDTH];
                            group3 <= dq_entries[25 * DQ_WIDTH - 1:24 * DQ_WIDTH];
                        end
                        1 : begin
                            group0 <= dq_entries[2 * DQ_WIDTH - 1:1 * DQ_WIDTH];
                            group1 <= dq_entries[10 * DQ_WIDTH - 1:9 * DQ_WIDTH];
                            group2 <= dq_entries[18 * DQ_WIDTH - 1:17 * DQ_WIDTH];
                            group3 <= dq_entries[26 * DQ_WIDTH - 1:25 * DQ_WIDTH];
                        end
                        2 : begin
                            group0 <= dq_entries[3 * DQ_WIDTH - 1:2 * DQ_WIDTH];
                            group1 <= dq_entries[11 * DQ_WIDTH - 1:10 * DQ_WIDTH];
                            group2 <= dq_entries[19 * DQ_WIDTH - 1:18 * DQ_WIDTH];
                            group3 <= dq_entries[27 * DQ_WIDTH - 1:26 * DQ_WIDTH];
                        end
                        3 : begin
                            group0 <= dq_entries[4 * DQ_WIDTH - 1:3 * DQ_WIDTH];
                            group1 <= dq_entries[12 * DQ_WIDTH - 1:11 * DQ_WIDTH];
                            group2 <= dq_entries[20 * DQ_WIDTH - 1:19 * DQ_WIDTH];
                            group3 <= dq_entries[28 * DQ_WIDTH - 1:27 * DQ_WIDTH];
                        end
                        4 : begin
                            group0 <= dq_entries[5 * DQ_WIDTH - 1:4 * DQ_WIDTH];
                            group1 <= dq_entries[13 * DQ_WIDTH - 1:12 * DQ_WIDTH];
                            group2 <= dq_entries[21 * DQ_WIDTH - 1:20 * DQ_WIDTH];
                            group3 <= dq_entries[29 * DQ_WIDTH - 1:28 * DQ_WIDTH];
                        end
                        5 : begin
                            group0 <= dq_entries[6 * DQ_WIDTH - 1:5 * DQ_WIDTH];
                            group1 <= dq_entries[14 * DQ_WIDTH - 1:13 * DQ_WIDTH];
                            group2 <= dq_entries[22 * DQ_WIDTH - 1:21 * DQ_WIDTH];
                            group3 <= dq_entries[30 * DQ_WIDTH - 1:29 * DQ_WIDTH];
                        end
                        6 : begin
                            group0 <= dq_entries[7 * DQ_WIDTH - 1:6 * DQ_WIDTH];
                            group1 <= dq_entries[15 * DQ_WIDTH - 1:14 * DQ_WIDTH];
                            group2 <= dq_entries[23 * DQ_WIDTH - 1:22 * DQ_WIDTH];
                            group3 <= dq_entries[31 * DQ_WIDTH - 1:30 * DQ_WIDTH];
                        end
                        7 : begin
                            group0 <= dq_entries[8 * DQ_WIDTH - 1:7 * DQ_WIDTH];
                            group1 <= dq_entries[16 * DQ_WIDTH - 1:15 * DQ_WIDTH];
                            group2 <= dq_entries[24 * DQ_WIDTH - 1:23 * DQ_WIDTH];
                            group3 <= dq_entries[32 * DQ_WIDTH - 1:31 * DQ_WIDTH];
                        end
                    endcase
                    head_bank <= read_index[4:3];
                    head_phase <= 1;
                end
                1 : begin
                    case (head_bank)
                        0 : dq_data <= group0;
                        1 : dq_data <= group1;
                        2 : dq_data <= group2;
                        3 : dq_data <= group3;
                    endcase
                    dq_valid <= 1;
                    dq_pop <= 1;
                    rd_ptr <= rd_ptr + 1'b1;
                    head_phase <= 2;
                end
                2 : if (! dq_req) head_phase <= 0;
                default : head_phase <= 0;
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
