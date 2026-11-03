// 本模块按 ARINC 615A 接收加载文件，也能把已加载的数据发回。
// 报文从 afdx_svc 进入，回应经同一模块交给发送核心。
// ARINC 615A 用 TFTP（Trivial File Transfer Protocol，简单文件传输协议）传文件。
// 本模块对应赛题的加卸载功能，一次处理一个头文件和一个数据文件。
// 加载区最多保存 8 KiB 数据，校验成功后才允许卸载。
module afdx_615a #(parameter LOCAL_RX_PORT = 0, SPLIT_CFG_ADDR = 0, CE_DIV = 2, CE_BANKS = 72,
    CFG_WRITE_SELECT = 0, READY_PREDICT = 0, CFG_READY_PREDICT = 0, CFG_READY_TERMS = 0) (

    // enable 为高且配置已启用时，模块才接受加卸载请求。
    input wire clk, reset, enable,
    input wire enable_next,
    input wire [CE_BANKS - 1:0] ce,

    // cfg_* 设置服务参数，并读取状态、加载字节数和加载区内容。
    // cfg_extra_data 返回端口与重试设置。
    input wire cfg_we,
    // The raw write request is already qualified by the full loader group.
    input wire cfg_ready_next, cfg_write_request,
    input wire cfg_ready_base, cfg_ready_rx_term, cfg_ready_rx_ack,
    input wire [6:0] cfg_wr_sel,
    input wire [(SPLIT_CFG_ADDR == 2 ? 15 : SPLIT_CFG_ADDR ? 11 : 8) - 1:0] cfg_addr,
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
    wire [7:0] cfg_write_addr = cfg_addr[(SPLIT_CFG_ADDR == 2 ? 7 : SPLIT_CFG_ADDR ? 3 : 0) +: 8];

    // 全速配置、捕获和加载区读回使用的常量。
    localparam ST_IDLE = 0, ST_BUSY = 1, ST_SUCCESS = 2, ST_FAILED = 3;
    localparam VERSION_A3 = 16'h4133, VERSION_A4 = 16'h4134, HEADER_FILE_VERSION = 16'h8002;
    localparam VERSION_A3_WORD = 32'h4133, VERSION_A4_WORD = 32'h4134;
    localparam MAIN_TID_INIT = 16'h8000, STATUS_TID_INIT = 16'h9000, TID_SEQUENCE_INIT = 16'h8100;
    localparam DENY_TID_INIT = 16'ha000;
    localparam DEFAULT_REQUEST_PORT = 16'd59, DEFAULT_TIMEOUT_CYCLES = 250000000, DEFAULT_RETRY_LIMIT = 8'd1;
    localparam REG_ENABLE = 8'hb0, REG_TX_VL = 8'hb1, REG_MEMORY_ADDRESS = 8'hb4, REG_REQUEST_PORT = 8'hb8;
    localparam REG_TIMEOUT = 8'hb9, REG_RETRY_LIMIT = 8'hba, REG_VERSION = 8'hbb;
    // 顶层提供同拍独热写选通；默认参数保留独立实例的原地址译码接口。
    wire [6:0] field_ready;
    wire configuration_ready_d = CFG_READY_TERMS
        ? (cfg_ready_base || (cfg_ready_rx_term && cfg_ready_rx_ack)) : cfg_ready_next;
    generate if(CFG_READY_PREDICT || CFG_READY_TERMS) begin : configuration_ready
        (* preserve = 1, dont_merge = 1 *) reg [6:0] ready_q;
        always @(posedge clk) begin
            if(reset) ready_q<=0;
            else ready_q<={7{configuration_ready_d}};
        end
        assign field_ready=ready_q;
    end else begin : external_configuration
        assign field_ready=7'b0;
    end endgenerate
    wire [6:0] cfg_write_sel = (CFG_READY_PREDICT || CFG_READY_TERMS) ? {
        field_ready[6] && cfg_write_request && cfg_write_addr==REG_VERSION,
        field_ready[5] && cfg_write_request && cfg_write_addr==REG_RETRY_LIMIT,
        field_ready[4] && cfg_write_request && cfg_write_addr==REG_TIMEOUT,
        field_ready[3] && cfg_write_request && cfg_write_addr==REG_REQUEST_PORT,
        field_ready[2] && cfg_write_request && cfg_write_addr==REG_MEMORY_ADDRESS,
        field_ready[1] && cfg_write_request && cfg_write_addr==REG_TX_VL,
        field_ready[0] && cfg_write_request && cfg_write_addr==REG_ENABLE
    } : CFG_WRITE_SELECT ? cfg_wr_sel : {
        cfg_we && cfg_write_addr == REG_VERSION,
        cfg_we && cfg_write_addr == REG_RETRY_LIMIT,
        cfg_we && cfg_write_addr == REG_TIMEOUT,
        cfg_we && cfg_write_addr == REG_REQUEST_PORT,
        cfg_we && cfg_write_addr == REG_MEMORY_ADDRESS,
        cfg_we && cfg_write_addr == REG_TX_VL,
        cfg_we && cfg_write_addr == REG_ENABLE
    };

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
    // Integrated next-state input is the original enable register's D.
    // Copies therefore equal enable on every clock, rather than delaying it.
    wire [2:0] local_ready;
    generate if(READY_PREDICT) begin : ready_prediction
        (* preserve = 1, dont_merge = 1 *) reg [2:0] ready_q;
        always @(posedge clk) begin
            if(reset) ready_q<=0;
            else ready_q<={3{enable_next}};
        end
        assign local_ready=ready_q;
    end else begin : external_ready
        assign local_ready={3{enable}};
    end endgenerate
    (* preserve = 1, dont_merge = 1 *) reg [9:0] rx_wa;
    reg [9:0] rx_index, rx_length;
    // 块号字节的前瞻译码随接收索引一起更新；无有效字节时保持，允许字节间有空拍。
    (* preserve = 1, dont_merge = 1 *) reg capture_op_q, capture_hi_q, capture_lo_q;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] rx_wd;
    reg [15:0] rx_op, rx_block, peer_sp, peer_dp;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] rx_port_stage, rx_port_local;
    // 四个端口分别寄存比较结果，避免跨端口的或逻辑串在输入比较后。
    // 合并后的匹配仍与 rx_port_local 同拍有效，不增加接收延迟。
    (* preserve = 1, dont_merge = 1 *) reg svc_request_match, svc_main_match, svc_status_match, svc_deny_match;
    (* preserve = 1, dont_merge = 1 *) reg [3:0] request_byte_match;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] main_pair_match, status_pair_match, deny_pair_match;
    (* preserve = 1, dont_merge = 1 *) reg request_config_idle;
    always @(posedge clk) begin
        if (reset) request_config_idle <= 1;
        else request_config_idle <= engine_status != ST_BUSY;
    end
    // Predict exactly the port registers written on this edge.  The second
    // comparison stage therefore sees the same target as the original full
    // comparison, including a simultaneous configuration or engine update.
    wire request_port_request = (CFG_READY_PREDICT || CFG_READY_TERMS)
        ? cfg_write_request && cfg_write_addr==REG_REQUEST_PORT : cfg_write_sel[3];
    wire timeout_request = (CFG_READY_PREDICT || CFG_READY_TERMS)
        ? cfg_write_request && cfg_write_addr==REG_TIMEOUT : cfg_write_sel[4];
    wire [3:0] request_write_allowed, timeout_write_allowed;
    genvar permit_byte;
    generate for(permit_byte=0;permit_byte<4;permit_byte=permit_byte+1) begin : field_permit
        if(CFG_READY_PREDICT || CFG_READY_TERMS) begin : prediction
            (* preserve=1,dont_merge=1 *) reg request_allowed, timeout_allowed;
            always @(posedge clk) begin
                if(reset) begin request_allowed<=0;timeout_allowed<=0;end
                else begin
                    request_allowed<=configuration_ready_d && engine_status!=ST_BUSY;
                    timeout_allowed<=configuration_ready_d && engine_status!=ST_BUSY;
                end
            end
            assign request_write_allowed[permit_byte]=request_allowed;
            assign timeout_write_allowed[permit_byte]=timeout_allowed;
        end else begin : external_fields
            assign request_write_allowed[permit_byte]=request_config_idle;
            assign timeout_write_allowed[permit_byte]=status!=ST_BUSY;
        end
        always @(posedge clk) begin
            if(reset) timeout_cycles[permit_byte*8+:8]<=DEFAULT_TIMEOUT_CYCLES[permit_byte*8+:8];
            else if(timeout_write_allowed[permit_byte] && timeout_request && cfg_wdata!=0)
                timeout_cycles[permit_byte*8+:8]<=cfg_wdata[permit_byte*8+:8];
        end
    end endgenerate
    genvar port_byte, port_pair;
    generate for (port_byte=0; port_byte<4; port_byte=port_byte+1) begin : port_compare
        always @(posedge clk) begin
            if (reset) begin
                request_byte_match[port_byte]<=0;
            end else begin
                request_byte_match[port_byte]<=
                    (request_write_allowed[port_byte] && request_port_request && cfg_wdata[15:0]!=0 &&
                        rx_dport[port_byte*4+:4]==cfg_wdata[port_byte*4+:4]) ||
                    (!(request_write_allowed[port_byte] && request_port_request && cfg_wdata[15:0]!=0) &&
                        rx_dport[port_byte*4+:4]==request_port[port_byte*4+:4]);
            end
        end
    end
    for (port_pair=0; port_pair<8; port_pair=port_pair+1) begin : tid_pair_compare
        always @(posedge clk) begin
            if (reset) begin
                main_pair_match[port_pair]<=0;
                status_pair_match[port_pair]<=0;
                deny_pair_match[port_pair]<=0;
            end else begin
                main_pair_match[port_pair]<=rx_dport[port_pair*2+:2]==engine_main_tid[port_pair*2+:2];
                status_pair_match[port_pair]<=rx_dport[port_pair*2+:2]==engine_status_tid[port_pair*2+:2];
                deny_pair_match[port_pair]<=rx_dport[port_pair*2+:2]==engine_deny_tid[port_pair*2+:2];
            end
        end
    end endgenerate
    wire svc_port_match = svc_request_match || svc_main_match || svc_status_match || svc_deny_match;
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
    wire [2:0] deny_format;
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
    // 配置采样单独跨一拍，给 RAM 读口到配置读回区之间留下寄存级。
    // 引擎仍直接使用 load_q；只把寄存器 5 的采样更新推迟一拍。
    (* preserve = 1, dont_merge = 1 *) reg [7:0] load_sample_local;
    reg  ram_deny_we, cmd_deny_we;
    reg [4:0] ram_deny_wa, cmd_deny_wa;
    reg [7:0] ram_deny_wd;
    reg [2:0] cmd_deny_format;
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
    wire [10:0] ram_hdr_ra;
    reg [10:0] cmd_hdr_ra;
    reg  ram_load_we, cmd_load_we;
    reg [12:0] ram_load_wa, cmd_load_wa;
    reg [7:0] ram_load_wd, cmd_load_wd;
    reg  ram_load_re, cmd_load_re;
    reg [12:0] ram_load_ra, cmd_load_ra;
    always @(posedge clk) begin
        if (reset) begin
            rx_port_stage <= 0;
            rx_port_local <= 0;
            svc_request_match <= 0;
            svc_main_match <= 0;
            svc_status_match <= 0;
            svc_deny_match <= 0;
        end
        else begin
            rx_port_stage <= rx_dport;
            rx_port_local <= rx_port_stage;
            svc_request_match <= &request_byte_match;
            svc_main_match <= (&main_pair_match[3:0]) && (&main_pair_match[7:4]);
            svc_status_match <= (&status_pair_match[3:0]) && (&status_pair_match[7:4]);
            svc_deny_match <= (&deny_pair_match[3:0]) && (&deny_pair_match[7:4]);
        end
    end

    wire local_port_claim = configured && (LOCAL_RX_PORT ? svc_port_match
        : (rx_dport == request_port || rx_dport == main_tid || rx_dport == status_tid
            || rx_dport == deny_tid));
    assign rx_claim = local_ready[0] && local_port_claim;
    wire index_byte = rx_valid && (receiving ||
        (local_ready[1] && local_port_claim && !packet_pending));
    wire length_byte = rx_valid && (receiving ||
        (local_ready[2] && local_port_claim && !packet_pending));

    // 接收口不能暂停发送方，每次只处理一个等待确认的数据块。
    always @(posedge clk) begin
        if (reset) begin
            rx_we <= 0;
            rx_wa <= 0;
            rx_wd <= 0;
            packet_pending <= 0;
            receiving <= 0;
            rx_op <= 0;
            rx_block <= 0;
            peer_sp <= 0;
            peer_dp <= 0;
        end
        else begin
            rx_we <= 0;
            // RAM 端口预存当前输入，写脉冲独立确认字节；未握手时这些候选值不会被使用。
            rx_wa <= rx_index;
            rx_wd <= rx_data;
            if (rx_valid && capture_op_q) rx_op[7:0] <= rx_data;
            // 前瞻位等价于本拍 receiving && rx_index==2/3，逐字节选通和数据不加流水。
            if (rx_valid && capture_hi_q) rx_block[15:8] <= rx_data;
            if (rx_valid && capture_lo_q) rx_block[7:0] <= rx_data;
            if (consume_q && !consume_previous) packet_pending <= 0;
            // 尚无待处理报文时预存端口；首字节仍采样同一值，接收及 pending 期间保持。
            if (!receiving && !packet_pending) begin
                rx_op[15:8] <= rx_data;
                peer_sp <= rx_sport;
                peer_dp <= incoming_port;
            end
            if (rx_valid && (receiving || (rx_claim && ! packet_pending))) begin
                rx_we <= 1;
                if (rx_last) begin
                    receiving <= 0;
                    packet_pending <= 1;
                end
                else begin
                    receiving <= 1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            rx_index<=0;capture_op_q<=0;capture_hi_q<=0;capture_lo_q<=0;
        end else if(index_byte) begin
            if(rx_last) begin
                rx_index<=0;capture_op_q<=0;capture_hi_q<=0;capture_lo_q<=0;
            end else begin
                rx_index<=rx_index+1'b1;
                capture_op_q<=rx_index==0;
                capture_hi_q<=rx_index==1;
                capture_lo_q<=rx_index==2;
            end
        end
    end
    always @(posedge clk) begin
        if(reset) rx_length<=0;
        else if(length_byte && rx_last) rx_length<=rx_index+1'b1;
    end

    // 配置读口保持两拍协议，加载区空闲读也保持主时钟速度。
    always @(posedge clk) begin
        if (reset) begin
            configured <= 0;
            configured_vl <= 0;
            memory_addr <= 0;
            request_port <= DEFAULT_REQUEST_PORT;
            retry_limit <= DEFAULT_RETRY_LIMIT;
            protocol_a4 <= 1;
            load_sample <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_rdata <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_extra_data <= 0;
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
            load_sample <= load_sample_local;
            deny_tid <= engine_deny_tid;
            loaded <= engine_loaded;
            lus_counter <= engine_lus_counter;
            main_tid <= engine_main_tid;
            reason <= engine_reason;
            retry_total <= engine_retry_total;
            status <= engine_status;
            status_tid <= engine_status_tid;
            if (cfg_write_sel[0] && status != ST_BUSY) configured <= cfg_wdata[0];
            if (cfg_write_sel[1] && status != ST_BUSY) configured_vl <= cfg_wdata[6:0];
            if (cfg_write_sel[2]) memory_addr <= cfg_wdata[12:0];
            if (cfg_write_sel[3] && status != ST_BUSY && cfg_wdata[15:0] != 0) request_port <= cfg_wdata[15:0];
            if (cfg_write_sel[5] && status != ST_BUSY) retry_limit <= cfg_wdata[7:0];
            if (cfg_write_sel[6] && status != ST_BUSY && (cfg_wdata[15:0] == VERSION_A3
                || cfg_wdata[15:0] == VERSION_A4)) protocol_a4 <= cfg_wdata[15:0] == VERSION_A4;
            if (SPLIT_CFG_ADDR != 2) begin
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
            end
            if (SPLIT_CFG_ADDR != 2) begin
            case (cfg_addr[2:0])
                0 : cfg_extra_data <= { 16'b0, request_port };
                1 : cfg_extra_data <= timeout_cycles;
                2 : cfg_extra_data <= { 24'b0, retry_limit };
                3 : cfg_extra_data <= protocol_a4 ? VERSION_A4_WORD : VERSION_A3_WORD;
                default : cfg_extra_data <= 0;
            endcase
            end
        end
    end
    // A denial byte is a ROM of the command address and three mode bits.
    // Decode at its RAM consumer instead of transporting a decoded byte
    // from the distant shared protocol engine and registering it again.
    function [7:0] denial_octet;
        input [4:0] position;
        input [2:0] format;
        begin
            denial_octet=0;
            case(position)
                1:denial_octet=3;
                3:denial_octet=1;
                7:denial_octet=format[0]?8'd9:8'd17;
                8:denial_octet="A";
                9:denial_octet=format[2]?"4":"3";
                10:denial_octet=8'h10;
                11:denial_octet=format[0]?8'd2:8'd0;
                12:denial_octet=format[0]?8'd0:8'd8;
                13:denial_octet=format[1]?"N":"B";
                14:denial_octet=format[1]?"O":"U";
                15:denial_octet=format[1]?" ":"S";
                16:denial_octet=format[1]?"D":"Y";
                17:denial_octet=format[1]?"A":8'd0;
                18:denial_octet=format[1]?"T":8'd0;
                19:denial_octet=format[1]?"A":8'd0;
                default:;
            endcase
        end
    endfunction

    // CE_DIV=2 has one fixed intervening clock. Sample the address on
    // the engine phase and hold it through the original physical RAM read.
    // This removes the otherwise redundant full-rate RAM address bridge.
    generate if(CE_DIV==2) begin : header_address_hold
        always @(posedge clk) begin
            if(reset) cmd_hdr_ra<=0;
            else if(ce[0]) cmd_hdr_ra<=hdr_ra;
        end
        assign ram_hdr_ra=cmd_hdr_ra;
    end else begin : header_address_pipeline
        reg [10:0] address_q;
        always @(posedge clk) begin
            if(reset) begin cmd_hdr_ra<=0;address_q<=0;end
            else begin cmd_hdr_ra<=hdr_ra;address_q<=cmd_hdr_ra;end
        end
        assign ram_hdr_ra=address_q;
    end endgenerate

    // 引擎输出保持到下一个 CE 拍，RAM 端口在本地寄存后使用。
    always @(posedge clk) begin
        if (reset) begin
            ram_deny_we <= 0;
            cmd_deny_we <= 0;
            ram_deny_wa <= 0;
            cmd_deny_wa <= 0;
            ram_deny_wd <= 0;
            cmd_deny_format <= 0;
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
            ram_deny_we <= cmd_deny_we && (CE_DIV == 1 || !ce[0]);
            cmd_deny_wa <= deny_wa;
            ram_deny_wa <= cmd_deny_wa;
            cmd_deny_format <= deny_format;
            ram_deny_wd <= denial_octet(cmd_deny_wa,cmd_deny_format);
            cmd_rx_re <= rx_re;
            ram_rx_re <= cmd_rx_re && (CE_DIV == 1 || !ce[0]);
            cmd_rx_ra <= rx_ra;
            ram_rx_ra <= cmd_rx_ra;
            cmd_tx_we <= tx_we;
            ram_tx_we <= cmd_tx_we && (CE_DIV == 1 || !ce[0]);
            cmd_tx_wa <= tx_wa;
            ram_tx_wa <= cmd_tx_wa;
            cmd_tx_wd <= tx_wd;
            ram_tx_wd <= cmd_tx_wd;
            cmd_lur_we <= lur_we;
            ram_lur_we <= cmd_lur_we && (CE_DIV == 1 || !ce[0]);
            cmd_lur_wa <= lur_wa;
            ram_lur_wa <= cmd_lur_wa;
            cmd_lur_wd <= lur_wd;
            ram_lur_wd <= cmd_lur_wd;
            cmd_lur_re <= lur_re;
            ram_lur_re <= cmd_lur_re && (CE_DIV == 1 || !ce[0]);
            cmd_lur_ra <= lur_ra;
            ram_lur_ra <= cmd_lur_ra;
            cmd_hdr_we <= hdr_we;
            ram_hdr_we <= cmd_hdr_we && (CE_DIV == 1 || !ce[0]);
            cmd_hdr_wa <= hdr_wa;
            ram_hdr_wa <= cmd_hdr_wa;
            cmd_hdr_wd <= hdr_wd;
            ram_hdr_wd <= cmd_hdr_wd;
            cmd_hdr_re <= hdr_re;
            ram_hdr_re <= cmd_hdr_re && (CE_DIV == 1 || !ce[0]);
            cmd_load_we <= load_we;
            ram_load_we <= cmd_load_we && (CE_DIV == 1 || !ce[0]);
            cmd_load_wa <= load_wa;
            ram_load_wa <= cmd_load_wa;
            cmd_load_wd <= load_wd;
            ram_load_wd <= cmd_load_wd;
            cmd_load_re <= load_re;
            ram_load_re <= status != ST_BUSY || (cmd_load_re && (CE_DIV == 1 || !ce[0]));
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
    // 原 RAM 读值无复位约束；配置采样寄存器仍按原协议复位。
    always @(posedge clk) load_sample_local <= load_q;
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
            afdx_615a_engine #(.CE_DIV(CE_DIV), .CE_BANKS(CE_BANKS)) engine (
                .clk(clk),
                .reset(reset),
                .ce_phase(ce),
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
                .deny_wd(),
                .deny_format(deny_format),
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
            afdx_615a_engine #(.CE_DIV(CE_DIV), .CE_BANKS(CE_BANKS)) engine (
                .clk(clk),
                .reset(reset),
                .ce_phase(ce),
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
                .deny_wd(),
                .deny_format(deny_format),
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
    // 模式 2：高位为写地址，bit 6 选主机，[5:3] 为主机读址，[2:0] 为 MIB 预读址。
    // MIB 地址在读请求之前稳定一拍；每四位输出使用独立译码副本，主机仍直接译码。
    wire [31:0] word_cfg_rdata_0 = {31'b0, configured};
    wire [31:0] word_cfg_rdata_1 = {25'b0, configured_vl};
    wire [31:0] word_cfg_rdata_2 = {16'b0, reason, 6'b0, status};
    wire [31:0] word_cfg_rdata_3 = {18'b0, loaded};
    wire [31:0] word_cfg_rdata_4 = {19'b0, memory_addr};
    wire [31:0] word_cfg_rdata_5 = {24'b0, load_sample};
    wire [31:0] word_cfg_rdata_6 = {16'b0, lus_counter};
    wire [31:0] word_cfg_rdata_7 = retry_total;
    wire [31:0] word_cfg_extra_data_0 = {16'b0, request_port};
    wire [31:0] word_cfg_extra_data_1 = timeout_cycles;
    wire [31:0] word_cfg_extra_data_2 = {24'b0, retry_limit};
    wire [31:0] word_cfg_extra_data_3 = protocol_a4 ? VERSION_A4_WORD : VERSION_A3_WORD;
    // Host and MIB share one parallel word reduction. Data words do not
    // traverse a second wide mux after address selection.
    genvar read_nibble;
    generate
        if (SPLIT_CFG_ADDR == 2) begin : local_read_decode
            for (read_nibble = 0; read_nibble < 8; read_nibble = read_nibble + 1) begin : nibble
                (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_lane;
                wire [7:0] lane = cfg_addr[6] ? (8'b1 << cfg_addr[5:3]) : mib_lane;
                (* keep = 1 *) wire [3:0] r01 =
                    ({4{lane[0]}} & word_cfg_rdata_0[read_nibble * 4 +: 4]) |
                    ({4{lane[1]}} & word_cfg_rdata_1[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] r23 =
                    ({4{lane[2]}} & word_cfg_rdata_2[read_nibble * 4 +: 4]) |
                    ({4{lane[3]}} & word_cfg_rdata_3[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] r45 =
                    ({4{lane[4]}} & word_cfg_rdata_4[read_nibble * 4 +: 4]) |
                    ({4{lane[5]}} & word_cfg_rdata_5[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] r67 =
                    ({4{lane[6]}} & word_cfg_rdata_6[read_nibble * 4 +: 4]) |
                    ({4{lane[7]}} & word_cfg_rdata_7[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] e01 =
                    ({4{lane[0]}} & word_cfg_extra_data_0[read_nibble * 4 +: 4]) |
                    ({4{lane[1]}} & word_cfg_extra_data_1[read_nibble * 4 +: 4]);
                (* keep = 1 *) wire [3:0] e23 =
                    ({4{lane[2]}} & word_cfg_extra_data_2[read_nibble * 4 +: 4]) |
                    ({4{lane[3]}} & word_cfg_extra_data_3[read_nibble * 4 +: 4]);
                always @(posedge clk) begin
                    if (reset) begin
                        mib_lane <= 8'b1;
                        cfg_rdata[read_nibble * 4 +: 4] <= 0;
                        cfg_extra_data[read_nibble * 4 +: 4] <= 0;
                    end
                    else begin
                        mib_lane <= 8'b1 << cfg_addr[2:0];
                        cfg_rdata[read_nibble * 4 +: 4] <= r01 | r23 | r45 | r67;
                        cfg_extra_data[read_nibble * 4 +: 4] <= e01 | e23;
                    end
                end
            end
        end
    endgenerate

endmodule
