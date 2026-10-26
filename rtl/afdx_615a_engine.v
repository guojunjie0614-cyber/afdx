// 协议状态只在 ce 拍更新；所有 RAM 和外部握手均留在全速外壳。
module afdx_615a_engine #(parameter CE_DIV = 2, CE_BANKS = 72) (
    input wire clk, reset,
    input wire [CE_BANKS - 1:0] ce_phase,
    input wire  enable_in,
    input wire  configured_in,
    input wire [15:0] request_port_in,
    input wire [31:0] timeout_cycles_in,
    input wire [7:0] retry_limit_in,
    input wire  protocol_a4_in,
    input wire  packet_pending_in,
    input wire [15:0] rx_op_in,
    input wire [15:0] rx_block_in,
    input wire [9:0] rx_length_in,
    input wire [15:0] peer_sp_in,
    input wire [15:0] peer_dp_in,
    input wire [7:0] rx_q_in,
    input wire [7:0] lur_q_in,
    input wire [7:0] hdr_q_in,
    input wire [7:0] load_q_in,
    input wire  send_complete_in,
    output reg  consume,
    output reg [1:0] status,
    output reg [7:0] reason,
    output reg [13:0] loaded,
    output reg [15:0] lus_counter,
    output reg [31:0] retry_total,
    output reg [15:0] main_tid,
    output reg [15:0] status_tid,
    output reg [15:0] deny_tid,
    output reg [15:0] tx_sport,
    output reg [15:0] tx_dport,
    output reg  send_request,
    output reg  send_mode,
    output reg [10:0] send_length,
    output reg  deny_we,
    output reg [4:0] deny_wa,
    output reg [7:0] deny_wd,
    output reg  rx_re,
    output reg [9:0] rx_ra,
    output reg  tx_we,
    output reg [9:0] tx_wa,
    output reg [7:0] tx_wd,
    output reg  lur_we,
    output reg [8:0] lur_wa,
    output reg [7:0] lur_wd,
    output reg  lur_re,
    output reg [8:0] lur_ra,
    output reg  hdr_we,
    output reg [10:0] hdr_wa,
    output reg [7:0] hdr_wd,
    output reg  hdr_re,
    output reg [10:0] hdr_ra,
    output reg  load_we,
    output reg [12:0] load_wa,
    output reg [7:0] load_wd,
    output reg  load_re,
    output reg [12:0] load_ra
);
    // 同步复位优先；显式使能保留硬件 CE 引脚，避免移入数据反馈选择器。
    // 含复位的使能保证复位拍也更新；各局部 CE 只驱动至多 32 位。
    (* direct_enable = 1, keep = 1 *) wire ce_1 = ce_phase[1] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_9 = ce_phase[9] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_10 = ce_phase[10] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_11 = ce_phase[11] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_12 = ce_phase[12] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_13 = ce_phase[13] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_14 = ce_phase[14] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_15 = ce_phase[15] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_16 = ce_phase[16] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_17 = ce_phase[17] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_18 = ce_phase[18] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_19 = ce_phase[19] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_20 = ce_phase[20] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_21 = ce_phase[21] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_22 = ce_phase[22] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_23 = ce_phase[23] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_24 = ce_phase[24] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_25 = ce_phase[25] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_26 = ce_phase[26] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_27 = ce_phase[27] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_28 = ce_phase[28] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_29 = ce_phase[29] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_30 = ce_phase[30] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_31 = ce_phase[31] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_32 = ce_phase[32] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_33 = ce_phase[33] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_34 = ce_phase[34] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_35 = ce_phase[35] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_36 = ce_phase[36] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_37 = ce_phase[37] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_38 = ce_phase[38] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_39 = ce_phase[39] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_40 = ce_phase[40] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_41 = ce_phase[41] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_42 = ce_phase[42] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_43 = ce_phase[43] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_44 = ce_phase[44] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_45 = ce_phase[45] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_46 = ce_phase[46] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_47 = ce_phase[47] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_48 = ce_phase[48] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_49 = ce_phase[49] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_50 = ce_phase[50] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_51 = ce_phase[51] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_52 = ce_phase[52] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_53 = ce_phase[53] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_54 = ce_phase[54] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_55 = ce_phase[55] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_56 = ce_phase[56] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_57 = ce_phase[57] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_58 = ce_phase[58] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_59 = ce_phase[59] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_60 = ce_phase[60] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_61 = ce_phase[61] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_62 = ce_phase[62] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_63 = ce_phase[63] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_64 = ce_phase[64] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_65 = ce_phase[65] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_66 = ce_phase[66] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_67 = ce_phase[67] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_68 = ce_phase[68] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_69 = ce_phase[69] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_70 = ce_phase[70] | reset;
    (* direct_enable = 1, keep = 1 *) wire ce_71 = ce_phase[71] | reset;
    // 这些状态接收并检查请求。
    localparam REASON_NONE = 0;
    localparam REASON_DESCRIPTION = 1;
    localparam REASON_LENGTH = 2;
    localparam REASON_CHECKSUM = 3;
    localparam REASON_TFTP_ERROR = 4;
    localparam REASON_RETRY_LIMIT = 5;
    localparam [7:0] IDLE = 8'd0;
    localparam [7:0] WAIT_PACKET = 8'd1;
    localparam [7:0] DISPATCH = 8'd2;
    localparam [7:0] DISPATCH_CHECK = 8'd72, DISPATCH_SELECT = 8'd73, PACKET_START = 8'd74, BUILD_CANDIDATE = 8'd75;
    localparam [7:0] NAME = 8'd3;
    localparam NAME_BYTE = 4;
    localparam [7:0] MODE = 8'd5;
    localparam MODE_BYTE = 6;
    localparam [7:0] REQUEST_OK = 8'd7;
    localparam [7:0] DENY_SEND = 8'd70;

    // 这些状态从存储器读取字节或数字。
    localparam [7:0] FETCH = 8'd8;
    localparam [7:0] FETCH_WAIT = 8'd9;
    localparam [7:0] FETCH_CAPTURE = 8'd10;
    localparam [7:0] FETCH_DONE = 8'd11;
    localparam [7:0] NUMBER = 8'd12;
    localparam [7:0] NUMBER_BYTE = 8'd13;

    // 这些状态构造并发送报文。
    localparam [7:0] BUILD = 8'd14;
    localparam [7:0] BUILD_PREP = 8'd60;
    localparam EMIT = 15;
    localparam [7:0] BUILD_FLUSH = 8'd16;
    localparam [7:0] TX_ADDR = 8'd17;
    localparam TX_WAIT = 18;
    localparam TX_CAPTURE = 19;
    localparam [7:0] TX_SEND = 8'd20;
    localparam [7:0] ACK_MAIN = 8'd28;

    // 这些状态计算进度并报告加载状态。
    localparam [7:0] START_LUS = 8'd21;
    localparam [7:0] RATIO_SCALE = 8'd22;
    localparam [7:0] RATIO_SUB = 8'd23;
    localparam [7:0] RATIO_DEC = 8'd24;
    localparam [7:0] LUS_WRQ = 8'd25;
    localparam [7:0] LUS_DATA = 8'd26;
    localparam [7:0] LUS_DONE = 8'd27;

    // 这些状态接收并保存文件内容。
    localparam [7:0] DATA_COPY = 8'd29;
    localparam DATA_BYTE = 30;
    localparam [7:0] DATA_END = 8'd31;

    // 这些状态检查上传请求列表。
    localparam [7:0] LUR_START = 8'd32;
    localparam LUR_LENGTH = 33;
    localparam LUR_VERSION = 34;
    localparam LUR_COUNT = 35;
    localparam LUR_HLEN = 36;
    localparam LUR_PLEN = 37;
    localparam [7:0] LUR_OFFSETS = 8'd61;
    localparam [7:0] LUR_READY = 8'd38;

    // 这些状态获取并检查头文件。
    localparam [7:0] RRQ_HEADER = 8'd39;
    localparam [7:0] HEADER_START = 8'd40;
    localparam HEADER_LENGTH = 41;
    localparam HEADER_VERSION = 42;
    localparam HEADER_PTR = 43;
    localparam [7:0] HEADER_PTR_CHECK = 8'd71;
    localparam [7:0] HEADER_PTR_MERGE = 8'd76;
    localparam [7:0] HEADER_CRC = 8'd44;
    localparam HEADER_CRC_BYTE = 45;
    localparam HEADER_CRC_EXPECT = 46;
    localparam HEADER_CRC_CHECK = 47;
    localparam HEADER_COUNT = 48;
    localparam HEADER_NLEN = 49;
    localparam HEADER_PLEN = 50;
    localparam [7:0] HEADER_SIZE = 8'd51;
    localparam HEADER_DCRC = 52;
    localparam HEADER_READY = 53;

    // 这些状态获取并校验数据文件。
    localparam [7:0] RRQ_DATA = 8'd54;
    localparam [7:0] DATA_CHECK = 8'd55;
    localparam [7:0] DATA_SUCCESS = 8'd56;

    // 这些状态检查卸载请求并传送加载区内容。
    localparam LNR_USER = 62;
    localparam [7:0] LNR_NAME = 8'd63;
    localparam LNR_BYTE = 64;
    localparam [7:0] LNR_READY = 8'd65;
    localparam [7:0] DL_WRQ = 8'd66;
    localparam [7:0] DL_BLOCK = 8'd67;
    localparam [7:0] DL_SIZE = 8'd68;
    localparam [7:0] DL_ACK = 8'd69;

    // 这些状态报告失败或结束本次操作。
    localparam [7:0] FAILURE = 8'd57;
    localparam FAILURE_SENT = 58;
    localparam [7:0] DONE = 8'd59;

    // state 记录当前文件处理步骤，HEADER_CRC_EXPECT 是未使用的编码。
    // wait_kind 记录当前等待哪一种确认或文件，packet_type 选择待发报文。
    localparam WK_LUI_ACK = 0, WK_LUR = 1, WK_DATA = 2, WK_LUS_ACK0 = 3, WK_LUS_ACK1 = 4,
        WK_DL_ACK0 = 3'd5, WK_DL_ACK = 3'd6;

    localparam PK_ACK = 0, PK_LUI = 1, PK_RRQ = 2, PK_LUS_WRQ = 3, PK_LUS = 4, PK_ERROR = 5, PK_DL_DATA = 6;

    // status 寄存器的取值：空闲、进行中、成功、失败。
    localparam ST_BUSY = 1, ST_SUCCESS = 2'd2, ST_FAILED = 2'd3;
    localparam [1:0] ST_IDLE = 2'd0;

    // 状态文件里的操作状态码：已接受、进行中、已完成，以及目标端中止（0x1003）。
    localparam LUS_IN_PROGRESS = 2, LUS_COMPLETED = 3, LUS_ABORTED = 16'h1003;
    localparam [15:0] LUS_NONE = 16'd0, LUS_ACCEPTED = 16'd1;

    // 目标端中止时，状态文件里逐文件的状态码是 0x1007，下面是它的高、低字节。
    localparam FILE_ABORTED_HIGH = 8'h10, FILE_ABORTED_LOW = 8'd7;

    // 状态文件里头文件名字段的起始位置。
    localparam LUS_NAME_POS = 10'd33;

    // file_kind 的取值：正在接收请求列表、头文件还是数据文件。
    localparam FILE_LIST = 0, FILE_HEADER = 1, FILE_DATA = 2;

    // 协议文件版本是两个 ASCII 字符 A3 或 A4；头文件格式版本固定为 0x8002。
    localparam VERSION_A3 = 16'h4133, VERSION_A4 = 16'h4134, HEADER_FILE_VERSION = 16'h8002;
    localparam VERSION_A3_WORD = 32'h4133, VERSION_A4_WORD = 32'h4134;

    // 文件校验用 16 位循环冗余校验：多项式 0x1021，初值全 1。
    localparam CRC16_POLY = 16'h1021, CRC16_INIT = 16'hffff;

    // 本端各类传输使用的 UDP 端口起始值，每开始一次新传输换一个端口。
    localparam MAIN_TID_INIT = 16'h8000, STATUS_TID_INIT = 16'h9000, TID_SEQUENCE_INIT = 16'h8100;
    localparam DENY_TID_INIT = 16'ha000;

    // 复位后的请求端口、超时（250000000 拍即 2 秒）和重传次数上限。
    localparam DEFAULT_REQUEST_PORT = 59, DEFAULT_TIMEOUT_CYCLES = 250000000, DEFAULT_RETRY_LIMIT = 1;

    // 本模块的配置寄存器地址（低 8 位）。
    localparam REG_ENABLE = 8'hb0, REG_TX_VL = 8'hb1, REG_MEMORY_ADDRESS = 8'hb4, REG_REQUEST_PORT = 8'hb8;
    localparam REG_TIMEOUT = 8'hb9, REG_RETRY_LIMIT = 8'hba, REG_VERSION = 8'hbb;

    // ASCII 字符 0；字母或上 ASCII_CASE_BIT 后变成小写，用于不分大小写的比较。
    localparam ASCII_ZERO = 8'h30, ASCII_CASE_BIT = 8'h20;

    // 与上它可把长度向下取到偶数。
    localparam EVEN_MASK = 32'hfffffffe;

    // TFTP 数据块最多 512 字节，数据和确认报文都从四字节报头开始。
    localparam TFTP_OPCODE_WRQ = 2, TFTP_OPCODE_DATA = 3, TFTP_OPCODE_ACK = 4, TFTP_OPCODE_ERROR = 5;
    localparam TFTP_HEADER_BYTES = 11'd4, TFTP_BLOCK_BYTES = 11'd512, TFTP_MAX_PACKET_BYTES = 10'd516;
    localparam TFTP_DATA_POS = 10'd4, PACKET_BUFFER_BYTES = 1024;

    // 请求列表、头文件和数据文件各自的存储容量；数据长度字段按双字节计。
    localparam LUR_BUFFER_BYTES = 512, HEADER_BUFFER_BYTES = 2048, LOAD_BUFFER_BYTES = 8192;
    localparam MAX_DATA_WORDS = 4096, MAX_FILENAME_BYTES = 64, MAX_HEADER_NAME_CHARS = 63;

    // 状态报文的固定字段和尾部长度，文件名、部件名插在这些字段之间。
    localparam LUS_PART_POS_BASE = 10'd34, LUS_DOWNLOAD_LENGTH_BASE = 10'd44, LUS_TAIL_BYTES = 10'd14;
    localparam LUR_FIXED_BYTES = 9'd10, LNR_NAME_POS = 13'd9;

    // 固定请求文件名及 octet 模式字段的位置和长度。
    localparam RRQ_NAME_POS = 11'd2, RRQ_MODE_POS = 11'd14;
    localparam RRQ_SUFFIX_BYTES = 10'd7, OCTET_MODE_BYTES = 10'd6;
    localparam TARGET_NAME_BYTES = 11, TARGET_DOWNLOAD_MARK_POS = 10;

    // 固定回应长度；确认报文只包含 TFTP 报头。
    localparam ERROR_PACKET_BYTES = 11, LUI_PACKET_BYTES = 13, LUS_SHORT_PACKET_BYTES = 32;
    localparam LUS_WRQ_PACKET_BYTES = 20, DOWNLOAD_RRQ_PACKET_BYTES = 19;

    // 头文件指针按双字节计，末尾六字节保存校验字段。
    localparam HEADER_MIN_BYTES = 32, HEADER_DATA_PTR_MIN_WORDS = 13, HEADER_TRAILER_BYTES = 6;
    localparam MAX_PROGRESS_PERCENT = 99, DECIMAL_BASE = 7'd10;

    localparam [7:0] NUMBER_READY = 8'd247;
    localparam [7:0] FETCH_WAIT_A = 8'd240, FETCH_WAIT_B = 8'd241, DENY_FLUSH = 8'd242, DENY_FINISH = 8'd243, FETCH_WAIT_C = 8'd244, DATA_DISPATCH = 8'd245, RATIO_TEST = 8'd246, LNR_USER_CHECK = 8'd248, RETRY_DECIDE = 8'd249;
    reg  enable;
    reg  configured;
    reg [15:0] request_port;
    reg [31:0] timeout_cycles;
    reg [7:0] retry_limit;
    reg  protocol_a4;
    reg  packet_pending;
    reg [15:0] rx_op;
    reg [15:0] rx_block;
    reg [9:0] rx_length;
    reg [15:0] peer_sp;
    reg [15:0] peer_dp;
    reg [7:0] rx_q;
    reg [7:0] lur_q;
    reg [7:0] hdr_q;
    reg [7:0] load_q;
    reg  send_complete;
    // REASON_DESCRIPTION：文件描述内容错误。
    // REASON_LENGTH：容量或长度错误。
    // REASON_CHECKSUM：校验值错误。
    // REASON_TFTP_ERROR：收到 TFTP 错误报文。
    // REASON_RETRY_LIMIT：重试次数已用完。




    // return_state/num_return 保存读取完成后应回到的状态。
    // after_tx/lus_return/ack_return 保存发送或确认后的返回状态。
    reg [7:0] state, return_state, num_return, after_tx, lus_return, ack_return;
    (* preserve = 1, dont_merge = 1 *) reg [2:0] wait_kind;
    reg [2:0] packet_type;
    (* preserve = 1, dont_merge = 1 *) reg [1:0] file_kind;
    reg [1:0] fetch_source;

    // main_tid/main_peer 保存传数据文件时本端和对端的 UDP 端口。
    // status_tid/status_peer 保存传状态文件时本端和对端的 UDP 端口。
    reg [15:0] main_peer, status_peer, tid_sequence;
    reg [15:0] block_number, ack_number;

    // timer 在等待报文时倒计时，超时后重发 packet_tx 中的内容。
    // retry_total 统计累计重发次数。
    reg [31:0] timer;
    reg [7:0] retries;

    // loaded/file_size 保存本次已加载字节数和期望大小。
    // 校验成功后才更新 available_size，供卸载读取。
    reg [13:0] file_size;
    reg [13:0] available_size, dl_acked, dl_remaining;
    reg [12:0] dl_read_addr;
    reg  download_mode, request_download, request_unsupported, deny_empty, deny_unsupported;
    reg [7:0] request_resume;
    reg [4:0] deny_pos;
    reg [15:0] saved_sport, saved_dport;

    // data_crc/expected_crc 用于核对数据文件，header_crc 用于核对头文件。
    // 16 位校验使用多项式 0x1021。
    reg [15:0] data_crc, expected_crc, header_crc;

    // metadata_size 保存列表或头文件的长度。
    // name_addr/len 和 header_pointer 定位变长字段。
    // 文件里的指针以两个字节为单位，使用前先乘二。
    reg [11:0] metadata_size, header_pointer, header_name_addr, data_name_addr;
    reg  header_pointer_ok;
    reg [31:0] header_limit;
    reg [3:0] pointer_less, pointer_equal;
    reg  pointer_minimum;
    // 文件长度在读取指针之前已稳定；提前寄存上界，分开减法和范围比较。
    reg [9:0] next_error_position;
    reg [9:0] next_lus_description_position;
    reg [9:0] next_filename_position;
    reg [9:0] next_wrq_mode_position;
    reg [9:0] next_rrq_mode_position;
    reg [12:0] next_rrq_header_read;
    reg [12:0] next_rrq_data_read;
    reg  next_enable;
    reg  next_configured;
    reg [15:0] next_request_port;
    reg [31:0] next_timeout_cycles;
    reg [7:0] next_retry_limit;
    reg  next_protocol_a4;
    reg  next_packet_pending;
    reg [15:0] next_rx_op;
    reg [15:0] next_rx_block;
    reg [9:0] next_rx_length;
    reg [15:0] next_peer_sp;
    reg [15:0] next_peer_dp;
    reg [7:0] next_rx_q;
    reg [7:0] next_lur_q;
    reg [7:0] next_hdr_q;
    reg [7:0] next_load_q;
    reg  next_send_complete;
    reg  next_send_request;
    reg  next_send_mode;
    reg [10:0] next_send_length;
    reg  next_deny_we;
    reg [4:0] next_deny_wa;
    reg [7:0] next_deny_wd;
    reg [1:0] next_status;
    reg [7:0] next_reason;
    reg [7:0] next_state;
    reg [15:0] next_command_op;
    reg [15:0] next_command_block;
    reg [15:0] next_command_sport;
    reg [15:0] next_command_dport;
    reg [9:0] next_command_length;
    reg [7:0] next_dispatch_match;
    reg [7:0] next_dispatch_action;
    reg  next_dispatch_current;
    reg  next_dispatch_repeat;
    reg [15:0] next_main_tid;
    reg [15:0] next_status_tid;
    reg [15:0] next_main_peer;
    reg [15:0] next_status_peer;
    reg [15:0] next_tid_sequence;
    reg [13:0] next_loaded;
    reg [13:0] next_file_size;
    reg [13:0] next_available_size;
    reg [13:0] next_dl_acked;
    reg [13:0] next_dl_remaining;
    reg [12:0] next_dl_read_addr;
    reg  next_download_mode;
    reg  next_request_download;
    reg  next_request_unsupported;
    reg [7:0] next_request_resume;
    reg  next_deny_empty;
    reg  next_deny_unsupported;
    reg [4:0] next_deny_pos;
    reg [15:0] next_deny_tid;
    reg [15:0] next_saved_sport;
    reg [15:0] next_saved_dport;
    reg [15:0] next_lus_counter;
    reg [31:0] next_retry_total;
    reg [15:0] next_tx_sport;
    reg [15:0] next_tx_dport;
    reg  next_consume;
    reg [31:0] next_timer;
    reg [7:0] next_retries;
    reg  next_rx_re;
    reg [9:0] next_rx_ra;
    reg  next_tx_we;
    reg [9:0] next_tx_wa;
    reg [7:0] next_tx_wd;
    reg  next_lur_we;
    reg [8:0] next_lur_wa;
    reg [7:0] next_lur_wd;
    reg  next_lur_re;
    reg [8:0] next_lur_ra;
    reg  next_hdr_we;
    reg [10:0] next_hdr_wa;
    reg [7:0] next_hdr_wd;
    reg  next_hdr_re;
    reg [10:0] next_hdr_ra;
    reg  next_load_we;
    reg [12:0] next_load_wa;
    reg [7:0] next_load_wd;
    reg  next_load_re;
    reg [12:0] next_load_ra;
    reg  next_manifest;
    reg [1:0] next_file_kind;
    reg [15:0] next_block_number;
    reg [15:0] next_ack_number;
    reg [15:0] next_data_crc;
    reg [15:0] next_header_crc;
    reg [15:0] next_expected_crc;
    reg [7:0] next_return_state;
    reg [7:0] next_num_return;
    reg [7:0] next_after_tx;
    reg [7:0] next_lus_return;
    reg [7:0] next_ack_return;
    reg [2:0] next_wait_kind;
    reg [2:0] next_packet_type;
    reg [2:0] next_pending_kind;
    reg [9:0] next_pending_length;
    reg [15:0] next_pending_sport;
    reg [15:0] next_pending_dport;
    reg [7:0] next_pending_after;
    reg [1:0] next_fetch_source;
    reg [12:0] next_fetch_addr;
    reg [7:0] next_byte_value;
    reg [31:0] next_number;
    reg [2:0] next_number_left;
    reg [9:0] next_packet_len;
    reg [9:0] next_packet_pos;
    reg [11:0] next_metadata_size;
    reg  next_header_pointer_ok;
    reg [3:0] next_pointer_less;
    reg [3:0] next_pointer_equal;
    reg  next_pointer_minimum;
    reg [11:0] next_header_pointer;
    reg [11:0] next_header_name_addr;
    reg [6:0] next_header_name_len;
    reg [6:0] next_part_len;
    reg [9:0] next_part_addr;
    reg [11:0] next_data_name_addr;
    reg [6:0] next_data_name_len;
    reg [15:0] next_lus_status;
    reg [6:0] next_percent;
    reg [19:0] next_scaled;
    reg [7:0] next_ratio_h;
    reg [7:0] next_ratio_t;
    reg [7:0] next_ratio_u;
    reg [3:0] next_decimal_tens;
    reg [6:0] next_decimal_rest;
    reg [10:0] next_copy_pos;
    reg [10:0] next_copy_len;
    reg [10:0] next_scan_pos;
    reg [4:0] next_name_pos;
    reg  next_request_write;
    reg [7:0] next_build_value;
    reg [9:0] next_lus_partlen_pos;
    reg [9:0] next_lus_part_pos;
    reg [9:0] next_lus_tail_pos;
    reg [9:0] next_lus_packet_len;
    reg [9:0] next_tail_index;
    reg [9:0] next_head_index;
    reg [9:0] next_part_index;
    reg [9:0] next_name_end;
    reg [9:0] next_mode_start;
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_1) begin
        if (reset) begin
            header_limit <= 0;
        end
        else begin
