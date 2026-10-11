// ARINC 615A加卸载目标，支持A4/A3协议文件和TFTP停等传输。
// rx_*接收服务消息，tx_*发请求/状态，cfg_*配置并读回加载RAM。
// 主文件与LUS各有TID；FETCH流水线读RAM，BUILD/EMIT逐字节成包。
// 上传为665-1单头文件/单数据文件；介质定义卸载读回最近成功加载的8 KiB RAM。
module afdx_615a (
    // clk/reset 为同步控制，enable 为核心就绪；配置使能后才认领加卸载端口。
    input wire clk, reset, enable,
    // cfg_* 设置目标/VL/超时/版本，并读状态、加载量和加载 RAM；extra_data 返回端口与重试参数。
    input wire cfg_we,
    input wire [7:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata, cfg_extra_data,
    // tx_* 以 valid/ready 发送 UDP 服务载荷，last 为报文尾；vl/sport/dport 给出 TFTP 会话。
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output reg [6:0] tx_vl,
    output reg [15:0] tx_sport, tx_dport,
    // rx_* 为无反压 UDP 载荷和 TID；rx_claim 认领请求端口及当前主/状态/拒绝 TID。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_sport, rx_dport,
    output wire rx_claim);
    localparam IDLE = 0, WAIT_PACKET = 1, DISPATCH = 2, NAME = 3, NAME_BYTE = 4, MODE = 5, MODE_BYTE = 6, REQUEST_OK = 7,
        FETCH = 8, FETCH_WAIT = 9, FETCH_CAPTURE = 10, FETCH_DONE = 11, NUMBER = 12, NUMBER_BYTE = 13, BUILD = 14, EMIT = 15,
        BUILD_FLUSH = 16, TX_ADDR = 17, TX_WAIT = 18, TX_CAPTURE = 19, TX_SEND = 20, START_LUS = 21, RATIO_SCALE = 22,
        RATIO_SUB = 23, RATIO_DEC = 24, LUS_WRQ = 25, LUS_DATA = 26, LUS_DONE = 27, ACK_MAIN = 28, DATA_COPY = 29,
        DATA_BYTE = 30, DATA_END = 31, LUR_START = 32, LUR_LENGTH = 33, LUR_VERSION = 34, LUR_COUNT = 35, LUR_HLEN = 36,
        LUR_PLEN = 37, LUR_READY = 38, RRQ_HEADER = 39, HEADER_START = 40, HEADER_LENGTH = 41, HEADER_VERSION = 42,
        HEADER_PTR = 43, HEADER_CRC = 44, HEADER_CRC_BYTE = 45, HEADER_CRC_EXPECT = 46, HEADER_CRC_CHECK = 47,
        HEADER_COUNT = 48, HEADER_NLEN = 49, HEADER_PLEN = 50, HEADER_SIZE = 51, HEADER_DCRC = 52, HEADER_READY = 53,
        RRQ_DATA = 54, DATA_CHECK = 55, DATA_SUCCESS = 56, FAILURE = 57, FAILURE_SENT = 58, DONE = 59, BUILD_PREP = 60,
        LUR_OFFSETS = 61, LNR_USER = 62, LNR_NAME = 63, LNR_BYTE = 64, LNR_READY = 65,
        DL_WRQ = 66, DL_BLOCK = 67, DL_SIZE = 68, DL_ACK = 69, DENY_SEND = 70, HEADER_PTR_CHECK = 71;
    // state 为文件/报文流程；HEADER_CRC_EXPECT 是未使用的保留编码。
    // wait_kind 区分初始化 ACK、请求列表、数据块及 LUS/LNS ACK；packet_type 选择待构造报文。
    localparam WK_LUI_ACK = 0, WK_LUR = 1, WK_DATA = 2, WK_LUS_ACK0 = 3, WK_LUS_ACK1 = 4,
        WK_DL_ACK0 = 5, WK_DL_ACK = 6;
    localparam PK_ACK = 0, PK_LUI = 1, PK_RRQ = 2, PK_LUS_WRQ = 3, PK_LUS = 4, PK_ERROR = 5, PK_DL_DATA = 6;
    // 失败原因：1 元数据，2 容量/长度，3 CRC，4 TFTP ERROR，5 重试耗尽。
    reg configured, protocol_a4;
    reg [1:0] status;
    reg [7:0] reason;
    // return_state/num_return 是读 RAM 子流程返回点；after_tx/lus_return/ack_return 串接发送与文件流程。
    reg [7:0] state, return_state, num_return, after_tx, lus_return, ack_return;
    reg [2:0] wait_kind, packet_type;
    reg [1:0] file_kind, fetch_source;
    // main_tid/main_peer 为主文件会话，status_tid/status_peer 为状态文件会话；两者分别匹配端口。
    reg [15:0] main_tid, main_peer, status_tid, status_peer, tid_sequence;
    reg [15:0] block_number, ack_number, lus_counter, request_port;
    // timer 在 WAIT_PACKET 倒计时；重发保留 packet_tx 内容，retry_total 统计累计次数。
    reg [31:0] timer, retry_total, timeout_cycles;
    reg [7:0] retries, retry_limit;
    // loaded/file_size 是当前上传长度；available_size 仅在校验成功后公布，供介质定义卸载使用。
    reg [13:0] loaded, file_size;
    reg [13:0] available_size, dl_acked, dl_remaining;
    reg [12:0] dl_read_addr;
    reg download_mode, request_download, request_unsupported, deny_empty, deny_unsupported;
    reg [7:0] request_resume;
    reg [4:0] deny_pos;
    reg [15:0] deny_tid, saved_sport, saved_dport;
    // data_crc/expected_crc 校验加载数据，header_crc 校验 ARINC 665-1 头；CRC16 多项式为 0x1021。
    reg [15:0] data_crc, expected_crc, header_crc;
    // metadata_size 记录列表/头长度；各 name_addr/len 和 header_pointer 保存可变字段位置，文件中的字指针需乘二。
    reg [11:0] metadata_size, header_pointer, header_name_addr, data_name_addr;
    reg header_pointer_ok;
    reg [6:0] header_name_len, part_len, data_name_len;
    reg [9:0] part_addr;
    reg manifest;
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
    reg [2:0] number_left;
    reg [9:0] packet_len, packet_pos, rx_length, rx_index;
    reg [15:0] rx_op, rx_block, peer_sp, peer_dp;
    reg [9:0] lus_partlen_pos, lus_part_pos, lus_tail_pos, lus_packet_len;
    reg [9:0] tail_index, head_index, part_index, name_end, mode_start;
    reg packet_pending, consume, receiving;
    reg [4:0] name_pos;
    reg request_write;
    reg [12:0] memory_addr;
    reg rx_we, rx_re;
    reg [9:0] rx_wa, rx_ra;
    reg [7:0] rx_wd;
    wire [7:0] rx_q;
    reg tx_we, tx_re;
    reg [9:0] tx_wa, tx_ra;
    reg [7:0] tx_wd;
    wire [7:0] tx_q;
    reg lur_we, lur_re;
    reg [8:0] lur_wa, lur_ra;
    reg [7:0] lur_wd;
    wire [7:0] lur_q;
    reg hdr_we, hdr_re;
    reg [10:0] hdr_wa, hdr_ra;
    reg [7:0] hdr_wd;
    wire [7:0] hdr_q;
    reg load_we, load_re;
    reg [12:0] load_wa, load_ra;
    reg [7:0] load_wd, load_sample;
    wire [7:0] load_q;
    // 存储分工：RX/TX 各 1 KiB，LUR/LNR 列表 512 B，665-1 头 2 KiB，加载区 8 KiB。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_rx (clk, rx_we, rx_wa, rx_wd, rx_re, rx_ra, rx_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_tx (clk, tx_we, tx_wa, tx_wd, tx_re, tx_ra, tx_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(512)) lur_ram (clk, lur_we, lur_wa, lur_wd, lur_re, lur_ra, lur_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(2048)) header_ram (clk, hdr_we, hdr_wa, hdr_wd, hdr_re, hdr_ra, hdr_q);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(8192)) load_ram (clk, load_we, load_wa, load_wd, load_re, load_ra, load_q);
    assign rx_claim = enable && configured && (rx_dport == request_port || rx_dport == main_tid || rx_dport == status_tid || rx_dport == deny_tid);
    function [15:0] crc16;
        input [15:0] old;
        input [7:0] value;
        reg [15:0] c;
        integer k;
        begin
            c = old ^ { value, 8'b0 };
            for (k = 0; k < 8; k = k + 1) c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
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
                0: memory_name="M"; 1: memory_name="E"; 2: memory_name="M";
                3: memory_name="O"; 4: memory_name="R"; 5: memory_name="Y";
                6: memory_name="."; 7: memory_name="B"; 8: memory_name="I";
                9: memory_name="N"; default: memory_name=0;
            endcase
        end
    endfunction
    // 初始化拒绝不覆盖正在等待ACK的重发缓冲，也不切换主传输TID。
    function [7:0] denial_byte;
        input [4:0] p;
        begin
            denial_byte=0;
            case (p)
                1: denial_byte=3; 3: denial_byte=1; 7: denial_byte=deny_unsupported ? 9:17;
                8: denial_byte="A"; 9: denial_byte=protocol_a4 ? "4":"3";
                10: denial_byte=8'h10; 11: denial_byte=deny_unsupported ? 2:0;
                12: denial_byte=deny_unsupported ? 0:8;
                13: denial_byte=deny_empty ? "N":"B";
                14: denial_byte=deny_empty ? "O":"U";
                15: denial_byte=deny_empty ? " ":"S";
                16: denial_byte=deny_empty ? "D":"Y";
                17: denial_byte=deny_empty ? "A":0;
                18: denial_byte=deny_empty ? "T":0;
                19: denial_byte=deny_empty ? "A":0;
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
            if (reason == 0) description = 0;
            else case (p)
                0 : description = "F";
                1 : description = "A";
                2 : description = "I";
                3 : description = "L";
                4 : description = " ";
                5 : description = 8'h30 + reason;
                default : description = 0;
            endcase
        end
    endfunction
    // 同步 RAM 读取子流程：get_byte 读一字节，get_number 拼大端整数，保存返回点后进入 FETCH。
    task get_byte;
        input [1:0] src;
        input [12:0] addr;
        input [7:0] destination;
        begin
            fetch_source <= src;
            fetch_addr <= addr;
            return_state <= destination;
            state <= FETCH;
        end
    endtask
    task get_number;
        input [1:0] src;
        input [12:0] addr;
        input [2:0] count;
        input [7:0] destination;
        begin
            fetch_source <= src;
            fetch_addr <= addr;
            number <= 0;
            number_left <= count;
            num_return <= destination;
            state <= NUMBER;
        end
    endtask
    // 报文构造入口：固定发送端口、类型与返回状态，清本报文重试计数，再逐字节写 TX RAM。
    task make_packet;
        input [2:0] kind;
        input [9:0] length;
        input [15:0] source_port, dest_port;
        input [7:0] destination;
        begin
            packet_type <= kind;
            packet_len <= length;
            packet_pos <= 0;
            tx_sport <= source_port;
            tx_dport <= dest_port;
            after_tx <= destination;
            retries <= 0;
            timer <= 0;
            state <= BUILD_PREP;
        end
    endtask
    task fail;
        input [7:0] code;
        begin
            reason <= code;
            status <= 3;
            state <= FAILURE;
        end
    endtask
    // 接收端无反压；停等 TFTP 每次只允许一份尚未处理的报文。
    always @(posedge clk) begin
        if (reset) begin
            rx_we <= 0;
            rx_wa <= 0;
            rx_wd <= 0;
            rx_index <= 0;
            packet_pending <= 0;
            receiving <= 0;
            rx_length <= 0;
            rx_op <= 0;
            rx_block <= 0;
            peer_sp <= 0;
            peer_dp <= 0;
        end
        else begin
            rx_we <= 0;
            if (consume) packet_pending <= 0;
            if (rx_valid && (receiving || (rx_claim && ! packet_pending))) begin
                rx_we <= 1;
                rx_wa <= rx_index;
                rx_wd <= rx_data;
                case (rx_index)
                    0 : begin
                        rx_op[15:8] <= rx_data;
                        peer_sp <= rx_sport;
                        peer_dp <= rx_dport;
                    end
                    1 : rx_op[7:0] <= rx_data;
                    2 : rx_block[15:8] <= rx_data;
                    3 : rx_block[7:0] <= rx_data;
                endcase
                if (rx_last) begin
                    rx_length <= rx_index + 1'b1;
                    rx_index <= 0;
                    receiving <= 0;
                    packet_pending <= 1;
                end
                else begin
                    rx_index <= rx_index + 1'b1;
                    receiving <= 1;
                end
            end
        end
    end
    always @(posedge clk) begin
        if (reset) begin
            configured <= 0;
            tx_vl <= 0;
            status <= 0;
            reason <= 0;
            state <= IDLE;
            main_tid <= 16'h8000;
            status_tid <= 16'h9000;
            main_peer <= 0;
            status_peer <= 0;
            tid_sequence <= 16'h8100;
            loaded <= 0;
            file_size <= 0;
            available_size <= 0;
            dl_acked <= 0;
            dl_remaining <= 0;
            dl_read_addr <= 0;
            download_mode <= 0;
            request_download <= 0;
            request_unsupported <= 0;
            request_resume <= IDLE;
            deny_empty <= 0;
            deny_unsupported <= 0;
            deny_pos <= 0;
            deny_tid <= 16'ha000;
            saved_sport <= 0;
            saved_dport <= 0;
            lus_counter <= 0;
            retry_total <= 0;
            tx_valid <= 0;
            tx_last <= 0;
            tx_data <= 0;
            tx_sport <= 0;
            tx_dport <= 0;
            consume <= 0;
            timer <= 0;
            retries <= 0;
            request_port <= 59;
            timeout_cycles <= 250000000;
            retry_limit <= 1;
            protocol_a4 <= 1;
            cfg_extra_data <= 0;
            rx_re <= 0;
            rx_ra <= 0;
            tx_we <= 0;
            tx_wa <= 0;
            tx_wd <= 0;
            tx_re <= 0;
            tx_ra <= 0;
            lur_we <= 0;
            lur_wa <= 0;
            lur_wd <= 0;
            lur_re <= 0;
            lur_ra <= 0;
            hdr_we <= 0;
            hdr_wa <= 0;
            hdr_wd <= 0;
            hdr_re <= 0;
            hdr_ra <= 0;
            load_we <= 0;
            load_wa <= 0;
            load_wd <= 0;
            load_re <= 0;
            load_ra <= 0;
            load_sample <= 0;
            memory_addr <= 0;
            cfg_rdata <= 0;
            manifest <= 0;
            file_kind <= 0;
            block_number <= 0;
            ack_number <= 0;
            data_crc <= 16'hffff;
            header_crc <= 16'hffff;
            expected_crc <= 0;
            return_state <= 0;
            num_return <= 0;
            after_tx <= 0;
            lus_return <= 0;
            ack_return <= 0;
            wait_kind <= 0;
            packet_type <= 0;
            fetch_source <= 0;
            fetch_addr <= 0;
            byte_value <= 0;
            number <= 0;
            number_left <= 0;
            packet_len <= 0;
            packet_pos <= 0;
            metadata_size <= 0;
            header_pointer_ok <= 0;
            header_pointer <= 0;
            header_name_addr <= 0;
            header_name_len <= 0;
            part_len <= 0;
            part_addr <= 0;
            data_name_addr <= 0;
            data_name_len <= 0;
            lus_status <= 0;
            percent <= 0;
            scaled <= 0;
            ratio_h <= 0;
            ratio_t <= 0;
            ratio_u <= 0;
            decimal_tens <= 0;
            decimal_rest <= 0;
            copy_pos <= 0;
            copy_len <= 0;
            scan_pos <= 0;
            name_pos <= 0;
            request_write <= 0;
            build_value <= 0;
            lus_partlen_pos <= 0;
            lus_part_pos <= 0;
            lus_tail_pos <= 0;
            lus_packet_len <= 0;
            tail_index <= 0;
            head_index <= 0;
            part_index <= 0;
            name_end <= 0;
            mode_start <= 0;
        end
        else begin
            consume <= 0;
            rx_re <= 0;
            tx_we <= 0;
            tx_re <= 0;
            lur_we <= 0;
            lur_re <= 0;
            hdr_we <= 0;
            hdr_re <= 0;
            load_we <= 0;
            // B4 写地址后等四拍再读 B5；读口只在上传停止后启用。
            load_re <= status != 1;
            load_ra <= memory_addr;
            load_sample <= load_q;
            if (cfg_we) case (cfg_addr)
                8'hb0 : if (status != 1) configured <= cfg_wdata[0];
                8'hb1 : if (status != 1) tx_vl <= cfg_wdata[6:0];
                8'hb4 : memory_addr <= cfg_wdata[12:0];
                8'hb8 : if (status != 1 && cfg_wdata[15:0] != 0) request_port <= cfg_wdata[15:0];
                8'hb9 : if (status != 1 && cfg_wdata != 0) timeout_cycles <= cfg_wdata;
                8'hba : if (status != 1) retry_limit <= cfg_wdata[7:0];
                8'hbb : if (status != 1 && (cfg_wdata[15:0] == 16'h4133 || cfg_wdata[15:0] == 16'h4134)) protocol_a4 <= cfg_wdata[15:0] == 16'h4134;
            endcase
            case (cfg_addr[2:0])
                0 : cfg_rdata <= { 31'b0, configured };
                1 : cfg_rdata <= { 25'b0, tx_vl };
                2 : cfg_rdata <= { 16'b0, reason, 6'b0, status };
                3 : cfg_rdata <= { 18'b0, loaded };
                4 : cfg_rdata <= { 19'b0, memory_addr };
                5 : cfg_rdata <= { 24'b0, load_sample };
                6 : cfg_rdata <= { 16'b0, lus_counter };
                7 : cfg_rdata <= retry_total;
            endcase
            case (cfg_addr[2:0])
                0 : cfg_extra_data <= { 16'b0, request_port };
                1 : cfg_extra_data <= timeout_cycles;
                2 : cfg_extra_data <= { 24'b0, retry_limit };
                3 : cfg_extra_data <= protocol_a4 ? 32'h4134 : 32'h4133;
                default : cfg_extra_data <= 0;
            endcase
            // ARINC 615A 上传：LUI→LUS→LUR→头文件→数据→最终 LUS；介质定义卸载：LND→LNS→LNR→数据→最终 LNS。
            case (state)
                // 等待已启用目标收到完整 UDP 报文，consume 后转 DISPATCH。
                IDLE : if (packet_pending && enable && configured) begin
                    consume <= 1;
                    request_resume <= IDLE;
                    state <= DISPATCH;
                end
                // 等待停等传输的下一 DATA/ACK；超时重发已保存报文，重试耗尽进入失败收尾。
                WAIT_PACKET : begin
                    if (packet_pending) begin
                        consume <= 1;
                        request_resume <= WAIT_PACKET;
                        state <= DISPATCH;
                        timer <= timeout_cycles;
                    end
                    else if (timer == 1) begin
                        timer <= 0;
                        if (retries == retry_limit) begin
                            if (wait_kind == WK_LUS_ACK0 || wait_kind == WK_LUS_ACK1) begin
                                reason <= 5;
                                status <= 3;
                                state <= DONE;
                            end
                            else fail (5);
                        end
                        else begin
                            retries <= retries + 1'b1;
                            retry_total <= retry_total + 1'b1;
                            packet_pos <= 0;
                            state <= TX_ADDR;
                        end
                    end
                    else timer <= timer - 1'b1;
                end
                // 按 TFTP opcode、块号和 TID 分流；重复 DATA 仅重发 ACK，匹配的新 DATA 才进入 DATA_COPY。
                DISPATCH : begin
                    if (peer_dp == request_port && (rx_op == 1 || rx_op == 2)) begin
                        request_write <= rx_op == 2;
                        request_download <= 0;
                        request_unsupported <= 0;
                        name_pos <= 0;
                        state <= NAME;
                    end
                    else if (rx_op == 5 && peer_dp == main_tid) fail (4);
                    else if (rx_op == 5 && peer_dp == status_tid) begin
                        reason <= 4;
                        status <= 3;
                        state <= DONE;
                    end
                    else if (wait_kind == WK_LUI_ACK && peer_dp == main_tid && peer_sp == main_peer && rx_op == 4 && rx_block == 1) begin
                        lus_status <= 1;
                        lus_return <= LUS_DONE;
                        state <= START_LUS;
                    end
                    else if (wait_kind == WK_LUS_ACK0 && peer_dp == status_tid && rx_op == 4 && rx_block == 0) begin
                        status_peer <= peer_sp;
                        state <= LUS_DATA;
                    end
                    else if (wait_kind == WK_LUS_ACK1 && peer_dp == status_tid && peer_sp == status_peer && rx_op == 4 && rx_block == 1) state <= lus_return;
                    else if (wait_kind == WK_DL_ACK0 && peer_dp == main_tid && rx_op == 4 && rx_block == 0) begin
                        main_peer <= peer_sp;
                        block_number <= 1;
                        state <= DL_BLOCK;
                    end
                    else if (wait_kind == WK_DL_ACK && peer_dp == main_tid && peer_sp == main_peer && rx_op == 4 && rx_block == block_number) state <= DL_ACK;
                    else if (wait_kind == WK_DATA && peer_dp == main_tid && rx_op == 3 && (main_peer == 0 || peer_sp == main_peer)) begin
                        main_peer <= peer_sp;
                        if (rx_block == block_number && rx_length >= 4 && rx_length <= 516) begin
                            copy_len <= rx_length - 4;
                            copy_pos <= 0;
                            state <= DATA_COPY;
                        end
                        else if (rx_block == block_number - 1'b1) begin
                            // 重复 DATA 只重发 ACK，不重复写加载区。
                            ack_number <= rx_block;
                            make_packet (PK_ACK, 4, main_tid, peer_sp, WAIT_PACKET);
                        end
                        else state <= WAIT_PACKET;
                    end
                    else state <= status == 1 ? WAIT_PACKET : IDLE;
                end
                // 从请求 RAM 取下一个文件名字节，转 NAME_BYTE。
                NAME : get_byte (0, { 6'b0, name_pos } + 11'd2, NAME_BYTE);
                // 匹配 LUI/LUR 或 LND/LNR 文件名并识别不支持的操作；名字结束后 MODE，错误发 TFTP ERROR。
                NAME_BYTE : if (name_pos == 9 && (byte_value == "U" || byte_value == "N" || (!request_write && byte_value == "C"))) begin
                    request_download <= byte_value == "N";
                    request_unsupported <= byte_value == "C";
                    name_pos <= name_pos + 1'b1;
                    state <= NAME;
                end
                else if (name_pos == 10 && !request_write && request_download && byte_value == "O") begin
                    request_unsupported <= 1;
                    name_pos <= name_pos + 1'b1;
                    state <= NAME;
                end
                else if (byte_value != target_name (name_pos, request_write ? "R" : request_download ? "D" : "I", request_download)) begin
                    reason <= 1;
                    make_packet (PK_ERROR, 11, tid_sequence, peer_sp, IDLE);
                end
                else if (name_pos == 11) begin
                    name_pos <= 0;
                    state <= MODE;
                end
                else begin
                    name_pos <= name_pos + 1'b1;
                    state <= NAME;
                end
                // 读取 TFTP 模式字节，转 MODE_BYTE。
                MODE : get_byte (0, { 6'b0, name_pos } + 11'd14, MODE_BYTE);
                // 只接受 octet 模式；终止 NUL 后 REQUEST_OK，其余继续 MODE 或发错误。
                MODE_BYTE : if ((byte_value | 8'h20) != (octet_byte (name_pos) | 8'h20) || (name_pos == 5 && byte_value != 0)) begin
                    reason <= 4;
                    make_packet (PK_ERROR, 11, tid_sequence, peer_sp, IDLE);
                    // RFC 2347：mode 的 NUL 后全部选项忽略，不发 OACK，继续 DATA1/ACK0。
                end
                else if (name_pos == 5) state <= REQUEST_OK;
                else begin
                    name_pos <= name_pos + 1'b1;
                    state <= MODE;
                end
                // 初始化主传输 TID/方向或接受列表 WRQ；忙、无可卸载数据、不支持操作时转 DENY_SEND。
                REQUEST_OK : begin
                    if (request_unsupported || (!request_write && status == 1) || (request_write && status == 1 && request_download != download_mode) ||
                        (!request_write && request_download && available_size == 0)) begin
                        // LCI/LNO按初始化文件格式拒绝；1002不启动后续操作。
                        deny_unsupported <= request_unsupported;
                        deny_empty <= status != 1;
                        deny_pos <= 0;
                        deny_tid <= tid_sequence;
                        tid_sequence <= tid_sequence + 1'b1;
                        saved_sport <= tx_sport;
                        saved_dport <= tx_dport;
                        tx_sport <= tid_sequence;
                        tx_dport <= peer_sp;
                        state <= DENY_SEND;
                    end
                    else if (request_write && status == 1 && wait_kind == WK_LUR) begin
                        main_peer <= peer_sp;
                        main_tid <= tid_sequence;
                        tid_sequence <= tid_sequence + 1'b1;
                        file_kind <= 0;
                        metadata_size <= 0;
                        block_number <= 1;
                        ack_number <= 0;
                        wait_kind <= WK_DATA;
                        make_packet (PK_ACK, 4, tid_sequence, peer_sp, WAIT_PACKET);
                    end
                    else if (! request_write) begin
                        status <= 1;
                        reason <= 0;
                        download_mode <= request_download;
                        main_peer <= peer_sp;
                        main_tid <= tid_sequence;
                        tid_sequence <= tid_sequence + 1'b1;
                        if (!request_download) begin
                            loaded <= 0;
                            available_size <= 0;
                        end
                        file_size <= request_download ? available_size : 0;
                        dl_acked <= 0;
                        manifest <= 0;
                        lus_counter <= 0;
                        wait_kind <= WK_LUI_ACK;
                        make_packet (PK_LUI, 13, tid_sequence, peer_sp, WAIT_PACKET);
                    end
                    else begin
                        reason <= 4;
                        make_packet (PK_ERROR, 11, tid_sequence, peer_sp, IDLE);
                    end
                end
                // 独立流式发送初始化拒绝，不覆盖待重发报文；末字节握手后恢复原等待状态。
                DENY_SEND : if (!tx_valid) begin
                    tx_valid <= 1;
                    tx_data <= denial_byte(deny_pos);
                    tx_last <= deny_pos == (deny_unsupported ? 12:20);
                end
                else if (tx_ready) begin
                    tx_valid <= 0;
                    tx_last <= 0;
                    deny_pos <= deny_pos + 1'b1;
                    if (deny_pos == (deny_unsupported ? 12:20)) begin
                        tx_sport <= saved_sport;
                        tx_dport <= saved_dport;
                        state <= request_resume;
                    end
                end
                // 按 fetch_source 选择 RX/列表/头文件/加载 RAM 并发读，转 FETCH_WAIT。
                FETCH : begin
                    case (fetch_source)
                        0 : begin
                            rx_re <= 1;
                            rx_ra <= fetch_addr[9:0];
                        end
                        1 : begin
                            lur_re <= 1;
                            lur_ra <= fetch_addr[8:0];
                        end
                        2 : begin
                            hdr_re <= 1;
                            hdr_ra <= fetch_addr[10:0];
                        end
                        3 : begin
                            load_re <= 1;
                            load_ra <= fetch_addr;
                        end
                    endcase
                    state <= FETCH_WAIT;
                end
                // 等待同步 RAM，转 FETCH_CAPTURE。
                FETCH_WAIT : state <= FETCH_CAPTURE;
                // 锁存选中 RAM 字节，转 FETCH_DONE。
                FETCH_CAPTURE : begin
                    case (fetch_source)
                        0 : byte_value <= rx_q;
                        1 : byte_value <= lur_q;
                        2 : byte_value <= hdr_q;
                        3 : byte_value <= load_q;
                    endcase
                    state <= FETCH_DONE;
                end
                // 跳回 get_byte 保存的 return_state。
                FETCH_DONE : state <= return_state;
                // 调用 FETCH 读取大端整数的下一字节。
                NUMBER : begin
                    return_state <= NUMBER_BYTE;
                    state <= FETCH;
                end
                // 拼接整数并推进地址，足够字节后回 num_return，否则 NUMBER。
                NUMBER_BYTE : begin
                    number <= { number[23:0], byte_value };
                    fetch_addr <= fetch_addr + 1'b1;
                    number_left <= number_left - 1'b1;
                    state <= number_left == 1 ? num_return : NUMBER;
                end
                // 可变字段的偏移先寄存，避免长度加法、比较和字节选择落在同一路径。
                // 寄存可变字段偏移及卸载 RAM 地址，转 BUILD。
                BUILD_PREP : begin
                    tail_index <= packet_pos - lus_tail_pos;
                    head_index <= packet_pos - 10'd33;
                    part_index <= packet_pos - lus_part_pos;
                    name_end <= packet_len - 10'd7;
                    mode_start <= packet_len - 10'd6;
                    dl_read_addr <= dl_acked[12:0] + packet_pos - 10'd4;
                    state <= BUILD;
                end
                // 按 packet_type 选择 TFTP/615A 字段；变长名字或卸载数据需先 FETCH，最终转 EMIT。
                BUILD : begin
                    build_value <= 0;
                    state <= EMIT;
                    case (packet_type)
                        PK_ACK : case (packet_pos)
                            1 : build_value <= 4;
                            2 : build_value <= ack_number[15:8];
                            3 : build_value <= ack_number[7:0];
                        endcase
                        PK_LUI : case (packet_pos)
                            1 : build_value <= 3;
                            3 : build_value <= 1;
                            7 : build_value <= 9;
                            8 : build_value <= "A";
                            9 : build_value <= protocol_a4 ? "4" : "3";
                            11 : build_value <= 1;
                        endcase
                        PK_ERROR : case (packet_pos)
                            1 : build_value <= 5;
                            3 : build_value <= reason == 1 ? 1 : reason == 4 ? 4 : 0;
                            default : if (packet_pos >= 4) build_value <= description (packet_pos - 4);
                        endcase
                        PK_LUS_WRQ : begin
                            if (packet_pos == 1) build_value <= 2;
                            else if (packet_pos >= 2 && packet_pos < 14) build_value <= target_name (packet_pos - 2, "S", download_mode);
                            else if (packet_pos >= 14) build_value <= octet_byte (packet_pos - 14);
                        end
                        PK_RRQ : begin
                            if (packet_pos == 1) build_value <= download_mode ? 2 : 1;
                            else if (packet_pos >= 2 && packet_pos < name_end) begin
                                if (download_mode) build_value <= memory_name(packet_pos - 2);
                                else if (file_kind == 1) get_byte (1, header_name_addr + packet_pos - 2, EMIT);
                                else get_byte (2, data_name_addr + packet_pos - 2, EMIT);
                            end
                            else if (packet_pos >= mode_start) build_value <= octet_byte (packet_pos - mode_start);
                        end
                        PK_DL_DATA : case (packet_pos)
                            1: build_value <= 3;
                            2: build_value <= block_number[15:8];
                            3: build_value <= block_number[7:0];
                            default: if (packet_pos >= 4) get_byte(3, dl_read_addr, EMIT);
                        endcase
                        PK_LUS : begin
                            case (packet_pos)
                                1 : build_value <= 3;
                                3 : build_value <= 1;
                                7 : build_value <= packet_len - 4;
                                8 : build_value <= "A";
                                9 : build_value <= protocol_a4 ? "4" : "3";
                                10 : build_value <= lus_status[15:8];
                                11 : build_value <= lus_status[7:0];
                                12 : build_value <= 8;
                                21 : build_value <= lus_counter[15:8];
                                22 : build_value <= lus_counter[7:0];
                                25, 26 : build_value <= lus_status == 2 ? 8'hff : 0;
                                27 : build_value <= ratio_h;
                                28 : build_value <= ratio_t;
                                29 : build_value <= ratio_u;
                                31 : build_value <= manifest;
                                32 : build_value <= header_name_len;
                                default : begin
                                    if (packet_pos >= 13 && packet_pos <= 20) build_value <= description (packet_pos - 13);
                                    else if (packet_pos >= 33 && packet_pos < lus_partlen_pos) get_byte (1,
                                        header_name_addr + head_index, EMIT);
                                    else if (!download_mode && packet_pos == lus_partlen_pos) build_value <= part_len;
                                    else if (!download_mode && packet_pos >= lus_part_pos && packet_pos < lus_tail_pos) get_byte (1,
                                        part_addr + part_index, EMIT);
                                    else if (download_mode && packet_pos >= 33 && packet_pos >= lus_tail_pos) case (tail_index)
                                        0: build_value <= lus_status == 16'h1003 ? 8'h10 : 0;
                                        1: build_value <= lus_status == 16'h1003 ? 7 : lus_status[7:0];
                                        2: build_value <= 8;
                                        default: build_value <= description(tail_index - 10'd3);
                                    endcase
                                    else if (packet_pos >= 33 && packet_pos >= lus_tail_pos) case (tail_index)
                                        0 : build_value <= ratio_h;
                                        1 : build_value <= ratio_t;
                                        2 : build_value <= ratio_u;
                                        3 : build_value <= lus_status == 16'h1003 ? 8'h10 : 0;
                                        4 : build_value <= lus_status == 16'h1003 ? 7 : lus_status[7:0];
                                        5 : build_value <= 8;
                                        default : build_value <= description (tail_index - 10'd6);
                                    endcase
                                end
                            endcase
                        end
                    endcase
                end
                // 把当前字节写发送 RAM；剩余字节回 BUILD_PREP，写完转 BUILD_FLUSH。
                EMIT : begin
                    tx_we <= 1;
                    tx_wa <= packet_pos;
                    tx_wd <= return_state == EMIT ? byte_value : build_value;
                    return_state <= 0;
                    packet_pos <= packet_pos + 1'b1;
                    state <= packet_pos + 1'b1 == packet_len ? BUILD_FLUSH : BUILD_PREP;
                end
                // 等最后一次写入落地，归零发送位置后 TX_ADDR。
                BUILD_FLUSH : begin
                    packet_pos <= 0;
                    state <= TX_ADDR;
                end
                // 发发送 RAM 读请求，转 TX_WAIT。
                TX_ADDR : begin
                    tx_re <= 1;
                    tx_ra <= packet_pos;
                    state <= TX_WAIT;
                end
                // 等同步 RAM 读，转 TX_CAPTURE。
                TX_WAIT : state <= TX_CAPTURE;
                // 锁存发送字节，转 TX_SEND。
                TX_CAPTURE : begin
                    tx_data <= tx_q;
                    state <= TX_SEND;
                end
                // 保持 valid/last 直到握手；非尾继续 TX_ADDR，尾跳 after_tx 并装载超时计数。
                TX_SEND : begin
                    if (! tx_valid) begin
                        tx_valid <= 1;
                        tx_last <= packet_pos + 1'b1 == packet_len;
                    end
                    else if (tx_ready) begin
                        tx_valid <= 0;
                        tx_last <= 0;
                        packet_pos <= packet_pos + 1'b1;
                        if (tx_last) begin
                            state <= after_tx;
                            timer <= timeout_cycles;
                        end
                        else state <= TX_ADDR;
                    end
                end
                // 为 LUS/LNS 状态文件分配独立 TID，记录序号与已完成字节量，转 RATIO_SCALE。
                START_LUS : begin
                    lus_counter <= lus_counter + 1'b1;
                    status_tid <= tid_sequence;
                    tid_sequence <= tid_sequence + 1'b1;
                    percent <= 0;
                    scaled <= download_mode ? {6'b0, dl_acked} : {6'b0, loaded};
                    state <= RATIO_SCALE;
                end
                // 用移位相加把完成量乘 100，转 RATIO_SUB。
                RATIO_SCALE : begin
                    scaled <= (scaled << 6) + (scaled << 5) + (scaled << 2);
                    state <= RATIO_SUB;
                end
                // 反复减总长求百分比；求完后转 RATIO_DEC，成功状态直接形成 100%。
                RATIO_SUB : begin
                    if (file_size != 0 && scaled >= file_size && percent < 99) begin
                        scaled <= scaled - file_size;
                        percent <= percent + 1'b1;
                    end
                    else begin
                        decimal_tens <= 0;
                        decimal_rest <= lus_status == 3 ? 0 : percent;
                        ratio_h <= lus_status == 3 ? "1" : " ";
                        state <= RATIO_DEC;
                    end
                end
                // 反复减 10 形成十进制比例，转 LUS_WRQ。
                RATIO_DEC : if (decimal_rest >= 10) begin
                    decimal_rest <= decimal_rest - 10;
                    decimal_tens <= decimal_tens + 1'b1;
                end
                else begin
                    ratio_t <= lus_status == 3 ? "0" : decimal_tens == 0 ? " " : 8'h30 + decimal_tens;
                    ratio_u <= 8'h30 + decimal_rest;
                    state <= LUS_WRQ;
                end
                // 发状态文件 WRQ 并等待 ACK0。
                LUS_WRQ : begin
                    wait_kind <= WK_LUS_ACK0;
                    make_packet (PK_LUS_WRQ, 20, status_tid, request_port, WAIT_PACKET);
                end
                // 收到 ACK0 后发 LUS/LNS DATA1 并等待 ACK1。
                LUS_DATA : begin
                    wait_kind <= WK_LUS_ACK1;
                    make_packet (PK_LUS, manifest ? lus_packet_len : 32, status_tid, status_peer, WAIT_PACKET);
                end
                // 初始状态文件确认后等待 LUR/LNR，回 IDLE。
                LUS_DONE : begin
                    wait_kind <= WK_LUR;
                    state <= IDLE;
                end
                // 构造当前主传输块的 ACK，发送后跳 ack_return。
                ACK_MAIN : begin
                    wait_kind <= WK_DATA;
                    make_packet (PK_ACK, 4, main_tid, main_peer, ack_return);
                end
                // 逐字节读取新 DATA 的有效载荷；复制完转 DATA_END。
                DATA_COPY : begin
                    if (copy_pos == copy_len) state <= DATA_END;
                    else get_byte (0, copy_pos + 4, DATA_BYTE);
                end
                // 按 file_kind 写列表/头文件/加载 RAM；数据文件同时更新 CRC，越界则失败。
                DATA_BYTE : begin
                    if (file_kind == 0) begin
                        if (metadata_size >= 512) fail (2);
                        else begin
                            lur_we <= 1;
                            lur_wa <= metadata_size[8:0];
                            lur_wd <= byte_value;
                            metadata_size <= metadata_size + 1'b1;
                            state <= DATA_COPY;
                        end
                    end
                    else if (file_kind == 1) begin
                        if (metadata_size >= 2048) fail (2);
                        else begin
                            hdr_we <= 1;
                            hdr_wa <= metadata_size[10:0];
                            hdr_wd <= byte_value;
                            metadata_size <= metadata_size + 1'b1;
                            state <= DATA_COPY;
                        end
                    end
                    else begin
                        if (loaded >= 8192) fail (2);
                        else begin
                            load_we <= 1;
                            load_wa <= loaded[12:0];
                            load_wd <= byte_value;
                            loaded <= loaded + 1'b1;
                            data_crc <= crc16 (data_crc, byte_value);
                            state <= DATA_COPY;
                        end
                    end
                    copy_pos <= copy_pos + 1'b1;
                end
                // 递增块号并确认；短块代表文件结束，分别转列表解析、头文件解析或数据校验。
                DATA_END : begin
                    block_number <= block_number + 1'b1;
                    ack_number <= rx_block;
                    if (copy_len < 512) begin
                        if (file_kind == 0) begin
                            ack_return <= LUR_START;
                            state <= ACK_MAIN;
                        end
                        else if (file_kind == 1) begin
                            ack_return <= HEADER_START;
                            state <= ACK_MAIN;
                        end
                        else state <= DATA_CHECK;
                    end
                    else begin
                        ack_return <= WAIT_PACKET;
                        if (file_kind == 2 && block_number == 1) begin
                            lus_status <= 2;
                            lus_return <= ACK_MAIN;
                            state <= START_LUS;
                        end
                        else state <= ACK_MAIN;
                    end
                end
                // 读取 LUR/LNR 文件总长，转 LUR_LENGTH。
                LUR_START : get_number (1, 0, 4, LUR_LENGTH);
                // 总长须等于已接收长度，然后读协议版本。
                LUR_LENGTH : if (number != metadata_size) fail (1);
                else get_number (1, 4, 2, LUR_VERSION);
                // 只接受 A3/A4，随后读取单文件数量。
                LUR_VERSION : if (number != 16'h4133 && number != 16'h4134) fail (1);
                else get_number (1, 6, 2, LUR_COUNT);
                // 只接受一个文件，随后读文件名长度。
                LUR_COUNT : if (number != 1) fail (1);
                else get_byte (1, 8, LUR_HLEN);
                // 检查名字长度并记录位置；上传继续件号，卸载转 LNR_USER。
                LUR_HLEN : if (byte_value < 2 || byte_value > 64) fail (1);
                else begin
                    header_name_len <= byte_value[6:0];
                    header_name_addr <= 9;
                    get_byte (1, 11'd9 + byte_value, download_mode ? LNR_USER : LUR_PLEN);
                end
                // 检查件号长度并预计算 LUS 可变字段位置，转 LUR_OFFSETS。
                LUR_PLEN : if (byte_value < 2 || byte_value > 64) fail (1);
                else begin
                    part_len <= byte_value[6:0];
                    part_addr <= 10 + header_name_len;
                    lus_partlen_pos <= 10'd33 + header_name_len;
                    lus_part_pos <= 10'd34 + header_name_len;
                    state <= LUR_OFFSETS;
                end
                // 算出状态尾部位置，转 LUR_READY。
                LUR_OFFSETS : begin
                    lus_tail_pos <= lus_part_pos + part_len;
                    state <= LUR_READY;
                end
                // 列表解析成功，发处理中 LUS，确认后 RRQ_HEADER。
                LUR_READY : begin
                    lus_packet_len <= lus_tail_pos + 10'd14;
                    manifest <= 1;
                    lus_status <= 2;
                    lus_return <= RRQ_HEADER;
                    state <= START_LUS;
                end
                // LNR单文件列表后是用户自定义数据；LNS没有LUS的件号和逐文件ratio。
                // 校验单文件卸载列表及用户数据长度，转 LNR_NAME。
                LNR_USER : begin
                    manifest <= 1;
                    lus_partlen_pos <= 10'd33 + header_name_len;
                    lus_tail_pos <= 10'd33 + header_name_len;
                    lus_packet_len <= 10'd44 + header_name_len;
                    scan_pos <= 0;
                    if (metadata_size != 12'd10 + header_name_len + byte_value || header_name_len != 11) fail(1);
                    else state <= LNR_NAME;
                end
                // 取卸载文件名字节，转 LNR_BYTE。
                LNR_NAME : get_byte(1, 13'd9 + scan_pos, LNR_BYTE);
                // 只接受 MEMORY.BIN；全名匹配后 LNR_READY，否则失败。
                LNR_BYTE : if (byte_value != memory_name(scan_pos[6:0])) fail(1);
                else if (scan_pos == 10) state <= LNR_READY;
                else begin scan_pos <= scan_pos + 1'b1; state <= LNR_NAME; end
                // 发处理中 LNS，确认后 DL_WRQ。
                LNR_READY : begin
                    lus_status <= 2;
                    lus_return <= DL_WRQ;
                    state <= START_LUS;
                end
                // 分配卸载数据 TID，发 MEMORY.BIN 的 WRQ 并等 ACK0。
                DL_WRQ : begin
                    main_tid <= tid_sequence;
                    main_peer <= 0;
                    tid_sequence <= tid_sequence + 1'b1;
                    wait_kind <= WK_DL_ACK0;
                    make_packet(PK_RRQ, 19, tid_sequence, request_port, WAIT_PACKET);
                end
                // 计算剩余卸载量，转 DL_SIZE。
                DL_BLOCK : begin
                    dl_remaining <= file_size - dl_acked;
                    state <= DL_SIZE;
                end
                // 按最多 512 字节构造 DATA 并等对应 ACK；整块边界最终还会发零长度短块。
                DL_SIZE : begin
                    copy_len <= dl_remaining >= 512 ? 512 : dl_remaining[10:0];
                    wait_kind <= WK_DL_ACK;
                    make_packet(PK_DL_DATA, dl_remaining >= 512 ? 516 : dl_remaining[9:0] + 10'd4, main_tid, main_peer, WAIT_PACKET);
                end
                // 推进已确认卸载量；短块后发成功 LNS，否则继续数据块或首块进度状态。
                DL_ACK : begin
                    dl_acked <= dl_acked + copy_len;
                    block_number <= block_number + 1'b1;
                    if (copy_len < 512) begin
                        lus_status <= 3;
                        lus_return <= DONE;
                        state <= START_LUS;
                    end
                    else if (block_number == 1) begin
                        lus_status <= 2;
                        lus_return <= DL_BLOCK;
                        state <= START_LUS;
                    end
                    else state <= DL_BLOCK;
                end
                // 列表获准后请求 ARINC 665-1 头文件，清元数据长度并等 DATA1。
                RRQ_HEADER : begin
                    file_kind <= 1;
                    metadata_size <= 0;
                    main_tid <= tid_sequence;
                    main_peer <= 0;
                    tid_sequence <= tid_sequence + 1'b1;
                    block_number <= 1;
                    wait_kind <= WK_DATA;
                    make_packet (PK_RRQ, header_name_len + 8, tid_sequence, request_port, WAIT_PACKET);
                end
                // 读取头文件字数，转 HEADER_LENGTH。
                HEADER_START : get_number (2, 0, 4, HEADER_LENGTH);
                // 把 16 位字数换为字节数并核对实际长度，随后读格式版本。
                HEADER_LENGTH : if ((number << 1) != metadata_size || metadata_size < 32) fail (1);
                else get_number (2, 4, 2, HEADER_VERSION);
                // 只接受 0x8002，随后读数据文件列表指针。
                HEADER_VERSION : if (number != 16'h8002) fail (1);
                else get_number (2, 14, 4, HEADER_PTR);
                // 寄存字指针的范围检查结果，转 HEADER_PTR_CHECK。
                HEADER_PTR : begin
                    // 范围检查结果先寄存，下一拍选择成功/失败，切开比较与状态选择路径。
                    header_pointer_ok <= number >= 13 && (number << 1) < metadata_size - 6;
                    state <= HEADER_PTR_CHECK;
                end
                // 合法指针换算成字节地址并开始 HEADER_CRC，不合法则失败。
                HEADER_PTR_CHECK : if (!header_pointer_ok) fail (1);
                else begin
                    header_pointer <= number[10:0] << 1;
                    header_crc <= 16'hffff;
                    scan_pos <= 0;
                    state <= HEADER_CRC;
                end
                // 逐字节扫描头 CRC 覆盖区；扫描结束读取保存的 CRC 并转 HEADER_CRC_CHECK。
                HEADER_CRC : if (scan_pos == metadata_size - 6) get_number (2, scan_pos, 2, HEADER_CRC_CHECK);
                else get_byte (2, scan_pos, HEADER_CRC_BYTE);
                // 更新 CRC16 并推进扫描位置，返回 HEADER_CRC。
                HEADER_CRC_BYTE : begin
                    header_crc <= crc16 (header_crc, byte_value);
                    scan_pos <= scan_pos + 1'b1;
                    state <= HEADER_CRC;
                end
                // 比较头 CRC，成功后读数据文件数量。
                HEADER_CRC_CHECK : if (number != header_crc) fail (3);
                else get_number (2, header_pointer, 2, HEADER_COUNT);
                // 只接受一个数据文件，随后读取名字长度。
                HEADER_COUNT : if (number != 1) fail (1);
                else get_number (2, header_pointer + 4, 2, HEADER_NLEN);
                // 检查数据名字长度，按偶数字节对齐定位件号长度。
                HEADER_NLEN : if (number == 0 || number > 63) fail (1);
                else begin
                    data_name_len <= number[6:0];
                    data_name_addr <= header_pointer + 6;
                    get_number (2, header_pointer + 6 + ((number + 1) & 32'hfffffffe), 2, HEADER_PLEN);
                end
                // 检查件号长度并跳过偶数字节对齐字段，转 HEADER_SIZE。
                HEADER_PLEN : if (number > 64) fail (1);
                else begin
                    scan_pos <= fetch_addr + ((number + 1) & 32'hfffffffe);
                    state <= HEADER_SIZE;
                end
                // 读取数据文件的 16 位字数，转 HEADER_DCRC。
                HEADER_SIZE : get_number (2, scan_pos, 4, HEADER_DCRC);
                // 限制到 1–4096 字（最多 8 KiB），随后读取预期数据 CRC。
                HEADER_DCRC : if (number == 0 || number > 4096) fail (2);
                else begin
                    file_size <= number[12:0] << 1;
                    get_number (2, scan_pos + 4, 2, HEADER_READY);
                end
                // 保存预期 CRC，发处理中 LUS，确认后 RRQ_DATA。
                HEADER_READY : begin
                    expected_crc <= number[15:0];
                    lus_status <= 2;
                    lus_return <= RRQ_DATA;
                    state <= START_LUS;
                end
                // 请求数据文件，清加载计数和 CRC，等待 DATA1。
                RRQ_DATA : begin
                    file_kind <= 2;
                    loaded <= 0;
                    data_crc <= 16'hffff;
                    main_tid <= tid_sequence;
                    main_peer <= 0;
                    tid_sequence <= tid_sequence + 1'b1;
                    block_number <= 1;
                    wait_kind <= WK_DATA;
                    make_packet (PK_RRQ, data_name_len + 9, tid_sequence, request_port, WAIT_PACKET);
                end
                // 比较实际字节数与数据 CRC；通过后先 ACK 最后块，再 DATA_SUCCESS。
                DATA_CHECK : if (loaded != file_size) fail (2);
                else if (data_crc != expected_crc) fail (3);
                else begin
                    ack_return <= DATA_SUCCESS;
                    state <= ACK_MAIN;
                end
                // 公布成功加载区长度，发成功 LUS，确认后 DONE。
                DATA_SUCCESS : begin
                    available_size <= loaded;
                    lus_status <= 3;
                    lus_return <= DONE;
                    state <= START_LUS;
                end
                // 先发 TFTP ERROR，发送后 FAILURE_SENT。
                FAILURE : begin
                    make_packet (PK_ERROR, 11, main_tid, main_peer == 0 ? request_port : main_peer, FAILURE_SENT);
                end
                // 再发失败 LUS/LNS，确认或重试结束后 DONE。
                FAILURE_SENT : begin
                    lus_status <= 16'h1003;
                    lus_return <= DONE;
                    state <= START_LUS;
                end
                // 锁存成功/失败状态，回 IDLE 等下一次操作。
                DONE : begin
                    status <= reason == 0 ? 2 : 3;
                    state <= IDLE;
                    wait_kind <= WK_LUR;
                end
                default : state <= IDLE;
            endcase
        end
    end
endmodule
