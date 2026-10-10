// 本地秒/纳秒时钟和RFC 4330 SNTP主从同步。
// cfg_*设置时钟及角色；rx/tx_*通过服务通道收发48字节NTP。
// 首字节采样四时间戳；分数换算、偏差计算和归一化分拍完成。
// RFC 4330 SNTPv4：48字节，四时间戳算法和首字节采样点不变。
module afdx_rtc (
    input wire clk, reset, enable,
    input wire cfg_we, cfg_re,
    input wire [3:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata,
    output reg [31:0] sync_count,
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output wire [6:0] tx_vl,
    output wire [15:0] tx_port,
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_port,
    output wire rx_claim);
    localparam NTP_EPOCH = 32'd3155673600;
    // 配置秒从2000-01-01 UTC起算，线上从1900年起算。
    reg active, master;
    reg [31:0] period, load_sec, load_ns;
    reg [6:0] vl;
    reg [15:0] port_number;
    reg [31:0] seconds, nanoseconds, snapshot_ns;
    reg signed [31:0] offset_sec;
    reg [31:0] offset_ns;
    wire load_time = cfg_we && cfg_addr == 0 && cfg_wdata[2];
    assign tx_vl = vl;
    assign tx_port = port_number;
    assign rx_claim = active && rx_port == port_number;
    // 12个32位字段的小寄存器组；无按VL展开的存储。
    reg [383:0] rx_packet;
    reg rx_busy, rx_done;
    reg [5:0] rx_index;
    reg [31:0] received_sec, received_ns;
    reg [31:0] req_sec, req_ns, echo_sec, echo_frac;
    reg [31:0] server_receive_sec, server_receive_ns, server_transmit_sec, server_transmit_ns;
    reg waiting, reply_pending, tx_reply;
    reg [31:0] countdown, tx_word, tx_word_low, tx_word_high;
    reg [5:0] tx_index;
    reg [2:0] tx_state;
    reg [3:0] calc_state;
    reg signed [31:0] diff_sec1, diff_sec2, diff_ns1, diff_ns2, sum_sec, sum_ns;
    reg signed [31:0] correction_sec, correction_ns;
    reg second_odd;
    reg [31:0] adjusted_sec, adjusted_ns;
    reg encode_tx_start, encode_rx_start, encode_rx_reference, decode_start;
    reg [31:0] encode_tx_value, encode_rx_value, decode_value;
    wire encode_tx_done, encode_rx_done, decode_done;
    wire [31:0] encode_tx_result, encode_rx_result, decode_result;
    reg [31:0] stamp_tx_sec, stamp_tx_frac, stamp_rx_sec, stamp_rx_frac, reference_sec, reference_frac;
    wire first_tx = active && enable && tx_state == 4 && tx_ready && tx_index == 0;
    wire first_rx = active && enable && rx_valid && rx_claim && ! rx_busy;
    afdx_ntp_fraction encode_tx (clk, reset, encode_tx_start, 1'b0, encode_tx_value, encode_tx_done, encode_tx_result);
    afdx_ntp_fraction encode_rx (clk, reset, encode_rx_start, 1'b0, encode_rx_value, encode_rx_done, encode_rx_result);
    afdx_ntp_fraction decode_rx (clk, reset, decode_start, 1'b1, decode_value, decode_done, decode_result);
    always @(posedge clk) begin
        if (reset) begin
            encode_tx_start <= 0;
            encode_rx_start <= 0;
            encode_rx_reference <= 0;
            encode_tx_value <= 0;
            encode_rx_value <= 0;
            stamp_tx_sec <= 0;
            stamp_tx_frac <= 0;
            stamp_rx_sec <= 0;
            stamp_rx_frac <= 0;
            reference_sec <= 0;
            reference_frac <= 0;
        end
        else begin
            encode_tx_start <= 0;
            encode_rx_start <= 0;
            if (first_tx) begin
                stamp_tx_sec <= seconds + NTP_EPOCH;
                encode_tx_value <= nanoseconds;
                encode_tx_start <= 1;
            end
            if (load_time) begin
                reference_sec <= load_sec + NTP_EPOCH;
                encode_rx_value <= load_ns;
                encode_rx_reference <= 1;
                encode_rx_start <= 1;
            end
            else if (first_rx && master) begin
                stamp_rx_sec <= seconds + NTP_EPOCH;
                encode_rx_value <= nanoseconds;
                encode_rx_reference <= 0;
                encode_rx_start <= 1;
            end
            if (encode_tx_done) stamp_tx_frac <= encode_tx_result;
            if (encode_rx_done) begin
                if (encode_rx_reference) reference_frac <= encode_rx_result;
                else stamp_rx_frac <= encode_rx_result;
            end
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            master <= 0;
            period <= 125000;
            vl <= 0;
            port_number <= 123;
            load_sec <= 0;
            load_ns <= 0;
            snapshot_ns <= 0;
            cfg_rdata <= 0;
        end
        else begin
            if (cfg_we) case (cfg_addr)
                0 : begin
                    active <= cfg_wdata[0];
                    master <= cfg_wdata[1];
                end
                1 : period <= cfg_wdata;
                2 : vl <= cfg_wdata[6:0];
                3 : port_number <= cfg_wdata[15:0];
                4 : load_sec <= cfg_wdata;
                5 : load_ns <= cfg_wdata;
            endcase
            // cfg模块提供第二级选择；读秒时同时快照纳秒。
            case (cfg_addr[2:0])
                0 : cfg_rdata <= { 30'b0, master, active };
                1 : cfg_rdata <= period;
                2 : cfg_rdata <= { 25'b0, vl };
                3 : cfg_rdata <= { 16'b0, port_number };
                4 : begin
                    cfg_rdata <= seconds;
                    if (cfg_re) snapshot_ns <= nanoseconds;
                end
                5 : cfg_rdata <= snapshot_ns;
                6 : cfg_rdata <= offset_sec;
                7 : cfg_rdata <= offset_ns;
                default : cfg_rdata <= 0;
            endcase
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            seconds <= 0;
            nanoseconds <= 0;
        end
        else if (load_time) begin
            seconds <= load_sec;
            nanoseconds <= load_ns;
        end
        else if (calc_state == 9) begin
            if (adjusted_ns >= 1000000000) begin
                seconds <= adjusted_sec + 32'd1;
                nanoseconds <= adjusted_ns - 32'd1000000000;
            end
            else begin
                seconds <= adjusted_sec;
                nanoseconds <= adjusted_ns;
            end
        end
        else if (nanoseconds >= 999999992) begin
            seconds <= seconds + 32'd1;
            nanoseconds <= nanoseconds - 32'd999999992;
        end
        else nanoseconds <= nanoseconds + 32'd8;
    end
    always @(posedge clk) begin
        if (reset) begin
            tx_valid <= 0;
            tx_data <= 0;
            tx_last <= 0;
            tx_state <= 0;
            tx_index <= 0;
            tx_word <= 0;
            tx_word_low <= 0;
            tx_word_high <= 0;
            tx_reply <= 0;
            rx_busy <= 0;
            rx_done <= 0;
            rx_index <= 0;
            rx_packet <= 0;
            received_sec <= 0;
            received_ns <= 0;
            req_sec <= 0;
            req_ns <= 0;
            echo_sec <= 0;
            echo_frac <= 0;
            server_receive_sec <= 0;
            server_receive_ns <= 0;
            server_transmit_sec <= 0;
            server_transmit_ns <= 0;
            decode_start <= 0;
            decode_value <= 0;
            waiting <= 0;
            reply_pending <= 0;
            countdown <= 0;
            calc_state <= 0;
            diff_sec1 <= 0;
            diff_sec2 <= 0;
            diff_ns1 <= 0;
            diff_ns2 <= 0;
            sum_sec <= 0;
            sum_ns <= 0;
            correction_sec <= 0;
            correction_ns <= 0;
            second_odd <= 0;
            adjusted_sec <= 0;
            adjusted_ns <= 0;
            offset_sec <= 0;
            offset_ns <= 0;
            sync_count <= 0;
        end
        else if (! active || ! enable || load_time) begin
            tx_valid <= 0;
            tx_last <= 0;
            tx_state <= 0;
            rx_busy <= 0;
            rx_done <= 0;
            waiting <= 0;
            reply_pending <= 0;
            countdown <= 0;
            calc_state <= 0;
            decode_start <= 0;
        end
        else begin
            rx_done <= 0;
            decode_start <= 0;
            if (countdown != 0) countdown <= countdown - 32'd1;
            if (rx_valid && rx_claim) begin
                rx_packet <= { rx_packet[375:0], rx_data };
                rx_busy <= ! rx_last;
                if (! rx_busy) begin
                    received_sec <= seconds;
                    received_ns <= nanoseconds;
                    rx_index <= 1;
                end
                else rx_index <= rx_index + 6'd1;
                if (rx_last && rx_index == 47) rx_done <= 1;
            end
            if (rx_done && rx_packet[381:379] == 4) begin
                if (master && rx_packet[378:376] == 3) begin
                    // Originate逐位复制请求的Transmit，不做纳秒往返换算。
                    echo_sec <= rx_packet[63:32];
                    echo_frac <= rx_packet[31:0];
                    reply_pending <= 1;
                end
                // 重发尚未发完时，新时间戳仍在更新，旧回应不得进入校时。
                else if (! master && waiting && tx_state == 0 && rx_packet[378:376] == 4 && rx_packet[191:160] == stamp_tx_sec && rx_packet[159:128] == stamp_tx_frac) begin
                    server_receive_sec <= rx_packet[127:96] - NTP_EPOCH;
                    server_transmit_sec <= rx_packet[63:32] - NTP_EPOCH;
                    calc_state <= 10;
                end
            end
            case (calc_state)
                10 : begin
                    decode_value <= rx_packet[95:64];
                    decode_start <= 1;
                    calc_state <= 11;
                end
                11 : if (decode_done) begin
                    server_receive_ns <= decode_result;
                    calc_state <= 12;
                end
                12 : begin
                    decode_value <= rx_packet[31:0];
                    decode_start <= 1;
                    calc_state <= 13;
                end
                13 : if (decode_done) begin
                    server_transmit_ns <= decode_result;
                    calc_state <= 14;
                end
                14 : begin
                    diff_sec1 <= $signed (server_receive_sec) - $signed (req_sec);
                    diff_ns1 <= $signed (server_receive_ns) - $signed (req_ns);
                    diff_sec2 <= $signed (server_transmit_sec) - $signed (received_sec);
                    diff_ns2 <= $signed (server_transmit_ns) - $signed (received_ns);
                    calc_state <= 2;
                end
                2 : begin
                    sum_sec <= diff_sec1 + diff_sec2;
                    sum_ns <= diff_ns1 + diff_ns2;
                    calc_state <= 3;
                end
                3 : begin
                    correction_sec <= sum_sec >>> 1;
                    correction_ns <= sum_ns >>> 1;
                    second_odd <= sum_sec[0];
                    calc_state <= 4;
                end
                4 : begin
                    correction_ns <= correction_ns + (second_odd ? 32'sd500000000 : 32'sd0);
                    calc_state <= 5;
                end
                5 : begin
                    if (correction_ns < 0) begin
                        correction_ns <= correction_ns + 32'sd1000000000;
                        correction_sec <= correction_sec - 32'sd1;
                    end
                    else if (correction_ns >= 1000000000) begin
                        correction_ns <= correction_ns - 32'sd1000000000;
                        correction_sec <= correction_sec + 32'sd1;
                    end
                    calc_state <= 6;
                end
                6 : begin
                    adjusted_sec <= seconds + correction_sec;
                    adjusted_ns <= nanoseconds + correction_ns;
                    calc_state <= 7;
                end
                7 : begin
                    if (adjusted_ns >= 1000000000) begin
                        adjusted_ns <= adjusted_ns - 32'd1000000000;
                        adjusted_sec <= adjusted_sec + 32'd1;
                    end
                    calc_state <= 8;
                end
                8 : begin
                    adjusted_ns <= adjusted_ns + 32'd32;
                    calc_state <= 9;
                end
                9 : begin
                    offset_sec <= correction_sec;
                    offset_ns <= correction_ns;
                    sync_count <= sync_count + 32'd1;
                    waiting <= 0;
                    calc_state <= 0;
                end
            endcase
            case (tx_state)
                0 : begin
                    tx_valid <= 0;
                    tx_last <= 0;
                    tx_index <= 0;
                    if (master && reply_pending) begin
                        tx_reply <= 1;
                        reply_pending <= 0;
                        tx_state <= 1;
                    end
                    // 周期到期重发；接收完成或校时计算中不覆盖本次时间戳。
                    else if (! master && countdown == 0 && calc_state == 0 && ! rx_done) begin
                        tx_reply <= 0;
                        waiting <= 1;
                        countdown <= period;
                        tx_state <= 1;
                    end
                end
                1 : begin
                    // 先按8字/4字分组，再选组和字节，避免12选1组合路径。
                    case (tx_index[4:2])
                        0 : tx_word_low <= tx_reply ? 32'h240104e6 : 32'h230004e6;
                        1 : tx_word_low <= 0;
                        2 : tx_word_low <= 0;
                        3 : tx_word_low <= tx_reply ? 32'h4c4f434c : 32'd0;
                        4 : tx_word_low <= tx_reply ? reference_sec : 32'd0;
                        5 : tx_word_low <= tx_reply ? reference_frac : 32'd0;
                        6 : tx_word_low <= tx_reply ? echo_sec : 32'd0;
                        7 : tx_word_low <= tx_reply ? echo_frac : 32'd0;
                    endcase
                    case (tx_index[3:2])
                        0 : tx_word_high <= tx_reply ? stamp_rx_sec : 32'd0;
                        1 : tx_word_high <= tx_reply ? stamp_rx_frac : 32'd0;
                        2 : tx_word_high <= stamp_tx_sec;
                        3 : tx_word_high <= stamp_tx_frac;
                    endcase
                    tx_state <= 2;
                end
                2 : begin
                    tx_word <= tx_index[5] ? tx_word_high : tx_word_low;
                    tx_state <= 3;
                end
                3 : begin
                    case (tx_index[1:0])
                        0 : tx_data <= tx_word[31:24];
                        1 : tx_data <= tx_word[23:16];
                        2 : tx_data <= tx_word[15:8];
                        3 : tx_data <= tx_word[7:0];
                    endcase
                    tx_valid <= 1;
                    tx_last <= (tx_index == 47);
                    tx_state <= 4;
                end
                4 : if (tx_ready) begin
                    if (tx_index == 0 && ! tx_reply) begin
                        req_sec <= seconds;
                        req_ns <= nanoseconds;
                    end
                    tx_valid <= 0;
                    tx_last <= 0;
                    if (tx_index == 47) tx_state <= 0;
                    else begin
                        tx_index <= tx_index + 6'd1;
                        tx_state <= 1;
                    end
                end
            endcase
        end
    end
endmodule