header_limit <= metadata_size - HEADER_TRAILER_BYTES;
        end
    end
    end
    reg [6:0] header_name_len, part_len, data_name_len;
    reg [9:0] part_addr;
    reg  manifest;
    reg [15:0] lus_status;
    reg [6:0] percent;
    reg [19:0] scaled;
    reg [7:0] ratio_h, ratio_t, ratio_u;
    reg [3:0] decimal_tens;
    reg [6:0] decimal_rest;
    reg [12:0] fetch_addr;
    reg [10:0] copy_pos, copy_len, scan_pos;
    reg [7:0] byte_value, build_value;
    reg [31:0] number;
    wire [31:0] pointer_bytes = {number[30:0], 1'b0};
    reg [2:0] number_left;
    reg [9:0] packet_len, packet_pos;

    // 接纳报文时保存头字段，后续接收不能改写正在译码的命令。
    reg [15:0] command_op, command_block, command_sport, command_dport;
    reg [9:0] command_length;
    reg [15:0] previous_block;
    reg [7:0] dispatch_match, dispatch_action;
    reg  dispatch_current, dispatch_repeat;
    (* preserve = 1 *) reg [6:0] expected_name, expected_mode;
    (* preserve = 1 *) reg  name_mark, name_option, name_bad, name_terminal, mode_bad, mode_terminal;
    (* preserve = 1 *) reg  request_reject;
    reg [2:0] pending_kind;
    reg [9:0] pending_length;
    reg [15:0] pending_sport, pending_dport;
    reg [7:0] pending_after;
    wire [7:0] dispatch_choice = {
        dispatch_match[7] && !(|dispatch_match[6:0]),
        dispatch_match[6] && !(|dispatch_match[5:0]),
        dispatch_match[5] && !(|dispatch_match[4:0]),
        dispatch_match[4] && !(|dispatch_match[3:0]),
        dispatch_match[3] && !(|dispatch_match[2:0]),
        dispatch_match[2] && !(|dispatch_match[1:0]),
        dispatch_match[1] && !dispatch_match[0], dispatch_match[0] };
    reg [9:0] lus_partlen_pos, lus_part_pos, lus_tail_pos, lus_packet_len;
    reg [9:0] tail_index, head_index, part_index, name_end, mode_start;

    reg [4:0] name_pos;
    reg  request_write;






















    // 各报文类型并行准备一个字节，下一拍只选择已寄存的结果。
    // 位置和常量偏移先寄存，避免位置加减、字符表和报文类型选择串在同一路径上。
    localparam PACKET_KIND_COUNT = 7;
    (* preserve = 1, dont_merge = 1 *) reg [9:0] build_position [0:PACKET_KIND_COUNT - 1];
    reg [7:0] candidate_byte [0:PACKET_KIND_COUNT - 1];
    reg [PACKET_KIND_COUNT - 1:0] candidate_read;
    reg [1:0] candidate_source [0:PACKET_KIND_COUNT - 1];
    reg [12:0] candidate_address [0:PACKET_KIND_COUNT - 1];
    reg [9:0] error_position, lus_description_position, filename_position;
    reg [9:0] wrq_mode_position, rrq_mode_position;
    reg [12:0] rrq_header_read, rrq_data_read;
    genvar byte_kind;
    generate
        for (byte_kind = 0; byte_kind < PACKET_KIND_COUNT; byte_kind = byte_kind + 1) begin : byte_position
            (* direct_enable = 1, keep = 1 *) wire local_ce = ce_phase[2 + byte_kind] | reset;
            always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (local_ce) begin
        if (reset) begin
            build_position[byte_kind] <= 0;
        end
        else begin
build_position[byte_kind] <= packet_pos;
        end
    end
    end
        end
    endgenerate
    reg [19:0] ratio_remainder;
    reg ratio_continue;
    reg number_metadata_ok, number_version_ok, number_one, number_header_length_ok;
    localparam DATA_COUNTS_WAIT = 8'd250;
    reg load_size_ok;
    always @(posedge clk) begin
        if (ce_70) begin
            if (reset) load_size_ok <= 0;
            else load_size_ok <= loaded == file_size;
        end
    end
    reg number_header_version_ok, number_crc_ok, number_name_ok, number_part_ok, number_data_size_ok;
    // 字段长度校验通过后只用地址宽度内的偶数长度，显式保留原运算的低 11 位。
    wire [31:0] number_even_length = (number + 1) & EVEN_MASK;
    reg [8:0] lnr_expected_length;
    reg lnr_name_ok;
    // 下一状态保持原非阻塞赋值的旧值语义；每组 CE 最多驱动 32 个数据位。
    always @* begin
        next_error_position = error_position;
        next_lus_description_position = lus_description_position;
        next_filename_position = filename_position;
        next_wrq_mode_position = wrq_mode_position;
        next_rrq_mode_position = rrq_mode_position;
        next_rrq_header_read = rrq_header_read;
        next_rrq_data_read = rrq_data_read;

next_error_position = packet_pos - 10'd4;
        next_lus_description_position = packet_pos - 10'd13;
        next_filename_position = packet_pos - 10'd2;
        next_wrq_mode_position = packet_pos - 10'd14;
        next_rrq_mode_position = packet_pos - mode_start;
        next_rrq_header_read = header_name_addr + filename_position;
        next_rrq_data_read = data_name_addr + filename_position;
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_9) begin
        if (reset) begin
            error_position <= 0;
            lus_description_position <= 0;
            filename_position <= 0;
        end
        else begin
            error_position <= next_error_position;
            lus_description_position <= next_lus_description_position;
            filename_position <= next_filename_position;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_10) begin
        if (reset) begin
            wrq_mode_position <= 0;
            rrq_mode_position <= 0;
        end
        else begin
            wrq_mode_position <= next_wrq_mode_position;
            rrq_mode_position <= next_rrq_mode_position;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_11) begin
        if (reset) begin
            rrq_header_read <= 0;
            rrq_data_read <= 0;
        end
        else begin
            rrq_header_read <= next_rrq_header_read;
            rrq_data_read <= next_rrq_data_read;
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_12) begin
        if (reset) begin
            candidate_byte[PK_ACK] <= 0;
            candidate_read[PK_ACK] <= 0;
            candidate_source[PK_ACK] <= 0;
            candidate_address[PK_ACK] <= 0;
        end
        else begin
            candidate_byte[PK_ACK] <= 0;
            candidate_read[PK_ACK] <= 0;
            case (build_position[PK_ACK])
                1 : candidate_byte[PK_ACK] <= 4;
                2 : candidate_byte[PK_ACK] <= ack_number[15:8];
                3 : candidate_byte[PK_ACK] <= ack_number[7:0];
            endcase
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_13) begin
        if (reset) begin
            candidate_byte[PK_LUI] <= 0;
            candidate_read[PK_LUI] <= 0;
            candidate_source[PK_LUI] <= 0;
            candidate_address[PK_LUI] <= 0;
        end
        else begin
            candidate_byte[PK_LUI] <= 0;
            candidate_read[PK_LUI] <= 0;
            case (build_position[PK_LUI])
                1 : candidate_byte[PK_LUI] <= 3;
                3 : candidate_byte[PK_LUI] <= 1;
                7 : candidate_byte[PK_LUI] <= 9;
                8 : candidate_byte[PK_LUI] <= "A";
                9 : candidate_byte[PK_LUI] <= protocol_a4 ? "4" : "3";
                11 : candidate_byte[PK_LUI] <= 1;
            endcase
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_14) begin
        if (reset) begin
            candidate_byte[PK_ERROR] <= 0;
            candidate_read[PK_ERROR] <= 0;
            candidate_source[PK_ERROR] <= 0;
            candidate_address[PK_ERROR] <= 0;
        end
        else begin
            candidate_byte[PK_ERROR] <= 0;
            candidate_read[PK_ERROR] <= 0;
            case (build_position[PK_ERROR])
                1 : candidate_byte[PK_ERROR] <= 5;
                3 : candidate_byte[PK_ERROR] <= reason == REASON_DESCRIPTION ? 8'd1 : reason == REASON_TFTP_ERROR ? 8'd4 : 8'd0;
                default : if (build_position[PK_ERROR] >= 4) candidate_byte[PK_ERROR] <= description (error_position);
            endcase
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_15) begin
        if (reset) begin
            candidate_byte[PK_LUS_WRQ] <= 0;
            candidate_read[PK_LUS_WRQ] <= 0;
            candidate_source[PK_LUS_WRQ] <= 0;
            candidate_address[PK_LUS_WRQ] <= 0;
        end
        else begin
            candidate_byte[PK_LUS_WRQ] <= 0;
            candidate_read[PK_LUS_WRQ] <= 0;
            begin
                if (build_position[PK_LUS_WRQ] == 1) candidate_byte[PK_LUS_WRQ] <= 2;
                else if (build_position[PK_LUS_WRQ] >= 2 && build_position[PK_LUS_WRQ] < 14)
                    candidate_byte[PK_LUS_WRQ] <= target_name (filename_position,
                    "S", download_mode);
                else if (build_position[PK_LUS_WRQ] >= 14) candidate_byte[PK_LUS_WRQ] <= octet_byte (wrq_mode_position);
            end
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_16) begin
        if (reset) begin
            candidate_byte[PK_RRQ] <= 0;
            candidate_read[PK_RRQ] <= 0;
            candidate_source[PK_RRQ] <= 0;
            candidate_address[PK_RRQ] <= 0;
        end
        else begin
            candidate_byte[PK_RRQ] <= 0;
            candidate_read[PK_RRQ] <= 0;
            begin
                if (build_position[PK_RRQ] == 1) candidate_byte[PK_RRQ] <= download_mode ? 8'd2 : 8'd1;
                else if (build_position[PK_RRQ] >= 2 && build_position[PK_RRQ] < name_end) begin
                    if (download_mode) candidate_byte[PK_RRQ] <= memory_name(filename_position);
                    else if (file_kind == FILE_HEADER)
                        begin
                            candidate_read[PK_RRQ] <= 1;
                            candidate_source[PK_RRQ] <= 1;
                            end
                    else begin
                        candidate_read[PK_RRQ] <= 1;
                        candidate_source[PK_RRQ] <= 2;
                    end
                end
                else if (build_position[PK_RRQ] >= mode_start) candidate_byte[PK_RRQ] <= octet_byte (rrq_mode_position);
            end
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_17) begin
        if (reset) begin
            candidate_byte[PK_DL_DATA] <= 0;
            candidate_read[PK_DL_DATA] <= 0;
            candidate_source[PK_DL_DATA] <= 0;
            candidate_address[PK_DL_DATA] <= 0;
        end
        else begin
            candidate_byte[PK_DL_DATA] <= 0;
            candidate_read[PK_DL_DATA] <= 0;
            case (build_position[PK_DL_DATA])
                1 : candidate_byte[PK_DL_DATA] <= 3;
                2 : candidate_byte[PK_DL_DATA] <= block_number[15:8];
                3 : candidate_byte[PK_DL_DATA] <= block_number[7:0];
                default : if (build_position[PK_DL_DATA] >= 4) begin
                    candidate_read[PK_DL_DATA] <= 1;
                    candidate_source[PK_DL_DATA] <= 3;
                    candidate_address[PK_DL_DATA] <= dl_read_addr;
                end
            endcase
        end
    end
    end

    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_18) begin
        if (reset) begin
            candidate_byte[PK_LUS] <= 0;
            candidate_read[PK_LUS] <= 0;
            candidate_source[PK_LUS] <= 0;
            candidate_address[PK_LUS] <= 0;
        end
        else begin
            candidate_byte[PK_LUS] <= 0;
            candidate_read[PK_LUS] <= 0;
            begin
                case (build_position[PK_LUS])

                    1 : candidate_byte[PK_LUS] <= 3;

                    3 : candidate_byte[PK_LUS] <= 1;

                    7 : candidate_byte[PK_LUS] <= packet_len[7:0] - 8'd4;

                    8 : candidate_byte[PK_LUS] <= "A";

                    9 : candidate_byte[PK_LUS] <= protocol_a4 ? "4" : "3";

                    10 : candidate_byte[PK_LUS] <= lus_status[15:8];

                    11 : candidate_byte[PK_LUS] <= lus_status[7:0];

                    12 : candidate_byte[PK_LUS] <= 8;

                    21 : candidate_byte[PK_LUS] <= lus_counter[15:8];

                    22 : candidate_byte[PK_LUS] <= lus_counter[7:0];

                    25, 26 : candidate_byte[PK_LUS] <= lus_status == LUS_IN_PROGRESS ? 8'hff : 8'd0;

                    27 : candidate_byte[PK_LUS] <= ratio_h;

                    28 : candidate_byte[PK_LUS] <= ratio_t;

                    29 : candidate_byte[PK_LUS] <= ratio_u;

                    31 : candidate_byte[PK_LUS] <= manifest;

                    32 : candidate_byte[PK_LUS] <= header_name_len;

                    default : begin
                        if (build_position[PK_LUS] >= 13
                            && build_position[PK_LUS] <= 20)
                                candidate_byte[PK_LUS] <= description (lus_description_position);
                        else if (build_position[PK_LUS] >= 33 && build_position[PK_LUS] < lus_partlen_pos) begin
                            candidate_read[PK_LUS] <= 1;
                            candidate_source[PK_LUS] <= 1;
                            candidate_address[PK_LUS] <= header_name_addr + head_index;
                        end
                        else if ( ! download_mode && build_position[PK_LUS] == lus_partlen_pos)
                            candidate_byte[PK_LUS] <= part_len;
                        else if ( ! download_mode && build_position[PK_LUS] >= lus_part_pos
                            && build_position[PK_LUS] < lus_tail_pos) begin
                                candidate_read[PK_LUS] <= 1;
                                candidate_source[PK_LUS] <= 1;
                                candidate_address[PK_LUS] <= part_addr + part_index;
                            end
                        else if (download_mode && build_position[PK_LUS] >= 33
                            && build_position[PK_LUS] >= lus_tail_pos) case (tail_index)
                            0 : candidate_byte[PK_LUS] <= lus_status == LUS_ABORTED ? FILE_ABORTED_HIGH : 8'd0;
                            1 : candidate_byte[PK_LUS] <= lus_status == LUS_ABORTED ? FILE_ABORTED_LOW
                                : lus_status[7:0];
                            2 : candidate_byte[PK_LUS] <= 8;
                            default : candidate_byte[PK_LUS] <= description(tail_index - 10'd3);
                        endcase
                        else if (build_position[PK_LUS] >= 33 && build_position[PK_LUS] >= lus_tail_pos)
                            case (tail_index)
                            0 : candidate_byte[PK_LUS] <= ratio_h;
                            1 : candidate_byte[PK_LUS] <= ratio_t;
                            2 : candidate_byte[PK_LUS] <= ratio_u;
                            3 : candidate_byte[PK_LUS] <= lus_status == LUS_ABORTED ? FILE_ABORTED_HIGH : 8'd0;
                            4 : candidate_byte[PK_LUS] <= lus_status == LUS_ABORTED ? FILE_ABORTED_LOW
                                : lus_status[7:0];
                            5 : candidate_byte[PK_LUS] <= 8;
                            default : candidate_byte[PK_LUS] <= description (tail_index - 10'd6);
                        endcase
                    end
                endcase
            end
        end
    end
    end

    // 全速来源先直接采样，随后仅使用本地的 CE 寄存器。
    // 下一状态保持原非阻塞赋值的旧值语义；每组 CE 最多驱动 32 个数据位。
    always @* begin
        next_enable = enable;
        next_configured = configured;
        next_request_port = request_port;
        next_timeout_cycles = timeout_cycles;
        next_retry_limit = retry_limit;
        next_protocol_a4 = protocol_a4;
        next_packet_pending = packet_pending;
        next_rx_op = rx_op;
        next_rx_block = rx_block;
        next_rx_length = rx_length;
        next_peer_sp = peer_sp;
        next_peer_dp = peer_dp;
        next_rx_q = rx_q;
        next_lur_q = lur_q;
        next_hdr_q = hdr_q;
        next_load_q = load_q;
        next_send_complete = send_complete;

            next_enable = enable_in;
            next_configured = configured_in;
            next_request_port = request_port_in;
            next_timeout_cycles = timeout_cycles_in;
            next_retry_limit = retry_limit_in;
            next_protocol_a4 = protocol_a4_in;
            next_packet_pending = packet_pending_in;
            next_rx_op = rx_op_in;
            next_rx_block = rx_block_in;
            next_rx_length = rx_length_in;
            next_peer_sp = peer_sp_in;
            next_peer_dp = peer_dp_in;
            next_rx_q = rx_q_in;
            next_lur_q = lur_q_in;
            next_hdr_q = hdr_q_in;
            next_load_q = load_q_in;
            next_send_complete = send_complete_in;
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_19) begin
        if (reset) begin
            enable <= 0;
            configured <= 0;
            request_port <= 0;
        end
        else begin
            enable <= next_enable;
            configured <= next_configured;
            request_port <= next_request_port;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_20) begin
        if (reset) begin
            timeout_cycles <= 0;
        end
        else begin
            timeout_cycles <= next_timeout_cycles;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_21) begin
        if (reset) begin
            retry_limit <= 0;
            protocol_a4 <= 0;
            packet_pending <= 0;
            rx_op <= 0;
        end
        else begin
            retry_limit <= next_retry_limit;
            protocol_a4 <= next_protocol_a4;
            packet_pending <= next_packet_pending;
            rx_op <= next_rx_op;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_22) begin
        if (reset) begin
            rx_block <= 0;
            rx_length <= 0;
        end
        else begin
            rx_block <= next_rx_block;
            rx_length <= next_rx_length;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_23) begin
        if (reset) begin
            peer_sp <= 0;
            peer_dp <= 0;
        end
        else begin
            peer_sp <= next_peer_sp;
            peer_dp <= next_peer_dp;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_24) begin
        if (reset) begin
            rx_q <= 0;
            lur_q <= 0;
            hdr_q <= 0;
            load_q <= 0;
        end
        else begin
            rx_q <= next_rx_q;
            lur_q <= next_lur_q;
            hdr_q <= next_hdr_q;
            load_q <= next_load_q;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_25) begin
        if (reset) begin
            send_complete <= 0;
        end
        else begin
            send_complete <= next_send_complete;
        end
    end
    end
    function [15:0] crc16;
        input [15:0] old;
        input [7:0] value;
        reg [15:0] c;
        integer k;
        begin
            c = old ^ { value, 8'b0 };
            for (k = 0; k < 8; k = k + 1) c = c[15] ? (c << 1) ^ CRC16_POLY : c << 1;
            crc16 = c;
        end
    endfunction

    function [7:0] target_name;
        input [4:0] p;
        input [7:0] suffix;
        input is_download;
        begin
            case (p)
                0 : target_name = "D";
                1 : target_name = "E";
                2 : target_name = "M";
                3 : target_name = "C";
                4 : target_name = "3";
                5 : target_name = "_";
                6 : target_name = "1";
                7 : target_name = ".";
                8 : target_name = "L";
                9 : target_name = is_download ? "N" : "U";
                10 : target_name = suffix;
                default : target_name = 0;
            endcase
        end
    endfunction

    function [7:0] memory_name;
        input [6:0] p;
        begin
            case (p)
                0 : memory_name = "M";
                1 : memory_name = "E";
                2 : memory_name = "M";
                3 : memory_name = "O";
                4 : memory_name = "R";
                5 : memory_name = "Y";
                6 : memory_name = ".";
                7 : memory_name = "B";
                8 : memory_name = "I";
                9 : memory_name = "N";
                default : memory_name = 0;
            endcase
        end
    endfunction

    // 拒绝新请求时使用独立输出，避免覆盖仍需重发的报文。
    function [7:0] denial_byte;
        input [4:0] p;
        begin
            denial_byte = 0;
            case (p)
                1 : denial_byte = 3;
                3 : denial_byte = 1;
                7 : denial_byte = deny_unsupported ? 8'd9 : 8'd17;
                8 : denial_byte = "A";
                9 : denial_byte = protocol_a4 ? "4" : "3";
                10 : denial_byte = 8'h10;
                11 : denial_byte = deny_unsupported ? 8'd2 : 8'd0;
                12 : denial_byte = deny_unsupported ? 8'd0 : 8'd8;
                13 : denial_byte = deny_empty ? "N" : "B";
                14 : denial_byte = deny_empty ? "O" : "U";
                15 : denial_byte = deny_empty ? " " : "S";
                16 : denial_byte = deny_empty ? "D" : "Y";
                17 : denial_byte = deny_empty ? "A" : 8'd0;
                18 : denial_byte = deny_empty ? "T" : 8'd0;
                19 : denial_byte = deny_empty ? "A" : 8'd0;
                default : ;
            endcase
        end
    endfunction

    function [7:0] octet_byte;
        input [4:0] p;
        begin
            case (p)
                0 : octet_byte = "o";
                1 : octet_byte = "c";
                2 : octet_byte = "t";
                3 : octet_byte = "e";
                4 : octet_byte = "t";
                default : octet_byte = 0;
            endcase
        end
    endfunction

    function [7:0] description;
        input [3:0] p;
        begin
            if (reason == REASON_NONE) description = 0;
            else case (p)
                0 : description = "F";
                1 : description = "A";
                2 : description = "I";
                3 : description = "L";
                4 : description = " ";
                5 : description = ASCII_ZERO + reason;
                default : description = 0;
            endcase
        end
    endfunction

    // get_byte 读取一个字节，get_number 读取高字节在前的整数。
    // 两者先保存返回状态，再进入同步读取过程。
    task get_byte;
        input [1:0] src;
        input [12:0] addr;
        input [7:0] destination;
        begin
            next_fetch_source = src;
            next_fetch_addr = addr;
            next_return_state = destination;
            next_state = FETCH;
        end
    endtask

    task get_number;
        input [1:0] src;
        input [12:0] addr;
        input [2:0] count;
        input [7:0] destination;
        begin
            next_fetch_source = src;
            next_fetch_addr = addr;
            next_number = 0;
            next_number_left = count;
            next_num_return = destination;
            next_state = 8'd12;
        end
    endtask

    // 请求字节的读取等待拍用于预先选择目标字符并比较，解析状态只消费一位结果。
    wire [7:0] expected_name_byte = target_name(name_pos,
        request_write ? "R" : request_download ? "D" : "I", request_download);
    wire [7:0] expected_mode_byte = octet_byte(name_pos);
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_26) begin
        if (reset) begin
            expected_name <= 0;
            expected_mode <= 0;
            name_mark <= 0;
            name_option <= 0;
            name_bad <= 0;
            name_terminal <= 0;
            mode_bad <= 0;
            mode_terminal <= 0;
            request_reject <= 0;
        end
        else begin
            expected_name <= expected_name_byte[6:0];
            expected_mode <= expected_mode_byte[6:0];
            name_mark <= name_pos == 9 && (byte_value == "U" || byte_value == "N"
                || (!request_write && byte_value == "C"));
            name_option <= name_pos == TARGET_DOWNLOAD_MARK_POS && !request_write && request_download
                && byte_value == "O";
            name_bad <= byte_value != expected_name;
            name_terminal <= name_pos == TARGET_NAME_BYTES;
            mode_bad <= (byte_value | ASCII_CASE_BIT) != (expected_mode | ASCII_CASE_BIT)
                || (name_pos == 5 && byte_value != 0);
            mode_terminal <= name_pos == 5;
            request_reject <= request_unsupported || (!request_write && status == ST_BUSY)
                || (request_write && status == ST_BUSY && request_download != download_mode)
                || (!request_write && request_download && available_size == 0);
        end
    end
    end

    // 块号递减独立成一拍，避免与报文比较、优先级和状态选择串成一条长链。
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_27) begin
        if (reset) previous_block <= 16'hffff;
        else previous_block <= block_number - 16'd1;
    end
    end

    // 开始构造报文时，先保存端口、报文类型和发送后的返回状态。
    task make_packet;
        input [2:0] kind;
        input [9:0] length;
        input [15:0] source_port, dest_port;
        input [7:0] destination;
        begin
            next_pending_kind = kind;
            next_pending_length = length;
            next_pending_sport = source_port;
            next_pending_dport = dest_port;
            next_pending_after = destination;
            next_state = PACKET_START;
        end
    endtask

    task fail;
        input [7:0] code;
        begin
            next_reason = code;
            next_status = 2'd3;
            next_state = FAILURE;
        end
    endtask

    // 下一状态保持原非阻塞赋值的旧值语义；每组 CE 最多驱动 32 个数据位。
    always @* begin
        next_send_request = send_request;
        next_send_mode = send_mode;
        next_send_length = send_length;
        next_deny_we = deny_we;
        next_deny_wa = deny_wa;
        next_deny_wd = deny_wd;
        next_status = status;
        next_reason = reason;
        next_state = state;
        next_command_op = command_op;
        next_command_block = command_block;
        next_command_sport = command_sport;
        next_command_dport = command_dport;
        next_command_length = command_length;
        next_dispatch_match = dispatch_match;
        next_dispatch_action = dispatch_action;
        next_dispatch_current = dispatch_current;
        next_dispatch_repeat = dispatch_repeat;
        next_main_tid = main_tid;
        next_status_tid = status_tid;
        next_main_peer = main_peer;
        next_status_peer = status_peer;
        next_tid_sequence = tid_sequence;
        next_loaded = loaded;
        next_file_size = file_size;
        next_available_size = available_size;
        next_dl_acked = dl_acked;
        next_dl_remaining = dl_remaining;
        next_dl_read_addr = dl_read_addr;
        next_download_mode = download_mode;
        next_request_download = request_download;
        next_request_unsupported = request_unsupported;
        next_request_resume = request_resume;
        next_deny_empty = deny_empty;
        next_deny_unsupported = deny_unsupported;
        next_deny_pos = deny_pos;
        next_deny_tid = deny_tid;
        next_saved_sport = saved_sport;
        next_saved_dport = saved_dport;
        next_lus_counter = lus_counter;
        next_retry_total = retry_total;
        next_tx_sport = tx_sport;
        next_tx_dport = tx_dport;
        next_consume = consume;
        next_timer = timer;
        next_retries = retries;
        next_rx_re = rx_re;
        next_rx_ra = rx_ra;
        next_tx_we = tx_we;
        next_tx_wa = tx_wa;
        next_tx_wd = tx_wd;
        next_lur_we = lur_we;
        next_lur_wa = lur_wa;
        next_lur_wd = lur_wd;
        next_lur_re = lur_re;
        next_lur_ra = lur_ra;
        next_hdr_we = hdr_we;
        next_hdr_wa = hdr_wa;
        next_hdr_wd = hdr_wd;
        next_hdr_re = hdr_re;
        next_hdr_ra = hdr_ra;
        next_load_we = load_we;
        next_load_wa = load_wa;
        next_load_wd = load_wd;
        next_load_re = load_re;
        next_load_ra = load_ra;
        next_manifest = manifest;
        next_file_kind = file_kind;
        next_block_number = block_number;
        next_ack_number = ack_number;
        next_data_crc = data_crc;
        next_header_crc = header_crc;
        next_expected_crc = expected_crc;
        next_return_state = return_state;
        next_num_return = num_return;
        next_after_tx = after_tx;
        next_lus_return = lus_return;
        next_ack_return = ack_return;
        next_wait_kind = wait_kind;
        next_packet_type = packet_type;
        next_pending_kind = pending_kind;
        next_pending_length = pending_length;
        next_pending_sport = pending_sport;
        next_pending_dport = pending_dport;
        next_pending_after = pending_after;
        next_fetch_source = fetch_source;
        next_fetch_addr = fetch_addr;
        next_byte_value = byte_value;
        next_number = number;
        next_number_left = number_left;
        next_packet_len = packet_len;
        next_packet_pos = packet_pos;
        next_metadata_size = metadata_size;
        next_header_pointer_ok = header_pointer_ok;
        next_pointer_less = pointer_less;
        next_pointer_equal = pointer_equal;
        next_pointer_minimum = pointer_minimum;
        next_header_pointer = header_pointer;
        next_header_name_addr = header_name_addr;
        next_header_name_len = header_name_len;
        next_part_len = part_len;
        next_part_addr = part_addr;
        next_data_name_addr = data_name_addr;
        next_data_name_len = data_name_len;
        next_lus_status = lus_status;
        next_percent = percent;
        next_scaled = scaled;
        next_ratio_h = ratio_h;
        next_ratio_t = ratio_t;
        next_ratio_u = ratio_u;
        next_decimal_tens = decimal_tens;
        next_decimal_rest = decimal_rest;
        next_copy_pos = copy_pos;
        next_copy_len = copy_len;
        next_scan_pos = scan_pos;
        next_name_pos = name_pos;
        next_request_write = request_write;
        next_build_value = build_value;
        next_lus_partlen_pos = lus_partlen_pos;
        next_lus_part_pos = lus_part_pos;
        next_lus_tail_pos = lus_tail_pos;
        next_lus_packet_len = lus_packet_len;
        next_tail_index = tail_index;
        next_head_index = head_index;
        next_part_index = part_index;
        next_name_end = name_end;
        next_mode_start = mode_start;

            next_deny_we = 0;
            next_consume = 0;
            next_rx_re = 0;
            next_tx_we = 0;

            next_lur_we = 0;
            next_lur_re = 0;
            next_hdr_we = 0;
            next_hdr_re = 0;
            next_load_we = 0;
            next_load_re = 0;
            // 加载操作依次交换初始化、状态、请求列表、头文件和数据文件。
            // 卸载操作依次交换初始化、状态、请求列表和数据文件。
            // 状态名里的缩写：LUS 是加载状态文件，LUR 是加载请求列表，LNR 是卸载请求列表。
            // WRQ 和 RRQ 是 TFTP 的写请求和读请求，DL 表示卸载。
            case (state)

                // ======== 第一部分：接收请求并检查文件名和传输模式 ========
                // IDLE：等完整请求，服务已启用且收到请求时转 DISPATCH。
                IDLE : if (packet_pending && enable && configured) begin
                    next_consume = 1;
                    next_command_op = rx_op;
                    next_command_block = rx_block;
                    next_command_length = rx_length;
                    next_command_sport = peer_sp;
                    next_command_dport = peer_dp;
                    next_request_resume = 8'd0;
                    next_state = DISPATCH_CHECK;
                end

                // WAIT_PACKET：等下一报文，超时则重发，重试耗尽时结束本次操作。
                WAIT_PACKET : begin
                    if (packet_pending) begin
                        next_consume = 1;
                        next_command_op = rx_op;
                        next_command_block = rx_block;
                        next_command_length = rx_length;
                        next_command_sport = peer_sp;
                        next_command_dport = peer_dp;
                        next_request_resume = 8'd1;
                        next_state = DISPATCH_CHECK;
                        next_timer = timeout_cycles;
                    end
                    else if (timer <= CE_DIV) begin
                        next_timer = 0;
                        next_state = RETRY_DECIDE;
                    end
                    else next_timer = timer - CE_DIV;
                end

                RETRY_DECIDE : begin
                        if (retries == retry_limit) begin
                            if (wait_kind == WK_LUS_ACK0 || wait_kind == WK_LUS_ACK1) begin
                                next_reason = 8'd5;
                                next_status = 2'd3;
                                next_state = DONE;
                            end
                            else fail (REASON_RETRY_LIMIT);
                        end
                        else begin
                            next_retries = retries + 1'b1;
                            next_retry_total = retry_total + 1'b1;
                            next_packet_pos = 0;
                            next_state = TX_ADDR;
                        end
                end

                // 比较、优先级和动作各占一拍；选择位互斥，动作不再串接长优先级链。
                DISPATCH_CHECK : begin
                    next_dispatch_match[0] = command_dport == request_port
                        && (command_op == 1 || command_op == TFTP_OPCODE_WRQ);
                    next_dispatch_match[1] = command_op == TFTP_OPCODE_ERROR && command_dport == main_tid;
                    next_dispatch_match[2] = command_op == TFTP_OPCODE_ERROR && command_dport == status_tid;
                    next_dispatch_match[3] = wait_kind == WK_LUI_ACK && command_dport == main_tid
                        && command_sport == main_peer
                        && command_op == TFTP_OPCODE_ACK && command_block == 1;
                    next_dispatch_match[4] = wait_kind == WK_LUS_ACK0 && command_dport == status_tid
                        && command_op == TFTP_OPCODE_ACK && command_block == 0;
                    next_dispatch_match[5] = wait_kind == WK_LUS_ACK1 && command_dport == status_tid
                        && command_sport == status_peer
                        && command_op == TFTP_OPCODE_ACK && command_block == 1;
                    next_dispatch_match[6] = (wait_kind == WK_DL_ACK0 && command_dport == main_tid
                        && command_op == TFTP_OPCODE_ACK && command_block == 0);
                    next_dispatch_match[7] = (wait_kind == WK_DL_ACK && command_dport == main_tid
                        && command_sport == main_peer
                        && command_op == TFTP_OPCODE_ACK && command_block == block_number)
                        || (wait_kind == WK_DATA && command_dport == main_tid && command_op == TFTP_OPCODE_DATA
                        && (main_peer == 0 || command_sport == main_peer));
                    next_dispatch_current = command_block == block_number && command_length >= TFTP_HEADER_BYTES
                        && command_length <= TFTP_MAX_PACKET_BYTES;
                    next_dispatch_repeat = command_block == previous_block;
                    next_state = DISPATCH_SELECT;
                end
                DISPATCH_SELECT : begin
                    next_dispatch_action = dispatch_choice;
                    next_state = DISPATCH;
                end
                DISPATCH : case (1'b1) // synthesis parallel_case
                    dispatch_action[0] : begin
                        next_request_write = command_op == TFTP_OPCODE_WRQ;
                        next_request_download = 0;
                        next_request_unsupported = 0;
                        next_name_pos = 0;
                        next_state = NAME;
                    end
                    dispatch_action[1] : fail (REASON_TFTP_ERROR);
                    dispatch_action[2] : begin
                        next_reason = 8'd4;
                        next_status = 2'd3;
                        next_state = DONE;
                    end
                    dispatch_action[3] : begin
                        next_lus_status = LUS_ACCEPTED;
                        next_lus_return = LUS_DONE;
                        next_state = START_LUS;
                    end
                    dispatch_action[4] : begin
                        next_status_peer = command_sport;
                        next_state = LUS_DATA;
                    end
                    dispatch_action[5] : next_state = lus_return;
                    dispatch_action[6] : begin
                        next_main_peer = command_sport;
                        next_block_number = 1;
                        next_state = DL_BLOCK;
                    end
                    dispatch_action[7] : next_state = DATA_DISPATCH;
                    default : next_state = status == ST_BUSY ? WAIT_PACKET : IDLE;
                endcase

                DATA_DISPATCH : if (wait_kind == WK_DL_ACK) next_state = DL_ACK;
                    else begin
                        next_main_peer = command_sport;
                        if (dispatch_current) begin
                            next_copy_len = command_length - TFTP_HEADER_BYTES;
                            next_copy_pos = 0;
                            next_state = DATA_COPY;
                        end
                        else if (dispatch_repeat) begin
                            // 重复数据块只重新发送确认，不再次写入加载区。
                            next_ack_number = command_block;
                            make_packet (PK_ACK, TFTP_HEADER_BYTES, main_tid, command_sport, WAIT_PACKET);
                        end
                        else next_state = 8'd1;
                    end

                // NAME：读取文件名的下一字节，然后转 NAME_BYTE。
                NAME : get_byte (0, { 6'b0, name_pos } + RRQ_NAME_POS, NAME_BYTE);

                // NAME_BYTE：识别操作文件名，名字读完后转 MODE，非法名字返回错误。
                NAME_BYTE : if (name_mark) begin
                    next_request_download = byte_value == "N";
                    next_request_unsupported = byte_value == "C";
                    next_name_pos = name_pos + 1'b1;
                    next_state = NAME;
                end
                else if (name_option) begin
                    next_request_unsupported = 1;
                    next_name_pos = name_pos + 1'b1;
                    next_state = NAME;
                end
                else if (name_bad) begin
                    next_reason = 8'd1;
                    make_packet (PK_ERROR, ERROR_PACKET_BYTES, tid_sequence, command_sport, IDLE);
                end
                else if (name_terminal) begin
                    next_name_pos = 0;
                    next_state = MODE;
                end
                else begin
                    next_name_pos = name_pos + 1'b1;
                    next_state = NAME;
                end

                // MODE：读取传输模式的下一字节，然后转 MODE_BYTE。
                MODE : get_byte (0, { 6'b0, name_pos } + RRQ_MODE_POS, MODE_BYTE);

                // MODE_BYTE：只接受 octet 模式，读完后转 REQUEST_OK，否则返回错误。
                MODE_BYTE : if (mode_bad) begin
                    next_reason = 8'd4;
                    make_packet (PK_ERROR, ERROR_PACKET_BYTES, tid_sequence, command_sport, IDLE);
                    // 按 RFC 2347 忽略模式字段后的选项，继续使用基本文件传输方式。
                end
                else if (mode_terminal) next_state = REQUEST_OK;
                else begin
                    next_name_pos = name_pos + 1'b1;
                    next_state = MODE;
                end

                // REQUEST_OK：接受请求后启动文件流程，无法接受时转 DENY_SEND。
                REQUEST_OK : begin
                    if (request_reject) begin
                        // 信息操作和操作员定义卸载返回状态 1002，不启动后续传输。
                        next_deny_unsupported = request_unsupported;
                        next_deny_empty = status != ST_BUSY;
                        next_deny_pos = 0;
                        next_deny_tid = tid_sequence;
                        next_tid_sequence = tid_sequence + 1'b1;
                        next_saved_sport = tx_sport;
                        next_saved_dport = tx_dport;
                        next_tx_sport = tid_sequence;
                        next_tx_dport = command_sport;
                        next_state = DENY_SEND;
                    end
                    else if (request_write && status == ST_BUSY && wait_kind == WK_LUR) begin
                        next_main_peer = command_sport;
                        next_main_tid = tid_sequence;
                        next_tid_sequence = tid_sequence + 1'b1;
                        next_file_kind = 2'd0;
                        next_metadata_size = 0;
                        next_block_number = 1;
                        next_ack_number = 0;
                        next_wait_kind = 3'd2;
                        make_packet (PK_ACK, TFTP_HEADER_BYTES, tid_sequence, command_sport, WAIT_PACKET);
                    end
                    else if ( ! request_write) begin
                        next_status = 2'd1;
                        next_reason = 8'd0;
                        next_download_mode = request_download;
                        next_main_peer = command_sport;
                        next_main_tid = tid_sequence;
                        next_tid_sequence = tid_sequence + 1'b1;
                        if ( ! request_download) begin
                            next_loaded = 0;
                            next_available_size = 0;
                        end
                        next_file_size = request_download ? available_size : 14'd0;
                        next_dl_acked = 0;
                        next_manifest = 0;
                        next_lus_counter = 0;
                        next_wait_kind = 3'd0;
                        make_packet (PK_LUI, LUI_PACKET_BYTES, tid_sequence, command_sport, WAIT_PACKET);
                    end
                    else begin
                        next_reason = 8'd4;
                        make_packet (PK_ERROR, ERROR_PACKET_BYTES, tid_sequence, command_sport, IDLE);
                    end
                end

                // 拒绝报文单独保存，正常报文 RAM 留给原会话重传。
                DENY_SEND : begin
                    next_deny_we = 1;
                    next_deny_wa = deny_pos;
                    next_deny_wd = denial_byte(deny_pos);
                    next_deny_pos = deny_pos + 1'b1;
                    if (deny_pos == (deny_unsupported ? 12 : 20)) next_state = DENY_FLUSH;
                end
                DENY_FLUSH : begin
                    next_send_mode = 1;
                    next_send_length = deny_unsupported ? 11'd13 : 11'd21;
                    next_send_request = ~send_request;
                    next_state = DENY_FINISH;
                end
                DENY_FINISH : if (send_complete == send_request) begin
                    next_tx_sport = saved_sport;
                    next_tx_dport = saved_dport;
                    next_state = request_resume;
                end

                // FETCH：请求读取指定存储区的字节，然后转 FETCH_WAIT。
                FETCH : begin
                    case (fetch_source)
                        0 : begin
                            next_rx_re = 1;
                            next_rx_ra = fetch_addr[9:0];
                        end
                        1 : begin
                            next_lur_re = 1;
                            next_lur_ra = fetch_addr[8:0];
                        end
                        2 : begin
                            next_hdr_re = 1;
                            next_hdr_ra = fetch_addr[10:0];
                        end
                        3 : begin
                            next_load_re = 1;
                            next_load_ra = fetch_addr;
                        end
                    endcase
                    next_state = FETCH_WAIT;
                end

                // FETCH_WAIT：等待同步读取，然后转 FETCH_CAPTURE。
                FETCH_WAIT : next_state = FETCH_WAIT_A;
                FETCH_WAIT_A : next_state = FETCH_WAIT_B;
                FETCH_WAIT_B : next_state = FETCH_WAIT_C;
                FETCH_WAIT_C : next_state = FETCH_CAPTURE;

                // FETCH_CAPTURE：保存读出的字节，然后转 FETCH_DONE。
                FETCH_CAPTURE : begin
                    case (fetch_source)
                        0 : next_byte_value = rx_q;
                        1 : next_byte_value = lur_q;
                        2 : next_byte_value = hdr_q;
                        3 : next_byte_value = load_q;
                    endcase
                    next_state = FETCH_DONE;
                end

                // FETCH_DONE：返回 get_byte 保存的调用状态。
                FETCH_DONE : next_state = return_state;

                // NUMBER：读取整数的下一字节，然后转 NUMBER_BYTE。
                NUMBER : begin
                    next_return_state = NUMBER_BYTE;
                    next_state = FETCH;
                end

                // NUMBER_BYTE：拼接整数，读够后等待比较结果更新，再返回 num_return。
                NUMBER_BYTE : begin
                    next_number = { number[23:0], byte_value };
                    next_fetch_addr = fetch_addr + 1'b1;
                    next_number_left = number_left - 1'b1;
                    next_state = number_left == 1 ? NUMBER_READY : NUMBER;
                end

                NUMBER_READY : next_state = num_return;

                // 字段位置先算好并寄存，下一拍再选择字节，以缩短组合路径。
                // ======== 第三部分：构造并发送一个报文 ========
                // 报文请求与实际启动分开，参数在本地寄存后再驱动构造器与计数器。
                PACKET_START : begin
                    next_packet_type = pending_kind;
                    next_packet_len = pending_length;
                    next_packet_pos = 0;
                    next_tx_sport = pending_sport;
                    next_tx_dport = pending_dport;
                    next_after_tx = pending_after;
                    next_retries = 0;
                    next_timer = 0;
                    next_state = 8'd60;
                end

                // BUILD_PREP：计算本字节使用的地址，然后转 BUILD。
                BUILD_PREP : begin
                    next_tail_index = packet_pos - lus_tail_pos;
                    next_head_index = packet_pos - LUS_NAME_POS;
                    next_part_index = packet_pos - lus_part_pos;
                    next_name_end = packet_len - RRQ_SUFFIX_BYTES;
                    next_mode_start = packet_len - OCTET_MODE_BYTES;
                    next_dl_read_addr = dl_acked[12:0] + packet_pos - TFTP_DATA_POS;
                    next_state = BUILD_CANDIDATE;
                end

                // 并行候选值需要一拍寄存，随后选择当前报文类型的结果。
                BUILD_CANDIDATE : next_state = BUILD;

                // BUILD：选择本字节内容，需读存储器时先读取，随后转 EMIT。
                BUILD : begin
                    next_build_value = 0;
                    next_state = 8'd15;
                    case (packet_type) // synthesis parallel_case
                        PK_ACK : begin
                            next_build_value = candidate_byte[PK_ACK];
                            if (candidate_read[PK_ACK])
                                get_byte(candidate_source[PK_ACK], candidate_address[PK_ACK], EMIT);
                        end
                        PK_LUI : begin
                            next_build_value = candidate_byte[PK_LUI];
                            if (candidate_read[PK_LUI])
                                get_byte(candidate_source[PK_LUI], candidate_address[PK_LUI], EMIT);
                        end
                        PK_ERROR : begin
                            next_build_value = candidate_byte[PK_ERROR];
                            if (candidate_read[PK_ERROR])
                                get_byte(candidate_source[PK_ERROR], candidate_address[PK_ERROR], EMIT);
                        end
                        PK_LUS_WRQ : begin
                            next_build_value = candidate_byte[PK_LUS_WRQ];
                            if (candidate_read[PK_LUS_WRQ])
                                get_byte(candidate_source[PK_LUS_WRQ], candidate_address[PK_LUS_WRQ], EMIT);
                        end
                        PK_RRQ : begin
                            next_build_value = candidate_byte[PK_RRQ];
                            if (candidate_read[PK_RRQ])
                                get_byte(candidate_source[PK_RRQ],
                                    candidate_source[PK_RRQ] == 1 ? rrq_header_read : rrq_data_read, EMIT);
                        end
                        PK_DL_DATA : begin
                            next_build_value = candidate_byte[PK_DL_DATA];
                            if (candidate_read[PK_DL_DATA])
                                get_byte(candidate_source[PK_DL_DATA], candidate_address[PK_DL_DATA], EMIT);
                        end
                        PK_LUS : begin
                            next_build_value = candidate_byte[PK_LUS];
                            if (candidate_read[PK_LUS])
                                get_byte(candidate_source[PK_LUS], candidate_address[PK_LUS], EMIT);
                        end
                        default : ;
                    endcase
                end

                // EMIT：写入待发字节，未写完转 BUILD_PREP，写完转 BUILD_FLUSH。
                EMIT : begin
                    next_tx_we = 1;
                    next_tx_wa = packet_pos;
                    next_tx_wd = return_state == EMIT ? byte_value : build_value;
                    next_return_state = 0;
                    next_packet_pos = packet_pos + 1'b1;
                    next_state = packet_pos + 1'b1 == packet_len ? BUILD_FLUSH : BUILD_PREP;
                end

                // BUILD_FLUSH：等最后一次写入完成，然后转 TX_ADDR。
                BUILD_FLUSH : begin
                    next_packet_pos = 0;
                    next_state = TX_ADDR;
                end

                // 整帧交给全速发送器，末字节握手后再启动重传计时。
                TX_ADDR : begin
                    next_send_mode = 0;
                    next_send_length = {1'b0, packet_len};
                    next_send_request = ~send_request;
                    next_state = TX_SEND;
                end
                TX_SEND : if (send_complete == send_request) begin
                    next_state = after_tx;
                    next_timer = timeout_cycles;
                end

                // ======== 第四部分：计算进度并发送状态文件 ========
                // START_LUS：准备状态文件的端口和进度，然后转 RATIO_SCALE。
                START_LUS : begin
                    next_lus_counter = lus_counter + 1'b1;
                    next_status_tid = tid_sequence;
                    next_tid_sequence = tid_sequence + 1'b1;
                    next_percent = 0;
                    next_scaled = download_mode ? {6'b0, dl_acked} : {6'b0, loaded};
                    next_state = RATIO_SCALE;
                end

                // RATIO_SCALE：乘 100；RATIO_TEST 先寄存比较和差值，再由 RATIO_SUB 执行动作。
                RATIO_SCALE : begin
                    next_scaled = (scaled << 6) + (scaled << 5) + (scaled << 2);
                    next_state = RATIO_TEST;
                end

                // RATIO_SUB：用反复相减求百分比，求完后转 RATIO_DEC。
                RATIO_TEST : next_state = RATIO_SUB;

                RATIO_SUB : begin
                    if (ratio_continue) begin
                        next_scaled = ratio_remainder;
                        next_state = RATIO_TEST;
                        next_percent = percent + 1'b1;
                    end
                    else begin
                        next_decimal_tens = 0;
                        next_decimal_rest = lus_status == LUS_COMPLETED ? 7'd0 : percent;
                        next_ratio_h = lus_status == LUS_COMPLETED ? "1" : " ";
                        next_state = RATIO_DEC;
                    end
                end

                // RATIO_DEC：把百分比变成十进制数字，完成后转 LUS_WRQ。
                RATIO_DEC : if (decimal_rest >= DECIMAL_BASE) begin
                    next_decimal_rest = decimal_rest - DECIMAL_BASE;
                    next_decimal_tens = decimal_tens + 1'b1;
                end
                else begin
                    next_ratio_t = lus_status == LUS_COMPLETED ? "0" : decimal_tens == 0 ? " " : ASCII_ZERO + decimal_tens;
                    next_ratio_u = ASCII_ZERO + decimal_rest;
                    next_state = LUS_WRQ;
                end

                // LUS_WRQ：请求发送状态文件，发完后等待第零块确认。
                LUS_WRQ : begin
                    next_wait_kind = 3'd3;
                    make_packet (PK_LUS_WRQ, LUS_WRQ_PACKET_BYTES, status_tid, request_port, WAIT_PACKET);
                end

                // LUS_DATA：发送状态文件数据，发完后等待第一块确认。
                LUS_DATA : begin
                    next_wait_kind = 3'd4;
                    make_packet (PK_LUS, manifest ? lus_packet_len : LUS_SHORT_PACKET_BYTES, status_tid,
                                 status_peer, WAIT_PACKET);
                end

                // LUS_DONE：初始状态文件获确认后转 IDLE，等待文件列表。
                LUS_DONE : begin
                    next_wait_kind = 3'd1;
                    next_state = 8'd0;
                end

                // ACK_MAIN：构造当前数据块的确认，发送后返回 ack_return。
                ACK_MAIN : begin
                    next_wait_kind = 3'd2;
                    make_packet (PK_ACK, TFTP_HEADER_BYTES, main_tid, main_peer, ack_return);
                end

                // ======== 第五部分：接收并保存文件的一块数据 ========
                // DATA_COPY：读下一有效字节，转 DATA_BYTE；全部读完转 DATA_END。
                DATA_COPY : begin
                    if (copy_pos == copy_len) next_state = DATA_END;
                    else get_byte (0, copy_pos + TFTP_HEADER_BYTES, DATA_BYTE);
                end

                // DATA_BYTE：保存一个文件字节并更新校验，再转 DATA_COPY。
                DATA_BYTE : begin
                    if (file_kind == FILE_LIST) begin
                        if (metadata_size >= LUR_BUFFER_BYTES) fail (REASON_LENGTH);
                        else begin
                            next_lur_we = 1;
                            next_lur_wa = metadata_size[8:0];
                            next_lur_wd = byte_value;
                            next_metadata_size = metadata_size + 1'b1;
                            next_state = DATA_COPY;
                        end
                    end
                    else if (file_kind == FILE_HEADER) begin
                        if (metadata_size >= HEADER_BUFFER_BYTES) fail (REASON_LENGTH);
                        else begin
                            next_hdr_we = 1;
                            next_hdr_wa = metadata_size[10:0];
                            next_hdr_wd = byte_value;
                            next_metadata_size = metadata_size + 1'b1;
                            next_state = DATA_COPY;
                        end
                    end
                    else begin
                        if (loaded >= LOAD_BUFFER_BYTES) fail (REASON_LENGTH);
                        else begin
                            next_load_we = 1;
                            next_load_wa = loaded[12:0];
                            next_load_wd = byte_value;
                            next_loaded = loaded + 1'b1;
                            next_data_crc = crc16 (data_crc, byte_value);
                            next_state = DATA_COPY;
                        end
                    end
                    next_copy_pos = copy_pos + 1'b1;
                end

                // DATA_END：确认当前块；短块结束文件，再转对应的文件检查过程。
                DATA_END : begin
                    next_block_number = block_number + 1'b1;
                    next_ack_number = command_block;
                    if (copy_len < TFTP_BLOCK_BYTES) begin
                        if (file_kind == FILE_LIST) begin
                            next_ack_return = LUR_START;
                            next_state = ACK_MAIN;
                        end
                        else if (file_kind == FILE_HEADER) begin
                            next_ack_return = HEADER_START;
                            next_state = ACK_MAIN;
                        end
                        else next_state = DATA_COUNTS_WAIT;
                    end
                    else begin
                        next_ack_return = 8'd1;
                        if (file_kind == FILE_DATA && block_number == 1) begin
                            next_lus_status = 16'd2;
                            next_lus_return = ACK_MAIN;
                            next_state = START_LUS;
                        end
                        else next_state = ACK_MAIN;
                    end
                end

                // ======== 第六部分：检查加载请求列表和卸载请求列表 ========
                // LUR_START：读取加载列表总长，然后转 LUR_LENGTH。
                LUR_START : get_number (1, 0, 4, LUR_LENGTH);

                // LUR_LENGTH：核对总长，通过后读取协议版本，否则报告失败。
                LUR_LENGTH : if (!number_metadata_ok) fail (REASON_DESCRIPTION);
                else get_number (1, 4, 2, LUR_VERSION);

                // LUR_VERSION：检查 A3/A4 版本，通过后读取文件数量，否则报告失败。
                LUR_VERSION : if (!number_version_ok) fail (REASON_DESCRIPTION);
                else get_number (1, 6, 2, LUR_COUNT);

                // LUR_COUNT：检查文件数量为一，通过后读取文件名长度，否则报告失败。
                LUR_COUNT : if (!number_one) fail (REASON_DESCRIPTION);
                else get_byte (1, 8, LUR_HLEN);

                // LUR_HLEN：检查文件名长度，加载时继续读件号，卸载时转 LNR_USER。
                LUR_HLEN : if (byte_value < 2 || byte_value > MAX_FILENAME_BYTES) fail (REASON_DESCRIPTION);
                else begin
                    next_header_name_len = byte_value[6:0];
                    next_header_name_addr = 9;
                    get_byte (1, 11'd9 + byte_value, download_mode ? LNR_USER : LUR_PLEN);
                end

                // LUR_PLEN：检查件号长度，通过后转 LUR_OFFSETS，否则报告失败。
                LUR_PLEN : if (byte_value < 2 || byte_value > MAX_FILENAME_BYTES) fail (REASON_DESCRIPTION);
                else begin
                    next_part_len = byte_value[6:0];
                    next_part_addr = 10'd10 + header_name_len;
                    next_lus_partlen_pos = LUS_NAME_POS + header_name_len;
                    next_lus_part_pos = LUS_PART_POS_BASE + header_name_len;
                    next_state = LUR_OFFSETS;
                end

                // LUR_OFFSETS：计算状态文件中变长字段的位置，然后转 LUR_READY。
                LUR_OFFSETS : begin
                    next_lus_tail_pos = lus_part_pos + part_len;
                    next_state = LUR_READY;
                end

                // LUR_READY：报告列表已接受，状态获确认后转 RRQ_HEADER。
                LUR_READY : begin
                    next_lus_packet_len = lus_tail_pos + LUS_TAIL_BYTES;
                    next_manifest = 1;
                    next_lus_status = 16'd2;
                    next_lus_return = RRQ_HEADER;
                    next_state = START_LUS;
                end

                // 卸载列表的文件名之后是用户数据，卸载状态不含加载件号字段。
                // LNR_USER：检查卸载列表的用户数据长度，通过后转 LNR_NAME。
                LNR_USER : begin
                    next_manifest = 1;
                    next_lus_partlen_pos = LUS_NAME_POS + header_name_len;
                    next_lus_tail_pos = LUS_NAME_POS + header_name_len;
                    next_lus_packet_len = LUS_DOWNLOAD_LENGTH_BASE + header_name_len;
                    next_scan_pos = 0;
                    next_state = LNR_USER_CHECK;
                end

                LNR_USER_CHECK : if (metadata_size != lnr_expected_length || !lnr_name_ok)
                    fail(REASON_DESCRIPTION);
                else next_state = LNR_NAME;

                // LNR_NAME：读取卸载文件名的下一字节，然后转 LNR_BYTE。
                LNR_NAME : get_byte(1, LNR_NAME_POS + scan_pos, LNR_BYTE);

                // LNR_BYTE：核对 MEMORY.BIN，完全匹配后转 LNR_READY，否则报告失败。
                LNR_BYTE : if (byte_value != memory_name(scan_pos[6:0])) fail(REASON_DESCRIPTION);
                else if (scan_pos == TARGET_DOWNLOAD_MARK_POS) next_state = LNR_READY;
                else begin
                    next_scan_pos = scan_pos + 1'b1;
                    next_state = LNR_NAME;
                end

                // LNR_READY：报告卸载列表已接受，状态获确认后转 DL_WRQ。
                LNR_READY : begin
                    next_lus_status = 16'd2;
                    next_lus_return = DL_WRQ;
                    next_state = START_LUS;
                end

                // DL_WRQ：请求发送 MEMORY.BIN，发完后等待第零块确认。
                DL_WRQ : begin
                    next_main_tid = tid_sequence;
                    next_main_peer = 0;
                    next_tid_sequence = tid_sequence + 1'b1;
                    next_wait_kind = WK_DL_ACK0;
                    make_packet(PK_RRQ, DOWNLOAD_RRQ_PACKET_BYTES, tid_sequence, request_port, WAIT_PACKET);
                end

                // DL_BLOCK：计算剩余待卸载字节数，然后转 DL_SIZE。
                DL_BLOCK : begin
                    next_dl_remaining = file_size - dl_acked;
                    next_state = DL_SIZE;
                end

                // DL_SIZE：发送最多 512 字节，发完后等待对应块的确认。
                DL_SIZE : begin
                    next_copy_len = dl_remaining >= TFTP_BLOCK_BYTES ? TFTP_BLOCK_BYTES : dl_remaining[10:0];
                    next_wait_kind = WK_DL_ACK;
                    make_packet(PK_DL_DATA,
                                dl_remaining >= TFTP_BLOCK_BYTES ? TFTP_MAX_PACKET_BYTES
                                                                : dl_remaining[9:0] + TFTP_DATA_POS,
                                main_tid, main_peer, WAIT_PACKET);
                end

                // DL_ACK：更新已确认字节数，未完转 DL_BLOCK，完成则发送成功状态。
                DL_ACK : begin
                    next_dl_acked = dl_acked + copy_len;
                    next_block_number = block_number + 1'b1;
                    if (copy_len < TFTP_BLOCK_BYTES) begin
                        next_lus_status = 16'd3;
                        next_lus_return = DONE;
                        next_state = START_LUS;
                    end
                    else if (block_number == 1) begin
                        next_lus_status = 16'd2;
                        next_lus_return = DL_BLOCK;
                        next_state = START_LUS;
                    end
                    else next_state = DL_BLOCK;
                end

                // ======== 第七部分：获取并检查头文件和数据文件 ========
                // RRQ_HEADER：请求加载头文件，发完后等待第一块数据。
                RRQ_HEADER : begin
                    next_file_kind = 2'd1;
                    next_metadata_size = 0;
                    next_main_tid = tid_sequence;
                    next_main_peer = 0;
                    next_tid_sequence = tid_sequence + 1'b1;
                    next_block_number = 1;
                    next_wait_kind = 3'd2;
                    make_packet (PK_RRQ, header_name_len + 8, tid_sequence, request_port, WAIT_PACKET);
                end

                // HEADER_START：读取头文件字数，然后转 HEADER_LENGTH。
                HEADER_START : get_number (2, 0, 4, HEADER_LENGTH);

                // HEADER_LENGTH：核对字数与实际长度，通过后读取格式版本。
                HEADER_LENGTH : if (!number_header_length_ok) fail (REASON_DESCRIPTION);
                else get_number (2, 4, 2, HEADER_VERSION);

                // HEADER_VERSION：检查版本为 0x8002，通过后读取数据文件指针。
                HEADER_VERSION : if (!number_header_version_ok) fail (REASON_DESCRIPTION);
                else get_number (2, 14, 4, HEADER_PTR);

                // HEADER_PTR：先逐字节比较指针与上界，再合并比较结果。
                HEADER_PTR : begin
                    next_pointer_minimum = number >= HEADER_DATA_PTR_MIN_WORDS;
                    next_pointer_less[0] = pointer_bytes[7:0] < header_limit[7:0];
                    next_pointer_equal[0] = pointer_bytes[7:0] == header_limit[7:0];
                    next_pointer_less[1] = pointer_bytes[15:8] < header_limit[15:8];
                    next_pointer_equal[1] = pointer_bytes[15:8] == header_limit[15:8];
                    next_pointer_less[2] = pointer_bytes[23:16] < header_limit[23:16];
                    next_pointer_equal[2] = pointer_bytes[23:16] == header_limit[23:16];
                    next_pointer_less[3] = pointer_bytes[31:24] < header_limit[31:24];
                    next_pointer_equal[3] = pointer_bytes[31:24] == header_limit[31:24];
                    next_state = HEADER_PTR_MERGE;
                end

                HEADER_PTR_MERGE : begin
                    next_header_pointer_ok = pointer_minimum && (pointer_less[3]
                        || (pointer_equal[3] && pointer_less[2])
                        || (pointer_equal[3] && pointer_equal[2] && pointer_less[1])
                        || (pointer_equal[3] && pointer_equal[2] && pointer_equal[1] && pointer_less[0]));
                    next_state = HEADER_PTR_CHECK;
                end

                // HEADER_PTR_CHECK：合法时开始 HEADER_CRC，否则报告失败。
                HEADER_PTR_CHECK : if ( ! header_pointer_ok) fail (REASON_DESCRIPTION);
                else begin
                    next_header_pointer = number[10:0] << 1;
                    next_header_crc = CRC16_INIT;
                    next_scan_pos = 0;
                    next_state = HEADER_CRC;
                end

                // HEADER_CRC：读取下一校验字节；读完覆盖区后读取预期校验值。
                HEADER_CRC : if (scan_pos == header_limit)
                    get_number (2, scan_pos, 2, HEADER_CRC_CHECK);
                else get_byte (2, scan_pos, HEADER_CRC_BYTE);

                // HEADER_CRC_BYTE：更新头文件校验值，再转 HEADER_CRC。
                HEADER_CRC_BYTE : begin
                    next_header_crc = crc16 (header_crc, byte_value);
                    next_scan_pos = scan_pos + 1'b1;
                    next_state = HEADER_CRC;
                end

                // HEADER_CRC_CHECK：核对头文件校验值，通过后读取数据文件数量。
                HEADER_CRC_CHECK : if (!number_crc_ok) fail (REASON_CHECKSUM);
                else get_number (2, header_pointer, 2, HEADER_COUNT);

                // HEADER_COUNT：要求只有一个数据文件，通过后读取文件名长度。
                HEADER_COUNT : if (!number_one) fail (REASON_DESCRIPTION);
                else get_number (2, header_pointer + 4, 2, HEADER_NLEN);

                // HEADER_NLEN：检查文件名长度，通过后定位件号字段。
                HEADER_NLEN : if (!number_name_ok) fail (REASON_DESCRIPTION);
                else begin
                    next_data_name_len = number[6:0];
                    next_data_name_addr = header_pointer + 12'd6;
                    get_number (2, header_pointer + 6 + ((number + 1) & EVEN_MASK), 2, HEADER_PLEN);
                end

                // HEADER_PLEN：检查件号长度并处理偶数字节对齐，然后转 HEADER_SIZE。
                HEADER_PLEN : if (!number_part_ok) fail (REASON_DESCRIPTION);
                else begin
                    next_scan_pos = fetch_addr[10:0] + number_even_length[10:0];
                    next_state = HEADER_SIZE;
                end

                // HEADER_SIZE：读取数据文件的字数，然后转 HEADER_DCRC。
                HEADER_SIZE : get_number (2, scan_pos, 4, HEADER_DCRC);

                // HEADER_DCRC：检查数据量不超过 8 KiB，通过后读取预期校验值。
                HEADER_DCRC : if (!number_data_size_ok) fail (REASON_LENGTH);
                else begin
                    next_file_size = number[12:0] << 1;
                    get_number (2, scan_pos + 4, 2, HEADER_READY);
                end

                // HEADER_READY：保存预期校验值并报告进度，获确认后转 RRQ_DATA。
                HEADER_READY : begin
                    next_expected_crc = number[15:0];
                    next_lus_status = 16'd2;
                    next_lus_return = RRQ_DATA;
                    next_state = START_LUS;
                end

                // RRQ_DATA：请求数据文件，发完后等待第一块数据。
                RRQ_DATA : begin
                    next_file_kind = 2'd2;
                    next_loaded = 0;
                    next_data_crc = CRC16_INIT;
                    next_main_tid = tid_sequence;
                    next_main_peer = 0;
                    next_tid_sequence = tid_sequence + 1'b1;
                    next_block_number = 1;
                    next_wait_kind = 3'd2;
                    make_packet (PK_RRQ, data_name_len + 9, tid_sequence, request_port, WAIT_PACKET);
                end

                // DATA_CHECK：核对文件大小和校验值，通过并确认末块后转 DATA_SUCCESS。
                DATA_COUNTS_WAIT : next_state = DATA_CHECK;
                DATA_CHECK : if (!load_size_ok) fail (REASON_LENGTH);
                else if (data_crc != expected_crc) fail (REASON_CHECKSUM);
                else begin
                    next_ack_return = DATA_SUCCESS;
                    next_state = ACK_MAIN;
                end

                // DATA_SUCCESS：公布加载区有效长度并报告成功，获确认后转 DONE。
                DATA_SUCCESS : begin
                    next_available_size = loaded;
                    next_lus_status = 16'd3;
                    next_lus_return = DONE;
                    next_state = START_LUS;
                end

                // ======== 第八部分：报告失败并结束本次操作 ========
                // FAILURE：发送文件传输错误，发送完成后转 FAILURE_SENT。
                FAILURE : begin
                    make_packet (PK_ERROR, ERROR_PACKET_BYTES, main_tid,
                                 main_peer == 0 ? request_port : main_peer, FAILURE_SENT);
                end

                // FAILURE_SENT：发送失败状态，确认或重试结束后转 DONE。
                FAILURE_SENT : begin
                    next_lus_status = LUS_ABORTED;
                    next_lus_return = DONE;
                    next_state = START_LUS;
                end

                // DONE：保存最终结果，然后转 IDLE 等待下一次操作。
                DONE : begin
                    next_status = reason == REASON_NONE ? ST_SUCCESS : ST_FAILED;
                    next_state = 8'd0;
                    next_wait_kind = 3'd1;
                end

                default : next_state = 8'd0;
            endcase
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_28) begin
        if (reset) begin
            send_request <= 0;
            send_mode <= 0;
            send_length <= 0;
            deny_we <= 0;
            deny_wa <= 0;
            deny_wd <= 0;
            status <= ST_IDLE;
        end
        else begin
            send_request <= next_send_request;
            send_mode <= next_send_mode;
            send_length <= next_send_length;
            deny_we <= next_deny_we;
            deny_wa <= next_deny_wa;
            deny_wd <= next_deny_wd;
            status <= next_status;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_29) begin
        if (reset) begin
            reason <= 8'd0;
            state <= 8'd0;
            command_op <= 0;
        end
        else begin
            reason <= next_reason;
            state <= next_state;
            command_op <= next_command_op;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_30) begin
        if (reset) begin
            command_block <= 0;
            command_sport <= 0;
        end
        else begin
            command_block <= next_command_block;
            command_sport <= next_command_sport;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_31) begin
        if (reset) begin
            command_dport <= 0;
            command_length <= 0;
        end
        else begin
            command_dport <= next_command_dport;
            command_length <= next_command_length;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_32) begin
        if (reset) begin
            dispatch_match <= 0;
            dispatch_action <= 0;
            dispatch_current <= 0;
            dispatch_repeat <= 0;
        end
        else begin
            dispatch_match <= next_dispatch_match;
            dispatch_action <= next_dispatch_action;
            dispatch_current <= next_dispatch_current;
            dispatch_repeat <= next_dispatch_repeat;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_33) begin
        if (reset) begin
            main_tid <= MAIN_TID_INIT;
            status_tid <= STATUS_TID_INIT;
        end
        else begin
            main_tid <= next_main_tid;
            status_tid <= next_status_tid;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_34) begin
        if (reset) begin
            main_peer <= 0;
            status_peer <= 0;
        end
        else begin
            main_peer <= next_main_peer;
            status_peer <= next_status_peer;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_35) begin
        if (reset) begin
            tid_sequence <= TID_SEQUENCE_INIT;
            loaded <= 0;
        end
        else begin
            tid_sequence <= next_tid_sequence;
            loaded <= next_loaded;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_36) begin
        if (reset) begin
            file_size <= 0;
            available_size <= 0;
        end
        else begin
            file_size <= next_file_size;
            available_size <= next_available_size;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_37) begin
        if (reset) begin
            dl_acked <= 0;
            dl_remaining <= 0;
        end
        else begin
            dl_acked <= next_dl_acked;
            dl_remaining <= next_dl_remaining;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_38) begin
        if (reset) begin
            dl_read_addr <= 0;
            download_mode <= 0;
            request_download <= 0;
            request_unsupported <= 0;
            request_resume <= 8'd0;
            deny_empty <= 0;
            deny_unsupported <= 0;
            deny_pos <= 0;
        end
        else begin
            dl_read_addr <= next_dl_read_addr;
            download_mode <= next_download_mode;
            request_download <= next_request_download;
            request_unsupported <= next_request_unsupported;
            request_resume <= next_request_resume;
            deny_empty <= next_deny_empty;
            deny_unsupported <= next_deny_unsupported;
            deny_pos <= next_deny_pos;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_39) begin
        if (reset) begin
            deny_tid <= DENY_TID_INIT;
            saved_sport <= 0;
        end
        else begin
            deny_tid <= next_deny_tid;
            saved_sport <= next_saved_sport;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_40) begin
        if (reset) begin
            saved_dport <= 0;
            lus_counter <= 0;
        end
        else begin
            saved_dport <= next_saved_dport;
            lus_counter <= next_lus_counter;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_41) begin
        if (reset) begin
            retry_total <= 0;
        end
        else begin
            retry_total <= next_retry_total;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_42) begin
        if (reset) begin
            tx_sport <= 0;
            tx_dport <= 0;
        end
        else begin
            tx_sport <= next_tx_sport;
            tx_dport <= next_tx_dport;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_43) begin
        if (reset) begin
            consume <= 0;
        end
        else begin
            consume <= next_consume;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_44) begin
        if (reset) begin
            timer <= 0;
        end
        else begin
            timer <= next_timer;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_45) begin
        if (reset) begin
            retries <= 0;
            rx_re <= 0;
            rx_ra <= 0;
            tx_we <= 0;
            tx_wa <= 0;
        end
        else begin
            retries <= next_retries;
            rx_re <= next_rx_re;
            rx_ra <= next_rx_ra;
            tx_we <= next_tx_we;
            tx_wa <= next_tx_wa;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_46) begin
        if (reset) begin
            tx_wd <= 0;
            lur_we <= 0;
            lur_wa <= 0;
            lur_wd <= 0;
            lur_re <= 0;
        end
        else begin
            tx_wd <= next_tx_wd;
            lur_we <= next_lur_we;
            lur_wa <= next_lur_wa;
            lur_wd <= next_lur_wd;
            lur_re <= next_lur_re;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_47) begin
        if (reset) begin
            lur_ra <= 0;
            hdr_we <= 0;
            hdr_wa <= 0;
            hdr_wd <= 0;
            hdr_re <= 0;
        end
        else begin
            lur_ra <= next_lur_ra;
            hdr_we <= next_hdr_we;
            hdr_wa <= next_hdr_wa;
            hdr_wd <= next_hdr_wd;
            hdr_re <= next_hdr_re;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_48) begin
        if (reset) begin
            hdr_ra <= 0;
            load_we <= 0;
            load_wa <= 0;
        end
        else begin
            hdr_ra <= next_hdr_ra;
            load_we <= next_load_we;
            load_wa <= next_load_wa;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_49) begin
        if (reset) begin
            load_wd <= 0;
            load_re <= 0;
            load_ra <= 0;
            manifest <= 0;
            file_kind <= 2'd0;
        end
        else begin
            load_wd <= next_load_wd;
            load_re <= next_load_re;
            load_ra <= next_load_ra;
            manifest <= next_manifest;
            file_kind <= next_file_kind;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_50) begin
        if (reset) begin
            block_number <= 0;
            ack_number <= 0;
        end
        else begin
            block_number <= next_block_number;
            ack_number <= next_ack_number;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_51) begin
        if (reset) begin
            data_crc <= CRC16_INIT;
            header_crc <= CRC16_INIT;
        end
        else begin
            data_crc <= next_data_crc;
            header_crc <= next_header_crc;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_52) begin
        if (reset) begin
            expected_crc <= 0;
            return_state <= 0;
            num_return <= 0;
        end
        else begin
            expected_crc <= next_expected_crc;
            return_state <= next_return_state;
            num_return <= next_num_return;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_53) begin
        if (reset) begin
            after_tx <= 0;
            lus_return <= 0;
            ack_return <= 0;
            wait_kind <= 0;
            packet_type <= 0;
        end
        else begin
            after_tx <= next_after_tx;
            lus_return <= next_lus_return;
            ack_return <= next_ack_return;
            wait_kind <= next_wait_kind;
            packet_type <= next_packet_type;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_54) begin
        if (reset) begin
            pending_kind <= 0;
            pending_length <= 0;
            pending_sport <= 0;
        end
        else begin
            pending_kind <= next_pending_kind;
            pending_length <= next_pending_length;
            pending_sport <= next_pending_sport;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_55) begin
        if (reset) begin
            pending_dport <= 0;
            pending_after <= 0;
            fetch_source <= 0;
        end
        else begin
            pending_dport <= next_pending_dport;
            pending_after <= next_pending_after;
            fetch_source <= next_fetch_source;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_56) begin
        if (reset) begin
            fetch_addr <= 0;
            byte_value <= 0;
        end
        else begin
            fetch_addr <= next_fetch_addr;
            byte_value <= next_byte_value;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_57) begin
        if (reset) begin
            number <= 0;
        end
        else begin
            number <= next_number;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_58) begin
        if (reset) begin
            number_left <= 0;
            packet_len <= 0;
            packet_pos <= 0;
        end
        else begin
            number_left <= next_number_left;
            packet_len <= next_packet_len;
            packet_pos <= next_packet_pos;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_59) begin
        if (reset) begin
            metadata_size <= 0;
            header_pointer_ok <= 0;
            pointer_less <= 0;
            pointer_equal <= 0;
            pointer_minimum <= 0;
        end
        else begin
            metadata_size <= next_metadata_size;
            header_pointer_ok <= next_header_pointer_ok;
            pointer_less <= next_pointer_less;
            pointer_equal <= next_pointer_equal;
            pointer_minimum <= next_pointer_minimum;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_60) begin
        if (reset) begin
            header_pointer <= 0;
            header_name_addr <= 0;
            header_name_len <= 0;
        end
        else begin
            header_pointer <= next_header_pointer;
            header_name_addr <= next_header_name_addr;
            header_name_len <= next_header_name_len;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_61) begin
        if (reset) begin
            part_len <= 0;
            part_addr <= 0;
            data_name_addr <= 0;
        end
        else begin
            part_len <= next_part_len;
            part_addr <= next_part_addr;
            data_name_addr <= next_data_name_addr;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_62) begin
        if (reset) begin
            data_name_len <= 0;
            lus_status <= LUS_NONE;
            percent <= 0;
        end
        else begin
            data_name_len <= next_data_name_len;
            lus_status <= next_lus_status;
            percent <= next_percent;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_63) begin
        if (reset) begin
            scaled <= 0;
            ratio_h <= 0;
        end
        else begin
            scaled <= next_scaled;
            ratio_h <= next_ratio_h;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_64) begin
        if (reset) begin
            ratio_t <= 0;
            ratio_u <= 0;
            decimal_tens <= 0;
            decimal_rest <= 0;
        end
        else begin
            ratio_t <= next_ratio_t;
            ratio_u <= next_ratio_u;
            decimal_tens <= next_decimal_tens;
            decimal_rest <= next_decimal_rest;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_65) begin
        if (reset) begin
            copy_pos <= 0;
            copy_len <= 0;
        end
        else begin
            copy_pos <= next_copy_pos;
            copy_len <= next_copy_len;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_66) begin
        if (reset) begin
            scan_pos <= 0;
            name_pos <= 0;
            request_write <= 0;
            build_value <= 0;
        end
        else begin
            scan_pos <= next_scan_pos;
            name_pos <= next_name_pos;
            request_write <= next_request_write;
            build_value <= next_build_value;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_67) begin
        if (reset) begin
            lus_partlen_pos <= 0;
            lus_part_pos <= 0;
            lus_tail_pos <= 0;
        end
        else begin
            lus_partlen_pos <= next_lus_partlen_pos;
            lus_part_pos <= next_lus_part_pos;
            lus_tail_pos <= next_lus_tail_pos;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_68) begin
        if (reset) begin
            lus_packet_len <= 0;
            tail_index <= 0;
            head_index <= 0;
        end
        else begin
            lus_packet_len <= next_lus_packet_len;
            tail_index <= next_tail_index;
            head_index <= next_head_index;
        end
    end
    end
    always @(posedge clk) begin
        // 外层 CE 包含 reset；同步复位优先级不变，并强制保留原生使能引脚。
        if (ce_69) begin
        if (reset) begin
            part_index <= 0;
            name_end <= 0;
            mode_start <= 0;
        end
        else begin
            part_index <= next_part_index;
            name_end <= next_name_end;
            mode_start <= next_mode_start;
        end
    end
    end

    // 比较和动作分拍；两个 CE 组分别只有 30 位和 10 位。
    always @(posedge clk) begin
        if (ce_70) begin
            if (reset) begin
                ratio_remainder <= 0;
                ratio_continue <= 0;
                number_metadata_ok <= 0;
                number_version_ok <= 0;
                number_one <= 0;
                number_header_length_ok <= 0;
                number_header_version_ok <= 0;
                number_crc_ok <= 0;
                number_name_ok <= 0;
                number_part_ok <= 0;
                number_data_size_ok <= 0;
            end
            else begin
                ratio_remainder <= scaled - file_size;
                ratio_continue <= file_size != 0 && scaled >= file_size && percent < MAX_PROGRESS_PERCENT;
                number_metadata_ok <= number == metadata_size;
                number_version_ok <= number == VERSION_A3 || number == VERSION_A4;
                number_one <= number == 1;
                number_header_length_ok <= (number << 1) == metadata_size && metadata_size >= HEADER_MIN_BYTES;
                number_header_version_ok <= number == HEADER_FILE_VERSION;
                number_crc_ok <= number == header_crc;
                number_name_ok <= number != 0 && number <= MAX_HEADER_NAME_CHARS;
                number_part_ok <= number <= MAX_FILENAME_BYTES;
                number_data_size_ok <= number != 0 && number <= MAX_DATA_WORDS;
            end
        end
    end
    always @(posedge clk) begin
        if (ce_71) begin
            if (reset) begin
                lnr_expected_length <= 0;
                lnr_name_ok <= 0;
            end
            else begin
                lnr_expected_length <= LUR_FIXED_BYTES + header_name_len + byte_value;
                lnr_name_ok <= header_name_len == TARGET_NAME_BYTES;
            end
        end
    end

endmodule
