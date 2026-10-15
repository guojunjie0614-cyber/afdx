// 本模块按 ARINC 615A 接收加载文件，也能把已加载的数据发回。
// 报文从 afdx_svc 进入，回应经同一模块交给发送核心。
// ARINC 615A 用 TFTP（Trivial File Transfer Protocol，简单文件传输协议）传文件。
// 本模块对应赛题的加卸载功能，一次处理一个头文件和一个数据文件。
// 加载区最多保存 8 KiB 数据，校验成功后才允许卸载。
module afdx_615a #(parameter LOCAL_RX_PORT = 0, SPLIT_CFG_ADDR = 0, CE_DIV = 2) (

    // enable 为高且配置已启用时，模块才接受加卸载请求。
    input wire clk, reset, enable, ce,

    // cfg_* 设置服务参数，并读取状态、加载字节数和加载区内容。
    // cfg_extra_data 返回端口与重试设置。
    input wire cfg_we,
    input wire [(SPLIT_CFG_ADDR ? 11 : 8) - 1:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_rdata, cfg_extra_data,

    // tx_valid 和 tx_ready 同为高时发送一个报文字节。
    // tx_last 标记末字节，tx_vl 选择发送配置，tx_sport/dport 给出两端端口。
    output wire tx_valid,
    input wire tx_ready,
    output wire [7:0] tx_data,
    output wire tx_last,
    output wire [6:0] tx_vl,
    output wire [15:0] tx_sport, tx_dport,

    // rx_valid 为高时必须接收当前字节，rx_last 标记报文末字节。
    // 目的端口匹配当前服务或传输任务时，rx_claim 为高。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_sport, rx_dport,
    output wire rx_claim);

    // 分离模式把主机写地址放在高 8 位，低 3 位保持共享读地址。
    // 默认位宽兼容独立使用；主机写译码不再经过网络管理读地址的选择器。
    wire [7:0] cfg_write_addr = SPLIT_CFG_ADDR ? cfg_addr >> 3 : cfg_addr;

    // 全速配置、捕获和加载区读回使用的常量。
    localparam ST_IDLE = 0, ST_BUSY = 1, ST_SUCCESS = 2, ST_FAILED = 3;
    localparam VERSION_A3 = 16'h4133, VERSION_A4 = 16'h4134, HEADER_FILE_VERSION = 16'h8002;
    localparam VERSION_A3_WORD = 32'h4133, VERSION_A4_WORD = 32'h4134;
    localparam MAIN_TID_INIT = 16'h8000, STATUS_TID_INIT = 16'h9000, TID_SEQUENCE_INIT = 16'h8100;
    localparam DENY_TID_INIT = 16'ha000;
    localparam DEFAULT_REQUEST_PORT = 59, DEFAULT_TIMEOUT_CYCLES = 250000000, DEFAULT_RETRY_LIMIT = 1;
    localparam REG_ENABLE = 8'hb0, REG_TX_VL = 8'hb1, REG_MEMORY_ADDRESS = 8'hb4, REG_REQUEST_PORT = 8'hb8;
    localparam REG_TIMEOUT = 8'hb9, REG_RETRY_LIMIT = 8'hba, REG_VERSION = 8'hbb;

    reg configured, protocol_a4;
    reg [6:0] configured_vl;
    reg [12:0] memory_addr;
    reg [15:0] request_port;
    reg [31:0] timeout_cycles;
    reg [7:0] retry_limit, load_sample;
    reg [1:0] status;
    reg [7:0] reason;
    reg [13:0] loaded;
    reg [15:0] lus_counter, main_tid, status_tid, deny_tid;
    reg [31:0] retry_total;
    reg consume_q, consume_previous;
    reg rx_we, packet_pending, receiving;
    reg [9:0] rx_wa, rx_index, rx_length;
    reg [7:0] rx_wd;
    reg [15:0] rx_op, rx_block, peer_sp, peer_dp;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] rx_port_stage, rx_port_local;
    wire [15:0] incoming_port = LOCAL_RX_PORT ? rx_port_local : rx_dport;
    wire send_complete, tx_re, read_mode;
    wire [9:0] tx_ra;
    wire [7:0] tx_q, deny_q;
    wire  consume;
    wire [1:0] engine_status;
    wire [7:0] engine_reason;
    wire [13:0] engine_loaded;
    wire [15:0] engine_lus_counter;
    wire [31:0] engine_retry_total;
    wire [15:0] engine_main_tid;
    wire [15:0] engine_status_tid;
    wire [15:0] engine_deny_tid;
    wire [15:0] engine_tx_sport;
    wire [15:0] engine_tx_dport;
    wire  send_request;
    wire  send_mode;
    wire [10:0] send_length;
    wire  deny_we;
    wire [4:0] deny_wa;
    wire [7:0] deny_wd;
    wire  rx_re;
    wire [9:0] rx_ra;
    wire  tx_we;
    wire [9:0] tx_wa;
    wire [7:0] tx_wd;
    wire  lur_we;
    wire [8:0] lur_wa;
    wire [7:0] lur_wd;
    wire  lur_re;
    wire [8:0] lur_ra;
    wire  hdr_we;
    wire [10:0] hdr_wa;
    wire [7:0] hdr_wd;
    wire  hdr_re;
    wire [10:0] hdr_ra;
    wire  load_we;
    wire [12:0] load_wa;
    wire [7:0] load_wd;
    wire  load_re;
    wire [12:0] load_ra;
    wire [7:0] rx_q;
    wire [7:0] lur_q;
    wire [7:0] hdr_q;
    wire [7:0] load_q;
    reg  ram_deny_we, cmd_deny_we;
    reg [4:0] ram_deny_wa, cmd_deny_wa;
    reg [7:0] ram_deny_wd, cmd_deny_wd;
    reg  ram_rx_re, cmd_rx_re;
    reg [9:0] ram_rx_ra, cmd_rx_ra;
    reg  ram_tx_we, cmd_tx_we;
    reg [9:0] ram_tx_wa, cmd_tx_wa;
    reg [7:0] ram_tx_wd, cmd_tx_wd;
    reg  ram_lur_we, cmd_lur_we;
    reg [8:0] ram_lur_wa, cmd_lur_wa;
    reg [7:0] ram_lur_wd, cmd_lur_wd;
    reg  ram_lur_re, cmd_lur_re;
    reg [8:0] ram_lur_ra, cmd_lur_ra;
    reg  ram_hdr_we, cmd_hdr_we;
    reg [10:0] ram_hdr_wa, cmd_hdr_wa;
    reg [7:0] ram_hdr_wd, cmd_hdr_wd;
    reg  ram_hdr_re, cmd_hdr_re;
    reg [10:0] ram_hdr_ra, cmd_hdr_ra;
    reg  ram_load_we, cmd_load_we;
    reg [12:0] ram_load_wa, cmd_load_wa;
    reg [7:0] ram_load_wd, cmd_load_wd;
    reg  ram_load_re, cmd_load_re;
    reg [12:0] ram_load_ra, cmd_load_ra;
    always @(posedge clk) begin
        if (reset) begin
            rx_port_stage <= 0;
            rx_port_local <= 0;
        end
        else begin
            rx_port_stage <= rx_dport;
            rx_port_local <= rx_port_stage;
        end
    end

    assign rx_claim = enable && configured && (incoming_port == request_port || incoming_port == main_tid
        || incoming_port == status_tid || incoming_port == deny_tid);

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
            if (consume_q && !consume_previous) packet_pending <= 0;
            if (rx_valid && (receiving || (rx_claim && ! packet_pending))) begin
                rx_we <= 1;
                rx_wa <= rx_index;
                rx_wd <= rx_data;
                case (rx_index)
                    0 : begin
                        rx_op[15:8] <= rx_data;
                        peer_sp <= rx_sport;
                        peer_dp <= incoming_port;
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

    // 配置读口保持两拍协议，加载区空闲读也保持主时钟速度。
    always @(posedge clk) begin
        if (reset) begin
            configured <= 0;
            configured_vl <= 0;
            memory_addr <= 0;
            request_port <= DEFAULT_REQUEST_PORT;
            timeout_cycles <= DEFAULT_TIMEOUT_CYCLES;
            retry_limit <= DEFAULT_RETRY_LIMIT;
            protocol_a4 <= 1;
            load_sample <= 0;
            cfg_rdata <= 0;
            cfg_extra_data <= 0;
            consume_q <= 0;
            consume_previous <= 0;
            status <= 0;
            reason <= 0;
            lus_counter <= 0;
            main_tid <= MAIN_TID_INIT;
            retry_total <= 0;
            loaded <= 0;
            status_tid <= STATUS_TID_INIT;
            deny_tid <= DENY_TID_INIT;
        end
        else begin
            consume_q <= consume;
            consume_previous <= consume_q;
            load_sample <= load_q;
            deny_tid <= engine_deny_tid;
            loaded <= engine_loaded;
            lus_counter <= engine_lus_counter;
            main_tid <= engine_main_tid;
            reason <= engine_reason;
            retry_total <= engine_retry_total;
            status <= engine_status;
            status_tid <= engine_status_tid;
            if (cfg_we) case (cfg_write_addr)
                REG_ENABLE : if (status != ST_BUSY) configured <= cfg_wdata[0];
                REG_TX_VL : if (status != ST_BUSY) configured_vl <= cfg_wdata[6:0];
                REG_MEMORY_ADDRESS : memory_addr <= cfg_wdata[12:0];
                REG_REQUEST_PORT : if (status != ST_BUSY && cfg_wdata[15:0] != 0) request_port <= cfg_wdata[15:0];
                REG_TIMEOUT : if (status != ST_BUSY && cfg_wdata != 0) timeout_cycles <= cfg_wdata;
                REG_RETRY_LIMIT : if (status != ST_BUSY) retry_limit <= cfg_wdata[7:0];
                REG_VERSION : if (status != ST_BUSY && (cfg_wdata[15:0] == VERSION_A3
                    || cfg_wdata[15:0] == VERSION_A4)) protocol_a4 <= cfg_wdata[15:0] == VERSION_A4;
            endcase
            case (cfg_addr[2:0])
                0 : cfg_rdata <= { 31'b0, configured };
                1 : cfg_rdata <= { 25'b0, configured_vl };
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
                3 : cfg_extra_data <= protocol_a4 ? VERSION_A4_WORD : VERSION_A3_WORD;
                default : cfg_extra_data <= 0;
            endcase
        end
    end
    // 引擎输出保持到下一个 CE 拍，RAM 端口在本地寄存后使用。
    always @(posedge clk) begin
        if (reset) begin
            ram_deny_we <= 0;
            cmd_deny_we <= 0;
            ram_deny_wa <= 0;
            cmd_deny_wa <= 0;
            ram_deny_wd <= 0;
            cmd_deny_wd <= 0;
            ram_rx_re <= 0;
            cmd_rx_re <= 0;
            ram_rx_ra <= 0;
            cmd_rx_ra <= 0;
            ram_tx_we <= 0;
            cmd_tx_we <= 0;
            ram_tx_wa <= 0;
            cmd_tx_wa <= 0;
            ram_tx_wd <= 0;
            cmd_tx_wd <= 0;
            ram_lur_we <= 0;
            cmd_lur_we <= 0;
            ram_lur_wa <= 0;
            cmd_lur_wa <= 0;
            ram_lur_wd <= 0;
            cmd_lur_wd <= 0;
            ram_lur_re <= 0;
            cmd_lur_re <= 0;
            ram_lur_ra <= 0;
            cmd_lur_ra <= 0;
            ram_hdr_we <= 0;
            cmd_hdr_we <= 0;
            ram_hdr_wa <= 0;
            cmd_hdr_wa <= 0;
            ram_hdr_wd <= 0;
            cmd_hdr_wd <= 0;
            ram_hdr_re <= 0;
            cmd_hdr_re <= 0;
            ram_hdr_ra <= 0;
            cmd_hdr_ra <= 0;
            ram_load_we <= 0;
            cmd_load_we <= 0;
            ram_load_wa <= 0;
            cmd_load_wa <= 0;
            ram_load_wd <= 0;
            cmd_load_wd <= 0;
            ram_load_re <= 0;
            cmd_load_re <= 0;
            ram_load_ra <= 0;
            cmd_load_ra <= 0;
        end
        else begin
            cmd_deny_we <= deny_we;
            ram_deny_we <= cmd_deny_we && (CE_DIV == 1 || !ce);
            cmd_deny_wa <= deny_wa;
            ram_deny_wa <= cmd_deny_wa;
            cmd_deny_wd <= deny_wd;
            ram_deny_wd <= cmd_deny_wd;
            cmd_rx_re <= rx_re;
            ram_rx_re <= cmd_rx_re && (CE_DIV == 1 || !ce);
            cmd_rx_ra <= rx_ra;
            ram_rx_ra <= cmd_rx_ra;
            cmd_tx_we <= tx_we;
            ram_tx_we <= cmd_tx_we && (CE_DIV == 1 || !ce);
            cmd_tx_wa <= tx_wa;
            ram_tx_wa <= cmd_tx_wa;
            cmd_tx_wd <= tx_wd;
            ram_tx_wd <= cmd_tx_wd;
            cmd_lur_we <= lur_we;
            ram_lur_we <= cmd_lur_we && (CE_DIV == 1 || !ce);
            cmd_lur_wa <= lur_wa;
            ram_lur_wa <= cmd_lur_wa;
            cmd_lur_wd <= lur_wd;
            ram_lur_wd <= cmd_lur_wd;
            cmd_lur_re <= lur_re;
            ram_lur_re <= cmd_lur_re && (CE_DIV == 1 || !ce);
            cmd_lur_ra <= lur_ra;
            ram_lur_ra <= cmd_lur_ra;
            cmd_hdr_we <= hdr_we;
            ram_hdr_we <= cmd_hdr_we && (CE_DIV == 1 || !ce);
            cmd_hdr_wa <= hdr_wa;
            ram_hdr_wa <= cmd_hdr_wa;
            cmd_hdr_wd <= hdr_wd;
            ram_hdr_wd <= cmd_hdr_wd;
            cmd_hdr_re <= hdr_re;
            ram_hdr_re <= cmd_hdr_re && (CE_DIV == 1 || !ce);
            cmd_hdr_ra <= hdr_ra;
            ram_hdr_ra <= cmd_hdr_ra;
            cmd_load_we <= load_we;
            ram_load_we <= cmd_load_we && (CE_DIV == 1 || !ce);
            cmd_load_wa <= load_wa;
            ram_load_wa <= cmd_load_wa;
            cmd_load_wd <= load_wd;
            ram_load_wd <= cmd_load_wd;
            cmd_load_re <= load_re;
            ram_load_re <= status != ST_BUSY || (cmd_load_re && (CE_DIV == 1 || !ce));
            cmd_load_ra <= load_ra;
            ram_load_ra <= status != ST_BUSY ? memory_addr : cmd_load_ra;
        end
    end
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_rx (
        .clk(clk), .write_enable(rx_we), .write_address(rx_wa), .write_data(rx_wd),
        .read_enable(ram_rx_re), .read_address(ram_rx_ra), .read_data(rx_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(1024)) packet_tx (
        .clk(clk), .write_enable(ram_tx_we), .write_address(ram_tx_wa), .write_data(ram_tx_wd),
        .read_enable(tx_re), .read_address(tx_ra), .read_data(tx_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(512)) lur_ram (
        .clk(clk), .write_enable(ram_lur_we), .write_address(ram_lur_wa), .write_data(ram_lur_wd),
        .read_enable(ram_lur_re), .read_address(ram_lur_ra), .read_data(lur_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(2048)) header_ram (
        .clk(clk), .write_enable(ram_hdr_we), .write_address(ram_hdr_wa), .write_data(ram_hdr_wd),
        .read_enable(ram_hdr_re), .read_address(ram_hdr_ra), .read_data(hdr_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(8192)) load_ram (
        .clk(clk), .write_enable(ram_load_we), .write_address(ram_load_wa), .write_data(ram_load_wd),
        .read_enable(ram_load_re), .read_address(ram_load_ra), .read_data(load_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(32)) denial_ram (
        .clk(clk), .write_enable(ram_deny_we), .write_address(ram_deny_wa), .write_data(ram_deny_wd),
        .read_enable(tx_re), .read_address(tx_ra[4:0]), .read_data(deny_q)
    );
    afdx_mgmt_tx #(.AW(10)) sender (
        .clk(clk), .reset(reset), .request(send_request), .length(send_length), .vl(configured_vl),
        .sport(engine_tx_sport), .dport(engine_tx_dport), .mode(send_mode), .complete(send_complete),
        .read_enable(tx_re), .read_address(tx_ra), .read_data(read_mode ? deny_q : tx_q), .read_mode(read_mode),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data), .tx_last(tx_last),
        .tx_vl(tx_vl), .tx_sport(tx_sport), .tx_dport(tx_dport)
    );

    generate
        if (CE_DIV == 2) begin : half_rate
            afdx_615a_engine #(.CE_DIV(CE_DIV)) engine (
                .clk(clk),
                .reset(reset),
                .ce(ce),
                .enable_in(enable),
                .configured_in(configured),
                .request_port_in(request_port),
                .timeout_cycles_in(timeout_cycles),
                .retry_limit_in(retry_limit),
                .protocol_a4_in(protocol_a4),
                .packet_pending_in(packet_pending),
                .rx_op_in(rx_op),
                .rx_block_in(rx_block),
                .rx_length_in(rx_length),
                .peer_sp_in(peer_sp),
                .peer_dp_in(peer_dp),
                .rx_q_in(rx_q),
                .lur_q_in(lur_q),
                .hdr_q_in(hdr_q),
                .load_q_in(load_q),
                .send_complete_in(send_complete),
                .consume(consume),
                .status(engine_status),
                .reason(engine_reason),
                .loaded(engine_loaded),
                .lus_counter(engine_lus_counter),
                .retry_total(engine_retry_total),
                .main_tid(engine_main_tid),
                .status_tid(engine_status_tid),
                .deny_tid(engine_deny_tid),
                .tx_sport(engine_tx_sport),
                .tx_dport(engine_tx_dport),
                .send_request(send_request),
                .send_mode(send_mode),
                .send_length(send_length),
                .deny_we(deny_we),
                .deny_wa(deny_wa),
                .deny_wd(deny_wd),
                .rx_re(rx_re),
                .rx_ra(rx_ra),
                .tx_we(tx_we),
                .tx_wa(tx_wa),
                .tx_wd(tx_wd),
                .lur_we(lur_we),
                .lur_wa(lur_wa),
                .lur_wd(lur_wd),
                .lur_re(lur_re),
                .lur_ra(lur_ra),
                .hdr_we(hdr_we),
                .hdr_wa(hdr_wa),
                .hdr_wd(hdr_wd),
                .hdr_re(hdr_re),
                .hdr_ra(hdr_ra),
                .load_we(load_we),
                .load_wa(load_wa),
                .load_wd(load_wd),
                .load_re(load_re),
                .load_ra(load_ra)
            );
        end
        else begin : full_rate
            afdx_615a_engine #(.CE_DIV(CE_DIV)) engine (
                .clk(clk),
                .reset(reset),
                .ce(ce),
                .enable_in(enable),
                .configured_in(configured),
                .request_port_in(request_port),
                .timeout_cycles_in(timeout_cycles),
                .retry_limit_in(retry_limit),
                .protocol_a4_in(protocol_a4),
                .packet_pending_in(packet_pending),
                .rx_op_in(rx_op),
                .rx_block_in(rx_block),
                .rx_length_in(rx_length),
                .peer_sp_in(peer_sp),
                .peer_dp_in(peer_dp),
                .rx_q_in(rx_q),
                .lur_q_in(lur_q),
                .hdr_q_in(hdr_q),
                .load_q_in(load_q),
                .send_complete_in(send_complete),
                .consume(consume),
                .status(engine_status),
                .reason(engine_reason),
                .loaded(engine_loaded),
                .lus_counter(engine_lus_counter),
                .retry_total(engine_retry_total),
                .main_tid(engine_main_tid),
                .status_tid(engine_status_tid),
                .deny_tid(engine_deny_tid),
                .tx_sport(engine_tx_sport),
                .tx_dport(engine_tx_dport),
                .send_request(send_request),
                .send_mode(send_mode),
                .send_length(send_length),
                .deny_we(deny_we),
                .deny_wa(deny_wa),
                .deny_wd(deny_wd),
                .rx_re(rx_re),
                .rx_ra(rx_ra),
                .tx_we(tx_we),
                .tx_wa(tx_wa),
                .tx_wd(tx_wd),
                .lur_we(lur_we),
                .lur_wa(lur_wa),
                .lur_wd(lur_wd),
                .lur_re(lur_re),
                .lur_ra(lur_ra),
                .hdr_we(hdr_we),
                .hdr_wa(hdr_wa),
                .hdr_wd(hdr_wd),
                .hdr_re(hdr_re),
                .hdr_ra(hdr_ra),
                .load_we(load_we),
                .load_wa(load_wa),
                .load_wd(load_wd),
                .load_re(load_re),
                .load_ra(load_ra)
            );
        end
    endgenerate
endmodule
