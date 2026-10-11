// SNMP v1/v2c代理，处理单变量Get/GetNext/Set及v2c Trap。
// rx/tx_*为UDP服务通道，mib_*访问共享配置总线。
// BER解析和回应构造逐字段推进；同步RAM访问拆为地址/等待/采样。
// 单变量绑定的SNMP v1/v2c代理；BER逐字节处理，两块RAM保存请求和回应。
module afdx_snmp (
    // clk/reset 为同步控制，enable 为核心就绪；now 给 MIB 读快照提供周期标签。
    input wire clk, reset, enable,
    input wire [31:0] now,
    // cfg_* 设置代理/community/Trap 并读回控制、统计和 sysDescr。
    input wire cfg_we,
    input wire [7:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_control_data, cfg_status_data, cfg_descr_data,
    // mib_* 通过共享总线读对象或写 user_id；ready 为请求授权，rvalid 为读数据有效。
    output reg mib_rd, mib_wr,
    output reg [17:0] mib_addr,
    output reg [31:0] mib_wdata,
    input wire mib_ready, mib_rvalid,
    input wire [31:0] mib_rdata,
    // tx_* 为回应/Trap 的握手字节流，tx_vl 为配置的发送 VL，tx_dport 为对端端口。
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output wire [6:0] tx_vl,
    output wire [15:0] tx_dport,
    // rx_* 是 UDP 载荷及端口；rx_claim 仅认领已启用代理的 UDP 161。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_sport, rx_dport,
    output wire rx_claim);
    localparam [127:0] DESCRIPTION = "C3 AFDX endpoint";
    localparam IDLE = 0, CAPTURE = 1, START = 2, FETCH0 = 3, FETCH1 = 4, FETCH2 = 5, FETCH3 = 6, TAG = 7, LENGTH = 8,
        LONG_LENGTH = 9, DISPATCH = 10, VERSION = 11, COMMUNITY = 12, INTEGER_VALUE = 13, LOOK_START = 14, LOOK_COMPARE = 15,
        LOOK_NEXT = 16, FOUND = 17, MISSING = 18, MIB_REQUEST = 19, MIB_WAIT = 20, VALUE_PREP = 21, LEN1 = 22, LEN2 = 23,
        LEN3 = 24, LEN4 = 25, BUILD = 26, COPY_COMM = 27, COPY_OID = 28, TX_FLUSH = 29, TX_ADDR = 30, TX_WAIT1 = 31,
        TX_WAIT2 = 32, TX_SEND = 33, SET_VALUE = 34, SET_CHECK = 35, SET_WRITE = 36, SET_ERROR = 37, COPY_VALUE = 38,
        TRAP_INIT = 39, TRAP_COMM0 = 40, TRAP_COMM1 = 41, TRAP_WORD = 42, TRAP_BYTE = 43;
    // cold_pending/auth_pending 保存尚未发送的冷启动/认证失败通知；发送完成才增加 traps_sent。
    reg configured, trap_enabled, cold_pending, auth_pending, sending_trap;
    reg [31:0] traps_sent;
    reg [7:0] trap_event;
    // 固定Trap尾部按四个64位字、再按八字节两级选择。
    reg [63:0] trap_word;
    reg get_set, echo_value, set_negative;
    reg [7:0] set_value_start, set_value_tag, set_value_length;
    reg [31:0] set_number;
    reg [6:0] response_vl;
    reg [4:0] configured_length;
    // community是4个32位的小寄存器组，最多16字节，高字节先发。
    reg [31:0] community0, community1, community2, community3;
    reg [31:0] uptime, uptime_cycles, requests, bad_community, sample_cycle;
    reg [6:0] state, return_state;
    reg [15:0] response_port;
    // cursor 是 BER 游标；outer_end/pdu_end/list_end/binding_end 强制恰好一个完整变量绑定。
    reg [8:0] rx_count, request_length, cursor, outer_end, pdu_end, list_end, binding_end;
    reg overflow;
    reg req_we, req_re, out_we, out_re;
    reg [7:0] req_wa, req_ra, req_wdata, out_wa, out_ra, out_wdata;
    wire [7:0] req_q, out_q;
    reg [7:0] byte_value, tag_value;
    reg [15:0] field_length;
    reg [1:0] length_left;
    reg [3:0] field;
    reg [4:0] value_pos, community_length, oid_length;
    reg [7:0] community_start, oid_start;
    reg [31:0] community_word;
    reg [7:0] community_expected;
    reg community_bad;
    reg version;
    reg get_next;
    reg [2:0] request_id_length;
    reg [31:0] request_id, id_shift;
    // candidate/object_index 选 MIB 对象；arc_index/oid_acc 按数字 OID 弧比较，避免直接比较字节。
    reg [5:0] candidate, object_index;
    reg [4:0] oid_pos;
    reg [3:0] arc_index;
    reg [31:0] oid_acc, expected_arc;
    wire [31:0] decoded_arc = { oid_acc[24:0], byte_value[6:0] };
    reg missing;
    reg [7:0] error_status, value_tag, value_length, response_oid_length;
    reg [31:0] value_number, value_shift;
    reg [127:0] descr_shift;
    reg [7:0] binding_length, list_length, pdu_length, message_length;
    // output_count 写回应，tx_pos 读回应；part/part_pos 控制 BER 外层到值的序列化。
    reg [8:0] output_count, response_length, tx_pos;
    reg [4:0] part, part_pos;
    // 两个 256 字节 RAM 分别保存请求与已构造回应，发送被反压时请求内容仍可用于错误回显。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(256)) request_ram (clk, req_we, req_wa, req_wdata, req_re, req_ra, req_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(256)) response_ram (clk, out_we, out_wa, out_wdata, out_re, out_ra, out_q);
    assign rx_claim = configured && rx_dport == 161;
    assign tx_vl = response_vl;
    assign tx_dport = response_port;
    // MIB按数字OID顺序排列：两个system标量，随后34个私有标量。
    function [31:0] mib_arc;
        input [5:0] item;
        input [3:0] position;
        begin
            mib_arc = 0;
            case (position)
                0 : mib_arc = 43;
                1 : mib_arc = 6;
                2 : mib_arc = 1;
                3 : mib_arc = item < 2 ? 2 : 4;
                4 : mib_arc = 1;
                5 : mib_arc = item < 2 ? 1 : 424242;
                6 : mib_arc = item < 2 ? (item == 0 ? 1 : 3) : 3;
                7 : mib_arc = item < 2 ? 0 : { 26'b0, item } - 32'd1;
                default : mib_arc = 0;
            endcase
        end
    endfunction
    function [7:0] mib_oid_byte;
        input [5:0] item;
        input [4:0] position;
        begin
            mib_oid_byte = 0;
            case (position)
                0 : mib_oid_byte = 8'h2b;
                1 : mib_oid_byte = 6;
                2 : mib_oid_byte = 1;
                3 : mib_oid_byte = item < 2 ? 2 : 4;
                4 : mib_oid_byte = 1;
                5 : mib_oid_byte = item < 2 ? 1 : 8'h99;
                6 : mib_oid_byte = item < 2 ? (item == 0 ? 1 : 3) : 8'hf2;
                7 : mib_oid_byte = item < 2 ? 0 : 8'h32;
                8 : mib_oid_byte = 3;
                9 : mib_oid_byte = { 2'b0, item } - 8'd1;
                default : mib_oid_byte = 0;
            endcase
        end
    endfunction
    // 私有 MIB 标量映射到配置/统计地址；只有索引 3 的 user_id 允许 Set。
    function [17:0] mib_address;
        input [5:0] item;
        begin
            case (item)
                0 : mib_address = 18'ha0;
                1 : mib_address = 18'h98;
                2 : mib_address = 0;
                3 : mib_address = 2;
                4 : mib_address = 18'h84;
                5 : mib_address = 18'h88;
                33 : mib_address = 18'h99;
                34 : mib_address = 18'h9a;
                35 : mib_address = 18'h9c;
                default : begin
                    if (item <= 12) mib_address = 18'h40 + item - 6;
                    else if (item <= 20) mib_address = 18'h48 + item - 13;
                    else if (item <= 28) mib_address = 18'h50 + item - 21;
                    else mib_address = 18'h58 + item - 29;
                end
            endcase
        end
    endfunction
    // RAM 字节读取子流程保存返回状态；emit 只登记一次回应 RAM 写入。
    task fetch;
        input [6:0] target;
        begin
            return_state <= target;
            state <= FETCH0;
        end
    endtask
    task emit;
        input [7:0] value;
        begin
            out_we <= 1;
            out_wa <= output_count[7:0];
            out_wdata <= value;
            output_count <= output_count + 9'd1;
        end
    endtask
    always @(posedge clk) begin
        if (reset) begin
            configured <= 0;
            trap_enabled <= 0;
            response_vl <= 0;
            configured_length <= 6;
            community0 <= 32'h7075626c;
            community1 <= 32'h69630000;
            community2 <= 0;
            community3 <= 0;
            uptime <= 0;
            uptime_cycles <= 0;
            cfg_control_data <= 0;
            cfg_status_data <= 0;
            cfg_descr_data <= 0;
        end
        else begin
            if (uptime_cycles == 1249999) begin
                uptime_cycles <= 0;
                uptime <= uptime + 32'd1;
            end
            else uptime_cycles <= uptime_cycles + 32'd1;
            if (cfg_we) case (cfg_addr)
                8'h90 : configured <= cfg_wdata[0];
                8'h91 : response_vl <= cfg_wdata[6:0];
                8'h92 : configured_length <= cfg_wdata[4:0];
                8'h93 : community0 <= cfg_wdata;
                8'h94 : community1 <= cfg_wdata;
                8'h95 : community2 <= cfg_wdata;
                8'h96 : community3 <= cfg_wdata;
                8'h9b : trap_enabled <= cfg_wdata[0];
            endcase
            case (cfg_addr[2:0])
                0 : cfg_control_data <= { 31'b0, configured };
                1 : cfg_control_data <= { 25'b0, response_vl };
                2 : cfg_control_data <= { 27'b0, configured_length };
                3 : cfg_control_data <= community0;
                4 : cfg_control_data <= community1;
                5 : cfg_control_data <= community2;
                6 : cfg_control_data <= community3;
                7 : cfg_control_data <= sample_cycle;
            endcase
            case (cfg_addr[2:0])
                0 : cfg_status_data <= uptime;
                1 : cfg_status_data <= requests;
                2 : cfg_status_data <= bad_community;
                3 : cfg_status_data <= { 31'b0, trap_enabled };
                4 : cfg_status_data <= traps_sent;
                default : cfg_status_data <= 0;
            endcase
            case (cfg_addr[2:0])
                0 : cfg_descr_data <= DESCRIPTION[127:96];
                1 : cfg_descr_data <= DESCRIPTION[95:64];
                2 : cfg_descr_data <= DESCRIPTION[63:32];
                3 : cfg_descr_data <= DESCRIPTION[31:0];
                default : cfg_descr_data <= 0;
            endcase
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            return_state <= IDLE;
            req_we <= 0;
            req_re <= 0;
            out_we <= 0;
            out_re <= 0;
            req_wa <= 0;
            req_ra <= 0;
            req_wdata <= 0;
            out_wa <= 0;
            out_ra <= 0;
            out_wdata <= 0;
            tx_valid <= 0;
            tx_data <= 0;
            tx_last <= 0;
            mib_rd <= 0;
            mib_wr <= 0;
            mib_addr <= 0;
            mib_wdata <= 0;
            requests <= 0;
            bad_community <= 0;
            sample_cycle <= 0;
            response_port <= 0;
            cold_pending <= 0;
            auth_pending <= 0;
            sending_trap <= 0;
            traps_sent <= 0;
            trap_event <= 0;
            trap_word <= 0;
            get_set <= 0;
            echo_value <= 0;
            set_negative <= 0;
            set_value_start <= 0;
            set_value_tag <= 0;
            set_value_length <= 0;
            set_number <= 0;
            rx_count <= 0;
            request_length <= 0;
            overflow <= 0;
            cursor <= 0;
            field <= 0;
            byte_value <= 0;
            tag_value <= 0;
            field_length <= 0;
            length_left <= 0;
            value_pos <= 0;
            outer_end <= 0;
            pdu_end <= 0;
            list_end <= 0;
            binding_end <= 0;
            community_length <= 0;
            community_start <= 0;
            community_word <= 0;
            community_expected <= 0;
            community_bad <= 0;
            version <= 0;
            get_next <= 0;
            request_id <= 0;
            request_id_length <= 0;
            id_shift <= 0;
            oid_start <= 0;
            oid_length <= 0;
            oid_pos <= 0;
            arc_index <= 0;
            oid_acc <= 0;
            expected_arc <= 0;
            candidate <= 0;
            object_index <= 0;
            missing <= 0;
            error_status <= 0;
            value_tag <= 0;
            value_length <= 0;
            response_oid_length <= 0;
            value_number <= 0;
            value_shift <= 0;
            descr_shift <= 0;
            binding_length <= 0;
            list_length <= 0;
            pdu_length <= 0;
            message_length <= 0;
            output_count <= 0;
            response_length <= 0;
            tx_pos <= 0;
            part <= 0;
            part_pos <= 0;
        end
        else begin
            req_we <= 0;
            req_re <= 0;
            out_we <= 0;
            out_re <= 0;
            if (rx_valid && rx_claim && rx_last) requests <= requests + 32'd1;
            if (! configured || ! enable) begin
                state <= IDLE;
                tx_valid <= 0;
                tx_last <= 0;
                mib_rd <= 0;
                mib_wr <= 0;
            end
            // SNMP BER 解析、MIB 访问、回应构造串行推进；请求/回应 PDU 与 Trap 均使用同一发送 RAM。
            else case (state)
                // 等待 UDP 请求；无请求时处理待发 Trap，分别转 CAPTURE/START 或 TRAP_INIT。
                IDLE : if (rx_valid && rx_claim) begin
                    sending_trap <= 0;
                    req_we <= 1;
                    req_wa <= 0;
                    req_wdata <= rx_data;
                    rx_count <= 1;
                    overflow <= 0;
                    response_port <= rx_sport;
                    if (rx_last) begin
                        request_length <= 1;
                        state <= START;
                    end
                    else state <= CAPTURE;
                end
                else if (trap_enabled && (cold_pending || auth_pending)) begin
                    sending_trap <= 1;
                    trap_event <= cold_pending ? 8'd1 : 8'd5;
                    if (cold_pending) cold_pending <= 0;
                    else auth_pending <= 0;
                    state <= TRAP_INIT;
                end
                // 缓存请求直到 last；溢出丢弃回 IDLE，否则 START。
                CAPTURE : if (rx_valid) begin
                    if (! overflow) begin
                        req_we <= 1;
                        req_wa <= rx_count[7:0];
                        req_wdata <= rx_data;
                        rx_count <= rx_count + 9'd1;
                    end
                    if (rx_count == 255) overflow <= 1;
                    if (rx_last) begin
                        request_length <= rx_count + 9'd1;
                        state <= overflow ? IDLE : START;
                    end
                end
                // 清本次 BER 解析上下文，从第一层 TAG 开始。
                START : begin
                    cursor <= 0;
                    field <= 0;
                    community_bad <= 0;
                    request_id <= 0;
                    missing <= 0;
                    echo_value <= 0;
                    error_status <= 0;
                    fetch (TAG);
                end
                // 检查 cursor 边界并发请求 RAM 读，预选 OID/community 参考字段，转 FETCH1。
                FETCH0 : begin
                    if (cursor >= request_length) state <= IDLE;
                    else begin
                        req_re <= 1;
                        req_ra <= cursor[7:0];
                        expected_arc <= mib_arc (candidate, arc_index);
                        case (value_pos[3:2])
                            0 : community_word <= community0;
                            1 : community_word <= community1;
                            2 : community_word <= community2;
                            3 : community_word <= community3;
                        endcase
                        state <= FETCH1;
                    end
                end
                // 等待同步 RAM，同时选择 community 字节，转 FETCH2。
                FETCH1 : begin
                    case (value_pos[1:0])
                        0 : community_expected <= community_word[31:24];
                        1 : community_expected <= community_word[23:16];
                        2 : community_expected <= community_word[15:8];
                        3 : community_expected <= community_word[7:0];
                    endcase
                    state <= FETCH2;
                end
                // 锁存 RAM 字节到 byte_value，转 FETCH3。
                FETCH2 : begin
                    byte_value <= req_q;
                    state <= FETCH3;
                end
                // 跳回 fetch 调用者保存的 return_state。
                FETCH3 : state <= return_state;
                // 记录 BER 类型，移动游标并读取 LENGTH。
                TAG : begin
                    tag_value <= byte_value;
                    cursor <= cursor + 9'd1;
                    fetch (LENGTH);
                end
                // 短长度直接 DISPATCH；0x81/0x82 长长度转 LONG_LENGTH，其余丢弃。
                LENGTH : begin
                    cursor <= cursor + 9'd1;
                    if (! byte_value[7]) begin
                        field_length <= { 9'b0, byte_value[6:0] };
                        state <= DISPATCH;
                    end
                    else if (byte_value == 8'h81 || byte_value == 8'h82) begin
                        length_left <= byte_value[1:0];
                        field_length <= 0;
                        fetch (LONG_LENGTH);
                    end
                    else state <= IDLE;
                end
                // 按字节拼长度；读够后 DISPATCH，否则继续 fetch。
                LONG_LENGTH : begin
                    field_length <= { field_length[7:0], byte_value };
                    cursor <= cursor + 9'd1;
                    length_left <= length_left - 2'd1;
                    if (length_left == 1) state <= DISPATCH;
                    else fetch (LONG_LENGTH);
                end
                // 逐层核对类型、长度和容器边界，按 field 选择字段解析；不支持的格式回 IDLE。
                DISPATCH : begin
                    value_pos <= 0;
                    if (field_length > 256 || cursor + field_length > request_length) state <= IDLE;
                    else case (field)
                        0 : if (tag_value == 8'h30) begin
                            outer_end <= cursor + field_length;
                            field <= 1;
                            fetch (TAG);
                        end
                        else state <= IDLE;
                        1 : if (tag_value == 2 && field_length == 1) fetch (VERSION);
                        else state <= IDLE;
                        2 : if (tag_value == 4 && field_length >= 1 && field_length <= 16) begin
                            community_length <= field_length[4:0];
                            community_start <= cursor[7:0];
                            community_bad <= (field_length != configured_length);
                            fetch (COMMUNITY);
                        end
                        else begin
                            bad_community <= bad_community + 32'd1;
                            if (trap_enabled) auth_pending <= 1;
                            state <= IDLE;
                        end
                        3 : if (tag_value == 8'ha0 || tag_value == 8'ha1 || tag_value == 8'ha3) begin
                            get_next <= (tag_value == 8'ha1);
                            get_set <= (tag_value == 8'ha3);
                            pdu_end <= cursor + field_length;
                            field <= 4;
                            fetch (TAG);
                        end
                        else state <= IDLE;
                        4, 5, 6 : if (tag_value == 2 && field_length >= 1 && field_length <= 4) begin
                            if (field == 4) request_id_length <= field_length[2:0];
                            fetch (INTEGER_VALUE);
                        end
                        else state <= IDLE;
                        7 : if (tag_value == 8'h30) begin
                            list_end <= cursor + field_length;
                            field <= 8;
                            fetch (TAG);
                        end
                        else state <= IDLE;
                        8 : if (tag_value == 8'h30) begin
                            binding_end <= cursor + field_length;
                            field <= 9;
                            fetch (TAG);
                        end
                        else state <= IDLE;
                        9 : if (tag_value == 6 && field_length >= 1 && field_length <= 16) begin
                            oid_start <= cursor[7:0];
                            oid_length <= field_length[4:0];
                            cursor <= cursor + field_length;
                            field <= 10;
                            fetch (TAG);
                        end
                        else state <= IDLE;
                        10 : if (((get_set && field_length <= 16) || (tag_value == 5 && field_length == 0)) && cursor + field_length == binding_end && binding_end == list_end && list_end == pdu_end && pdu_end == outer_end && outer_end == request_length) begin
                            set_value_start <= cursor[7:0];
                            set_value_tag <= tag_value;
                            set_value_length <= field_length[7:0];
                            candidate <= 0;
                            state <= LOOK_START;
                        end
                        else state <= IDLE;
                        default : state <= IDLE;
                    endcase
                end
                // 只接受 SNMP v1/v2c 的 0/1 版本值，通过后读 community。
                VERSION : begin
                    if (byte_value <= 1) begin
                        version <= byte_value[0];
                        cursor <= cursor + 9'd1;
                        field <= 2;
                        fetch (TAG);
                    end
                    else state <= IDLE;
                end
                // 逐字节比较 community；相等继续 PDU，不匹配记认证事件并丢弃。
                COMMUNITY : begin
                    community_bad <= community_bad || byte_value != community_expected;
                    cursor <= cursor + 9'd1;
                    value_pos <= value_pos + 5'd1;
                    if (value_pos + 1 == community_length) begin
                        if (community_bad || byte_value != community_expected) begin
                            bad_community <= bad_community + 32'd1;
                            if (trap_enabled) auth_pending <= 1;
                            state <= IDLE;
                        end
                        else begin
                            field <= 3;
                            fetch (TAG);
                        end
                    end
                    else fetch (COMMUNITY);
                end
                // 读取 request-id/error-status/error-index；字段结束后读取下一 TAG。
                INTEGER_VALUE : begin
                    if (field == 4) request_id <= { request_id[23:0], byte_value };
                    cursor <= cursor + 9'd1;
                    value_pos <= value_pos + 5'd1;
                    if (value_pos + 1 == field_length) begin
                        field <= field + 4'd1;
                        fetch (TAG);
                    end
                    else fetch (INTEGER_VALUE);
                end
                // 把请求 OID 游标归零，开始与当前 MIB 候选逐个数字弧比较。
                LOOK_START : begin
                    cursor <= { 1'b0, oid_start };
                    oid_pos <= 0;
                    arc_index <= 0;
                    oid_acc <= 0;
                    fetch (LOOK_COMPARE);
                end
                // 解析 base-128 OID 弧；Get 找精确相等，GetNext 找严格后继，否则 LOOK_NEXT。
                LOOK_COMPARE : begin
                    if (byte_value[7]) begin
                        if (oid_pos + 1 == oid_length) state <= IDLE;
                        else begin
                            oid_acc <= decoded_arc;
                            cursor <= cursor + 9'd1;
                            oid_pos <= oid_pos + 5'd1;
                            fetch (LOOK_COMPARE);
                        end
                    end
                    else if (decoded_arc < expected_arc) state <= get_next ? FOUND : LOOK_NEXT;
                    else if (decoded_arc > expected_arc) state <= LOOK_NEXT;
                    else if (oid_pos + 1 == oid_length) begin
                        if (arc_index == (candidate < 2 ? 7 : 8)) state <= get_next ? LOOK_NEXT : FOUND;
                        else state <= get_next ? FOUND : LOOK_NEXT;
                    end
                    else if (arc_index == (candidate < 2 ? 7 : 8)) state <= LOOK_NEXT;
                    else begin
                        oid_acc <= 0;
                        arc_index <= arc_index + 4'd1;
                        oid_pos <= oid_pos + 5'd1;
                        cursor <= cursor + 9'd1;
                        fetch (LOOK_COMPARE);
                    end
                end
                // 递增候选并重比；36 项均未找到则 MISSING。
                LOOK_NEXT : if (candidate == 35) state <= MISSING;
                else begin
                    candidate <= candidate + 6'd1;
                    state <= LOOK_START;
                end
                // 记录对象和寄存器地址；Get 发读，Set 校验可写对象与类型后读值，非法写转 SET_ERROR。
                FOUND : begin
                    object_index <= candidate;
                    mib_addr <= mib_address (candidate);
                    missing <= 0;
                    if (! get_set) begin
                        mib_rd <= 1;
                        state <= MIB_REQUEST;
                    end
                    else if (candidate != 3) begin
                        error_status <= version ? 17 : 2;
                        state <= SET_ERROR;
                    end
                    else if (set_value_tag != 8'h42) begin
                        error_status <= version ? 7 : 3;
                        state <= SET_ERROR;
                    end
                    else if (set_value_length < 1 || set_value_length > 5) begin
                        error_status <= version ? 8 : 3;
                        state <= SET_ERROR;
                    end
                    else begin
                        cursor <= { 1'b0, set_value_start };
                        value_pos <= 0;
                        set_number <= 0;
                        set_negative <= 0;
                        fetch (SET_VALUE);
                    end
                end
                // Get 返回 v1 错误或 v2c 异常值；Set 返回不可写错误。
                MISSING : begin
                    if (get_set) begin
                        error_status <= version ? 17 : 2;
                        state <= SET_ERROR;
                    end
                    else begin
                        missing <= 1;
                        error_status <= version ? 0 : 2;
                        value_tag <= version ? (get_next ? 8'h82 : 8'h80) : 8'h05;
                        value_length <= 0;
                        response_oid_length <= { 3'b0, oid_length };
                        state <= LEN1;
                    end
                end
                // 拼接 Set 数值并记录符号；全部字节收完后 SET_CHECK。
                SET_VALUE : begin
                    set_number <= { set_number[23:0], byte_value };
                    if (value_pos == 0) set_negative <= byte_value[7];
                    value_pos <= value_pos + 5'd1;
                    cursor <= cursor + 9'd1;
                    if (value_pos + 1 == set_value_length) state <= SET_CHECK;
                    else fetch (SET_VALUE);
                end
                // 只接受非负 16 位 user_id，合格发总线写，否则 SET_ERROR。
                SET_CHECK : begin
                    if (set_negative || | set_number[31:16]) begin
                        error_status <= version ? 10 : 3;
                        state <= SET_ERROR;
                    end
                    else begin
                        mib_wdata <= set_number;
                        mib_wr <= 1;
                        state <= SET_WRITE;
                    end
                end
                // 总线写成功后再读回，用实际配置值生成成功回应。
                // 等待写握手完成，再发读以构造实际写入值的回应。
                SET_WRITE : if (mib_ready) begin
                    mib_wr <= 0;
                    mib_rd <= 1;
                    state <= MIB_REQUEST;
                end
                // 保留请求 OID/值用于错误回显，转 LEN1。
                SET_ERROR : begin
                    missing <= 1;
                    echo_value <= 1;
                    value_tag <= set_value_tag;
                    value_length <= set_value_length;
                    response_oid_length <= { 3'b0, oid_length };
                    state <= LEN1;
                end
                // 等共享配置总线授权，记录采样周期，撤销读请求后 MIB_WAIT。
                MIB_REQUEST : if (mib_ready) begin
                    mib_rd <= 0;
                    sample_cycle <= now;
                    state <= MIB_WAIT;
                end
                // 等 mib_rvalid，锁存数值后 VALUE_PREP。
                MIB_WAIT : if (mib_rvalid) begin
                    value_number <= mib_rdata;
                    state <= VALUE_PREP;
                end
                // 选择 SNMP 值类型和最短非负编码长度，转 LEN1。
                VALUE_PREP : begin
                    response_oid_length <= object_index < 2 ? 8 : 11;
                    if (object_index == 0) begin
                        value_tag <= 4;
                        value_length <= 16;
                        value_shift <= 0;
                    end
                    else begin
                        value_tag <= object_index == 1 ? 8'h43 : (object_index >= 2 && object_index <= 4 ? 8'h42 : 8'h41);
                        if (value_number[31]) begin
                            value_length <= 5;
                            value_shift <= value_number;
                        end
                        else if (| value_number[30:23]) begin
                            value_length <= 4;
                            value_shift <= value_number;
                        end
                        else if (| value_number[22:15]) begin
                            value_length <= 3;
                            value_shift <= { value_number[23:0], 8'b0 };
                        end
                        else if (| value_number[14:7]) begin
                            value_length <= 2;
                            value_shift <= { value_number[15:0], 16'b0 };
                        end
                        else begin
                            value_length <= 1;
                            value_shift <= { value_number[7:0], 24'b0 };
                        end
                    end
                    state <= LEN1;
                end
                // 计算变量绑定长度，转 LEN2。
                LEN1 : begin
                    binding_length <= response_oid_length + value_length + 8'd4;
                    state <= LEN2;
                end
                // 计算绑定列表长度，Trap 额外计入通知 OID，转 LEN3。
                LEN2 : begin
                    list_length <= binding_length + (sending_trap ? 8'd27 : 8'd2);
                    state <= LEN3;
                end
                // 计算 PDU 长度，转 LEN4。
                LEN3 : begin
                    pdu_length <= list_length + { 5'b0, request_id_length } + 8'd10;
                    state <= LEN4;
                end
                // 计算消息总长并准备 ID/描述移位寄存器，转 BUILD。
                LEN4 : begin
                    message_length <= pdu_length + { 3'b0, community_length } + 8'd7;
                    response_length <= pdu_length + { 4'b0, community_length } + 9'd9;
                    id_shift <= request_id << ((4 - request_id_length) * 8);
                    descr_shift <= DESCRIPTION;
                    part <= 0;
                    part_pos <= 0;
                    output_count <= 0;
                    state <= BUILD;
                end
                // part 0–6 发外层头，7 community，8–18 PDU头，19–27 绑定头/OID，28 值；结束转发送。
                BUILD : case (part)
                    0 : begin
                        emit (8'h30);
                        part <= 1;
                    end
                    1 : begin
                        emit (message_length);
                        part <= 2;
                    end
                    2 : begin
                        emit (2);
                        part <= 3;
                    end
                    3 : begin
                        emit (1);
                        part <= 4;
                    end
                    4 : begin
                        emit ({ 7'b0, version });
                        part <= 5;
                    end
                    5 : begin
                        emit (4);
                        part <= 6;
                    end
                    6 : begin
                        emit ({ 3'b0, community_length });
                        part <= 7;
                        part_pos <= 0;
                    end
                    7 : if (sending_trap) state <= TRAP_COMM0;
                    else begin
                        cursor <= { 1'b0, community_start } + part_pos;
                        fetch (COPY_COMM);
                    end
                    8 : begin
                        emit (sending_trap ? 8'ha7 : 8'ha2);
                        part <= 9;
                    end
                    9 : begin
                        emit (pdu_length);
                        part <= 10;
                    end
                    10 : begin
                        emit (2);
                        part <= 11;
                    end
                    11 : begin
                        emit ({ 5'b0, request_id_length });
                        part <= 12;
                        part_pos <= 0;
                    end
                    12 : begin
                        emit (id_shift[31:24]);
                        id_shift <= { id_shift[23:0], 8'b0 };
                        part_pos <= part_pos + 5'd1;
                        if (part_pos + 1 == request_id_length) part <= 13;
                    end
                    13 : begin
                        emit (2);
                        part <= 14;
                    end
                    14 : begin
                        emit (1);
                        part <= 15;
                    end
                    15 : begin
                        emit (error_status);
                        part <= 16;
                    end
                    16 : begin
                        emit (2);
                        part <= 17;
                    end
                    17 : begin
                        emit (1);
                        part <= 18;
                    end
                    18 : begin
                        emit (error_status == 0 ? 8'd0 : 8'd1);
                        part <= 19;
                    end
                    19 : begin
                        emit (8'h30);
                        part <= 20;
                    end
                    20 : begin
                        emit (list_length);
                        part <= 21;
                    end
                    21 : begin
                        emit (8'h30);
                        part <= 22;
                    end
                    22 : begin
                        emit (binding_length);
                        part <= 23;
                    end
                    23 : begin
                        emit (6);
                        part <= 24;
                    end
                    24 : begin
                        emit (response_oid_length);
                        part <= 25;
                        part_pos <= 0;
                    end
                    25 : begin
                        if (missing) begin
                            cursor <= { 1'b0, oid_start } + part_pos;
                            fetch (COPY_OID);
                        end
                        else begin
                            emit (mib_oid_byte (object_index, part_pos));
                            part_pos <= part_pos + 5'd1;
                            if (part_pos + 1 == response_oid_length) part <= 26;
                        end
                    end
                    26 : begin
                        emit (value_tag);
                        part <= 27;
                    end
                    27 : begin
                        emit (value_length);
                        part <= 28;
                        part_pos <= 0;
                        if (value_length == 0) state <= TX_FLUSH;
                    end
                    28 : if (echo_value) begin
                        cursor <= { 1'b0, set_value_start } + part_pos;
                        fetch (COPY_VALUE);
                    end
                    else begin
                        if (object_index == 0 && ! missing) begin
                            emit (descr_shift[127:120]);
                            descr_shift <= { descr_shift[119:0], 8'b0 };
                        end
                        else if (value_length == 5 && part_pos == 0) emit (0);
                        else begin
                            emit (value_shift[31:24]);
                            value_shift <= { value_shift[23:0], 8'b0 };
                        end
                        part_pos <= part_pos + 5'd1;
                        if (part_pos + 1 == value_length) begin
                            part_pos <= 0;
                            state <= sending_trap ? TRAP_WORD : TX_FLUSH;
                        end
                    end
                    default : state <= IDLE;
                endcase
                // 把请求或配置中的 community 字节写回应；整段完毕继续 PDU。
                COPY_COMM : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    if (part_pos + 1 == community_length) part <= 8;
                    state <= BUILD;
                end
                // 把原请求 OID 写回应，完整后继续值字段。
                COPY_OID : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    if (part_pos + 1 == response_oid_length) part <= 26;
                    state <= BUILD;
                end
                // 错误 Set 原样回显值，末字节后 TX_FLUSH。
                COPY_VALUE : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    state <= part_pos + 1 == value_length ? TX_FLUSH : BUILD;
                end
                // 构造 v2c Trap 上下文，首个绑定为 sysUpTime，目的 UDP 端口为 162。
                TRAP_INIT : begin
                    response_port <= 162;
                    version <= 1;
                    get_set <= 0;
                    missing <= 0;
                    echo_value <= 0;
                    error_status <= 0;
                    request_id <= 0;
                    request_id_length <= 1;
                    community_length <= configured_length;
                    object_index <= 1;
                    value_number <= uptime;
                    state <= VALUE_PREP;
                end
                // 选择配置 community 的 32 位字，转 TRAP_COMM1。
                TRAP_COMM0 : begin
                    case (part_pos[3:2])
                        0 : community_word <= community0;
                        1 : community_word <= community1;
                        2 : community_word <= community2;
                        3 : community_word <= community3;
                    endcase
                    state <= TRAP_COMM1;
                end
                // 选择字内字节，转 COPY_COMM 写回应。
                TRAP_COMM1 : begin
                    case (part_pos[1:0])
                        0 : byte_value <= community_word[31:24];
                        1 : byte_value <= community_word[23:16];
                        2 : byte_value <= community_word[15:8];
                        3 : byte_value <= community_word[7:0];
                    endcase
                    state <= COPY_COMM;
                end
                // 选择 snmpTrapOID 固定编码的 64 位分组，转 TRAP_BYTE。
                TRAP_WORD : begin
                    case (part_pos[4:3])
                        0 : trap_word <= 64'h3017060a2b060106;
                        1 : trap_word <= 64'h0301010401000609;
                        2 : trap_word <= 64'h2b06010603010105;
                        3 : trap_word <= { trap_event, 56'b0 };
                    endcase
                    state <= TRAP_BYTE;
                end
                // 发一个通知 OID 字节；尾字节完成转 TX_FLUSH，否则继续 TRAP_WORD。
                TRAP_BYTE : begin
                    case (part_pos[2:0])
                        0 : emit (trap_word[63:56]);
                        1 : emit (trap_word[55:48]);
                        2 : emit (trap_word[47:40]);
                        3 : emit (trap_word[39:32]);
                        4 : emit (trap_word[31:24]);
                        5 : emit (trap_word[23:16]);
                        6 : emit (trap_word[15:8]);
                        7 : emit (trap_word[7:0]);
                    endcase
                    part_pos <= part_pos + 5'd1;
                    state <= part_pos == 24 ? TX_FLUSH : TRAP_WORD;
                end
                // 等待最后 RAM 写入生效并归零发送位置，转 TX_ADDR。
                TX_FLUSH : begin
                    tx_pos <= 0;
                    state <= TX_ADDR;
                end
                // 发回应 RAM 读请求，转 TX_WAIT1。
                TX_ADDR : begin
                    out_re <= 1;
                    out_ra <= tx_pos[7:0];
                    state <= TX_WAIT1;
                end
                // 等待同步读，转 TX_WAIT2。
                TX_WAIT1 : state <= TX_WAIT2;
                // 装载字节及 valid/last，转 TX_SEND。
                TX_WAIT2 : begin
                    tx_data <= out_q;
                    tx_valid <= 1;
                    tx_last <= (tx_pos + 1 == response_length);
                    state <= TX_SEND;
                end
                // 保持输出到握手；非末字节继续取数，末字节回 IDLE，Trap 同时计数。
                TX_SEND : if (tx_ready) begin
                    tx_valid <= 0;
                    tx_last <= 0;
                    if (tx_last) begin
                        state <= IDLE;
                        if (sending_trap) traps_sent <= traps_sent + 32'd1;
                    end
                    else begin
                        tx_pos <= tx_pos + 9'd1;
                        state <= TX_ADDR;
                    end
                end
                default : state <= IDLE;
            endcase
            // 开关只控制后续事件；停用时不保留待发Trap，也不重发已提交消息。
            if (! configured || ! trap_enabled) begin
                cold_pending <= 0;
                auth_pending <= 0;
            end
            if (cfg_we && cfg_addr == 8'h90 && cfg_wdata[0] && ! configured && trap_enabled) cold_pending <= 1;
        end
    end
endmodule
