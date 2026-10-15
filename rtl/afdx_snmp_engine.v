// 所有协议寄存器只在 ce 拍更新；RAM 和外部接口位于全速外壳。
module afdx_snmp_engine (
    input wire clk, reset, ce,
    input wire  enable_in,
    input wire [31:0] now_in,
    input wire  configured_in,
    input wire  trap_enabled_in,
    input wire [4:0] configured_length_in,
    input wire [31:0] community0_in,
    input wire [31:0] community1_in,
    input wire [31:0] community2_in,
    input wire [31:0] community3_in,
    input wire [31:0] uptime_in,
    input wire  capture_pending_in,
    input wire [8:0] capture_length_in,
    input wire [15:0] capture_port_in,
    input wire  trap_grant_in,
    input wire  cold_request_in,
    input wire [7:0] req_q_in,
    input wire  send_complete_in,
    input wire  mib_complete_in,
    input wire [31:0] mib_rdata_in,
    output reg  req_re,
    output reg [7:0] req_ra,
    output reg  out_we,
    output reg [7:0] out_wa,
    output reg [7:0] out_wdata,
    output reg [15:0] response_port,
    output reg [8:0] response_length,
    output reg [31:0] bad_community,
    output reg [31:0] traps_sent,
    output reg [31:0] sample_cycle,
    output reg [17:0] mib_addr,
    output reg [31:0] mib_wdata,
    output reg  capture_consumed,
    output reg  capture_idle,
    output reg  trap_offer,
    output reg  cold_ack,
    output reg  send_request,
    output reg  mib_request,
    output reg  mib_write
);
    localparam [127:0] DESCRIPTION = "C3 AFDX endpoint";

    // 下面是主状态机的状态，按用途分组。
    // 接收请求，并从请求存储器里读一个字节：
    localparam IDLE = 0, CAPTURE = 1, START = 2, FETCH0 = 3, FETCH1 = 4, FETCH2 = 5, FETCH3 = 6;

    // 解析请求的各字段：
    localparam TAG = 7, LENGTH = 8, LONG_LENGTH = 9, DISPATCH = 10, VERSION = 11, COMMUNITY = 12;
    localparam INTEGER_VALUE = 13, DISPATCH_SUM = 45, DISPATCH_CHECK = 46;

    // 查找对象，再读取或设置它的值：
    localparam LOOK_START = 14, LOOK_COMPARE = 15, LOOK_NEXT = 16, FOUND = 17, MISSING = 18;
    localparam MIB_ADDRESS = 44;
    localparam MIB_REQUEST = 19, MIB_WAIT = 20, SET_VALUE = 34, SET_CHECK = 35, SET_WRITE = 36, SET_ERROR = 37;

    // 计算各层长度并构造回应：
    localparam VALUE_PREP = 21, LEN1 = 22, LEN2 = 23, LEN3 = 24, LEN4 = 25, BUILD = 26;
    localparam COPY_COMM = 27, COPY_OID = 28, COPY_VALUE = 38;

    // 发送回应：
    localparam TX_FLUSH = 29, TX_ADDR = 30, TX_WAIT1 = 31, TX_WAIT2 = 32, TX_SEND = 33;

    // 构造事件通知：
    localparam TRAP_INIT = 39, TRAP_COMM0 = 40, TRAP_COMM1 = 41, TRAP_WORD = 42, TRAP_BYTE = 43;

    // 管理请求和事件通知使用的 UDP 端口。
    localparam SNMP_PORT = 161, TRAP_PORT = 162;

    // 报文按“类型、长度、内容”逐层编码，下面是用到的类型字节。
    // 基本类型：整数、字节串、空值、对象标识符、序列。
    localparam TAG_INTEGER = 8'h02, TAG_OCTET_STRING = 8'h04, TAG_NULL = 8'h05, TAG_OID = 8'h06;
    localparam TAG_SEQUENCE = 8'h30;

    // 操作类型：查询、查询下一个、回应、设置、事件通知。
    localparam PDU_GET = 8'ha0, PDU_GET_NEXT = 8'ha1, PDU_RESPONSE = 8'ha2, PDU_SET = 8'ha3, PDU_TRAP = 8'ha7;

    // 数值类型：计数器、非负整数、运行时间。
    localparam TYPE_COUNTER32 = 8'h41, TYPE_GAUGE32 = 8'h42, TYPE_TIMETICKS = 8'h43;

    // v2c 表示“没有这个对象”和“已到末尾”的两种特殊值。
    localparam EXC_NO_SUCH_OBJECT = 8'h80, EXC_END_OF_MIB = 8'h82;

    // 长度字节为这两个值时，后面再跟 1 或 2 个字节给出实际长度。
    localparam LENGTH_1_BYTE = 8'h81, LENGTH_2_BYTES = 8'h82;

    // 回应里的错误码。v1 用 2、3；v2c 用 7、8、10、17。
    localparam ERR_NONE = 0, ERR_NO_SUCH_NAME = 2, ERR_BAD_VALUE = 3, ERR_WRONG_TYPE = 7;
    localparam ERR_WRONG_LENGTH = 8, ERR_WRONG_VALUE = 10, ERR_NOT_WRITABLE = 17;

    // 事件通知的编号：冷启动和认证失败。
    localparam TRAP_COLD_START = 8'd1, TRAP_AUTH_FAILURE = 8'd5;

    // 口令和对象标识符最长 16 字节；复位后的口令是 6 个字符的 public。
    localparam MAX_COMMUNITY_LENGTH = 16, MAX_OID_LENGTH = 16, DEFAULT_COMMUNITY_LENGTH = 6;
    localparam DEFAULT_COMMUNITY0 = 32'h7075626c, DEFAULT_COMMUNITY1 = 32'h69630000;

    // 运行时间每 10 ms 加一，即每 1250000 拍；计到 UPTIME_TICK_LAST 后归零。
    localparam UPTIME_TICK_LAST = 1249999;

    // 本模块的配置寄存器地址（低 8 位）。
    localparam REG_ENABLE = 8'h90, REG_TX_VL = 8'h91, REG_COMMUNITY_LENGTH = 8'h92;
    localparam REG_COMMUNITY0 = 8'h93, REG_COMMUNITY1 = 8'h94, REG_COMMUNITY2 = 8'h95, REG_COMMUNITY3 = 8'h96;
    localparam REG_TRAP_ENABLE = 8'h9b;

    // 各对象在共享配置总线上的地址；四个 COUNT 是一组计数器的起始地址。
    localparam ADDR_DESCR = 18'ha0, ADDR_UPTIME = 18'h98, ADDR_RTC_SECONDS = 18'h84, ADDR_RTC_SYNC = 18'h88;
    localparam ADDR_REQUESTS = 18'h99, ADDR_BAD_COMMUNITY = 18'h9a, ADDR_TRAPS_SENT = 18'h9c;
    localparam ADDR_TX_COUNT = 18'h40, ADDR_A_COUNT = 18'h48, ADDR_B_COUNT = 18'h50, ADDR_SHARED_COUNT = 18'h58;

    // field 的取值：正在解析请求的第几个字段。
    localparam FIELD_MESSAGE = 0, FIELD_VERSION = 1, FIELD_COMMUNITY = 2, FIELD_PDU = 3, FIELD_REQUEST_ID = 4;
    localparam FIELD_ERROR_STATUS = 5, FIELD_ERROR_INDEX = 6, FIELD_BINDING_LIST = 7, FIELD_BINDING = 8;
    localparam FIELD_OID = 9, FIELD_VALUE = 10;

    // part 的取值：正在写回应的第几个字段，每个字段依次是类型、长度、内容。
    localparam B_MESSAGE_TAG = 0, B_MESSAGE_LENGTH = 1, B_VERSION_TAG = 2, B_VERSION_LENGTH = 3, B_VERSION = 4;
    localparam B_COMMUNITY_TAG = 5, B_COMMUNITY_LENGTH = 6, B_COMMUNITY = 7, B_PDU_TAG = 8, B_PDU_LENGTH = 9;
    localparam B_ID_TAG = 10, B_ID_LENGTH = 11, B_ID = 12, B_STATUS_TAG = 13, B_STATUS_LENGTH = 14, B_STATUS = 15;
    localparam B_INDEX_TAG = 16, B_INDEX_LENGTH = 17, B_INDEX = 18, B_LIST_TAG = 19, B_LIST_LENGTH = 20;
    localparam B_BINDING_TAG = 21, B_BINDING_LENGTH = 22, B_OID_TAG = 23, B_OID_LENGTH = 24, B_OID = 25;
    localparam B_VALUE_TAG = 26, B_VALUE_LENGTH = 27, B_VALUE = 28;

    // 对象标识符开头的 1.3 合并编码为 43；私有分支的企业数字为 424242。
    // 企业数字使用每字节七个有效位编码为 0x99、0xf2、0x32。
    localparam OID_FIRST_ARC = 43, OID_FIRST_BYTE = 8'h2b, OID_ENTERPRISE_ARC = 424242;
    localparam OID_ENTERPRISE_BYTE0 = 8'h99, OID_ENTERPRISE_BYTE1 = 8'hf2, OID_ENTERPRISE_BYTE2 = 8'h32;
    localparam SYSTEM_OBJECT_COUNT = 2, LAST_OBJECT_INDEX = 35;
    localparam SYSTEM_OID_LAST_ARC = 7, PRIVATE_OID_LAST_ARC = 8;
    localparam SYSTEM_OID_BYTES = 8, PRIVATE_OID_BYTES = 11;

    // 请求与回应各有 256 字节存储；请求写到下标 255 后不能再增加字节。
    localparam PACKET_BUFFER_BYTES = 256, REQUEST_LAST_POS = 255;
    localparam ADDR_USER_ID = 2;

    // snmpTrapOID.0 变量绑定的固定编码，最后一个字节另填事件编号。
    localparam TRAP_OID_WORD0 = 64'h3017060a2b060106, TRAP_OID_WORD1 = 64'h0301010401000609;
    localparam TRAP_OID_WORD2 = 64'h2b06010603010105, TRAP_OID_LAST_POS = 24;

    localparam FETCH_WAIT_A = 120, FETCH_WAIT_B = 121, FETCH_WAIT_C = 122;
    reg  enable;
    reg [31:0] now;
    reg  configured;
    reg  trap_enabled;
    reg [4:0] configured_length;
    reg [31:0] community0;
    reg [31:0] community1;
    reg [31:0] community2;
    reg [31:0] community3;
    reg [31:0] uptime;
    reg  capture_pending;
    reg [8:0] capture_length;
    reg [15:0] capture_port;
    reg  trap_grant;
    reg  cold_request;
    reg [7:0] req_q;
    reg  send_complete;
    reg  mib_complete;
    reg [31:0] mib_rdata;
    // cold_pending/auth_pending 保存尚未发送的启动和认证失败通知。
    // 通知发送完成后，traps_sent 才增加。
    reg  cold_pending, auth_pending, sending_trap;

    reg [7:0] trap_event;

    // 固定通知内容分两级选择，先选 64 位字，再选字内字节。
    reg [63:0] trap_word;
    reg  get_set, echo_value, set_negative;
    reg [7:0] set_value_start, set_value_tag, set_value_length;
    reg [31:0] set_number;



    // community 保存最多 16 字节的团体名，按高字节在前发送。


    reg [6:0] state, return_state;


    // cursor 记录当前读取位置，各层结束位置用来检查字段是否越界。
    // 本实现只接受一个完整的变量绑定。
    reg [8:0] request_length, cursor, outer_end, pdu_end, list_end, binding_end;




    reg [7:0] byte_value, tag_value;
    reg [15:0] field_length;
    reg [1:0] length_left;
    reg [3:0] field;
    reg [15:0] field_end;
    reg  field_bounds_ok;
    reg [FIELD_VALUE:0] field_accept;
    reg  value_chain_ok;
    reg [4:0] value_pos, community_length, oid_length;
    reg [7:0] community_start, oid_start;
    reg [31:0] community_word;
    reg [7:0] community_expected;
    reg  community_bad;
    reg  version;
    reg  get_next;
    reg [2:0] request_id_length;
    reg [31:0] request_id, id_shift;

    // candidate/object_index 选择待查询的寄存器对象。
    // 对象标识符（Object Identifier，OID）按数字逐段比较，不按编码后的字节大小比较。
    reg [5:0] candidate, object_index;
    reg [4:0] oid_pos;
    reg [3:0] arc_index;
    reg [31:0] oid_acc, expected_arc;
    wire [31:0] decoded_arc = { oid_acc[24:0], byte_value[6:0] };
    wire [31:0] fetched_arc = { oid_acc[24:0], req_q[6:0] };
    reg [3:0] arc_less_byte, arc_equal_byte;
    reg  arc_less, arc_greater, oid_last_byte, oid_last_arc;
    (* preserve = 1 *) reg  description_value;
    reg [87:0] oid_shift;
    reg  missing;
    reg [7:0] error_status, value_tag, value_length, response_oid_length;
    reg [31:0] value_number, value_shift;
    reg [127:0] descr_shift;
    reg [7:0] binding_length, list_length, pdu_length, message_length;

    // output_count 记录回应写到哪里，tx_pos 记录发到哪里。
    // part/part_pos 记录当前构造哪个字段及字段内的位置。
    reg [8:0] output_count;
    reg [4:0] part, part_pos;

    // 来自全速段的寄存器和 RAM 输出先采样，再进入协议逻辑。
    always @(posedge clk) begin
        if (reset) begin
            enable <= 0;
            now <= 0;
            configured <= 0;
            trap_enabled <= 0;
            configured_length <= 0;
            community0 <= 0;
            community1 <= 0;
            community2 <= 0;
            community3 <= 0;
            uptime <= 0;
            capture_pending <= 0;
            capture_length <= 0;
            capture_port <= 0;
            trap_grant <= 0;
            cold_request <= 0;
            req_q <= 0;
            send_complete <= 0;
            mib_complete <= 0;
            mib_rdata <= 0;
        end
        else if (ce) begin
            enable <= enable_in;
            now <= now_in;
            configured <= configured_in;
            trap_enabled <= trap_enabled_in;
            configured_length <= configured_length_in;
            community0 <= community0_in;
            community1 <= community1_in;
            community2 <= community2_in;
            community3 <= community3_in;
            uptime <= uptime_in;
            capture_pending <= capture_pending_in;
            capture_length <= capture_length_in;
            capture_port <= capture_port_in;
            trap_grant <= trap_grant_in;
            cold_request <= cold_request_in;
            req_q <= req_q_in;
            send_complete <= send_complete_in;
            mib_complete <= mib_complete_in;
            mib_rdata <= mib_rdata_in;
        end
    end
    // 对象按编号的数字顺序排列，先是两个系统对象，再是 34 个私有对象。
    // 系统对象的标识符是 1.3.6.1.2.1.1.x.0，私有对象是 1.3.6.1.4.1.424242.3.x.0。
    // 开头的 1.3 按编码规则合并成一个数 43（即一个字节 0x2b）。
    // mib_arc 给出标识符的第几个数字，mib_oid_byte 给出编码后的第几个字节。
    function [31:0] mib_arc;
        input [5:0] item;
        input [3:0] position;
        begin
            mib_arc = 0;
            case (position)
                0 : mib_arc = OID_FIRST_ARC;
                1 : mib_arc = 6;
                2 : mib_arc = 1;
                3 : mib_arc = item < SYSTEM_OBJECT_COUNT ? 2 : 4;
                4 : mib_arc = 1;
                5 : mib_arc = item < SYSTEM_OBJECT_COUNT ? 1 : OID_ENTERPRISE_ARC;
                6 : mib_arc = item < SYSTEM_OBJECT_COUNT ? (item == 0 ? 1 : 3) : 3;
                7 : mib_arc = item < SYSTEM_OBJECT_COUNT ? 0 : { 26'b0, item } - 32'd1;
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
                0 : mib_oid_byte = OID_FIRST_BYTE;
                1 : mib_oid_byte = 6;
                2 : mib_oid_byte = 1;
                3 : mib_oid_byte = item < SYSTEM_OBJECT_COUNT ? 2 : 4;
                4 : mib_oid_byte = 1;
                5 : mib_oid_byte = item < SYSTEM_OBJECT_COUNT ? 1 : OID_ENTERPRISE_BYTE0;
                6 : mib_oid_byte = item < SYSTEM_OBJECT_COUNT ? (item == 0 ? 1 : 3) : OID_ENTERPRISE_BYTE1;
                7 : mib_oid_byte = item < SYSTEM_OBJECT_COUNT ? 0 : OID_ENTERPRISE_BYTE2;
                8 : mib_oid_byte = 3;
                9 : mib_oid_byte = { 2'b0, item } - 8'd1;
                default : mib_oid_byte = 0;
            endcase
        end
    endfunction

    // 编码后的 OID 预先装入移位寄存器，构造回应时只取首字节。
    // 对象选择、字节位置选择和回应字段选择因此不再落在同一拍。
    genvar oid_byte;
    generate
        for (oid_byte = 0; oid_byte < PRIVATE_OID_BYTES; oid_byte = oid_byte + 1) begin : oid_encoding
            wire [7:0] next_byte;
            if (oid_byte == PRIVATE_OID_BYTES - 1) begin : tail
                assign next_byte = 0;
            end
            else begin : body
                assign next_byte = oid_shift[79 - oid_byte * 8 -: 8];
            end
            always @(posedge clk) begin
        if (reset) oid_shift[87 - oid_byte * 8 -: 8] <= 0;
        else if (ce) if (state == LEN4)
                    oid_shift[87 - oid_byte * 8 -: 8] <= mib_oid_byte(object_index, oid_byte);
                else if (state == BUILD && part == B_OID && !missing) begin
                    oid_shift[87 - oid_byte * 8 -: 8] <= next_byte;
                end
    end
        end
    endgenerate

    // 私有对象对应配置或统计地址，只有索引 3 的 user_id 允许设置。
    // 对象 0–5 依次是描述、运行时间、版本、user_id、时钟秒和同步次数。
    // 对象 6–12 是发送计数，13–20 和 21–28 是 A、B 网接收计数，29–32 是两网合计的计数，
    // 对象 33–35 是本模块自己的三个计数。
    function [17:0] mib_address;
        input [5:0] item;
        begin
            case (item)
                0 : mib_address = ADDR_DESCR;
                1 : mib_address = ADDR_UPTIME;
                2 : mib_address = 0;
                3 : mib_address = ADDR_USER_ID;
                4 : mib_address = ADDR_RTC_SECONDS;
                5 : mib_address = ADDR_RTC_SYNC;
                33 : mib_address = ADDR_REQUESTS;
                34 : mib_address = ADDR_BAD_COMMUNITY;
                35 : mib_address = ADDR_TRAPS_SENT;
                default : begin
                    if (item <= 12) mib_address = ADDR_TX_COUNT + item - 6;
                    else if (item <= 20) mib_address = ADDR_A_COUNT + item - 13;
                    else if (item <= 28) mib_address = ADDR_B_COUNT + item - 21;
                    else mib_address = ADDR_SHARED_COUNT + item - 29;
                end
            endcase
        end
    endfunction

    // 读取请求字节前保存返回状态，emit 每次只登记一个回应字节。
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
            capture_consumed <= 0;
            capture_idle <= 0;
            trap_offer <= 0;
            cold_ack <= 0;
            send_request <= 0;
            mib_request <= 0;
            mib_write <= 0;
            state <= IDLE;
            return_state <= IDLE;
            arc_less_byte <= 0;
            arc_equal_byte <= 0;
            arc_less <= 0;
            arc_greater <= 0;
            oid_last_byte <= 0;
            oid_last_arc <= 0;
            description_value <= 0;

            req_re <= 0;
            out_we <= 0;

            req_ra <= 0;

            out_wa <= 0;

            out_wdata <= 0;

            mib_addr <= 0;
            mib_wdata <= 0;

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

            request_length <= 0;

            cursor <= 0;
            field <= FIELD_MESSAGE;
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
            error_status <= ERR_NONE;
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

            part <= B_MESSAGE_TAG;
            part_pos <= 0;
        end
        else if (ce) begin
            capture_idle <= state == IDLE;
            trap_offer <= state == IDLE && trap_enabled && (cold_pending || auth_pending);
            if (!capture_pending) capture_consumed <= 0;

            req_re <= 0;
            out_we <= 0;

            if ( ! configured || ! enable) begin
                state <= IDLE;

            end
            // 模块依次解析请求、访问寄存器、构造回应，再逐字节发送。
            // SNMP 报文的每个字段都按类型（TAG）、长度（LENGTH）、值的顺序编码。
            else case (state)

                // ======== 第一部分：接收请求，并按位置读出请求字节 ========
                // 完整请求和通知授权均由全速捕获段保持到接收确认。
                IDLE : if (capture_pending) begin
                    capture_consumed <= 1;
                    sending_trap <= 0;
                    request_length <= capture_length;
                    response_port <= capture_port;
                    state <= START;
                end
                else if (trap_grant && trap_enabled && (cold_pending || auth_pending)) begin
                    sending_trap <= 1;
                    trap_event <= cold_pending ? TRAP_COLD_START : TRAP_AUTH_FAILURE;
                    if (cold_pending) cold_pending <= 0;
                    else auth_pending <= 0;
                    state <= TRAP_INIT;
                end

                // START：复位本次解析位置，然后读取 TAG。
                START : begin
                    cursor <= 0;
                    field <= FIELD_MESSAGE;
                    community_bad <= 0;
                    request_id <= 0;
                    missing <= 0;
                    echo_value <= 0;
                    error_status <= ERR_NONE;
                    fetch (TAG);
                end

                // FETCH0：检查读取范围并发出读请求，然后转 FETCH1。
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

                // FETCH1：等待同步读取并选择口令字节，然后转 FETCH2。
                FETCH1 : begin
                    case (value_pos[1:0])
                        0 : community_expected <= community_word[31:24];
                        1 : community_expected <= community_word[23:16];
                        2 : community_expected <= community_word[15:8];
                        3 : community_expected <= community_word[7:0];
                    endcase
                    state <= FETCH_WAIT_A;
                end

                // 利用原有读取等待拍，先比较四个字节，再合并比较结果。
                FETCH_WAIT_A : state <= FETCH_WAIT_B;
                FETCH_WAIT_B : state <= FETCH_WAIT_C;
                FETCH_WAIT_C : state <= FETCH2;

                FETCH2 : begin
                    byte_value <= req_q;
                    arc_less_byte[3] <= fetched_arc[31:24] < expected_arc[31:24];
                    arc_less_byte[2] <= fetched_arc[23:16] < expected_arc[23:16];
                    arc_less_byte[1] <= fetched_arc[15:8] < expected_arc[15:8];
                    arc_less_byte[0] <= fetched_arc[7:0] < expected_arc[7:0];
                    arc_equal_byte[3] <= fetched_arc[31:24] == expected_arc[31:24];
                    arc_equal_byte[2] <= fetched_arc[23:16] == expected_arc[23:16];
                    arc_equal_byte[1] <= fetched_arc[15:8] == expected_arc[15:8];
                    arc_equal_byte[0] <= fetched_arc[7:0] == expected_arc[7:0];
                    state <= FETCH3;
                end

                // FETCH3：返回调用读取操作时保存的状态。
                FETCH3 : begin
                    arc_less <= arc_less_byte[3] || (arc_equal_byte[3] && arc_less_byte[2])
                        || (&arc_equal_byte[3:2] && arc_less_byte[1])
                        || (&arc_equal_byte[3:1] && arc_less_byte[0]);
                    arc_greater <= (!arc_less_byte[3] && !arc_equal_byte[3])
                        || (arc_equal_byte[3] && !arc_less_byte[2] && !arc_equal_byte[2])
                        || (&arc_equal_byte[3:2] && !arc_less_byte[1] && !arc_equal_byte[1])
                        || (&arc_equal_byte[3:1] && !arc_less_byte[0] && !arc_equal_byte[0]);
                    oid_last_byte <= {1'b0, oid_pos} + 6'd1 == {1'b0, oid_length};
                    oid_last_arc <= arc_index == (candidate < SYSTEM_OBJECT_COUNT
                        ? SYSTEM_OID_LAST_ARC : PRIVATE_OID_LAST_ARC);
                    state <= return_state;
                end

                // ======== 第二部分：逐个字段解析请求 ========
                // TAG：保存字段类型，然后读取 LENGTH。
                TAG : begin
                    tag_value <= byte_value;
                    cursor <= cursor + 9'd1;
                    fetch (LENGTH);
                end

                // LENGTH：短长度转 DISPATCH，长长度转 LONG_LENGTH，非法长度转 IDLE。
                LENGTH : begin
                    cursor <= cursor + 9'd1;
                    if ( ! byte_value[7]) begin
                        field_length <= { 9'b0, byte_value[6:0] };
                        state <= DISPATCH_SUM;
                    end
                    else if (byte_value == LENGTH_1_BYTE || byte_value == LENGTH_2_BYTES) begin
                        length_left <= byte_value[1:0];
                        field_length <= 0;
                        fetch (LONG_LENGTH);
                    end
                    else state <= IDLE;
                end

                // LONG_LENGTH：逐字节拼出长度，读够后转 DISPATCH。
                LONG_LENGTH : begin
                    field_length <= { field_length[7:0], byte_value };
                    cursor <= cursor + 9'd1;
                    length_left <= length_left - 2'd1;
                    if (length_left == 1) state <= DISPATCH_SUM;
                    else fetch (LONG_LENGTH);
                end

                // 字段结束位置、格式条件和边界分拍准备，解析拍只消费局部标记。
                DISPATCH_SUM : begin
                    field_end <= cursor + field_length;
                    field_accept[FIELD_MESSAGE] <= tag_value == TAG_SEQUENCE;
                    field_accept[FIELD_VERSION] <= tag_value == TAG_INTEGER && field_length == 1;
                    field_accept[FIELD_COMMUNITY] <= tag_value == TAG_OCTET_STRING
                        && field_length >= 1 && field_length <= MAX_COMMUNITY_LENGTH;
                    field_accept[FIELD_PDU] <= tag_value == PDU_GET || tag_value == PDU_GET_NEXT
                        || tag_value == PDU_SET;
                    field_accept[FIELD_REQUEST_ID] <= tag_value == TAG_INTEGER
                        && field_length >= 1 && field_length <= 4;
                    field_accept[FIELD_ERROR_STATUS] <= 0;
                    field_accept[FIELD_ERROR_INDEX] <= 0;
                    field_accept[FIELD_BINDING_LIST] <= 0;
                    field_accept[FIELD_BINDING] <= 0;
                    field_accept[FIELD_OID] <= tag_value == TAG_OID
                        && field_length >= 1 && field_length <= MAX_OID_LENGTH;
                    field_accept[FIELD_VALUE] <= (get_set && field_length <= 16)
                        || (tag_value == TAG_NULL && field_length == 0);
                    state <= DISPATCH_CHECK;
                end

                DISPATCH_CHECK : begin
                    field_bounds_ok <= field_length <= PACKET_BUFFER_BYTES && field_end <= request_length;
                    value_chain_ok <= field_end == binding_end && binding_end == list_end
                        && list_end == pdu_end && pdu_end == outer_end && outer_end == request_length;
                    state <= DISPATCH;
                end

                // DISPATCH：检查字段边界并转到对应解析状态，格式错误时转 IDLE。
                DISPATCH : begin
                    value_pos <= 0;
                    if (!field_bounds_ok) state <= IDLE;
                    else case (field) // synthesis parallel_case

                        FIELD_MESSAGE : if (field_accept[FIELD_MESSAGE]) begin
                            outer_end <= field_end;
                            field <= FIELD_VERSION;
                            fetch (TAG);
                        end
                        else state <= IDLE;

                        FIELD_VERSION : if (field_accept[FIELD_VERSION]) fetch (VERSION);
                        else state <= IDLE;

                        FIELD_COMMUNITY : if (field_accept[FIELD_COMMUNITY]) begin
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

                        FIELD_PDU : if (field_accept[FIELD_PDU]) begin
                            get_next <= (tag_value == PDU_GET_NEXT);
                            get_set <= (tag_value == PDU_SET);
                            pdu_end <= field_end;
                            field <= FIELD_REQUEST_ID;
                            fetch (TAG);
                        end
                        else state <= IDLE;

                        FIELD_REQUEST_ID, FIELD_ERROR_STATUS, FIELD_ERROR_INDEX :
                            if (field_accept[FIELD_REQUEST_ID]) begin
                            if (field == FIELD_REQUEST_ID) request_id_length <= field_length[2:0];
                            fetch (INTEGER_VALUE);
                        end
                        else state <= IDLE;

                        FIELD_BINDING_LIST : if (field_accept[FIELD_MESSAGE]) begin
                            list_end <= field_end;
                            field <= FIELD_BINDING;
                            fetch (TAG);
                        end
                        else state <= IDLE;

                        FIELD_BINDING : if (field_accept[FIELD_MESSAGE]) begin
                            binding_end <= field_end;
                            field <= FIELD_OID;
                            fetch (TAG);
                        end
                        else state <= IDLE;

                        FIELD_OID : if (field_accept[FIELD_OID]) begin
                            oid_start <= cursor[7:0];
                            oid_length <= field_length[4:0];
                            cursor <= field_end;
                            field <= FIELD_VALUE;
                            fetch (TAG);
                        end
                        else state <= IDLE;

                        FIELD_VALUE : if (field_accept[FIELD_VALUE] && value_chain_ok) begin
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

                // VERSION：检查协议版本，通过后读口令，否则转 IDLE。
                VERSION : begin
                    if (byte_value <= 1) begin
                        version <= byte_value[0];
                        cursor <= cursor + 9'd1;
                        field <= FIELD_COMMUNITY;
                        fetch (TAG);
                    end
                    else state <= IDLE;
                end

                // COMMUNITY：逐字节核对口令，通过后读下一字段，否则转 IDLE。
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
                            field <= FIELD_PDU;
                            fetch (TAG);
                        end
                    end
                    else fetch (COMMUNITY);
                end

                // INTEGER_VALUE：读完请求中的整数字段后，继续读取 TAG。
                INTEGER_VALUE : begin
                    if (field == FIELD_REQUEST_ID) request_id <= { request_id[23:0], byte_value };
                    cursor <= cursor + 9'd1;
                    value_pos <= value_pos + 5'd1;
                    if (value_pos + 1 == field_length) begin
                        field <= field + 4'd1;
                        fetch (TAG);
                    end
                    else fetch (INTEGER_VALUE);
                end

                // ======== 第三部分：查找对象，读取或设置它的值 ========
                // LOOK_START：从对象编号的第一个数字开始，然后转 LOOK_COMPARE。
                LOOK_START : begin
                    cursor <= { 1'b0, oid_start };
                    oid_pos <= 0;
                    arc_index <= 0;
                    oid_acc <= 0;
                    fetch (LOOK_COMPARE);
                end

                // LOOK_COMPARE：逐个数字比较对象编号，匹配转 FOUND，否则转 LOOK_NEXT。
                LOOK_COMPARE : begin
                    if (byte_value[7]) begin
                        if (oid_last_byte) state <= IDLE;
                        else begin
                            oid_acc <= decoded_arc;
                            cursor <= cursor + 9'd1;
                            oid_pos <= oid_pos + 5'd1;
                            fetch (LOOK_COMPARE);
                        end
                    end
                    else if (arc_less) state <= get_next ? FOUND : LOOK_NEXT;
                    else if (arc_greater) state <= LOOK_NEXT;
                    else if (oid_last_byte) begin
                        if (oid_last_arc)
                            state <= get_next ? LOOK_NEXT : FOUND;
                        else state <= get_next ? FOUND : LOOK_NEXT;
                    end
                    else if (oid_last_arc)
                        state <= LOOK_NEXT;
                    else begin
                        oid_acc <= 0;
                        arc_index <= arc_index + 4'd1;
                        oid_pos <= oid_pos + 5'd1;
                        cursor <= cursor + 9'd1;
                        fetch (LOOK_COMPARE);
                    end
                end

                // LOOK_NEXT：换下一个对象重试，全部试完后转 MISSING。
                LOOK_NEXT : if (candidate == LAST_OBJECT_INDEX) state <= MISSING;
                else begin
                    candidate <= candidate + 6'd1;
                    state <= LOOK_START;
                end

                // FOUND：查询转 MIB_REQUEST；设置先读入待写值，非法写转 SET_ERROR。
                FOUND : begin
                    object_index <= candidate;
                    mib_addr <= mib_address (candidate);
                    missing <= 0;
                    if ( ! get_set) begin

                        state <= MIB_ADDRESS;
                    end
                    else if (candidate != 3) begin
                        error_status <= version ? ERR_NOT_WRITABLE : ERR_NO_SUCH_NAME;
                        state <= SET_ERROR;
                    end
                    else if (set_value_tag != TYPE_GAUGE32) begin
                        error_status <= version ? ERR_WRONG_TYPE : ERR_BAD_VALUE;
                        state <= SET_ERROR;
                    end
                    else if (set_value_length < 1 || set_value_length > 5) begin
                        error_status <= version ? ERR_WRONG_LENGTH : ERR_BAD_VALUE;
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

                // MISSING：生成对象不存在或不可写的结果，然后准备回应长度。
                MISSING : begin
                    if (get_set) begin
                        error_status <= version ? ERR_NOT_WRITABLE : ERR_NO_SUCH_NAME;
                        state <= SET_ERROR;
                    end
                    else begin
                        missing <= 1;
                        error_status <= version ? ERR_NONE : ERR_NO_SUCH_NAME;
                        value_tag <= version ? (get_next ? EXC_END_OF_MIB : EXC_NO_SUCH_OBJECT) : TAG_NULL;
                        value_length <= 0;
                        response_oid_length <= { 3'b0, oid_length };
                        state <= LEN1;
                    end
                end

                // SET_VALUE：拼出待写整数，读完后转 SET_CHECK。
                SET_VALUE : begin
                    set_number <= { set_number[23:0], byte_value };
                    if (value_pos == 0) set_negative <= byte_value[7];
                    value_pos <= value_pos + 5'd1;
                    cursor <= cursor + 9'd1;
                    if (value_pos + 1 == set_value_length) state <= SET_CHECK;
                    else fetch (SET_VALUE);
                end

                // SET_CHECK：检查数值范围，通过则写总线，否则转 SET_ERROR。
                SET_CHECK : begin
                    if (set_negative || | set_number[31:16]) begin
                        error_status <= version ? ERR_WRONG_VALUE : ERR_BAD_VALUE;
                        state <= SET_ERROR;
                    end
                    else begin
                        mib_wdata <= set_number;
                        mib_write <= 1;
                        mib_request <= ~mib_request;
                        state <= SET_WRITE;
                    end
                end

                // SET_WRITE：等写握手完成，再读回实际值。
                SET_WRITE : if (mib_complete == mib_request) begin
                    state <= MIB_ADDRESS;
                end

                // SET_ERROR：保留请求中的编号和值用于错误回应，然后转 LEN1。
                SET_ERROR : begin
                    missing <= 1;
                    echo_value <= 1;
                    value_tag <= set_value_tag;
                    value_length <= set_value_length;
                    response_oid_length <= { 3'b0, oid_length };
                    state <= LEN1;
                end

                // 先稳定地址一拍，让各个计数器分组在本地保存预译码结果。
                MIB_ADDRESS : begin
                    mib_write <= 0;
                    mib_request <= ~mib_request;
                    sample_cycle <= now;
                    state <= MIB_WAIT;
                end
                MIB_WAIT : if (mib_complete == mib_request) begin
                    value_number <= mib_rdata;
                    state <= VALUE_PREP;
                end

                // ======== 第四部分：计算各层长度，构造回应或事件通知 ========
                // VALUE_PREP：确定回应值的类型和长度，然后转 LEN1。
                VALUE_PREP : begin
                    response_oid_length <= object_index < SYSTEM_OBJECT_COUNT ? SYSTEM_OID_BYTES : PRIVATE_OID_BYTES;
                    if (object_index == 0) begin
                        value_tag <= 4;
                        value_length <= 16;
                        value_shift <= 0;
                    end
                    else begin
                        value_tag <= object_index == 1 ? TYPE_TIMETICKS : (object_index >= SYSTEM_OBJECT_COUNT
                            && object_index <= 4 ? TYPE_GAUGE32 : TYPE_COUNTER32);
                        if (value_number[31]) begin
                            value_length <= 5;
                            value_shift <= value_number;
                        end
                        else if ( | value_number[30:23]) begin
                            value_length <= 4;
                            value_shift <= value_number;
                        end
                        else if ( | value_number[22:15]) begin
                            value_length <= 3;
                            value_shift <= { value_number[23:0], 8'b0 };
                        end
                        else if ( | value_number[14:7]) begin
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

                // LEN1：计算一个变量的编码长度，然后转 LEN2。
                LEN1 : begin
                    binding_length <= response_oid_length + value_length + 8'd4;
                    state <= LEN2;
                end

                // LEN2：计算变量列表的编码长度，然后转 LEN3。
                LEN2 : begin
                    list_length <= binding_length + (sending_trap ? 8'd27 : 8'd2);
                    state <= LEN3;
                end

                // LEN3：计算协议数据单元的长度，然后转 LEN4。
                LEN3 : begin
                    pdu_length <= list_length + { 5'b0, request_id_length } + 8'd10;
                    state <= LEN4;
                end

                // LEN4：计算整条消息的长度，然后转 BUILD。
                LEN4 : begin
                    description_value <= object_index == 0 && !missing;
                    message_length <= pdu_length + { 3'b0, community_length } + 8'd7;
                    response_length <= pdu_length + { 4'b0, community_length } + 9'd9;
                    id_shift <= request_id << ((4 - request_id_length) * 8);
                    descr_shift <= DESCRIPTION;
                    part <= B_MESSAGE_TAG;
                    part_pos <= 0;
                    output_count <= 0;
                    state <= BUILD;
                end

                // BUILD：依次写入回应的各字段，全部完成后进入发送过程。
                BUILD : case (part)

                    B_MESSAGE_TAG : begin
                        emit (TAG_SEQUENCE);
                        part <= B_MESSAGE_LENGTH;
                    end

                    B_MESSAGE_LENGTH : begin
                        emit (message_length);
                        part <= B_VERSION_TAG;
                    end

                    B_VERSION_TAG : begin
                        emit (TAG_INTEGER);
                        part <= B_VERSION_LENGTH;
                    end

                    B_VERSION_LENGTH : begin
                        emit (1);
                        part <= B_VERSION;
                    end

                    B_VERSION : begin
                        emit ({ 7'b0, version });
                        part <= B_COMMUNITY_TAG;
                    end

                    B_COMMUNITY_TAG : begin
                        emit (TAG_OCTET_STRING);
                        part <= B_COMMUNITY_LENGTH;
                    end

                    B_COMMUNITY_LENGTH : begin
                        emit ({ 3'b0, community_length });
                        part <= B_COMMUNITY;
                        part_pos <= 0;
                    end

                    B_COMMUNITY : if (sending_trap) state <= TRAP_COMM0;
                    else begin
                        cursor <= { 1'b0, community_start } + part_pos;
                        fetch (COPY_COMM);
                    end

                    B_PDU_TAG : begin
                        emit (sending_trap ? PDU_TRAP : PDU_RESPONSE);
                        part <= B_PDU_LENGTH;
                    end

                    B_PDU_LENGTH : begin
                        emit (pdu_length);
                        part <= B_ID_TAG;
                    end

                    B_ID_TAG : begin
                        emit (TAG_INTEGER);
                        part <= B_ID_LENGTH;
                    end

                    B_ID_LENGTH : begin
                        emit ({ 5'b0, request_id_length });
                        part <= B_ID;
                        part_pos <= 0;
                    end

                    B_ID : begin
                        emit (id_shift[31:24]);
                        id_shift <= { id_shift[23:0], 8'b0 };
                        part_pos <= part_pos + 5'd1;
                        if (part_pos + 1 == request_id_length) part <= B_STATUS_TAG;
                    end

                    B_STATUS_TAG : begin
                        emit (TAG_INTEGER);
                        part <= B_STATUS_LENGTH;
                    end

                    B_STATUS_LENGTH : begin
                        emit (1);
                        part <= B_STATUS;
                    end

                    B_STATUS : begin
                        emit (error_status);
                        part <= B_INDEX_TAG;
                    end

                    B_INDEX_TAG : begin
                        emit (TAG_INTEGER);
                        part <= B_INDEX_LENGTH;
                    end

                    B_INDEX_LENGTH : begin
                        emit (1);
                        part <= B_INDEX;
                    end

                    B_INDEX : begin
                        emit (error_status == ERR_NONE ? 8'd0 : 8'd1);
                        part <= B_LIST_TAG;
                    end

                    B_LIST_TAG : begin
                        emit (TAG_SEQUENCE);
                        part <= B_LIST_LENGTH;
                    end

                    B_LIST_LENGTH : begin
                        emit (list_length);
                        part <= B_BINDING_TAG;
                    end

                    B_BINDING_TAG : begin
                        emit (TAG_SEQUENCE);
                        part <= B_BINDING_LENGTH;
                    end

                    B_BINDING_LENGTH : begin
                        emit (binding_length);
                        part <= B_OID_TAG;
                    end

                    B_OID_TAG : begin
                        emit (TAG_OID);
                        part <= B_OID_LENGTH;
                    end

                    B_OID_LENGTH : begin
                        emit (response_oid_length);
                        part <= B_OID;
                        part_pos <= 0;
                    end

                    B_OID : begin
                        if (missing) begin
                            cursor <= { 1'b0, oid_start } + part_pos;
                            fetch (COPY_OID);
                        end
                        else begin
                            emit (oid_shift[87:80]);
                            part_pos <= part_pos + 5'd1;
                            if (part_pos + 1 == response_oid_length) part <= B_VALUE_TAG;
                        end
                    end

                    B_VALUE_TAG : begin
                        emit (value_tag);
                        part <= B_VALUE_LENGTH;
                    end

                    B_VALUE_LENGTH : begin
                        emit (value_length);
                        part <= B_VALUE;
                        part_pos <= 0;
                        if (value_length == 0) state <= TX_FLUSH;
                    end

                    B_VALUE : if (echo_value) begin
                        cursor <= { 1'b0, set_value_start } + part_pos;
                        fetch (COPY_VALUE);
                    end
                    else begin
                        if (description_value) begin
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

                // COPY_COMM：写入口令字节，写完后继续构造协议头。
                COPY_COMM : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    if (part_pos + 1 == community_length) part <= B_PDU_TAG;
                    state <= BUILD;
                end

                // COPY_OID：写入请求中的对象编号，写完后继续值字段。
                COPY_OID : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    if (part_pos + 1 == response_oid_length) part <= B_VALUE_TAG;
                    state <= BUILD;
                end

                // COPY_VALUE：复制错误请求中的值，写完后转 TX_FLUSH。
                COPY_VALUE : begin
                    emit (byte_value);
                    part_pos <= part_pos + 5'd1;
                    state <= part_pos + 1 == value_length ? TX_FLUSH : BUILD;
                end

                // TRAP_INIT：准备事件通知及运行时间字段，然后计算回应长度。
                TRAP_INIT : begin
                    response_port <= TRAP_PORT;
                    version <= 1;
                    get_set <= 0;
                    missing <= 0;
                    echo_value <= 0;
                    error_status <= ERR_NONE;
                    request_id <= 0;
                    request_id_length <= 1;
                    community_length <= configured_length;
                    object_index <= 1;
                    value_number <= uptime;
                    state <= VALUE_PREP;
                end

                // TRAP_COMM0：选择口令所在的字，然后转 TRAP_COMM1。
                TRAP_COMM0 : begin
                    case (part_pos[3:2])
                        0 : community_word <= community0;
                        1 : community_word <= community1;
                        2 : community_word <= community2;
                        3 : community_word <= community3;
                    endcase
                    state <= TRAP_COMM1;
                end

                // TRAP_COMM1：选择字内的字节，然后转 COPY_COMM。
                TRAP_COMM1 : begin
                    case (part_pos[1:0])
                        0 : byte_value <= community_word[31:24];
                        1 : byte_value <= community_word[23:16];
                        2 : byte_value <= community_word[15:8];
                        3 : byte_value <= community_word[7:0];
                    endcase
                    state <= COPY_COMM;
                end

                // TRAP_WORD：选择事件编号所在的字，然后转 TRAP_BYTE。
                TRAP_WORD : begin
                    case (part_pos[4:3])
                        0 : trap_word <= TRAP_OID_WORD0;
                        1 : trap_word <= TRAP_OID_WORD1;
                        2 : trap_word <= TRAP_OID_WORD2;
                        3 : trap_word <= { trap_event, 56'b0 };
                    endcase
                    state <= TRAP_BYTE;
                end

                // TRAP_BYTE：写一个事件编号字节，写完转 TX_FLUSH，否则转 TRAP_WORD。
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
                    state <= part_pos == TRAP_OID_LAST_POS ? TX_FLUSH : TRAP_WORD;
                end

                // 最后一个 RAM 写完成后，交给全速发送段；等待整帧确认。
                TX_FLUSH : begin
                    send_request <= ~send_request;
                    state <= TX_SEND;
                end
                TX_SEND : if (send_complete == send_request) begin
                    state <= IDLE;
                    if (sending_trap) traps_sent <= traps_sent + 32'd1;
                end

                default : state <= IDLE;
            endcase
            // 关闭事件通知后，模块丢弃尚未发送的通知请求。
            if ( ! configured || ! trap_enabled) begin
                cold_pending <= 0;
                auth_pending <= 0;
            end
            if (!cold_request) cold_ack <= 0;
            if (cold_request && !cold_ack) begin
                cold_pending <= 1;
                cold_ack <= 1;
            end
        end
    end

endmodule
