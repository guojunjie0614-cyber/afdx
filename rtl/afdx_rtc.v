// 本模块维护本地时钟，并通过网络请求和回应校准时间。
// 它通过 afdx_svc 收发报文，通过配置口设置主从角色和读取时间。
// 本模块对应赛题的 RTC（Real-Time Clock，实时时钟）同步功能。
// SNTP（Simple Network Time Protocol，简单网络时间协议）
// 用四个收发时间戳估算本地时钟的偏差。
module afdx_rtc #(parameter LOCAL_RX_PORT = 0, BANKED_RX = 0, SPLIT_CFG_ADDR = 0) (

    // enable 为高表示收发核心就绪，本地时钟每拍增加 8 ns。
    input wire clk, reset, enable,

    // cfg_* 设置主从角色、请求周期和报文端口，也可装载时间。
    // 读取秒时同时保存纳秒值，sync_count 统计成功校时次数。
    input wire cfg_we, cfg_re,
    input wire [(SPLIT_CFG_ADDR ? 8 : 4) - 1:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata,
    output reg [31:0] sync_count,

    // tx_valid 和 tx_ready 同为高时发送一个时间报文字节。
    // tx_last 标记第 48 个字节，tx_vl/port 选择发送通道。
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output wire [6:0] tx_vl,
    output wire [15:0] tx_port,

    // rx_valid 为高时接收一个字节，满 48 字节后才置 rx_done。
    // rx_claim 为高表示接收端口匹配本服务。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_port,
    output wire rx_claim);

    // 高 4 位专供主机写译码，低 4 位保持共享读地址。
    wire [3:0] cfg_write_addr = SPLIT_CFG_ADDR ? cfg_addr >> 4 : cfg_addr;

    localparam CALC_IDLE = 0;
    localparam CALC_START_T2 = 10;
    localparam CALC_WAIT_T2 = 11;
    localparam CALC_START_T3 = 12;
    localparam CALC_WAIT_T3 = 13;
    localparam CALC_DIFFERENCES = 14;
    localparam CALC_SUM = 2;
    localparam CALC_HALF = 3;
    localparam CALC_HALF_SECOND = 4;
    localparam CALC_NORMALIZE_OFFSET = 5;
    localparam CALC_ADD_OFFSET = 6;
    localparam CALC_NORMALIZE_TIME = 7;
    localparam CALC_LATENCY = 8;
    localparam CALC_APPLY = 9;
    localparam NTP_EPOCH = 32'd3155673600;

    // tx_state 的取值。
    localparam TX_IDLE = 0, TX_GROUPS = 1, TX_WORD = 2, TX_BYTE = 3, TX_HANDSHAKE = 4;

    // 一秒的纳秒数（无符号和有符号两种写法，分别用于本地时间和带符号的校正量）、半秒的纳秒数。
    localparam NS_PER_SECOND = 32'd1000000000, NS_PER_SECOND_S = 32'sd1000000000;
    localparam HALF_SECOND_NS_S = 32'sd500000000;

    // 时钟周期 8 ns；纳秒数到达 LAST_TICK_NS 时，下一拍进位到秒。
    // 校正量从算出到生效经过 4 拍，所以再补 32 ns。
    localparam CLOCK_NS = 32'd8, LAST_TICK_NS = 32'd999999992, PIPELINE_NS = 32'd32;

    // 复位后的请求周期（125000 拍即 1 ms）和服务端口。
    localparam DEFAULT_PERIOD = 125000, NTP_PORT = 123;

    // 报文共 48 字节，PACKET_LAST 是末字节的下标。
    localparam PACKET_LAST = 47;

    // 报文首字节里的版本号和模式：3 是客户端请求，4 是服务端回应。
    localparam NTP_VERSION = 4, MODE_CLIENT = 3, MODE_SERVER = 4;

    // 回应和请求的报文首字，以及回应里的参考标识，含义见发送处的说明。
    localparam REPLY_HEADER = 32'h240104e6, REQUEST_HEADER = 32'h230004e6, REFERENCE_ID = 32'h4c4f434c;

    // 配置字的序号。
    localparam REG_CONTROL = 0, REG_PERIOD = 1, REG_VL = 2, REG_PORT = 3, REG_SECONDS = 4, REG_NS = 5;
    localparam REG_OFFSET_SEC = 6, REG_OFFSET_NS = 7;

    // 配置秒从2000-01-01 UTC起算，线上从1900年起算。
    // active 表示服务已启用，master 为高表示本机是服务端。
    // 客户端用 period/countdown 控制请求间隔。
    reg active, master;
    reg [31:0] period, load_sec, load_ns;
    reg [6:0] vl;
    reg [15:0] port_number;

    // seconds/nanoseconds 保存本地时间。
    // offset_sec/ns 保存最近一次校正量。
    // snapshot_ns 保存读秒时的纳秒值，便于分两次读出完整时间。
    reg [31:0] seconds, nanoseconds, snapshot_ns;
    reg signed [31:0] offset_sec;
    reg [31:0] offset_ns;
    wire load_time = cfg_we && cfg_write_addr == 0 && cfg_wdata[2];

    assign tx_vl = vl;
    assign tx_port = port_number;
    // 顶层交付口提前三拍给出端口，两级局部寄存分摊跨模块布线。
    // 独立使用本模块时，默认保持端口与有效字节同时到达的接口。
    (* preserve = 1, dont_merge = 1 *) reg [15:0] rx_port_stage, rx_port_local;
    wire [15:0] incoming_port = LOCAL_RX_PORT ? rx_port_local : rx_port;
    always @(posedge clk) begin
        if (reset) begin
            rx_port_stage <= 0;
            rx_port_local <= 0;
        end
        else begin
            rx_port_stage <= rx_port;
            rx_port_local <= rx_port_stage;
        end
    end

    assign rx_claim = active && incoming_port == port_number;

    // 报文的 12 个 32 位字段保存在寄存器中。
    reg [383:0] rx_packet;
    reg rx_busy, rx_done;
    reg rx_done_delayed;
    wire packet_done = BANKED_RX ? rx_done_delayed : rx_done;
    reg [5:0] rx_index;
    reg [31:0] received_sec, received_ns;

    // T1 是客户端发送请求的时间，由 req 保存。
    // T2 是服务端收到请求的时间，由 server_receive 保存。
    // T3 是服务端发送回应的时间，由 server_transmit 保存。
    // T4 是客户端收到回应的时间，由 received 保存。
    // 这些时间都在服务接口传输首字节时采样。
    reg [31:0] req_sec, req_ns, echo_sec, echo_frac;
    reg [31:0] server_receive_sec, server_receive_ns, server_transmit_sec, server_transmit_ns;

    // waiting 表示客户端仍在等回应，reply_pending 表示服务端有待发回应。
    // echo_* 原样回送请求中的发送时间，供客户端匹配本次请求。
    reg waiting, reply_pending, tx_reply;
    reg [31:0] countdown, tx_word, tx_word_low, tx_word_high;
    reg [5:0] tx_index;

    // TX_IDLE：等待回应任务或请求到期，满足条件后转 TX_GROUPS。
    // TX_GROUPS：选出两组候选字，下一拍转 TX_WORD。
    // TX_WORD：选出当前字，下一拍转 TX_BYTE。
    // TX_BYTE：选出当前字节并置 valid，下一拍转 TX_HANDSHAKE。
    // TX_HANDSHAKE：等待握手；还有字节时转 TX_GROUPS，报文结束后转 TX_IDLE。
    reg [2:0] tx_state;

    // CALC_IDLE：等待匹配的回应，收到后转 CALC_START_T2。
    // CALC_START_T2：启动 T2 小数换算，下一拍转 CALC_WAIT_T2。
    // CALC_WAIT_T2：等待 T2 换算完成，然后转 CALC_START_T3。
    // CALC_START_T3：启动 T3 小数换算，下一拍转 CALC_WAIT_T3。
    // CALC_WAIT_T3：等待 T3 换算完成，然后转 CALC_DIFFERENCES。
    // CALC_DIFFERENCES：计算 T2-T1 和 T3-T4，下一拍转 CALC_SUM。
    // CALC_SUM：相加两段时间差，下一拍转 CALC_HALF。
    // CALC_HALF：把和除以二，下一拍转 CALC_HALF_SECOND。
    // CALC_HALF_SECOND：补入奇数秒对应的半秒，下一拍转 CALC_NORMALIZE_OFFSET。
    // CALC_NORMALIZE_OFFSET：处理纳秒的借位或进位，下一拍转 CALC_ADD_OFFSET。
    // CALC_ADD_OFFSET：把校正量加到本地时间，下一拍转 CALC_NORMALIZE_TIME。
    // CALC_NORMALIZE_TIME：处理新的秒边界，下一拍转 CALC_LATENCY。
    // CALC_LATENCY：补偿计算经过的 32 ns，下一拍转 CALC_APPLY。
    // CALC_APPLY：应用校正并计数，下一拍转 CALC_IDLE。
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
    wire first_tx = active && enable && tx_state == TX_HANDSHAKE && tx_ready && tx_index == 0;
    wire first_rx = active && enable && rx_valid && rx_claim && ! rx_busy;
    afdx_ntp_fraction encode_tx (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .start(encode_tx_start),
        .to_nanoseconds(1'b0),
        .value(encode_tx_value),
        .done(encode_tx_done),
        .result(encode_tx_result)
    );
    afdx_ntp_fraction encode_rx (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .start(encode_rx_start),
        .to_nanoseconds(1'b0),
        .value(encode_rx_value),
        .done(encode_rx_done),
        .result(encode_rx_result)
    );
    afdx_ntp_fraction decode_rx (
        // 时钟和复位
        .clk(clk),
        .reset(reset),
        // 数据和握手
        .start(decode_start),
        .to_nanoseconds(1'b1),
        .value(decode_value),
        .done(decode_done),
        .result(decode_result)
    );

    // 接收数据按 24 位分组，各组用独立的写使能寄存器，避免单个使能跨过整个报文寄存器。
    // 首字节时间仍在原接口拍采样；完整报文标记延后一拍，与分组数据对齐。
    genvar packet_group;
    generate
        if (BANKED_RX) begin : local_receive
            reg [7:0] data_stage;
            wire [383:0] shifted_packet = {rx_packet[375:0], data_stage};
            always @(posedge clk) data_stage <= rx_data;
            for (packet_group = 0; packet_group < 16; packet_group = packet_group + 1) begin : word
                (* preserve = 1, dont_merge = 1 *) reg write_byte;
                always @(posedge clk) begin
                    if (reset) write_byte <= 0;
                    else write_byte <= active && enable && rx_valid && rx_claim;
                    if (reset) rx_packet[packet_group * 24 +: 24] <= 0;
                    else if (write_byte)
                        rx_packet[packet_group * 24 +: 24] <= shifted_packet[packet_group * 24 +: 24];
                end
            end
        end
        else begin : direct_receive
            always @(posedge clk) begin
                if (reset) rx_packet <= 0;
                else if (active && enable && rx_valid && rx_claim)
                    rx_packet <= {rx_packet[375:0], rx_data};
            end
        end
    endgenerate
    always @(posedge clk) begin
        if (reset || !active || !enable || load_time) rx_done_delayed <= 0;
        else rx_done_delayed <= rx_done;
    end

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
            // 采样时间后，独立换算模块将纳秒转换为报文的小数格式。
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
            period <= DEFAULT_PERIOD;
            vl <= 0;
            port_number <= NTP_PORT;
            load_sec <= 0;
            load_ns <= 0;
            snapshot_ns <= 0;
            cfg_rdata <= 0;
        end
        else begin
            // 配置字 0 控制主从角色、使能和时间装载。
            // 配置字 1 设置请求周期。
            // 配置字 2 设置发送虚拟链路索引。
            // 配置字 3 设置服务端口。
            // 配置字 4 设置秒。
            // 配置字 5 设置纳秒。
            if (cfg_we) case (cfg_write_addr)
                REG_CONTROL : begin
                    active <= cfg_wdata[0];
                    master <= cfg_wdata[1];
                end
                REG_PERIOD : period <= cfg_wdata;
                REG_VL : vl <= cfg_wdata[6:0];
                REG_PORT : port_number <= cfg_wdata[15:0];
                REG_SECONDS : load_sec <= cfg_wdata;
                REG_NS : load_ns <= cfg_wdata;
            endcase
            // 读秒时同时保存纳秒值，由配置模块再选择最终读结果。
            case (cfg_addr[2:0])
                REG_CONTROL : cfg_rdata <= { 30'b0, master, active };
                REG_PERIOD : cfg_rdata <= period;
                REG_VL : cfg_rdata <= { 25'b0, vl };
                REG_PORT : cfg_rdata <= { 16'b0, port_number };
                REG_SECONDS : begin
                    cfg_rdata <= seconds;
                    if (cfg_re) snapshot_ns <= nanoseconds;
                end
                REG_NS : cfg_rdata <= snapshot_ns;
                REG_OFFSET_SEC : cfg_rdata <= offset_sec;
                REG_OFFSET_NS : cfg_rdata <= offset_ns;
                default : cfg_rdata <= 0;
            endcase
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            seconds <= 0;
            nanoseconds <= 0;
        end
        // 配置装载优先于同步校正，两者都没有时按拍递增。
        // 纳秒达到十亿时向秒进位。
        else if (load_time) begin
            seconds <= load_sec;
            nanoseconds <= load_ns;
        end
        else if (calc_state == CALC_APPLY) begin
            if (adjusted_ns >= NS_PER_SECOND_S) begin
                seconds <= adjusted_sec + 32'd1;
                nanoseconds <= adjusted_ns - NS_PER_SECOND;
            end
            else begin
                seconds <= adjusted_sec;
                nanoseconds <= adjusted_ns;
            end
        end
        else if (nanoseconds >= LAST_TICK_NS) begin
            seconds <= seconds + 32'd1;
            nanoseconds <= nanoseconds - LAST_TICK_NS;
        end
        else nanoseconds <= nanoseconds + CLOCK_NS;
    end

    wire abort_protocol = !active || !enable || load_time;
    // 预先保存下一拍的提交状态，各副本只驱动一个 32 位对外状态寄存器。
    (* preserve = 1, dont_merge = 1 *) reg apply_seconds, apply_nanoseconds, apply_count;
    always @(posedge clk) begin
        if (reset) begin
            apply_seconds <= 0;
            apply_nanoseconds <= 0;
            apply_count <= 0;
            offset_sec <= 0;
            offset_ns <= 0;
            sync_count <= 0;
        end
        else begin
            apply_seconds <= calc_state == CALC_LATENCY && !abort_protocol;
            apply_nanoseconds <= calc_state == CALC_LATENCY && !abort_protocol;
            apply_count <= calc_state == CALC_LATENCY && !abort_protocol;
            if (apply_seconds && !abort_protocol) offset_sec <= correction_sec;
            if (apply_nanoseconds && !abort_protocol) offset_ns <= correction_ns;
            if (apply_count && !abort_protocol) sync_count <= sync_count + 32'd1;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            tx_valid <= 0;
            tx_data <= 0;
            tx_last <= 0;
            tx_state <= TX_IDLE;
            tx_index <= 0;
            tx_word <= 0;
            tx_word_low <= 0;
            tx_word_high <= 0;
            tx_reply <= 0;
            rx_busy <= 0;
            rx_done <= 0;
            rx_index <= 0;
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
            calc_state <= CALC_IDLE;
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

        end
        else begin
            rx_done <= 0;
            decode_start <= 0;
            if (countdown != 0) countdown <= countdown - 32'd1;
            if (rx_valid && rx_claim) begin
                rx_busy <= ! rx_last;
                if ( ! rx_busy) begin
                    received_sec <= seconds;
                    received_ns <= nanoseconds;
                    rx_index <= 1;
                end
                else rx_index <= rx_index + 6'd1;
                if (rx_last && rx_index == PACKET_LAST) rx_done <= 1;
            end
            // 客户端只接受版本、模式及请求时间都匹配的回应。
            // Originate 是回应中回送的请求时间，必须等于当前请求的 Transmit 字段。
            if (packet_done && rx_packet[381:379] == NTP_VERSION) begin
                if (master && rx_packet[378:376] == MODE_CLIENT) begin
                    // 服务端逐位复制请求的发送时间，避免换算改变匹配字段。
                    echo_sec <= rx_packet[63:32];
                    echo_frac <= rx_packet[31:0];
                    reply_pending <= 1;
                end
                // 重发报文还未发完时，不接受旧请求的回应。
                else if ( ! master && waiting && tx_state == TX_IDLE && rx_packet[378:376] == MODE_SERVER
                    && rx_packet[191:160] == stamp_tx_sec && rx_packet[159:128] == stamp_tx_frac) begin
                    server_receive_sec <= rx_packet[127:96] - NTP_EPOCH;
                    server_transmit_sec <= rx_packet[63:32] - NTP_EPOCH;
                    calc_state <= CALC_START_T2;
                end
            end
            // 时钟偏差为 ((T2-T1)+(T3-T4))/2。
            // 秒和纳秒分开计算，再处理借位和进位。
            case (calc_state)

                CALC_START_T2 : begin
                    decode_value <= rx_packet[95:64];
                    decode_start <= 1;
                    calc_state <= CALC_WAIT_T2;
                end

                CALC_WAIT_T2 : if (decode_done) begin
                    server_receive_ns <= decode_result;
                    calc_state <= CALC_START_T3;
                end

                CALC_START_T3 : begin
                    decode_value <= rx_packet[31:0];
                    decode_start <= 1;
                    calc_state <= CALC_WAIT_T3;
                end

                CALC_WAIT_T3 : if (decode_done) begin
                    server_transmit_ns <= decode_result;
                    calc_state <= CALC_DIFFERENCES;
                end

                CALC_DIFFERENCES : begin
                    diff_sec1 <= $signed (server_receive_sec) - $signed (req_sec);
                    diff_ns1 <= $signed (server_receive_ns) - $signed (req_ns);
                    diff_sec2 <= $signed (server_transmit_sec) - $signed (received_sec);
                    diff_ns2 <= $signed (server_transmit_ns) - $signed (received_ns);
                    calc_state <= CALC_SUM;
                end

                CALC_SUM : begin
                    sum_sec <= diff_sec1 + diff_sec2;
                    sum_ns <= diff_ns1 + diff_ns2;
                    calc_state <= CALC_HALF;
                end

                CALC_HALF : begin
                    correction_sec <= sum_sec >>> 1;
                    correction_ns <= sum_ns >>> 1;
                    second_odd <= sum_sec[0];
                    calc_state <= CALC_HALF_SECOND;
                end

                CALC_HALF_SECOND : begin
                    correction_ns <= correction_ns + (second_odd ? HALF_SECOND_NS_S : 32'sd0);
                    calc_state <= CALC_NORMALIZE_OFFSET;
                end

                CALC_NORMALIZE_OFFSET : begin
                    if (correction_ns < 0) begin
                        correction_ns <= correction_ns + NS_PER_SECOND_S;
                        correction_sec <= correction_sec - 32'sd1;
                    end
                    else if (correction_ns >= NS_PER_SECOND_S) begin
                        correction_ns <= correction_ns - NS_PER_SECOND_S;
                        correction_sec <= correction_sec + 32'sd1;
                    end
                    calc_state <= CALC_ADD_OFFSET;
                end

                CALC_ADD_OFFSET : begin
                    adjusted_sec <= seconds + correction_sec;
                    adjusted_ns <= nanoseconds + correction_ns;
                    calc_state <= CALC_NORMALIZE_TIME;
                end

                CALC_NORMALIZE_TIME : begin
                    if (adjusted_ns >= NS_PER_SECOND_S) begin
                        adjusted_ns <= adjusted_ns - NS_PER_SECOND;
                        adjusted_sec <= adjusted_sec + 32'd1;
                    end
                    calc_state <= CALC_LATENCY;
                end

                CALC_LATENCY : begin
                    adjusted_ns <= adjusted_ns + PIPELINE_NS;
                    calc_state <= CALC_APPLY;
                end

                CALC_APPLY : begin
                    waiting <= 0;
                    calc_state <= CALC_IDLE;
                end
            endcase
            // 服务端发送待答复的报文，客户端在请求周期到期时重发。
            case (tx_state)

                TX_IDLE : begin
                    tx_valid <= 0;
                    tx_last <= 0;
                    tx_index <= 0;
                    if (master && reply_pending) begin
                        tx_reply <= 1;
                        reply_pending <= 0;
                        tx_state <= TX_GROUPS;
                    end
                    // 正在接收完整回应或计算校正量时，客户端暂不启动下一次请求。
                    else if ( ! master && countdown == 0 && calc_state == CALC_IDLE && !rx_done && !packet_done) begin
                        tx_reply <= 0;
                        waiting <= 1;
                        countdown <= period;
                        tx_state <= TX_GROUPS;
                    end
                end

                TX_GROUPS : begin
                    // 字段分两组选择，以减少一拍内的数据选择层数。
                    case (tx_index[4:2])
                        // 报文首字：回应为版本 4、模式 4（服务端）、层级 1；
                        // 请求为版本 4、模式 3（客户端）。
                        // 后两个字节是轮询间隔 2^4 秒和时钟精度 2^-26 秒。
                        0 : tx_word_low <= tx_reply ? REPLY_HEADER : REQUEST_HEADER;
                        1 : tx_word_low <= 0;
                        2 : tx_word_low <= 0;
                        // 回应的参考标识是 ASCII 字符 LOCL，表示时间来自本地时钟。
                        3 : tx_word_low <= tx_reply ? REFERENCE_ID : 32'd0;
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
                    tx_state <= TX_WORD;
                end

                TX_WORD : begin
                    tx_word <= tx_index[5] ? tx_word_high : tx_word_low;
                    tx_state <= TX_BYTE;
                end

                TX_BYTE : begin
                    case (tx_index[1:0])
                        0 : tx_data <= tx_word[31:24];
                        1 : tx_data <= tx_word[23:16];
                        2 : tx_data <= tx_word[15:8];
                        3 : tx_data <= tx_word[7:0];
                    endcase
                    tx_valid <= 1;
                    tx_last <= (tx_index == PACKET_LAST);
                    tx_state <= TX_HANDSHAKE;
                end

                TX_HANDSHAKE : if (tx_ready) begin
                    if (tx_index == 0 && ! tx_reply) begin
                        req_sec <= seconds;
                        req_ns <= nanoseconds;
                    end
                    tx_valid <= 0;
                    tx_last <= 0;
                    if (tx_index == PACKET_LAST) tx_state <= TX_IDLE;
                    else begin
                        tx_index <= tx_index + 6'd1;
                        tx_state <= TX_GROUPS;
                    end
                end
            endcase
            // 中止只覆盖控制位；宽中间结果会在下一事务使用前重新计算。
            if (abort_protocol) begin
                tx_valid <= 0;
                tx_last <= 0;
                tx_state <= TX_IDLE;
                rx_busy <= 0;
                rx_done <= 0;
                waiting <= 0;
                reply_pending <= 0;
                countdown <= 0;
                calc_state <= CALC_IDLE;
                decode_start <= 0;
            end
        end
    end

endmodule
