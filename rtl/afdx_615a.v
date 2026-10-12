// 本模块按 ARINC 615A 接收加载文件，也能把已加载的数据发回。
// 报文从 afdx_svc 进入，回应经同一模块交给发送核心。
// ARINC 615A 用 TFTP（Trivial File Transfer Protocol，简单文件传输协议）传文件。
// 本模块对应赛题的加卸载功能，一次处理一个头文件和一个数据文件。
// 加载区最多保存 8 KiB 数据，校验成功后才允许卸载。
module afdx_615a (
    // enable 为高且配置已启用时，模块才接受加卸载请求。
    input wire clk, reset, enable,
    // cfg_* 设置服务参数，并读取状态、加载字节数和加载区内容。
    // cfg_extra_data 返回端口与重试设置。
    input wire cfg_we,
    input wire [7:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata, cfg_extra_data,
    // tx_valid 和 tx_ready 同为高时发送一个报文字节。
    // tx_last 标记末字节，tx_vl 选择发送配置，tx_sport/dport 给出两端端口。
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output reg [6:0] tx_vl,
    output reg [15:0] tx_sport, tx_dport,
    // rx_valid 为高时必须接收当前字节，rx_last 标记报文末字节。
    // 目的端口匹配当前服务或传输任务时，rx_claim 为高。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_sport, rx_dport,
    output wire rx_claim);
    // 这些状态接收并检查请求。
    localparam REASON_NONE = 0;
    localparam REASON_DESCRIPTION = 1;
    localparam REASON_LENGTH = 2;
    localparam REASON_CHECKSUM = 3;
    localparam REASON_TFTP_ERROR = 4;
    localparam REASON_RETRY_LIMIT = 5;
    localparam IDLE = 0;
    localparam WAIT_PACKET = 1;
    localparam DISPATCH = 2;
    localparam NAME = 3;
    localparam NAME_BYTE = 4;
    localparam MODE = 5;
    localparam MODE_BYTE = 6;
    localparam REQUEST_OK = 7;
    localparam DENY_SEND = 70;
    // 这些状态从存储器读取字节或数字。
    localparam FETCH = 8;
    localparam FETCH_WAIT = 9;
    localparam FETCH_CAPTURE = 10;
    localparam FETCH_DONE = 11;
    localparam NUMBER = 12;
    localparam NUMBER_BYTE = 13;
    // 这些状态构造并发送报文。
    localparam BUILD = 14;
    localparam BUILD_PREP = 60;
    localparam EMIT = 15;
    localparam BUILD_FLUSH = 16;
    localparam TX_ADDR = 17;
    localparam TX_WAIT = 18;
    localparam TX_CAPTURE = 19;
    localparam TX_SEND = 20;
    localparam ACK_MAIN = 28;
    // 这些状态计算进度并报告加载状态。
    localparam START_LUS = 21;
    localparam RATIO_SCALE = 22;
    localparam RATIO_SUB = 23;
    localparam RATIO_DEC = 24;
    localparam LUS_WRQ = 25;
    localparam LUS_DATA = 26;
    localparam LUS_DONE = 27;
    // 这些状态接收并保存文件内容。
    localparam DATA_COPY = 29;
    localparam DATA_BYTE = 30;
    localparam DATA_END = 31;
    // 这些状态检查上传请求列表。
    localparam LUR_START = 32;
    localparam LUR_LENGTH = 33;
    localparam LUR_VERSION = 34;
    localparam LUR_COUNT = 35;
    localparam LUR_HLEN = 36;
    localparam LUR_PLEN = 37;
    localparam LUR_OFFSETS = 61;
    localparam LUR_READY = 38;
    // 这些状态获取并检查头文件。
    localparam RRQ_HEADER = 39;
    localparam HEADER_START = 40;
    localparam HEADER_LENGTH = 41;
    localparam HEADER_VERSION = 42;
    localparam HEADER_PTR = 43;
    localparam HEADER_PTR_CHECK = 71;
    localparam HEADER_CRC = 44;
    localparam HEADER_CRC_BYTE = 45;
    localparam HEADER_CRC_EXPECT = 46;
    localparam HEADER_CRC_CHECK = 47;
    localparam HEADER_COUNT = 48;
    localparam HEADER_NLEN = 49;
    localparam HEADER_PLEN = 50;
    localparam HEADER_SIZE = 51;
    localparam HEADER_DCRC = 52;
    localparam HEADER_READY = 53;
    // 这些状态获取并校验数据文件。
    localparam RRQ_DATA = 54;
    localparam DATA_CHECK = 55;
    localparam DATA_SUCCESS = 56;
    // 这些状态检查卸载请求并传送加载区内容。
    localparam LNR_USER = 62;
    localparam LNR_NAME = 63;
    localparam LNR_BYTE = 64;
    localparam LNR_READY = 65;
    localparam DL_WRQ = 66;
    localparam DL_BLOCK = 67;
    localparam DL_SIZE = 68;
    localparam DL_ACK = 69;
    // 这些状态报告失败或结束本次操作。
    localparam FAILURE = 57;
    localparam FAILURE_SENT = 58;
    localparam DONE = 59;
    // state 记录当前文件处理步骤，HEADER_CRC_EXPECT 是未使用的编码。
    // wait_kind 记录当前等待哪一种确认或文件，packet_type 选择待发报文。
    localparam WK_LUI_ACK = 0, WK_LUR = 1, WK_DATA = 2, WK_LUS_ACK0 = 3, WK_LUS_ACK1 = 4,
        WK_DL_ACK0 = 5, WK_DL_ACK = 6;
    localparam PK_ACK = 0, PK_LUI = 1, PK_RRQ = 2, PK_LUS_WRQ = 3, PK_LUS = 4, PK_ERROR = 5, PK_DL_DATA = 6;
    // reason=1 表示文件描述内容错误。
    // reason=2 表示容量或长度错误。
    // reason=3 表示校验值错误。
    // reason=4 表示收到 TFTP 错误报文。
    // reason=5 表示重试次数已用完。
    reg configured, protocol_a4;
    reg [1:0] status;
    reg [7:0] reason;
    // return_state/num_return 保存读取完成后应回到的状态。
    // after_tx/lus_return/ack_return 保存发送或确认后的返回状态。
    reg [7:0] state, return_state, num_return, after_tx, lus_return, ack_return;
    reg [2:0] wait_kind, packet_type;
    reg [1:0] file_kind, fetch_source;
    // main_tid/main_peer 保存传数据文件时本端和对端的 UDP 端口。
    // status_tid/status_peer 保存传状态文件时本端和对端的 UDP 端口。
    reg [15:0] main_tid, main_peer, status_tid, status_peer, tid_sequence;
    reg [15:0] block_number, ack_number, lus_counter, request_port;
    // timer 在等待报文时倒计时，超时后重发 packet_tx 中的内容。
    // retry_total 统计累计重发次数。
    reg [31:0] timer, retry_total, timeout_cycles;
    reg [7:0] retries, retry_limit;
    // loaded/file_size 保存本次已加载字节数和期望大小。
    // 校验成功后才更新 available_size，供卸载读取。
    reg [13:0] loaded, file_size;
    reg [13:0] available_size, dl_acked, dl_remaining;
    reg [12:0] dl_read_addr;
    reg download_mode, request_download, request_unsupported, deny_empty, deny_unsupported;
    reg [7:0] request_resume;
    reg [4:0] deny_pos;
    reg [15:0] deny_tid, saved_sport, saved_dport;
    // data_crc/expected_crc 用于核对数据文件，header_crc 用于核对头文件。
    // 16 位校验使用多项式 0x1021。
    reg [15:0] data_crc, expected_crc, header_crc;
    // metadata_size 保存列表或头文件的长度。
    // name_addr/len 和 header_pointer 定位变长字段。
    // 文件里的指针以两个字节为单位，使用前先乘二。
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
    // packet_rx 保存收到的报文，容量为 1 KiB。
    // packet_tx 保存待发报文，容量为 1 KiB。
    // lur_ram 保存请求列表，容量为 512 字节。
    // header_ram 保存头文件，容量为 2 KiB。
    // load_ram 保存加载数据，容量为 8 KiB。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_rx (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(rx_we),
        .write_address(rx_wa),
        .write_data(rx_wd),
        .read_enable(rx_re),
        .read_address(rx_ra),
        .read_data(rx_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_tx (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(tx_we),
        .write_address(tx_wa),
        .write_data(tx_wd),
        .read_enable(tx_re),
        .read_address(tx_ra),
        .read_data(tx_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(512)) lur_ram (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(lur_we),
        .write_address(lur_wa),
        .write_data(lur_wd),
        .read_enable(lur_re),
        .read_address(lur_ra),
        .read_data(lur_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(2048)) header_ram (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(hdr_we),
        .write_address(hdr_wa),
        .write_data(hdr_wd),
        .read_enable(hdr_re),
        .read_address(hdr_ra),
        .read_data(hdr_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(8192)) load_ram (
        // 这些端口用于时钟和复位。
        .clk(clk),
        // 这些端口用于数据和握手。
        .write_enable(load_we),
        .write_address(load_wa),
        .write_data(load_wd),
        .read_enable(load_re),
        .read_address(load_ra),
        .read_data(load_q)
    );
    assign rx_claim = enable && configured && (rx_dport == request_port || rx_dport == main_tid
        || rx_dport == status_tid || rx_dport == deny_tid);
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
    // 拒绝新请求时使用独立输出，避免覆盖仍需重发的报文。
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
            if (reason == REASON_NONE) description = 0;
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
    // get_byte 读取一个字节，get_number 读取高字节在前的整数。
    // 两者先保存返回状态，再进入同步读取过程。
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
    // 开始构造报文时，先保存端口、报文类型和发送后的返回状态。
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
    // 接收口不能暂停发送方，每次只处理一个等待确认的数据块。
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
            reason <= REASON_NONE;
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
            // 配置口写 B4 后等四拍再读 B5，且只能在加载停止后读加载区。
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
                8'hbb : if (status != 1 && (cfg_wdata[15:0] == 16'h4133
                    || cfg_wdata[15:0] == 16'h4134)) protocol_a4 <= cfg_wdata[15:0] == 16'h4134;
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
            // 加载操作依次交换初始化、状态、请求列表、头文件和数据文件。
            // 卸载操作依次交换初始化、状态、请求列表和数据文件。
            // 状态名里的缩写：LUS 是加载状态文件，LUR 是加载请求列表，LNR 是卸载请求列表。
            // WRQ 和 RRQ 是 TFTP 的写请求和读请求，DL 表示卸载。
            case (state)
                // IDLE：等完整请求，服务已启用且收到请求时转 DISPATCH。
                IDLE : if (packet_pending && enable && configured) begin
                    consume <= 1;
                    request_resume <= IDLE;
                    state <= DISPATCH;
                end
                // WAIT_PACKET：等下一报文，超时则重发，重试耗尽时结束本次操作。
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
                                reason <= REASON_RETRY_LIMIT;
                                status <= 3;
                                state <= DONE;
                            end
                            else fail (REASON_RETRY_LIMIT);
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
                // DISPATCH：核对报文类型、块号和端口，再进入相应处理状态。
                DISPATCH : begin
                    if (peer_dp == request_port && (rx_op == 1 || rx_op == 2)) begin
                        request_write <= rx_op == 2;
                        request_download <= 0;
                        request_unsupported <= 0;
                        name_pos <= 0;
                        state <= NAME;
                    end
                    else if (rx_op == 5 && peer_dp == main_tid) fail (REASON_TFTP_ERROR);
                    else if (rx_op == 5 && peer_dp == status_tid) begin
                        reason <= REASON_TFTP_ERROR;
                        status <= 3;
                        state <= DONE;
                    end
                    else if (wait_kind == WK_LUI_ACK && peer_dp == main_tid && peer_sp == main_peer && rx_op == 4
                        && rx_block == 1) begin
                        lus_status <= 1;
                        lus_return <= LUS_DONE;
                        state <= START_LUS;
                    end
                    else if (wait_kind == WK_LUS_ACK0 && peer_dp == status_tid && rx_op == 4 && rx_block == 0) begin
                        status_peer <= peer_sp;
                        state <= LUS_DATA;
                    end
                    else if (wait_kind == WK_LUS_ACK1 && peer_dp == status_tid && peer_sp == status_peer
                        && rx_op == 4 && rx_block == 1) state <= lus_return;
                    else if (wait_kind == WK_DL_ACK0 && peer_dp == main_tid && rx_op == 4 && rx_block == 0) begin
                        main_peer <= peer_sp;
                        block_number <= 1;
                        state <= DL_BLOCK;
                    end
                    else if (wait_kind == WK_DL_ACK && peer_dp == main_tid && peer_sp == main_peer && rx_op == 4
                        && rx_block == block_number) state <= DL_ACK;
                    else if (wait_kind == WK_DATA && peer_dp == main_tid && rx_op == 3 && (main_peer == 0
                        || peer_sp == main_peer)) begin
                        main_peer <= peer_sp;
                        if (rx_block == block_number && rx_length >= 4 && rx_length <= 516) begin
                            copy_len <= rx_length - 4;
                            copy_pos <= 0;
                            state <= DATA_COPY;
                        end
                        else if (rx_block == block_number - 1'b1) begin
                            // 重复数据块只重新发送确认，不再次写入加载区。
                            ack_number <= rx_block;
                            make_packet (PK_ACK, 4, main_tid, peer_sp, WAIT_PACKET);
                        end
                        else state <= WAIT_PACKET;
                    end
                    else state <= status == 1 ? WAIT_PACKET : IDLE;
                end
                // NAME：读取文件名的下一字节，然后转 NAME_BYTE。
                NAME : get_byte (0, { 6'b0, name_pos } + 11'd2, NAME_BYTE);
                // NAME_BYTE：识别操作文件名，名字读完后转 MODE，非法名字返回错误。
                NAME_BYTE : if (name_pos == 9 && (byte_value == "U" || byte_value == "N" || (!request_write
                    && byte_value == "C"))) begin
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
                else if (byte_value != target_name (name_pos, request_write ? "R" : request_download ? "D" : "I",
                    request_download)) begin
                    reason <= REASON_DESCRIPTION;
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
                // MODE：读取传输模式的下一字节，然后转 MODE_BYTE。
                MODE : get_byte (0, { 6'b0, name_pos } + 11'd14, MODE_BYTE);
                // MODE_BYTE：只接受 octet 模式，读完后转 REQUEST_OK，否则返回错误。
                MODE_BYTE : if ((byte_value | 8'h20) != (octet_byte (name_pos) | 8'h20) || (name_pos == 5
                    && byte_value != 0)) begin
                    reason <= REASON_TFTP_ERROR;
                    make_packet (PK_ERROR, 11, tid_sequence, peer_sp, IDLE);
                    // 按 RFC 2347 忽略模式字段后的选项，继续使用基本文件传输方式。
                end
                else if (name_pos == 5) state <= REQUEST_OK;
                else begin
                    name_pos <= name_pos + 1'b1;
                    state <= MODE;
                end
                // REQUEST_OK：接受请求后启动文件流程，无法接受时转 DENY_SEND。
                REQUEST_OK : begin
                    if (request_unsupported || (!request_write && status == 1) || (request_write && status == 1
                        && request_download != download_mode) ||
                        (!request_write && request_download && available_size == 0)) begin
                        // 信息操作和操作员定义卸载返回状态 1002，不启动后续传输。
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
                        reason <= REASON_NONE;
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
                        reason <= REASON_TFTP_ERROR;
                        make_packet (PK_ERROR, 11, tid_sequence, peer_sp, IDLE);
                    end
                end
                // DENY_SEND：发送拒绝回应，末字节握手后恢复原等待状态。
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
                // FETCH：请求读取指定存储区的字节，然后转 FETCH_WAIT。
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
                // FETCH_WAIT：等待同步读取，然后转 FETCH_CAPTURE。
                FETCH_WAIT : state <= FETCH_CAPTURE;
                // FETCH_CAPTURE：保存读出的字节，然后转 FETCH_DONE。
                FETCH_CAPTURE : begin
                    case (fetch_source)
                        0 : byte_value <= rx_q;
                        1 : byte_value <= lur_q;
                        2 : byte_value <= hdr_q;
                        3 : byte_value <= load_q;
                    endcase
                    state <= FETCH_DONE;
                end
                // FETCH_DONE：返回 get_byte 保存的调用状态。
                FETCH_DONE : state <= return_state;
                // NUMBER：读取整数的下一字节，然后转 NUMBER_BYTE。
                NUMBER : begin
                    return_state <= NUMBER_BYTE;
                    state <= FETCH;
                end
                // NUMBER_BYTE：拼接整数，读够后返回 num_return，否则转 NUMBER。
                NUMBER_BYTE : begin
                    number <= { number[23:0], byte_value };
                    fetch_addr <= fetch_addr + 1'b1;
                    number_left <= number_left - 1'b1;
                    state <= number_left == 1 ? num_return : NUMBER;
                end
                // 字段位置先算好并寄存，下一拍再选择字节，以缩短组合路径。
                // BUILD_PREP：计算本字节使用的地址，然后转 BUILD。
                BUILD_PREP : begin
                    tail_index <= packet_pos - lus_tail_pos;
                    head_index <= packet_pos - 10'd33;
                    part_index <= packet_pos - lus_part_pos;
                    name_end <= packet_len - 10'd7;
                    mode_start <= packet_len - 10'd6;
                    dl_read_addr <= dl_acked[12:0] + packet_pos - 10'd4;
                    state <= BUILD;
                end
                // BUILD：选择本字节内容，需读存储器时先读取，随后转 EMIT。
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
                            3 : build_value <= reason == REASON_DESCRIPTION ? 1 : reason == REASON_TFTP_ERROR ? 4 : 0;
                            default : if (packet_pos >= 4) build_value <= description (packet_pos - 4);
                        endcase
                        PK_LUS_WRQ : begin
                            if (packet_pos == 1) build_value <= 2;
                            else if (packet_pos >= 2 && packet_pos < 14) build_value <= target_name (packet_pos - 2,
                                "S", download_mode);
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
                                    if (packet_pos >= 13
                                        && packet_pos <= 20) build_value <= description (packet_pos - 13);
                                    else if (packet_pos >= 33 && packet_pos < lus_partlen_pos) get_byte (1,
                                        header_name_addr + head_index, EMIT);
                                    else if (!download_mode && packet_pos == lus_partlen_pos) build_value <= part_len;
                                    else if (!download_mode && packet_pos >= lus_part_pos
                                        && packet_pos < lus_tail_pos) get_byte (1,
                                        part_addr + part_index, EMIT);
                                    else if (download_mode && packet_pos >= 33
                                        && packet_pos >= lus_tail_pos) case (tail_index)
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
                // EMIT：写入待发字节，未写完转 BUILD_PREP，写完转 BUILD_FLUSH。
                EMIT : begin
                    tx_we <= 1;
                    tx_wa <= packet_pos;
                    tx_wd <= return_state == EMIT ? byte_value : build_value;
                    return_state <= 0;
                    packet_pos <= packet_pos + 1'b1;
                    state <= packet_pos + 1'b1 == packet_len ? BUILD_FLUSH : BUILD_PREP;
                end
                // BUILD_FLUSH：等最后一次写入完成，然后转 TX_ADDR。
                BUILD_FLUSH : begin
                    packet_pos <= 0;
                    state <= TX_ADDR;
                end
                // TX_ADDR：请求读取待发字节，然后转 TX_WAIT。
                TX_ADDR : begin
                    tx_re <= 1;
                    tx_ra <= packet_pos;
                    state <= TX_WAIT;
                end
                // TX_WAIT：等待同步读取，然后转 TX_CAPTURE。
                TX_WAIT : state <= TX_CAPTURE;
                // TX_CAPTURE：保存待发字节，然后转 TX_SEND。
                TX_CAPTURE : begin
                    tx_data <= tx_q;
                    state <= TX_SEND;
                end
                // TX_SEND：等待握手，未发完转 TX_ADDR，发完返回 after_tx。
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
                // START_LUS：准备状态文件的端口和进度，然后转 RATIO_SCALE。
                START_LUS : begin
                    lus_counter <= lus_counter + 1'b1;
                    status_tid <= tid_sequence;
                    tid_sequence <= tid_sequence + 1'b1;
                    percent <= 0;
                    scaled <= download_mode ? {6'b0, dl_acked} : {6'b0, loaded};
                    state <= RATIO_SCALE;
                end
                // RATIO_SCALE：把已完成字节数乘 100，然后转 RATIO_SUB。
                RATIO_SCALE : begin
                    scaled <= (scaled << 6) + (scaled << 5) + (scaled << 2);
                    state <= RATIO_SUB;
                end
                // RATIO_SUB：用反复相减求百分比，求完后转 RATIO_DEC。
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
                // RATIO_DEC：把百分比变成十进制数字，完成后转 LUS_WRQ。
                RATIO_DEC : if (decimal_rest >= 10) begin
                    decimal_rest <= decimal_rest - 10;
                    decimal_tens <= decimal_tens + 1'b1;
                end
                else begin
                    ratio_t <= lus_status == 3 ? "0" : decimal_tens == 0 ? " " : 8'h30 + decimal_tens;
                    ratio_u <= 8'h30 + decimal_rest;
                    state <= LUS_WRQ;
                end
                // LUS_WRQ：请求发送状态文件，发完后等待第零块确认。
                LUS_WRQ : begin
                    wait_kind <= WK_LUS_ACK0;
                    make_packet (PK_LUS_WRQ, 20, status_tid, request_port, WAIT_PACKET);
                end
                // LUS_DATA：发送状态文件数据，发完后等待第一块确认。
                LUS_DATA : begin
                    wait_kind <= WK_LUS_ACK1;
                    make_packet (PK_LUS, manifest ? lus_packet_len : 32, status_tid, status_peer, WAIT_PACKET);
                end
                // LUS_DONE：初始状态文件获确认后转 IDLE，等待文件列表。
                LUS_DONE : begin
                    wait_kind <= WK_LUR;
                    state <= IDLE;
                end
                // ACK_MAIN：构造当前数据块的确认，发送后返回 ack_return。
                ACK_MAIN : begin
                    wait_kind <= WK_DATA;
                    make_packet (PK_ACK, 4, main_tid, main_peer, ack_return);
                end
                // DATA_COPY：读下一有效字节，转 DATA_BYTE；全部读完转 DATA_END。
                DATA_COPY : begin
                    if (copy_pos == copy_len) state <= DATA_END;
                    else get_byte (0, copy_pos + 4, DATA_BYTE);
                end
                // DATA_BYTE：保存一个文件字节并更新校验，再转 DATA_COPY。
                DATA_BYTE : begin
                    if (file_kind == 0) begin
                        if (metadata_size >= 512) fail (REASON_LENGTH);
                        else begin
                            lur_we <= 1;
                            lur_wa <= metadata_size[8:0];
                            lur_wd <= byte_value;
                            metadata_size <= metadata_size + 1'b1;
                            state <= DATA_COPY;
                        end
                    end
                    else if (file_kind == 1) begin
                        if (metadata_size >= 2048) fail (REASON_LENGTH);
                        else begin
                            hdr_we <= 1;
                            hdr_wa <= metadata_size[10:0];
                            hdr_wd <= byte_value;
                            metadata_size <= metadata_size + 1'b1;
                            state <= DATA_COPY;
                        end
                    end
                    else begin
                        if (loaded >= 8192) fail (REASON_LENGTH);
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
                // DATA_END：确认当前块；短块结束文件，再转对应的文件检查过程。
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
                // LUR_START：读取加载列表总长，然后转 LUR_LENGTH。
                LUR_START : get_number (1, 0, 4, LUR_LENGTH);
                // LUR_LENGTH：核对总长，通过后读取协议版本，否则报告失败。
                LUR_LENGTH : if (number != metadata_size) fail (REASON_DESCRIPTION);
                else get_number (1, 4, 2, LUR_VERSION);
                // LUR_VERSION：检查 A3/A4 版本，通过后读取文件数量，否则报告失败。
                LUR_VERSION : if (number != 16'h4133 && number != 16'h4134) fail (REASON_DESCRIPTION);
                else get_number (1, 6, 2, LUR_COUNT);
                // LUR_COUNT：检查文件数量为一，通过后读取文件名长度，否则报告失败。
                LUR_COUNT : if (number != 1) fail (REASON_DESCRIPTION);
                else get_byte (1, 8, LUR_HLEN);
                // LUR_HLEN：检查文件名长度，加载时继续读件号，卸载时转 LNR_USER。
                LUR_HLEN : if (byte_value < 2 || byte_value > 64) fail (REASON_DESCRIPTION);
                else begin
                    header_name_len <= byte_value[6:0];
                    header_name_addr <= 9;
                    get_byte (1, 11'd9 + byte_value, download_mode ? LNR_USER : LUR_PLEN);
                end
                // LUR_PLEN：检查件号长度，通过后转 LUR_OFFSETS，否则报告失败。
                LUR_PLEN : if (byte_value < 2 || byte_value > 64) fail (REASON_DESCRIPTION);
                else begin
                    part_len <= byte_value[6:0];
                    part_addr <= 10 + header_name_len;
                    lus_partlen_pos <= 10'd33 + header_name_len;
                    lus_part_pos <= 10'd34 + header_name_len;
                    state <= LUR_OFFSETS;
                end
                // LUR_OFFSETS：计算状态文件中变长字段的位置，然后转 LUR_READY。
                LUR_OFFSETS : begin
                    lus_tail_pos <= lus_part_pos + part_len;
                    state <= LUR_READY;
                end
                // LUR_READY：报告列表已接受，状态获确认后转 RRQ_HEADER。
                LUR_READY : begin
                    lus_packet_len <= lus_tail_pos + 10'd14;
                    manifest <= 1;
                    lus_status <= 2;
                    lus_return <= RRQ_HEADER;
                    state <= START_LUS;
                end
                // 卸载列表的文件名之后是用户数据，卸载状态不含加载件号字段。
                // LNR_USER：检查卸载列表的用户数据长度，通过后转 LNR_NAME。
                LNR_USER : begin
                    manifest <= 1;
                    lus_partlen_pos <= 10'd33 + header_name_len;
                    lus_tail_pos <= 10'd33 + header_name_len;
                    lus_packet_len <= 10'd44 + header_name_len;
                    scan_pos <= 0;
                    if (metadata_size != 12'd10 + header_name_len + byte_value || header_name_len != 11)
                        fail(REASON_DESCRIPTION);
                    else state <= LNR_NAME;
                end
                // LNR_NAME：读取卸载文件名的下一字节，然后转 LNR_BYTE。
                LNR_NAME : get_byte(1, 13'd9 + scan_pos, LNR_BYTE);
                // LNR_BYTE：核对 MEMORY.BIN，完全匹配后转 LNR_READY，否则报告失败。
                LNR_BYTE : if (byte_value != memory_name(scan_pos[6:0])) fail(REASON_DESCRIPTION);
                else if (scan_pos == 10) state <= LNR_READY;
                else begin scan_pos <= scan_pos + 1'b1; state <= LNR_NAME; end
                // LNR_READY：报告卸载列表已接受，状态获确认后转 DL_WRQ。
                LNR_READY : begin
                    lus_status <= 2;
                    lus_return <= DL_WRQ;
                    state <= START_LUS;
                end
                // DL_WRQ：请求发送 MEMORY.BIN，发完后等待第零块确认。
                DL_WRQ : begin
                    main_tid <= tid_sequence;
                    main_peer <= 0;
                    tid_sequence <= tid_sequence + 1'b1;
                    wait_kind <= WK_DL_ACK0;
                    make_packet(PK_RRQ, 19, tid_sequence, request_port, WAIT_PACKET);
                end
                // DL_BLOCK：计算剩余待卸载字节数，然后转 DL_SIZE。
                DL_BLOCK : begin
                    dl_remaining <= file_size - dl_acked;
                    state <= DL_SIZE;
                end
                // DL_SIZE：发送最多 512 字节，发完后等待对应块的确认。
                DL_SIZE : begin
                    copy_len <= dl_remaining >= 512 ? 512 : dl_remaining[10:0];
                    wait_kind <= WK_DL_ACK;
                    make_packet(PK_DL_DATA, dl_remaining >= 512 ? 516 : dl_remaining[9:0] + 10'd4, main_tid,
                        main_peer, WAIT_PACKET);
                end
                // DL_ACK：更新已确认字节数，未完转 DL_BLOCK，完成则发送成功状态。
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
                // RRQ_HEADER：请求加载头文件，发完后等待第一块数据。
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
                // HEADER_START：读取头文件字数，然后转 HEADER_LENGTH。
                HEADER_START : get_number (2, 0, 4, HEADER_LENGTH);
                // HEADER_LENGTH：核对字数与实际长度，通过后读取格式版本。
                HEADER_LENGTH : if ((number << 1) != metadata_size || metadata_size < 32) fail (REASON_DESCRIPTION);
                else get_number (2, 4, 2, HEADER_VERSION);
                // HEADER_VERSION：检查版本为 0x8002，通过后读取数据文件指针。
                HEADER_VERSION : if (number != 16'h8002) fail (REASON_DESCRIPTION);
                else get_number (2, 14, 4, HEADER_PTR);
                // HEADER_PTR：检查指针范围并保存结果，然后转 HEADER_PTR_CHECK。
                HEADER_PTR : begin
                    // 先保存范围检查结果，下一拍再决定是否继续。
                    header_pointer_ok <= number >= 13 && (number << 1) < metadata_size - 6;
                    state <= HEADER_PTR_CHECK;
                end
                // HEADER_PTR_CHECK：合法时开始 HEADER_CRC，否则报告失败。
                HEADER_PTR_CHECK : if (!header_pointer_ok) fail (REASON_DESCRIPTION);
                else begin
                    header_pointer <= number[10:0] << 1;
                    header_crc <= 16'hffff;
                    scan_pos <= 0;
                    state <= HEADER_CRC;
                end
                // HEADER_CRC：读取下一校验字节；读完覆盖区后读取预期校验值。
                HEADER_CRC : if (scan_pos == metadata_size - 6) get_number (2, scan_pos, 2, HEADER_CRC_CHECK);
                else get_byte (2, scan_pos, HEADER_CRC_BYTE);
                // HEADER_CRC_BYTE：更新头文件校验值，再转 HEADER_CRC。
                HEADER_CRC_BYTE : begin
                    header_crc <= crc16 (header_crc, byte_value);
                    scan_pos <= scan_pos + 1'b1;
                    state <= HEADER_CRC;
                end
                // HEADER_CRC_CHECK：核对头文件校验值，通过后读取数据文件数量。
                HEADER_CRC_CHECK : if (number != header_crc) fail (REASON_CHECKSUM);
                else get_number (2, header_pointer, 2, HEADER_COUNT);
                // HEADER_COUNT：要求只有一个数据文件，通过后读取文件名长度。
                HEADER_COUNT : if (number != 1) fail (REASON_DESCRIPTION);
                else get_number (2, header_pointer + 4, 2, HEADER_NLEN);
                // HEADER_NLEN：检查文件名长度，通过后定位件号字段。
                HEADER_NLEN : if (number == 0 || number > 63) fail (REASON_DESCRIPTION);
                else begin
                    data_name_len <= number[6:0];
                    data_name_addr <= header_pointer + 6;
                    get_number (2, header_pointer + 6 + ((number + 1) & 32'hfffffffe), 2, HEADER_PLEN);
                end
                // HEADER_PLEN：检查件号长度并处理偶数字节对齐，然后转 HEADER_SIZE。
                HEADER_PLEN : if (number > 64) fail (REASON_DESCRIPTION);
                else begin
                    scan_pos <= fetch_addr + ((number + 1) & 32'hfffffffe);
                    state <= HEADER_SIZE;
                end
                // HEADER_SIZE：读取数据文件的字数，然后转 HEADER_DCRC。
                HEADER_SIZE : get_number (2, scan_pos, 4, HEADER_DCRC);
                // HEADER_DCRC：检查数据量不超过 8 KiB，通过后读取预期校验值。
                HEADER_DCRC : if (number == 0 || number > 4096) fail (REASON_LENGTH);
                else begin
                    file_size <= number[12:0] << 1;
                    get_number (2, scan_pos + 4, 2, HEADER_READY);
                end
                // HEADER_READY：保存预期校验值并报告进度，获确认后转 RRQ_DATA。
                HEADER_READY : begin
                    expected_crc <= number[15:0];
                    lus_status <= 2;
                    lus_return <= RRQ_DATA;
                    state <= START_LUS;
                end
                // RRQ_DATA：请求数据文件，发完后等待第一块数据。
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
                // DATA_CHECK：核对文件大小和校验值，通过并确认末块后转 DATA_SUCCESS。
                DATA_CHECK : if (loaded != file_size) fail (REASON_LENGTH);
                else if (data_crc != expected_crc) fail (REASON_CHECKSUM);
                else begin
                    ack_return <= DATA_SUCCESS;
                    state <= ACK_MAIN;
                end
                // DATA_SUCCESS：公布加载区有效长度并报告成功，获确认后转 DONE。
                DATA_SUCCESS : begin
                    available_size <= loaded;
                    lus_status <= 3;
                    lus_return <= DONE;
                    state <= START_LUS;
                end
                // FAILURE：发送文件传输错误，发送完成后转 FAILURE_SENT。
                FAILURE : begin
                    make_packet (PK_ERROR, 11, main_tid, main_peer == 0 ? request_port : main_peer, FAILURE_SENT);
                end
                // FAILURE_SENT：发送失败状态，确认或重试结束后转 DONE。
                FAILURE_SENT : begin
                    lus_status <= 16'h1003;
                    lus_return <= DONE;
                    state <= START_LUS;
                end
                // DONE：保存最终结果，然后转 IDLE 等待下一次操作。
                DONE : begin
                    status <= reason == REASON_NONE ? 2 : 3;
                    state <= IDLE;
                    wait_kind <= WK_LUR;
                end
                default : state <= IDLE;
            endcase
        end
    end
endmodule
