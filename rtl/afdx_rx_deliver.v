// 按已接纳的描述读取接收环形缓冲，连续交付UDP载荷。
// 描述队列给出来源、地址及元数据；d_*为无反压应用输出。
// 读口和预取流水线归本模块；交付结束后更新已释放的环形地址。
// 交付状态：两拍选择队头、连续发出同步RAM读请求、三级数据流水、末字节后再取。
module afdx_rx_deliver #(
    parameter RX_RING_AW = 12, RX_DQ_AW = 4) (
    input wire clk, reset,
    input wire [RX_DQ_AW:0] dq_count,
    input wire [16 * (RX_RING_AW + 56) - 1:0] dq_entries,
    output reg dq_pop,
    output reg ring_a_re, ring_b_re,
    output reg [RX_RING_AW - 1:0] ring_a_ra, ring_b_ra,
    input wire [7:0] ring_a_q, ring_b_q,
    output reg [RX_RING_AW:0] read_ptr_a, read_ptr_b,
    output reg d_valid,
    output reg [7:0] d_data,
    output reg d_last,
    output reg [11:0] d_vl,
    output reg [15:0] d_sport, d_dport,
    output reg d_net);
    localparam DQ_WIDTH = RX_RING_AW + 56;
    reg [RX_DQ_AW - 1:0] rd_ptr;
    wire [3:0] read_index = rd_ptr;
    reg [1:0] head_phase;
    reg head_bank;
    reg [DQ_WIDTH - 1:0] group0, group1, dq_data;
    reg dq_req, dq_valid;
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
                    // 16项寄存器组先各八选一，下一拍二选一；只由本模块读。
                    case (read_index[2:0])
                        0 : begin
                            group0 <= dq_entries[1 * DQ_WIDTH - 1:0 * DQ_WIDTH];
                            group1 <= dq_entries[9 * DQ_WIDTH - 1:8 * DQ_WIDTH];
                        end
                        1 : begin
                            group0 <= dq_entries[2 * DQ_WIDTH - 1:1 * DQ_WIDTH];
                            group1 <= dq_entries[10 * DQ_WIDTH - 1:9 * DQ_WIDTH];
                        end
                        2 : begin
                            group0 <= dq_entries[3 * DQ_WIDTH - 1:2 * DQ_WIDTH];
                            group1 <= dq_entries[11 * DQ_WIDTH - 1:10 * DQ_WIDTH];
                        end
                        3 : begin
                            group0 <= dq_entries[4 * DQ_WIDTH - 1:3 * DQ_WIDTH];
                            group1 <= dq_entries[12 * DQ_WIDTH - 1:11 * DQ_WIDTH];
                        end
                        4 : begin
                            group0 <= dq_entries[5 * DQ_WIDTH - 1:4 * DQ_WIDTH];
                            group1 <= dq_entries[13 * DQ_WIDTH - 1:12 * DQ_WIDTH];
                        end
                        5 : begin
                            group0 <= dq_entries[6 * DQ_WIDTH - 1:5 * DQ_WIDTH];
                            group1 <= dq_entries[14 * DQ_WIDTH - 1:13 * DQ_WIDTH];
                        end
                        6 : begin
                            group0 <= dq_entries[7 * DQ_WIDTH - 1:6 * DQ_WIDTH];
                            group1 <= dq_entries[15 * DQ_WIDTH - 1:14 * DQ_WIDTH];
                        end
                        7 : begin
                            group0 <= dq_entries[8 * DQ_WIDTH - 1:7 * DQ_WIDTH];
                            group1 <= dq_entries[16 * DQ_WIDTH - 1:15 * DQ_WIDTH];
                        end
                    endcase
                    head_bank <= read_index[3];
                    head_phase <= 1;
                end
                1 : begin
                    dq_data <= head_bank ? group1 : group0;
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
            // RAM输出先各自寄存，再作两选一；读指针在RAM实际读取那拍前进。
            data_a <= ring_a_q;
            data_b <= ring_b_q;
            if (ring_a_re) read_ptr_a <= read_ptr_a + 1'b1;
            if (ring_b_re) read_ptr_b <= read_ptr_b + 1'b1;
            d_valid <= valid_pipe[2];
            d_last <= valid_pipe[2] && last_pipe[2];
            if (valid_pipe[2]) d_data <= d_net ? data_b : data_a;
            if (valid_pipe[2] && last_pipe[2]) dq_req <= 1;
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
