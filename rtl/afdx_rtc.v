// 本模块维护本地时钟，并通过网络请求和回应校准时间。
// 它通过 afdx_svc 收发报文，通过配置口设置主从角色和读取时间。
// 本模块对应赛题的 RTC（Real-Time Clock，实时时钟）同步功能。
// SNTP（Simple Network Time Protocol，简单网络时间协议）
// 用四个收发时间戳估算本地时钟的偏差。
module afdx_rtc #(parameter LOCAL_RX_PORT = 0, BANKED_RX = 0, SPLIT_CFG_ADDR = 0,
    CFG_WRITE_SELECT = 0, RX_STREAM_DELAY_CYCLES = 0, CFG_READY_TERMS = 0) (

    // enable 为高表示收发核心就绪，本地时钟每拍增加 8 ns。
    input wire clk, reset, enable,

    // cfg_* 设置主从角色、请求周期和报文端口，也可装载时间。
    // 读取秒时同时保存纳秒值，sync_count 统计成功校时次数。
    // 预译码模式在原写使能端口上传六位独热选通，默认仍为单比特。
    input wire [(CFG_WRITE_SELECT ? 6 : 1) - 1:0] cfg_we,
    input wire cfg_re,
    input wire [(SPLIT_CFG_ADDR == 2 ? 11 : SPLIT_CFG_ADDR ? 8 : 4) - 1:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata,
    output reg [31:0] sync_count,

    // tx_valid 和 tx_ready 同为高时发送一个时间报文字节。
    // tx_last 标记第 48 个字节，tx_vl/port 选择发送通道。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg tx_valid,
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
    output wire rx_claim,
    input wire cfg_ready_base, cfg_ready_rx_term, cfg_ready_rx_ack,
    input wire cfg_write_request);

    // 高 4 位专供主机写译码，低 4 位保持共享读地址。
    wire [3:0] cfg_write_addr = cfg_addr[(SPLIT_CFG_ADDR == 2 ? 7 : SPLIT_CFG_ADDR ? 4 : 0) +: 4];

    localparam CALC_OFFSET_CANDIDATES = 15, CALC_TIME_CANDIDATES = 16;
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
    // 校正量从算出到生效经过 5 拍，所以再补 40 ns。
    localparam CLOCK_NS = 32'd8, LAST_TICK_NS = 32'd999999992, PIPELINE_NS = 32'd40;

    // 复位后的请求周期（125000 拍即 1 ms）和服务端口。
    localparam DEFAULT_PERIOD = 125000;
    localparam [15:0] NTP_PORT = 16'd123;

    // 报文共 48 字节，PACKET_LAST 是末字节的下标。
    localparam PACKET_LAST = 47;

    // 报文首字节里的版本号和模式：3 是客户端请求，4 是服务端回应。
    localparam NTP_VERSION = 4, MODE_CLIENT = 3, MODE_SERVER = 4;

    // 回应和请求的报文首字，以及回应里的参考标识，含义见发送处的说明。
    localparam REPLY_HEADER = 32'h240104e6, REQUEST_HEADER = 32'h230004e6, REFERENCE_ID = 32'h4c4f434c;

    // 配置字的序号。
    localparam REG_CONTROL = 0, REG_PERIOD = 1, REG_VL = 2, REG_PORT = 3, REG_SECONDS = 4, REG_NS = 5;
    localparam REG_OFFSET_SEC = 6, REG_OFFSET_NS = 7;
    // 顶层传入当拍独热选通；独立实例保留原来的地址译码接口。
    wire [11:0] rtc_field_ready;
    generate if(CFG_READY_TERMS) begin : configuration_terms
        // Four narrow fields and four bytes of each time-load word own
        // identical, same-cycle ready state; no distant ready gates 64 FFs.
        (* preserve=1,dont_merge=1 *) reg [11:0] field_ctl;
        always @(posedge clk) begin
            if(reset) field_ctl<=0;
            else field_ctl<={12{cfg_ready_base || (cfg_ready_rx_term && cfg_ready_rx_ack)}};
        end
        assign rtc_field_ready=field_ctl;
    end else begin : external_configuration
        assign rtc_field_ready=12'b0;
    end endgenerate
    wire [5:0] cfg_write_sel = CFG_READY_TERMS ? {
        rtc_field_ready[8] && cfg_write_request && cfg_write_addr==REG_NS,
        rtc_field_ready[4] && cfg_write_request && cfg_write_addr==REG_SECONDS,
        rtc_field_ready[3] && cfg_write_request && cfg_write_addr==REG_PORT,
        rtc_field_ready[2] && cfg_write_request && cfg_write_addr==REG_VL,
        rtc_field_ready[1] && cfg_write_request && cfg_write_addr==REG_PERIOD,
        rtc_field_ready[0] && cfg_write_request && cfg_write_addr==REG_CONTROL
    } : CFG_WRITE_SELECT ? cfg_we : {
        cfg_we && cfg_write_addr == REG_NS,
        cfg_we && cfg_write_addr == REG_SECONDS,
        cfg_we && cfg_write_addr == REG_PORT,
        cfg_we && cfg_write_addr == REG_VL,
        cfg_we && cfg_write_addr == REG_PERIOD,
        cfg_we && cfg_write_addr == REG_CONTROL
    };

    // 配置秒从2000-01-01 UTC起算，线上从1900年起算。
    // active 表示服务已启用，master 为高表示本机是服务端。
    // 客户端用 period/countdown 控制请求间隔。
    reg active, master;
    (* preserve = 1, dont_merge = 1 *) reg active_rx, active_tx, active_protocol;
    (* preserve = 1, dont_merge = 1 *) reg master_rx, master_tx;
    reg [31:0] period, load_sec, load_ns;
    (* preserve = 1, dont_merge = 1 *) reg period_zero;
    (* preserve = 1, dont_merge = 1 *) reg [31:0] period_read;
    reg [31:0] load_sec_increment;
    reg [6:0] vl;
    reg [15:0] port_number;

    // seconds/nanoseconds 保存本地时间。
    // offset_sec/ns 保存最近一次校正量。
    // snapshot_ns 保存读秒时的纳秒值，便于分两次读出完整时间。
    reg [31:0] seconds, nanoseconds, snapshot_ns;
    // T50：读秒使能在 rtc 内分成 4 份缓冲，各驱动 8 位切片，缩短顶层使能锥到使能端的连线。
    (* keep = 1, dont_merge = 1 *) wire cfg_re_b0 = cfg_re;
    (* keep = 1, dont_merge = 1 *) wire cfg_re_b1 = cfg_re;
    (* keep = 1, dont_merge = 1 *) wire cfg_re_b2 = cfg_re;
    (* keep = 1, dont_merge = 1 *) wire cfg_re_b3 = cfg_re;
    // 校正加法使用同拍本地镜像；复制下一拍值而非延迟采样，避免秒源跨区布线后再串加法。
    (* preserve = 1, dont_merge = 1 *) reg [31:0] seconds_calc, nanoseconds_calc;
    reg [31:0] timestamp_seconds, timestamp_nanoseconds;
    // seconds_increment 恒为 seconds + 1；tick_overflow 恒表示当前纳秒到达秒边界。
    reg [31:0] seconds_increment;
    // Each flag describes one byte of the current seconds+1 value.
    // Three short prefix terms replace the 16-bit carry/comparator feedback.
    (* preserve = 1, dont_merge = 1 *) reg [2:0] seconds_byte_full;
    reg load_overflow;
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg tick_overflow;
    reg signed [31:0] offset_sec;
    reg [31:0] offset_ns;
    wire load_time = cfg_write_sel[REG_CONTROL] && cfg_wdata[2];
    // 远端配置信号只进这一个寄存器，装载生效推迟一拍，各使能锥不再含译码。
    reg load_pending;

    assign tx_vl = vl;
    assign tx_port = port_number;
    // 顶层交付口提前三拍给出端口，两级局部寄存分摊跨模块布线。
    // 独立使用本模块时，默认保持端口与有效字节同时到达的接口。
    (* preserve = 1, dont_merge = 1 *) reg [15:0] rx_port_stage, rx_port_local;
    wire [15:0] incoming_port = LOCAL_RX_PORT ? rx_port_local : rx_port;
    reg local_port_match;
    always @(posedge clk) begin
        if (reset) begin
            rx_port_stage <= 0;
            rx_port_local <= 0;
            local_port_match <= 0;
        end
        else begin
            rx_port_stage <= rx_port;
            rx_port_local <= rx_port_stage;
            // 与本拍更新后的本地端口比较；配置写同时发生时也保持原匹配语义。
            local_port_match <= cfg_write_sel[REG_PORT]
                ? rx_port_stage == cfg_wdata[15:0] : rx_port_stage == port_number;
        end
    end

    assign rx_claim = active_rx && (LOCAL_RX_PORT ? local_port_match : incoming_port == port_number);

    // Only the header and timestamp fields used by the protocol are retained.
    reg [7:0] rx_header;
    (* preserve = 1, dont_merge = 1 *) reg rx_client_header, rx_server_header;
    reg [31:0] rx_origin_sec, rx_origin_frac;
    reg [31:0] rx_receive_sec, rx_receive_frac, rx_transmit_sec, rx_transmit_frac;
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
    (* preserve = 1, dont_merge = 1 *) reg [5:0] tx_index_next;
    (* preserve = 1, dont_merge = 1 *) reg tx_index_first_q, tx_index_last_q, countdown_zero_q;

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
    // CALC_HALF_SECOND：补入半秒；候选计算拍并行计算进位、借位和比较，再转 CALC_NORMALIZE_OFFSET。
    // CALC_NORMALIZE_OFFSET：处理纳秒的借位或进位，下一拍转 CALC_ADD_OFFSET。
    // CALC_ADD_OFFSET：采样校正后的本地时间；候选计算拍先计算秒进位，再转 CALC_NORMALIZE_TIME。
    // CALC_NORMALIZE_TIME：处理新的秒边界，下一拍转 CALC_LATENCY。
    // CALC_LATENCY：补偿计算经过的 40 ns，下一拍转 CALC_APPLY。
    // CALC_APPLY：应用校正并计数，下一拍转 CALC_IDLE。
    reg [4:0] calc_state;
    // calc_busy 与 calc_state 同拍影子：进入计算置位、回到空闲清除，
    // 供发送状态机就近判断，独热位不再跨模块连线。
    (* preserve = 1, dont_merge = 1 *) reg calc_busy;
    // 线性转移的前瞻位与当前状态同拍，宽数据通路不再直接由远处独热状态位驱动。
    (* preserve = 1, dont_merge = 1 *) reg in_add_offset_q, in_normalize_time_q, in_latency_q, in_apply_q;
    reg signed [31:0] diff_sec1, diff_sec2, diff_ns1, diff_ns2, sum_sec, sum_ns;
    reg signed [31:0] correction_sec, correction_ns;
    (* preserve = 1, dont_merge = 1 *) reg signed [31:0] correction_sec_calc, correction_ns_calc;
    reg second_odd;
    reg offset_negative, offset_overflow, time_overflow;
    reg signed [31:0] offset_ns_plus, offset_ns_minus, offset_sec_plus, offset_sec_minus;
    reg [31:0] time_ns_minus, time_sec_plus;
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) reg final_overflow;
    reg [31:0] final_ns_wrapped, final_sec_increment, final_sec_twice;
    reg final_tick_direct, final_tick_wrapped;
    localparam MAX_BEFORE_PIPELINE = 32'hffffffff - PIPELINE_NS;
    reg [31:0] adjusted_sec, adjusted_ns;
    reg encode_tx_start, encode_rx_start, encode_rx_reference, decode_start;
    reg [31:0] encode_tx_value, encode_rx_value, decode_value;
    wire encode_tx_done, encode_rx_done, decode_done;
    wire [31:0] encode_tx_result, encode_rx_result, decode_result;
    reg [31:0] stamp_tx_sec, stamp_tx_frac, stamp_rx_sec, stamp_rx_frac, reference_sec, reference_frac;
    // 首字节进入握手态时预置，握手或中止时清除；不在时间戳使能端再译码下标。
    // active/enable 仍在事件拍直接门控，保持停用当拍不采样的语义。
    (* preserve = 1, dont_merge = 1 *) reg tx_first_armed;
    wire tx_armed = active_tx && enable && tx_first_armed;
    wire first_tx = tx_armed && tx_ready;
    wire rx_byte = rx_valid && rx_claim;
    wire rx_armed = enable && rx_claim && ! rx_busy;
    wire first_rx = rx_armed && rx_valid;
    (* preserve = 1, dont_merge = 1 *) reg first_tx_q, first_rx_q;
    reg reference_event_q;
    reg [31:0] reference_nanoseconds_q;
    afdx_ntp_fraction #(.LOCAL_CAPTURE(1)) encode_tx (
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
    afdx_ntp_fraction #(.LOCAL_CAPTURE(1)) encode_rx (
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
    afdx_ntp_fraction #(.LOCAL_CAPTURE(1)) decode_rx (
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

    // The banked interface delays the byte and its index together.  The
    // completion pulse is delayed by the same amount; the first-byte time
    // capture remains on the original interface.
    // These are the RTC's own byte boundary, not mergeable copies of the
    // loader/SNMP capture FFs on the same shared input stream.
    (* preserve = 1, dont_merge = 1 *) reg [7:0] rx_data_stage;
    (* preserve = 1, dont_merge = 1 *) reg [5:0] rx_index_stage;
    (* preserve = 1, dont_merge = 1 *) reg rx_write_stage;
    wire [5:0] incoming_index = rx_busy ? rx_index : 6'd0;
    wire field_write = BANKED_RX ? rx_write_stage : (enable && rx_byte);
    wire [5:0] field_index = BANKED_RX ? rx_index_stage : incoming_index;
    wire [7:0] field_data = BANKED_RX ? rx_data_stage : rx_data;
    always @(posedge clk) begin
        if (reset) begin
            rx_data_stage <= 0;
            rx_index_stage <= 0;
            rx_write_stage <= 0;
            rx_header <= 0;
            rx_client_header <= 0;rx_server_header <= 0;
            rx_origin_sec <= 0; rx_origin_frac <= 0;
            rx_receive_sec <= 0; rx_receive_frac <= 0;
            rx_transmit_sec <= 0; rx_transmit_frac <= 0;
        end else begin
            rx_data_stage <= rx_data;
            rx_index_stage <= incoming_index;
            rx_write_stage <= enable && rx_byte;
            if (field_write) begin
                if (field_index == 0) begin
                    rx_header <= field_data;
                    rx_client_header <= field_data[5:3] == NTP_VERSION && field_data[2:0] == MODE_CLIENT;
                    rx_server_header <= field_data[5:3] == NTP_VERSION && field_data[2:0] == MODE_SERVER;
                end
                if (field_index >= 24 && field_index <= 27)
                    rx_origin_sec <= {rx_origin_sec[23:0], field_data};
                if (field_index >= 28 && field_index <= 31)
                    rx_origin_frac <= {rx_origin_frac[23:0], field_data};
                if (field_index >= 32 && field_index <= 35)
                    rx_receive_sec <= {rx_receive_sec[23:0], field_data};
                if (field_index >= 36 && field_index <= 39)
                    rx_receive_frac <= {rx_receive_frac[23:0], field_data};
                if (field_index >= 40 && field_index <= 43)
                    rx_transmit_sec <= {rx_transmit_sec[23:0], field_data};
                if (field_index >= 44 && field_index <= 47)
                    rx_transmit_frac <= {rx_transmit_frac[23:0], field_data};
            end
        end
    end
    always @(posedge clk) begin
        if (reset || !active || !enable || load_pending) rx_done_delayed <= 0;
        else rx_done_delayed <= rx_done;
    end
    always @(posedge clk) begin
        if (reset) load_pending <= 0;
        else load_pending <= load_time;
    end

    // Byte comparisons are registered locally.  All eight Originate bytes
    // have settled before packet_done, including with the banked data stage.
    (* preserve = 1, dont_merge = 1 *) reg [7:0] reply_byte_match;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] reply_nibble_match;
    wire reply_match = &reply_byte_match;
    genvar origin_byte;
    generate for (origin_byte = 0; origin_byte < 8; origin_byte = origin_byte + 1) begin : origin_compare
        always @(posedge clk) begin
            if (reset) begin
                reply_nibble_match[origin_byte] <= 0;
                reply_nibble_match[origin_byte+8] <= 0;
                reply_byte_match[origin_byte] <= 0;
            end else begin
                reply_nibble_match[origin_byte] <= rx_origin_sec[origin_byte*4+:4] == stamp_tx_sec[origin_byte*4+:4];
                reply_nibble_match[origin_byte+8] <= rx_origin_frac[origin_byte*4+:4] == stamp_tx_frac[origin_byte*4+:4];
                reply_byte_match[origin_byte] <= &reply_nibble_match[origin_byte*2+:2];
            end
        end
    end endgenerate

    // ready/valid 的远端组合链只到单比特事件寄存器，下一拍再驱动时间戳和换算输入。
    // RX 在事件拍确定 master 和装载优先级，避免下一拍配置改变时丢失或补采事件。
    // TX 与装载原本就是独立分支；RX 换算器的装载命令也等量延后，保持命令先后顺序。
    always @(posedge clk) begin
        if (reset) begin
            first_tx_q <= 0;
            first_rx_q <= 0;
            reference_event_q <= 0;
            reference_nanoseconds_q <= 0;
        end
        else begin
            first_tx_q <= first_tx;
            first_rx_q <= first_rx && master_rx && !load_pending;
            reference_event_q <= load_pending;
            reference_nanoseconds_q <= load_ns;
        end
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
            // timestamp_* 保存事件拍的原时间，延后使能不改变报文时间戳数值。
            if (first_tx_q) begin
                stamp_tx_sec <= timestamp_seconds + NTP_EPOCH;
                encode_tx_value <= timestamp_nanoseconds;
                encode_tx_start <= 1;
            end
            // 参考秒和实际时间装载仍在原拍生效，仅共享换算器的命令延后一拍。
            if (load_pending) reference_sec <= load_sec + NTP_EPOCH;
            if (reference_event_q) begin
                encode_rx_value <= reference_nanoseconds_q;
                encode_rx_reference <= 1;
                encode_rx_start <= 1;
            end
            else if (first_rx_q) begin
                stamp_rx_sec <= receive_timestamp_seconds + NTP_EPOCH;
                encode_rx_value <= receive_timestamp_nanoseconds;
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
            active_rx <= 0;active_tx <= 0;active_protocol <= 0;
            master_rx <= 0;master_tx <= 0;
            period <= DEFAULT_PERIOD;
            period_zero <= 0;
            period_read <= DEFAULT_PERIOD;
            vl <= 0;
            port_number <= NTP_PORT;
            load_overflow <= 0;
            snapshot_ns <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_rdata <= 0;
        end
        else begin
            // 配置字 0 控制主从角色、使能和时间装载。
            // 配置字 1 设置请求周期。
            // 配置字 2 设置发送虚拟链路索引。
            // 配置字 3 设置服务端口。
            // 配置字 4 设置秒。
            // 配置字 5 设置纳秒。
            if (cfg_write_sel[REG_CONTROL]) begin
                active <= cfg_wdata[0];
                master <= cfg_wdata[1];
                active_rx <= cfg_wdata[0];active_tx <= cfg_wdata[0];active_protocol <= cfg_wdata[0];
                master_rx <= cfg_wdata[1];master_tx <= cfg_wdata[1];
            end
            if (cfg_write_sel[REG_PERIOD]) begin
                period <= cfg_wdata;
                period_zero <= cfg_wdata == 0;
                period_read <= cfg_wdata;
            end
            if (cfg_write_sel[REG_VL]) vl <= cfg_wdata[6:0];
            if (cfg_write_sel[REG_PORT]) port_number <= cfg_wdata[15:0];
            if (cfg_write_sel[REG_NS])
                load_overflow <= ge32(cfg_wdata, LAST_TICK_NS);
            if (SPLIT_CFG_ADDR == 2) begin
                if (cfg_re_b0) snapshot_ns[7:0] <= nanoseconds[7:0];
                if (cfg_re_b1) snapshot_ns[15:8] <= nanoseconds[15:8];
                if (cfg_re_b2) snapshot_ns[23:16] <= nanoseconds[23:16];
                if (cfg_re_b3) snapshot_ns[31:24] <= nanoseconds[31:24];
            end
            // 读秒时同时保存纳秒值，由配置模块再选择最终读结果。
            if (SPLIT_CFG_ADDR != 2) begin
            case (cfg_addr[2:0])
                REG_CONTROL : cfg_rdata <= { 30'b0, master, active };
                REG_PERIOD : cfg_rdata <= period;
                REG_VL : cfg_rdata <= { 25'b0, vl };
                REG_PORT : cfg_rdata <= { 16'b0, port_number };
                REG_SECONDS : begin
                    cfg_rdata <= seconds;
                    if (cfg_re_b0) snapshot_ns[7:0] <= nanoseconds[7:0];
                    if (cfg_re_b1) snapshot_ns[15:8] <= nanoseconds[15:8];
                    if (cfg_re_b2) snapshot_ns[23:16] <= nanoseconds[23:16];
                    if (cfg_re_b3) snapshot_ns[31:24] <= nanoseconds[31:24];
                end
                REG_NS : cfg_rdata <= snapshot_ns;
                REG_OFFSET_SEC : cfg_rdata <= offset_sec;
                REG_OFFSET_NS : cfg_rdata <= offset_ns;
                default : cfg_rdata <= 0;
            endcase
            end
        end
    end

    wire [31:0] rtc_load_increment = cfg_wdata + 32'd1;
    genvar load_byte;
    generate for(load_byte=0;load_byte<4;load_byte=load_byte+1) begin : time_load_field
        wire seconds_write = CFG_READY_TERMS
            ? rtc_field_ready[4+load_byte] && cfg_write_request && cfg_write_addr==REG_SECONDS
            : cfg_write_sel[REG_SECONDS];
        wire ns_write = CFG_READY_TERMS
            ? rtc_field_ready[8+load_byte] && cfg_write_request && cfg_write_addr==REG_NS
            : cfg_write_sel[REG_NS];
        always @(posedge clk) begin
            if(reset) begin
                load_sec[load_byte*8+:8]<=0;
                load_sec_increment[load_byte*8+:8]<=load_byte==0 ? 8'd1 : 8'd0;
                load_ns[load_byte*8+:8]<=0;
            end else begin
                if(seconds_write) begin
                    load_sec[load_byte*8+:8]<=cfg_wdata[load_byte*8+:8];
                    load_sec_increment[load_byte*8+:8]<=rtc_load_increment[load_byte*8+:8];
                end
                if(ns_write) load_ns[load_byte*8+:8]<=cfg_wdata[load_byte*8+:8];
            end
        end
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            seconds <= 0;
            seconds_calc <= 0;
            seconds_increment <= 1;
            seconds_byte_full <= 0;

            nanoseconds <= 0;
            nanoseconds_calc <= 0;
        end
        // 配置装载优先于同步校正，两者都没有时按拍递增。
        // 纳秒达到十亿时向秒进位。
        else if (load_pending) begin
            seconds <= load_sec;
            seconds_calc <= load_sec;
            seconds_increment <= load_sec_increment;
            seconds_byte_full <= {load_sec_increment[23:16] == 8'hff,
                load_sec_increment[15:8] == 8'hff, load_sec_increment[7:0] == 8'hff};

            nanoseconds <= load_ns;
            nanoseconds_calc <= load_ns;
        end
        else if (in_apply_q) begin
            if (final_overflow) begin
                seconds <= final_sec_increment;
                seconds_calc <= final_sec_increment;
                seconds_increment <= final_sec_twice;
                seconds_byte_full <= {final_sec_twice[23:16] == 8'hff,
                    final_sec_twice[15:8] == 8'hff, final_sec_twice[7:0] == 8'hff};

                nanoseconds <= final_ns_wrapped;
                nanoseconds_calc <= final_ns_wrapped;
            end
            else begin
                seconds <= adjusted_sec;
                seconds_calc <= adjusted_sec;
                seconds_increment <= final_sec_increment;
                seconds_byte_full <= {final_sec_increment[23:16] == 8'hff,
                    final_sec_increment[15:8] == 8'hff, final_sec_increment[7:0] == 8'hff};

                nanoseconds <= adjusted_ns;
                nanoseconds_calc <= adjusted_ns;
            end
        end
        else if (tick_overflow) begin
            seconds <= seconds_increment;
            seconds_calc <= seconds_increment;
            seconds_increment[7:0] <= seconds_increment[7:0] + 8'd1;
            seconds_increment[15:8] <= seconds_increment[15:8] + seconds_byte_full[0];
            seconds_increment[23:16] <= seconds_increment[23:16] + (&seconds_byte_full[1:0]);
            seconds_increment[31:24] <= seconds_increment[31:24] + (&seconds_byte_full);
            seconds_byte_full[0] <= seconds_increment[7:0] == 8'hfe;
            seconds_byte_full[1] <= seconds_byte_full[0]
                ? seconds_increment[15:8] == 8'hfe : seconds_increment[15:8] == 8'hff;
            seconds_byte_full[2] <= (&seconds_byte_full[1:0])
                ? seconds_increment[23:16] == 8'hfe : seconds_increment[23:16] == 8'hff;

            nanoseconds <= nanoseconds - LAST_TICK_NS;
            nanoseconds_calc <= nanoseconds_calc - LAST_TICK_NS;
        end
        else begin
            nanoseconds <= nanoseconds + CLOCK_NS;
            nanoseconds_calc <= nanoseconds_calc + CLOCK_NS;
        end
    end

    // 按字节并行比较，再合并优先级，限制常数比较的进位链长度。
    function ge32;
        input [31:0] value, limit;
        begin
            ge32 = (value[31:24] > limit[31:24])
                || (value[31:24] == limit[31:24] && value[23:16] > limit[23:16])
                || (value[31:16] == limit[31:16] && value[15:8] > limit[15:8])
                || (value[31:8] == limit[31:8] && value[7:0] >= limit[7:0]);
        end
    endfunction

    // 比较与更新时间选择分拍：各比较只看上一拍数据，mode 记录上一拍实际更新方式。
    // nn 表示连续两次正常 +8；wn/ww 表示上拍回卷后，本拍正常递增或再次回卷。
    localparam TIME_NORMAL = 5'b00001, TIME_WRAP = 5'b00010, TIME_LOAD = 5'b00100,
        TIME_APPLY_DIRECT = 5'b01000, TIME_APPLY_WRAP = 5'b10000;
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) reg [4:0] previous_time_mode, previous_wrap_mode;
    reg tick_nn, tick_wn, tick_ww, tick_ln, tick_lw, tick_dn, tick_dw, tick_an, tick_aw;
    wire predicted_normal = (previous_time_mode[0] && tick_nn)
        || (previous_time_mode[1] && tick_wn) || (previous_time_mode[2] && tick_ln)
        || (previous_time_mode[3] && tick_dn) || (previous_time_mode[4] && tick_an);
    // 正常递增后最多超出边界 7 ns，随后一次回卷必定不再进位。
    wire predicted_wrap = (previous_wrap_mode[1] && tick_ww) || (previous_wrap_mode[2] && tick_lw)
        || (previous_wrap_mode[3] && tick_dw) || (previous_wrap_mode[4] && tick_aw);
    always @(posedge clk) begin
        if (reset) begin
            tick_overflow <= 0;
            previous_time_mode <= TIME_NORMAL;
            previous_wrap_mode <= TIME_NORMAL;
            tick_nn <= 0; tick_wn <= 0; tick_ww <= 0;
            tick_ln <= 0; tick_lw <= 0; tick_dn <= 0; tick_dw <= 0; tick_an <= 0; tick_aw <= 0;
        end
        else begin
            tick_nn <= ge32(nanoseconds, LAST_TICK_NS - 2 * CLOCK_NS);
            tick_wn <= ge32(nanoseconds, 2 * LAST_TICK_NS - CLOCK_NS);
            tick_ww <= ge32(nanoseconds, 3 * LAST_TICK_NS);
            tick_ln <= ge32(load_ns, LAST_TICK_NS - CLOCK_NS);
            tick_lw <= ge32(load_ns, 2 * LAST_TICK_NS);
            tick_dn <= ge32(adjusted_ns, LAST_TICK_NS - CLOCK_NS);
            tick_dw <= ge32(adjusted_ns, 2 * LAST_TICK_NS);
            tick_an <= ge32(final_ns_wrapped, LAST_TICK_NS - CLOCK_NS);
            tick_aw <= ge32(final_ns_wrapped, 2 * LAST_TICK_NS);
            // Exclusive update terms avoid three serial mode/data muxes on
            // the already registered overflow prediction. Priority is still
            // load, correction apply, then the ordinary clock step.
            tick_overflow <= (load_pending && load_overflow) ||
                (!load_pending && in_apply_q &&
                    ((final_overflow && final_tick_wrapped) || (!final_overflow && final_tick_direct))) ||
                (!load_pending && !in_apply_q &&
                    ((tick_overflow && predicted_wrap) || (!tick_overflow && predicted_normal)));
            if (load_pending) begin
                previous_time_mode <= TIME_LOAD;
                previous_wrap_mode <= TIME_LOAD;
            end
            else if (in_apply_q) begin
                previous_time_mode <= final_overflow ? TIME_APPLY_WRAP : TIME_APPLY_DIRECT;
                previous_wrap_mode <= final_overflow ? TIME_APPLY_WRAP : TIME_APPLY_DIRECT;
            end
            else begin
                previous_time_mode <= tick_overflow ? TIME_WRAP : TIME_NORMAL;
                previous_wrap_mode <= tick_overflow ? TIME_WRAP : TIME_NORMAL;
            end
        end
    end

    // 事件拍先同时保存时间和局部写使能，下一拍分发到各 32 位时间戳；采样时刻不变。
    (* preserve = 1, dont_merge = 1 *) reg receive_seconds_event, receive_nanoseconds_event;
    (* preserve = 1, dont_merge = 1 *) reg request_seconds_event, request_nanoseconds_event;
    wire request_event = rtc_request_armed && tx_ready;
    // Only the parent stream delay is compensated here. Existing banked
    // byte capture and local event registers already have their own timing.
    // History preserves exact pre-step/pre-wrap values, unlike subtracting
    // a constant from a clock that may have loaded or applied an offset.
    wire [(RX_STREAM_DELAY_CYCLES+1)*32-1:0] receive_seconds_history,receive_ns_history;
    assign receive_seconds_history[31:0]=timestamp_seconds;
    assign receive_ns_history[31:0]=timestamp_nanoseconds;
    wire [31:0] receive_timestamp_seconds=receive_seconds_history[RX_STREAM_DELAY_CYCLES*32+:32];
    wire [31:0] receive_timestamp_nanoseconds=receive_ns_history[RX_STREAM_DELAY_CYCLES*32+:32];
    genvar history_stage;
    generate for(history_stage=0;history_stage<RX_STREAM_DELAY_CYCLES;history_stage=history_stage+1) begin : receive_time_history
        (* preserve=1,dont_merge=1 *) reg [31:0] seconds_q,nanoseconds_q;
        assign receive_seconds_history[(history_stage+1)*32+:32]=seconds_q;
        assign receive_ns_history[(history_stage+1)*32+:32]=nanoseconds_q;
        always @(posedge clk) begin
            if(reset) begin seconds_q<=0;nanoseconds_q<=0;end
            else begin
                seconds_q<=receive_seconds_history[history_stage*32+:32];
                nanoseconds_q<=receive_ns_history[history_stage*32+:32];
            end
        end
    end endgenerate
    always @(posedge clk) begin
        if (reset) begin
            timestamp_seconds <= 0;
            timestamp_nanoseconds <= 0;
            receive_seconds_event <= 0;
            receive_nanoseconds_event <= 0;
            request_seconds_event <= 0;
            request_nanoseconds_event <= 0;
            received_sec <= 0;
            received_ns <= 0;
            req_sec <= 0;
            req_ns <= 0;
        end
        else begin
            timestamp_seconds <= seconds;
            timestamp_nanoseconds <= nanoseconds;
            receive_seconds_event <= first_rx;
            receive_nanoseconds_event <= first_rx;
            request_seconds_event <= request_event;
            request_nanoseconds_event <= request_event;
            if (receive_seconds_event) received_sec <= receive_timestamp_seconds;
            if (receive_nanoseconds_event) received_ns <= receive_timestamp_nanoseconds;
            if (request_seconds_event) req_sec <= timestamp_seconds;
            if (request_nanoseconds_event) req_ns <= timestamp_nanoseconds;
        end
    end

    wire abort_protocol = !active_protocol || !enable || load_pending;
    always @(posedge clk) begin
        if (reset || abort_protocol) begin
            in_add_offset_q <= 0;
            in_normalize_time_q <= 0;
            in_latency_q <= 0;
            in_apply_q <= 0;
        end
        else begin
            in_add_offset_q <= calc_state == CALC_NORMALIZE_OFFSET;
            in_normalize_time_q <= calc_state == CALC_TIME_CANDIDATES;
            in_latency_q <= calc_state == CALC_NORMALIZE_TIME;
            in_apply_q <= calc_state == CALC_LATENCY;
        end
    end

    // 与原状态机写入拍完全相同；不要再套 calc_state 的 case，否则会重新引入独热位长线。
    // 当拍中止仍允许宽中间结果更新，保持原有“只清控制位”的语义。
    always @(posedge clk) begin
        if (reset) begin
            adjusted_sec <= 0;
            adjusted_ns <= 0;
        end
        else if (in_add_offset_q) begin
            adjusted_sec <= seconds_calc + correction_sec_calc;
            adjusted_ns <= nanoseconds_calc + correction_ns_calc;
        end
        else if (in_normalize_time_q) begin
            if (time_overflow) begin
                adjusted_sec <= time_sec_plus;
                adjusted_ns <= time_ns_minus;
            end
        end
        else if (in_latency_q) adjusted_ns <= adjusted_ns + PIPELINE_NS;
    end

    // 下标只在 IDLE 清零、HANDSHAKE 推进；到 BYTE/下一次 HANDSHAKE 前至少稳定两拍。
    // 利用原有 GROUPS/WORD/BYTE 准备拍预计算，不增加字节间隔或握手延迟。
    (* preserve = 1, dont_merge = 1 *) reg [5:0] tx_index_compare;
    (* preserve = 1, dont_merge = 1 *) reg rtc_byte_taken;
    wire [5:0] rtc_effective_index = rtc_byte_taken ? tx_index_next : tx_index;
    always @(posedge clk) begin
        if(reset) begin rtc_byte_taken<=0;tx_index<=0;end
        else begin
            rtc_byte_taken<=tx_state==TX_HANDSHAKE && tx_ready && !tx_index_last_q;
            if(tx_state==TX_IDLE) tx_index<=0;
            else if(rtc_byte_taken) tx_index<=tx_index_next;
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            tx_index_compare <= 0;
            tx_index_next <= 6'd1;
            tx_index_first_q <= 1;
            tx_index_last_q <= 0;
        end
        else begin
            tx_index_compare <= rtc_effective_index;
            tx_index_next <= tx_index_compare + 6'd1;
            tx_index_first_q <= tx_index_compare == 0;
            tx_index_last_q <= tx_index_compare == PACKET_LAST;
        end
    end

    // Every offset byte has same-cycle local mode/load/commit controls.
    // A disable or load on the original application edge still cancels it;
    // no registered delayed abort is substituted for that decision.
    genvar offset_byte;
    generate for (offset_byte=0; offset_byte<8; offset_byte=offset_byte+1) begin : offset_commit
        (* preserve = 1, dont_merge = 1 *) reg active_local, load_local, apply_local;
        wire abort_local = !active_local || !enable || load_local;
        always @(posedge clk) begin
            if (reset) begin active_local<=0;load_local<=0;apply_local<=0;end
            else begin
                if (cfg_write_sel[REG_CONTROL]) active_local<=cfg_wdata[0];
                load_local<=load_time;
                apply_local<=calc_state==CALC_LATENCY && !abort_local;
            end
        end
        if (offset_byte<4) begin : sec
            always @(posedge clk) begin
                if (reset) offset_sec[offset_byte*8+:8]<=0;
                else if (apply_local && !abort_local)
                    offset_sec[offset_byte*8+:8]<=correction_sec[offset_byte*8+:8];
            end
        end else begin : ns
            always @(posedge clk) begin
                if (reset) offset_ns[(offset_byte-4)*8+:8]<=0;
                else if (apply_local && !abort_local)
                    offset_ns[(offset_byte-4)*8+:8]<=correction_ns[(offset_byte-4)*8+:8];
            end
        end
    end endgenerate
    (* preserve = 1, dont_merge = 1 *) reg apply_count;
    always @(posedge clk) begin
        if (reset) begin apply_count<=0;sync_count<=0;end
        else begin
            apply_count<=calc_state==CALC_LATENCY && !abort_protocol;
            if (apply_count && !abort_protocol) sync_count<=sync_count+32'd1;
        end
    end

    // HALF already owns a preparation edge. Predict the two nontrivial
    // byte carries of +0x1dcd6500 there; HALF_SECOND then has only byte adders.
    (* preserve=1,dont_merge=1 *) reg [1:0] rtc_half_carry;
    wire [31:0] rtc_half_value = sum_ns >>> 1;
    wire rtc_half_c16 = rtc_half_value[15:8]>=8'h9b;
    wire rtc_half_c24 = rtc_half_value[23:16]>8'h32 ||
        (rtc_half_value[23:16]==8'h32 && rtc_half_c16);
    always @(posedge clk) begin
        if(reset) rtc_half_carry<=0;
        else if(calc_state==CALC_HALF)
            rtc_half_carry<={sum_sec[0] && rtc_half_c24,sum_sec[0] && rtc_half_c16};
    end
    function [31:0] rtc_add_half;
        input [31:0] value;
        input odd;
        input [1:0] carry;
        begin
            rtc_add_half[7:0]=value[7:0];
            rtc_add_half[15:8]=value[15:8]+(odd?8'h65:8'h00);
            rtc_add_half[23:16]=value[23:16]+(odd?8'hcd:8'h00)+{7'b0,carry[0]};
            rtc_add_half[31:24]=value[31:24]+(odd?8'h1d:8'h00)+{7'b0,carry[1]};
        end
    endfunction

    // Same-cycle run/first-request predicates use the original next values.
    // Enable remains a current-cycle input for standalone callers.
    (* preserve=1,dont_merge=1 *) reg rtc_run_ctl, rtc_request_armed;
    wire rtc_tx_running = rtc_run_ctl && enable;
    wire rtc_tx_idle = tx_state==TX_IDLE;
    wire rtc_tx_groups = tx_state==TX_GROUPS;
    wire rtc_tx_word = tx_state==TX_WORD;
    wire rtc_tx_byte = tx_state==TX_BYTE;
    wire rtc_tx_handshake = tx_state==TX_HANDSHAKE;
    wire rtc_tx_invalid = tx_state>TX_HANDSHAKE;
    wire rtc_tx_launch = rtc_server_launch || rtc_client_launch;
    wire rtc_control_hold = !rtc_tx_idle && !rtc_tx_byte && (!rtc_tx_handshake || !tx_ready);
    wire rtc_first_armed_next = rtc_tx_running &&
        ((rtc_tx_byte && tx_index_first_q) || (rtc_control_hold && tx_first_armed));
    wire rtc_reply_next = rtc_tx_idle && rtc_server_launch ? 1'b1 :
        rtc_tx_idle && rtc_client_launch ? 1'b0 : tx_reply;
    always @(posedge clk) begin
        if(reset) begin
            rtc_run_ctl<=0;rtc_request_armed<=0;
            tx_state<=TX_IDLE;tx_valid<=0;tx_last<=0;tx_first_armed<=0;
        end else begin
            rtc_run_ctl<=(cfg_write_sel[REG_CONTROL] ? cfg_wdata[0] : active_protocol) && !load_time;
            rtc_request_armed<=rtc_first_armed_next && !rtc_reply_next;
            // Parallel equations retain numeric state values and their
            // original phases, including hold on an unused state encoding.
            tx_state[0]<=rtc_tx_running && ((rtc_tx_idle && rtc_tx_launch) || rtc_tx_word ||
                (rtc_tx_handshake && tx_ready && !tx_index_last_q) || (rtc_tx_invalid && tx_state[0]));
            tx_state[1]<=rtc_tx_running && (rtc_tx_groups || rtc_tx_word || (rtc_tx_invalid && tx_state[1]));
            tx_state[2]<=rtc_tx_running && (rtc_tx_byte || (rtc_tx_handshake && !tx_ready) ||
                (rtc_tx_invalid && tx_state[2]));
            tx_valid<=rtc_tx_running && (rtc_tx_byte || (rtc_control_hold && tx_valid));
            tx_last<=rtc_tx_running && ((rtc_tx_byte && tx_index_last_q) || (rtc_control_hold && tx_last));
            tx_first_armed<=rtc_first_armed_next;
        end
    end

    // Predict the complete response acceptance from the exact D functions
    // of its registered inputs. Each byte owns a same-edge permit: these
    // are not delayed accepted events and add no timestamp/data pipeline.
    // Waiting responses may replace these seconds even while calculation is
    // busy; abort clears protocol control but never cancels that old-edge
    // seconds capture. Both original priority rules remain intact.
    wire rtc_client_launch = !master_tx && countdown_zero_q && !calc_busy && !rx_done && !packet_done;
    wire rtc_server_launch = master_tx && reply_pending;
    wire rtc_waiting_next = !abort_protocol &&
        ((tx_state==TX_IDLE && rtc_client_launch) || (waiting && calc_state!=CALC_APPLY));
    wire rtc_tx_idle_next = abort_protocol ||
        (tx_state==TX_IDLE && !rtc_server_launch && !rtc_client_launch) ||
        (tx_state==TX_HANDSHAKE && tx_ready && tx_index_last_q);
    wire rtc_master_next = cfg_write_sel[REG_CONTROL] ? cfg_wdata[1] : master_rx;
    wire rtc_server_header_next = field_write && field_index==0
        ? (field_data[5:3]==NTP_VERSION && field_data[2:0]==MODE_SERVER) : rx_server_header;
    wire rtc_packet_done_next = BANKED_RX
        ? (!active || !enable || load_pending ? 1'b0 : rx_done)
        : (!abort_protocol && rx_byte && rx_last && rx_index==PACKET_LAST);
    wire rtc_accept_next = rtc_packet_done_next && !rtc_master_next && rtc_waiting_next
        && rtc_tx_idle_next && rtc_server_header_next && (&reply_nibble_match);
    (* preserve=1,dont_merge=1 *) reg [8:0] rtc_capture_ctl;
    wire [31:0] rtc_receive_seconds = rx_receive_sec - NTP_EPOCH;
    wire [31:0] rtc_transmit_seconds = rx_transmit_sec - NTP_EPOCH;
    genvar capture_byte;
    generate for(capture_byte=0;capture_byte<9;capture_byte=capture_byte+1) begin : response_capture
        always @(posedge clk) begin
            if(reset) rtc_capture_ctl[capture_byte]<=0;
            else rtc_capture_ctl[capture_byte]<=rtc_accept_next;
        end
        if(capture_byte<4) begin : receive_word
            always @(posedge clk) begin
                if(reset) server_receive_sec[capture_byte*8+:8]<=0;
                else if(rtc_capture_ctl[capture_byte])
                    server_receive_sec[capture_byte*8+:8]<=rtc_receive_seconds[capture_byte*8+:8];
            end
        end else if(capture_byte<8) begin : transmit_word
            always @(posedge clk) begin
                if(reset) server_transmit_sec[(capture_byte-4)*8+:8]<=0;
                else if(rtc_capture_ctl[capture_byte])
                    server_transmit_sec[(capture_byte-4)*8+:8]<=rtc_transmit_seconds[(capture_byte-4)*8+:8];
            end
        end
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            tx_data <= 0;
            tx_word <= 0;
            tx_word_low <= 0;
            tx_word_high <= 0;
            tx_reply <= 0;
            rx_busy <= 0;
            rx_done <= 0;
            rx_index <= 0;
            echo_sec <= 0;
            echo_frac <= 0;
            server_receive_ns <= 0;
            server_transmit_ns <= 0;
            decode_start <= 0;
            decode_value <= 0;
            waiting <= 0;
            reply_pending <= 0;
            countdown <= 0;
            countdown_zero_q <= 1;
            calc_state <= CALC_IDLE;
            calc_busy <= 0;
            diff_sec1 <= 0;
            diff_sec2 <= 0;
            diff_ns1 <= 0;
            diff_ns2 <= 0;
            sum_sec <= 0;
            sum_ns <= 0;
            correction_sec <= 0;
            correction_ns <= 0;
            correction_sec_calc <= 0;
            correction_ns_calc <= 0;
            offset_negative <= 0;
            offset_overflow <= 0;
            time_overflow <= 0;
            offset_ns_plus <= 0;
            offset_ns_minus <= 0;
            offset_sec_plus <= 0;
            offset_sec_minus <= 0;
            time_ns_minus <= 0;
            time_sec_plus <= 0;
            final_overflow <= 0;
            final_ns_wrapped <= 0;
            final_sec_increment <= 0;
            final_sec_twice <= 0;
            final_tick_direct <= 0;
            final_tick_wrapped <= 0;
            second_odd <= 0;
        end
        else begin
            rx_done <= 0;
            decode_start <= 0;
            // 零标志描述本拍减一后的值；装载和中止在各自分支覆盖，始终与 countdown 同拍。
            countdown_zero_q <= countdown_zero_q || countdown == 32'd1;
            if (!countdown_zero_q) countdown <= countdown - 32'd1;
            if (rx_byte) begin
                rx_busy <= ! rx_last;
                if ( ! rx_busy) begin
                    rx_index <= 1;
                end
                else rx_index <= rx_index + 6'd1;
                if (rx_last && rx_index == PACKET_LAST) rx_done <= 1;
            end
            // 客户端只接受版本、模式及请求时间都匹配的回应。
            // Originate 是回应中回送的请求时间，必须等于当前请求的 Transmit 字段。
            if (packet_done) begin
                if (master_rx && rx_client_header) begin
                    // 服务端逐位复制请求的发送时间，避免换算改变匹配字段。
                    echo_sec <= rx_transmit_sec;
                    echo_frac <= rx_transmit_frac;
                    reply_pending <= 1;
                end
            end
            // Same-edge local acceptance includes packet_done and TX_IDLE;
            // a retry still excludes an old response throughout transmission.
            if (rtc_capture_ctl[8]) begin
                calc_state <= CALC_START_T2;
                calc_busy <= 1;
            end
            // 时钟偏差为 ((T2-T1)+(T3-T4))/2。
            // 秒和纳秒分开计算，再处理借位和进位。
            case (calc_state)

                CALC_START_T2 : begin
                    decode_value <= rx_receive_frac;
                    decode_start <= 1;
                    calc_state <= CALC_WAIT_T2;
                end

                CALC_WAIT_T2 : if (decode_done) begin
                    server_receive_ns <= decode_result;
                    calc_state <= CALC_START_T3;
                end

                CALC_START_T3 : begin
                    decode_value <= rx_transmit_frac;
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
                    correction_sec_calc <= sum_sec >>> 1;
                    correction_ns_calc <= sum_ns >>> 1;
                    second_odd <= sum_sec[0];
                    calc_state <= CALC_HALF_SECOND;
                end

                CALC_HALF_SECOND : begin
                    correction_ns <= rtc_add_half(correction_ns,second_odd,rtc_half_carry);
                    correction_ns_calc <= rtc_add_half(correction_ns_calc,second_odd,rtc_half_carry);
                    calc_state <= CALC_OFFSET_CANDIDATES;
                end

                CALC_OFFSET_CANDIDATES : begin
                    offset_negative <= correction_ns < 0;
                    offset_overflow <= correction_ns >= NS_PER_SECOND_S;
                    offset_ns_plus <= correction_ns + NS_PER_SECOND_S;
                    offset_ns_minus <= correction_ns - NS_PER_SECOND_S;
                    offset_sec_plus <= correction_sec + 32'sd1;
                    offset_sec_minus <= correction_sec - 32'sd1;
                    calc_state <= CALC_NORMALIZE_OFFSET;
                end

                CALC_NORMALIZE_OFFSET : begin
                    if (offset_negative) begin
                        correction_ns <= offset_ns_plus;
                        correction_sec <= offset_sec_minus;
                        correction_ns_calc <= offset_ns_plus;
                        correction_sec_calc <= offset_sec_minus;
                    end
                    else if (offset_overflow) begin
                        correction_ns <= offset_ns_minus;
                        correction_sec <= offset_sec_plus;
                        correction_ns_calc <= offset_ns_minus;
                        correction_sec_calc <= offset_sec_plus;
                    end
                    calc_state <= CALC_ADD_OFFSET;
                end

                CALC_ADD_OFFSET : begin
                    calc_state <= CALC_TIME_CANDIDATES;
                end

                CALC_TIME_CANDIDATES : begin
                    time_overflow <= ge32(adjusted_ns, NS_PER_SECOND);
                    time_ns_minus <= adjusted_ns - NS_PER_SECOND;
                    time_sec_plus <= adjusted_sec + 32'd1;
                    calc_state <= CALC_NORMALIZE_TIME;
                end

                CALC_NORMALIZE_TIME : begin
                    calc_state <= CALC_LATENCY;
                end

                CALC_LATENCY : begin
                    // 预先并行计算最终进位及两种结果；应用拍只选择，不串接比较和加法。
                    final_overflow <= ge32(adjusted_ns, NS_PER_SECOND - PIPELINE_NS)
                        && !ge32(adjusted_ns, MAX_BEFORE_PIPELINE + 1);
                    final_tick_direct <= ge32(adjusted_ns, LAST_TICK_NS - PIPELINE_NS)
                        && !ge32(adjusted_ns, MAX_BEFORE_PIPELINE + 1);
                    final_tick_wrapped <= ge32(adjusted_ns, NS_PER_SECOND + LAST_TICK_NS - PIPELINE_NS)
                        && !ge32(adjusted_ns, MAX_BEFORE_PIPELINE + 1);
                    final_ns_wrapped <= adjusted_ns + PIPELINE_NS - NS_PER_SECOND;
                    final_sec_increment <= adjusted_sec + 32'd1;
                    final_sec_twice <= adjusted_sec + 32'd2;
                    calc_state <= CALC_APPLY;
                end

                CALC_APPLY : begin
                    waiting <= 0;
                    calc_state <= CALC_IDLE;
                    calc_busy <= 0;
                end
            endcase
            // 服务端发送待答复的报文，客户端在请求周期到期时重发。
            case (tx_state)

                TX_IDLE : begin
                    if (master_tx && reply_pending) begin
                        tx_reply <= 1;
                        reply_pending <= 0;
                    end
                    // 正在接收完整回应或计算校正量时，客户端暂不启动下一次请求。
                    else if ( ! master_tx && countdown_zero_q && ! calc_busy && !rx_done && !packet_done) begin
                        tx_reply <= 0;
                        waiting <= 1;
                        countdown <= period;
                        countdown_zero_q <= period_zero;
                    end
                end

                TX_GROUPS : begin
                    // 字段分两组选择，以减少一拍内的数据选择层数。
                    case (rtc_effective_index[4:2])
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
                    case (rtc_effective_index[3:2])
                        0 : tx_word_high <= tx_reply ? stamp_rx_sec : 32'd0;
                        1 : tx_word_high <= tx_reply ? stamp_rx_frac : 32'd0;
                        2 : tx_word_high <= stamp_tx_sec;
                        3 : tx_word_high <= stamp_tx_frac;
                    endcase
                end

                TX_WORD : begin
                    tx_word <= tx_index[5] ? tx_word_high : tx_word_low;
                end

                TX_BYTE : begin
                    case (tx_index[1:0])
                        0 : tx_data <= tx_word[31:24];
                        1 : tx_data <= tx_word[23:16];
                        2 : tx_data <= tx_word[15:8];
                        3 : tx_data <= tx_word[7:0];
                    endcase
                end

                TX_HANDSHAKE : begin end
            endcase
            // 中止只覆盖控制位；宽中间结果会在下一事务使用前重新计算。
            if (abort_protocol) begin
                rx_busy <= 0;
                rx_done <= 0;
                waiting <= 0;
                reply_pending <= 0;
                countdown <= 0;
                countdown_zero_q <= 1;
                calc_state <= CALC_IDLE;
                calc_busy <= 0;
                decode_start <= 0;
            end
        end
    end

    // 模式 2：高位为写地址，bit 6 选主机，[5:3] 为主机读址，[2:0] 为 MIB 预读址。
    // MIB 地址在读请求之前稳定一拍；每四位输出使用独立译码副本，主机仍直接译码。
    wire [31:0] word_cfg_rdata_0 = {30'b0, master, active};
    wire [31:0] word_cfg_rdata_1 = period_read;
    wire [31:0] word_cfg_rdata_2 = {25'b0, vl};
    wire [31:0] word_cfg_rdata_3 = {16'b0, port_number};
    wire [31:0] word_cfg_rdata_4 = seconds;
    wire [31:0] word_cfg_rdata_5 = snapshot_ns;
    wire [31:0] word_cfg_rdata_6 = offset_sec;
    wire [31:0] word_cfg_rdata_7 = offset_ns;
    genvar read_nibble;
    generate
        if (SPLIT_CFG_ADDR == 2) begin : local_read_decode
            for (read_nibble = 0; read_nibble < 8; read_nibble = read_nibble + 1) begin : nibble
                (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_lane;
                // Select the address before the parallel data reduction;
                // snapshot/seconds no longer traverse a second host-data mux.
                wire [7:0] lane = cfg_addr[6] ? (8'b1 << cfg_addr[5:3]) : mib_lane;
                (* keep = 1 *) wire [3:0] pair01 =
                    ({4{lane[0]}} & word_cfg_rdata_0[read_nibble * 4 +: 4]) |
                    ({4{lane[1]}} & word_cfg_rdata_1[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] pair23 =
                    ({4{lane[2]}} & word_cfg_rdata_2[read_nibble * 4 +: 4]) |
                    ({4{lane[3]}} & word_cfg_rdata_3[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] pair45 =
                    ({4{lane[4]}} & word_cfg_rdata_4[read_nibble * 4 +: 4]) |
                    ({4{lane[5]}} & word_cfg_rdata_5[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] pair67 =
                    ({4{lane[6]}} & word_cfg_rdata_6[read_nibble * 4 +: 4]) |
                    ({4{lane[7]}} & word_cfg_rdata_7[read_nibble * 4 +: 4]);
                always @(posedge clk) begin
                    if (reset) begin
                        mib_lane <= 8'b1;
                        cfg_rdata[read_nibble * 4 +: 4] <= 0;
                    end
                    else begin
                        mib_lane <= 8'b1 << cfg_addr[2:0];
                        cfg_rdata[read_nibble * 4 +: 4] <= pair01 | pair23 | pair45 | pair67;
                    end
                end
            end
        end
    endgenerate

endmodule
