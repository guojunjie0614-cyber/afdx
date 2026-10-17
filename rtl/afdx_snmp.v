// 本模块响应网络管理请求，也会主动报告指定事件。
// 管理报文从 afdx_svc 进入，查询结果来自共享配置总线。
// 本模块对应赛题的 SNMP（Simple Network Management Protocol，
// 简单网络管理协议）功能，一次处理一个变量。
// 它支持 v1/v2c 的 Get、GetNext 和 Set 请求，也能主动发送 v2c 的 Trap 通知。
module afdx_snmp #(parameter LOCAL_RX_PORT = 0, SPLIT_CFG_ADDR = 0, CE_DIV = 2, CE_BANKS = 59) (

    // enable 为高表示核心就绪，now 给寄存器读取结果标记时间。
    input wire clk, reset, enable,
    input wire [CE_BANKS - 1:0] ce,
    input wire [31:0] now,

    // cfg_* 配置代理开关、团体名和 Trap 通知，并读取状态。
    // 团体名（community）是 SNMP 报文里携带的访问口令。
    input wire cfg_we,
    input wire [(SPLIT_CFG_ADDR == 2 ? 15 : SPLIT_CFG_ADDR ? 11 : 8) - 1:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    output reg [31:0] cfg_control_data, cfg_status_data, cfg_descr_data,

    // mib_* 通过共享配置总线读寄存器或写 user_id。
    // ready 表示请求可执行，rvalid 表示返回数据有效。
    output reg mib_rd, mib_wr,
    output reg [17:0] mib_addr,
    output reg [31:0] mib_wdata,
    input wire mib_ready, mib_rvalid,
    input wire [31:0] mib_rdata,

    // tx_valid 和 tx_ready 同为高时发送一个回应或通知字节。
    // tx_vl 选择发送配置，tx_dport 给出对端端口。
    output wire tx_valid,
    input wire tx_ready,
    output wire [7:0] tx_data,
    output wire tx_last,
    output wire [6:0] tx_vl,
    output wire [15:0] tx_dport,

    // rx_valid 为高时接收字节，rx_claim 表示已启用且目的端口为 161。
    input wire rx_valid,
    input wire [7:0] rx_data,
    input wire rx_last,
    input wire [15:0] rx_sport, rx_dport,
    output wire rx_claim);

    wire [7:0] cfg_write_addr = SPLIT_CFG_ADDR == 2 ? cfg_addr >> 7 : SPLIT_CFG_ADDR ? cfg_addr >> 3 : cfg_addr;
    localparam [127:0] DESCRIPTION = "C3 AFDX endpoint";
    localparam SNMP_PORT = 161, TRAP_PORT = 162;
    localparam MAX_COMMUNITY_LENGTH = 16, MAX_OID_LENGTH = 16, DEFAULT_COMMUNITY_LENGTH = 6;
    localparam DEFAULT_COMMUNITY0 = 32'h7075626c, DEFAULT_COMMUNITY1 = 32'h69630000;
    localparam UPTIME_TICK_LAST = 1249999;
    localparam REG_ENABLE = 8'h90, REG_TX_VL = 8'h91, REG_COMMUNITY_LENGTH = 8'h92;
    localparam REG_COMMUNITY0 = 8'h93, REG_COMMUNITY1 = 8'h94, REG_COMMUNITY2 = 8'h95, REG_COMMUNITY3 = 8'h96;
    localparam REG_TRAP_ENABLE = 8'h9b;
    localparam PACKET_BUFFER_BYTES = 256, REQUEST_LAST_POS = 255;
    reg configured, trap_enabled;
    reg [6:0] response_vl;
    reg [4:0] configured_length;
    reg [31:0] community0, community1, community2, community3;
    reg [31:0] uptime, uptime_cycles, requests, bad_community, traps_sent, sample_cycle;
    reg req_we, receiving, overflow, capture_pending, trap_grant, cold_request;
    reg [7:0] req_wa, req_wdata;
    reg [8:0] rx_count, capture_length;
    reg [15:0] capture_port;
    reg consumed_q, idle_q, offer_q, cold_ack_q;
    wire req_re;
    wire [7:0] req_ra, req_q;
    wire out_we;
    wire [7:0] out_wa, out_wdata;
    wire [8:0] response_length;
    wire [15:0] response_port;
    wire capture_consumed, capture_idle, trap_offer, cold_ack, send_request, send_complete;
    wire [31:0] engine_bad_community, engine_traps_sent, engine_sample_cycle;
    reg cmd_req_re, cmd_out_we;
    reg [7:0] cmd_req_ra, cmd_out_wa, cmd_out_data;
    reg ram_req_re, ram_out_we;
    reg [7:0] ram_req_ra, ram_out_wa, ram_out_data;
    wire out_re;
    wire [7:0] out_ra, out_q;
    wire mib_request, mib_write;
    wire [17:0] engine_mib_addr;
    wire [31:0] engine_mib_wdata;
    reg mib_request_q, mib_write_q, mib_complete, mib_transaction;
    reg [17:0] mib_addr_q;
    reg [31:0] mib_wdata_q, mib_result;
    reg [1:0] mib_state;
    // 顶层交付口提前三拍给出端口，两级局部寄存分摊跨模块布线。
    // 独立使用本模块时，默认保持端口与有效字节同时到达的接口。
    (* preserve = 1, dont_merge = 1 *) reg [15:0] rx_port_stage, rx_port_local;
    wire [15:0] incoming_port = LOCAL_RX_PORT ? rx_port_local : rx_dport;
    reg local_port_match;
    always @(posedge clk) begin
        if (reset) begin
            rx_port_stage <= 0;
            rx_port_local <= 0;
            local_port_match <= 0;
        end
        else begin
            rx_port_stage <= rx_dport;
            rx_port_local <= rx_port_stage;
            local_port_match <= rx_port_stage == SNMP_PORT;
        end
    end

    assign rx_claim = configured && (LOCAL_RX_PORT ? local_port_match : incoming_port == SNMP_PORT);
    // 捕获启动的本地前提一次会合，远端字节有效位只进末级与门。
    wire accept_armed = rx_claim && idle_q && ! capture_pending && ! consumed_q && ! trap_grant;

    always @(posedge clk) begin
        if (reset) begin
            configured <= 0;
            trap_enabled <= 0;
            response_vl <= 0;
            configured_length <= DEFAULT_COMMUNITY_LENGTH;
            // 复位后的默认团体名是 6 个字符的 public。
            community0 <= DEFAULT_COMMUNITY0;
            community1 <= DEFAULT_COMMUNITY1;
            community2 <= 0;
            community3 <= 0;
            uptime <= 0;
            uptime_cycles <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_control_data <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_status_data <= 0;
            if (SPLIT_CFG_ADDR != 2) cfg_descr_data <= 0;
        end
        else begin
            // 每 1250000 拍是 10 ms，正好是 SNMP 运行时间（sysUpTime）的一个计数单位。
            if (uptime_cycles == UPTIME_TICK_LAST) begin
                uptime_cycles <= 0;
                uptime <= uptime + 32'd1;
            end
            else uptime_cycles <= uptime_cycles + 32'd1;
            if (cfg_we) case (cfg_write_addr)
                REG_ENABLE : configured <= cfg_wdata[0];
                REG_TX_VL : response_vl <= cfg_wdata[6:0];
                REG_COMMUNITY_LENGTH : configured_length <= cfg_wdata[4:0];
                REG_COMMUNITY0 : community0 <= cfg_wdata;
                REG_COMMUNITY1 : community1 <= cfg_wdata;
                REG_COMMUNITY2 : community2 <= cfg_wdata;
                REG_COMMUNITY3 : community3 <= cfg_wdata;
                REG_TRAP_ENABLE : trap_enabled <= cfg_wdata[0];
            endcase
            if (SPLIT_CFG_ADDR != 2) begin
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
            end
            if (SPLIT_CFG_ADDR != 2) begin
            case (cfg_addr[2:0])
                0 : cfg_status_data <= uptime;
                1 : cfg_status_data <= requests;
                2 : cfg_status_data <= bad_community;
                3 : cfg_status_data <= { 31'b0, trap_enabled };
                4 : cfg_status_data <= traps_sent;
                default : cfg_status_data <= 0;
            endcase
            end
            if (SPLIT_CFG_ADDR != 2) begin
            case (cfg_addr[2:0])
                0 : cfg_descr_data <= DESCRIPTION[127:96];
                1 : cfg_descr_data <= DESCRIPTION[95:64];
                2 : cfg_descr_data <= DESCRIPTION[63:32];
                3 : cfg_descr_data <= DESCRIPTION[31:0];
                default : cfg_descr_data <= 0;
            endcase
            end
        end
    end

    // 捕获、计数、通知仲裁和配置脉冲展宽均在每拍执行。
    always @(posedge clk) begin
        if (reset) begin
            requests <= 0;
            bad_community <= 0;
            traps_sent <= 0;
            sample_cycle <= 0;
            req_we <= 0;
            req_wa <= 0;
            req_wdata <= 0;
            receiving <= 0;
            overflow <= 0;
            rx_count <= 0;
            capture_pending <= 0;
            capture_length <= 0;
            capture_port <= 0;
            consumed_q <= 0;
            idle_q <= 0;
            offer_q <= 0;
            cold_ack_q <= 0;
            trap_grant <= 0;
            cold_request <= 0;
        end
        else begin
            bad_community <= engine_bad_community;
            traps_sent <= engine_traps_sent;
            sample_cycle <= engine_sample_cycle;
            consumed_q <= capture_consumed;
            idle_q <= capture_idle;
            offer_q <= trap_offer;
            cold_ack_q <= cold_ack;
            req_we <= 0;
            if (rx_valid && rx_claim && rx_last) requests <= requests + 32'd1;
            if (consumed_q) capture_pending <= 0;
            if (!idle_q || !offer_q) trap_grant <= 0;
            else if (!receiving && !capture_pending && !consumed_q && !(rx_valid && rx_claim)) trap_grant <= 1;
            if (cold_ack_q) cold_request <= 0;
            if (cfg_we && cfg_write_addr == REG_ENABLE && cfg_wdata[0] && !configured && trap_enabled)
                cold_request <= 1;
            if (!configured || !enable) begin
                receiving <= 0;
                capture_pending <= 0;
            end
            else if (!receiving) begin
                // accept_armed 是全本地项，远端 rx_valid 只进末级与门。
                if (accept_armed && rx_valid) begin
                    req_we <= 1;
                    req_wa <= 0;
                    req_wdata <= rx_data;
                    capture_port <= rx_sport;
                    rx_count <= 1;
                    overflow <= 0;
                    receiving <= !rx_last;
                    if (rx_last) begin
                        capture_pending <= 1;
                        capture_length <= 1;
                    end
                end
            end
            else if (rx_valid) begin
                if (!overflow) begin
                    req_we <= 1;
                    req_wa <= rx_count[7:0];
                    req_wdata <= rx_data;
                    rx_count <= rx_count + 9'd1;
                end
                if (rx_count == REQUEST_LAST_POS) overflow <= 1;
                if (rx_last) begin
                    receiving <= 0;
                    capture_pending <= !overflow;
                    capture_length <= rx_count + 9'd1;
                end
            end
        end
    end

    // RAM 端口由全速寄存器直接驱动，只提交一次每个 CE 命令。
    always @(posedge clk) begin
        if (reset) begin
            cmd_req_re <= 0;
            cmd_req_ra <= 0;
            cmd_out_we <= 0;
            cmd_out_wa <= 0;
            cmd_out_data <= 0;
            ram_req_re <= 0;
            ram_req_ra <= 0;
            ram_out_we <= 0;
            ram_out_wa <= 0;
            ram_out_data <= 0;
        end
        else begin
            cmd_req_re <= req_re;
            cmd_req_ra <= req_ra;
            cmd_out_we <= out_we;
            cmd_out_wa <= out_wa;
            cmd_out_data <= out_wdata;
            ram_req_re <= cmd_req_re && (CE_DIV == 1 || !ce[0]);
            ram_req_ra <= cmd_req_ra;
            ram_out_we <= cmd_out_we && (CE_DIV == 1 || !ce[0]);
            ram_out_wa <= cmd_out_wa;
            ram_out_data <= cmd_out_data;
        end
    end
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(256)) request_ram (
        .clk(clk), .write_enable(req_we), .write_address(req_wa), .write_data(req_wdata),
        .read_enable(ram_req_re), .read_address(ram_req_ra), .read_data(req_q)
    );
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(256)) response_ram (
        .clk(clk), .write_enable(ram_out_we), .write_address(ram_out_wa), .write_data(ram_out_data),
        .read_enable(out_re), .read_address(out_ra), .read_data(out_q)
    );
    afdx_mgmt_tx #(.AW(8)) sender (
        .clk(clk), .reset(reset), .request(send_request), .length(response_length), .vl(response_vl),
        .sport(16'd161), .dport(response_port), .mode(1'b0), .complete(send_complete),
        .read_enable(out_re), .read_address(out_ra), .read_data(out_q), .read_mode(),
        .tx_valid(tx_valid), .tx_ready(tx_ready), .tx_data(tx_data), .tx_last(tx_last),
        .tx_vl(tx_vl), .tx_sport(), .tx_dport(tx_dport)
    );

    // 一次请求只在主总线上执行一次；返回数据保持到下一次请求。
    always @(posedge clk) begin
        if (reset) begin
            mib_request_q <= 0;
            mib_write_q <= 0;
            mib_addr_q <= 0;
            mib_wdata_q <= 0;
            mib_transaction <= 0;
            mib_complete <= 0;
            mib_result <= 0;
            mib_state <= 0;
            mib_rd <= 0;
            mib_wr <= 0;
            mib_addr <= 0;
            mib_wdata <= 0;
        end
        else begin
            mib_request_q <= mib_request;
            mib_write_q <= mib_write;
            mib_addr_q <= engine_mib_addr;
            mib_wdata_q <= engine_mib_wdata;
            case (mib_state)
                0 : if (mib_request_q != mib_complete) begin
                    mib_transaction <= mib_request_q;
                    mib_addr <= mib_addr_q;
                    mib_wdata <= mib_wdata_q;
                    // 地址先稳定一拍，供全速配置读口预译码。
                    mib_state <= 3;
                end
                3 : begin
                    mib_rd <= !mib_write_q;
                    mib_wr <= mib_write_q;
                    mib_state <= 1;
                end
                1 : if (mib_ready) begin
                    mib_rd <= 0;
                    mib_wr <= 0;
                    if (mib_wr) begin
                        mib_complete <= mib_transaction;
                        mib_state <= 0;
                    end
                    else mib_state <= 2;
                end
                2 : if (mib_rvalid) begin
                    mib_result <= mib_rdata;
                    mib_complete <= mib_transaction;
                    mib_state <= 0;
                end
            endcase
        end
    end

    generate
        if (CE_DIV == 2) begin : half_rate
            afdx_snmp_engine #(.CE_BANKS(CE_BANKS)) engine (
                .clk(clk),
                .reset(reset),
                .ce_phase(ce),
                .enable_in(enable),
                .now_in(now),
                .configured_in(configured),
                .trap_enabled_in(trap_enabled),
                .configured_length_in(configured_length),
                .community0_in(community0),
                .community1_in(community1),
                .community2_in(community2),
                .community3_in(community3),
                .uptime_in(uptime),
                .capture_pending_in(capture_pending),
                .capture_length_in(capture_length),
                .capture_port_in(capture_port),
                .trap_grant_in(trap_grant),
                .cold_request_in(cold_request),
                .req_q_in(req_q),
                .send_complete_in(send_complete),
                .mib_complete_in(mib_complete),
                .mib_rdata_in(mib_result),
                .req_re(req_re),
                .req_ra(req_ra),
                .out_we(out_we),
                .out_wa(out_wa),
                .out_wdata(out_wdata),
                .response_port(response_port),
                .response_length(response_length),
                .bad_community(engine_bad_community),
                .traps_sent(engine_traps_sent),
                .sample_cycle(engine_sample_cycle),
                .mib_addr(engine_mib_addr),
                .mib_wdata(engine_mib_wdata),
                .capture_consumed(capture_consumed),
                .capture_idle(capture_idle),
                .trap_offer(trap_offer),
                .cold_ack(cold_ack),
                .send_request(send_request),
                .mib_request(mib_request),
                .mib_write(mib_write)
            );
        end
        else begin : full_rate
            afdx_snmp_engine #(.CE_BANKS(CE_BANKS)) engine (
                .clk(clk),
                .reset(reset),
                .ce_phase(ce),
                .enable_in(enable),
                .now_in(now),
                .configured_in(configured),
                .trap_enabled_in(trap_enabled),
                .configured_length_in(configured_length),
                .community0_in(community0),
                .community1_in(community1),
                .community2_in(community2),
                .community3_in(community3),
                .uptime_in(uptime),
                .capture_pending_in(capture_pending),
                .capture_length_in(capture_length),
                .capture_port_in(capture_port),
                .trap_grant_in(trap_grant),
                .cold_request_in(cold_request),
                .req_q_in(req_q),
                .send_complete_in(send_complete),
                .mib_complete_in(mib_complete),
                .mib_rdata_in(mib_result),
                .req_re(req_re),
                .req_ra(req_ra),
                .out_we(out_we),
                .out_wa(out_wa),
                .out_wdata(out_wdata),
                .response_port(response_port),
                .response_length(response_length),
                .bad_community(engine_bad_community),
                .traps_sent(engine_traps_sent),
                .sample_cycle(engine_sample_cycle),
                .mib_addr(engine_mib_addr),
                .mib_wdata(engine_mib_wdata),
                .capture_consumed(capture_consumed),
                .capture_idle(capture_idle),
                .trap_offer(trap_offer),
                .cold_ack(cold_ack),
                .send_request(send_request),
                .mib_request(mib_request),
                .mib_write(mib_write)
            );
        end
    endgenerate
    // 模式 2：高位为写地址，bit 6 选主机，[5:3] 为主机读址，[2:0] 为 MIB 预读址。
    // MIB 地址在读请求之前稳定一拍；每四位输出使用独立译码副本，主机仍直接译码。
    wire [31:0] word_cfg_control_data_0 = {31'b0, configured};
    wire [31:0] word_cfg_control_data_1 = {25'b0, response_vl};
    wire [31:0] word_cfg_control_data_2 = {27'b0, configured_length};
    wire [31:0] word_cfg_control_data_3 = community0;
    wire [31:0] word_cfg_control_data_4 = community1;
    wire [31:0] word_cfg_control_data_5 = community2;
    wire [31:0] word_cfg_control_data_6 = community3;
    wire [31:0] word_cfg_control_data_7 = sample_cycle;
    wire [31:0] word_cfg_status_data_0 = uptime;
    wire [31:0] word_cfg_status_data_1 = requests;
    wire [31:0] word_cfg_status_data_2 = bad_community;
    wire [31:0] word_cfg_status_data_3 = {31'b0, trap_enabled};
    wire [31:0] word_cfg_status_data_4 = traps_sent;
    wire [31:0] word_cfg_descr_data_0 = DESCRIPTION[127:96];
    wire [31:0] word_cfg_descr_data_1 = DESCRIPTION[95:64];
    wire [31:0] word_cfg_descr_data_2 = DESCRIPTION[63:32];
    wire [31:0] word_cfg_descr_data_3 = DESCRIPTION[31:0];
    genvar read_nibble;
    generate
        if (SPLIT_CFG_ADDR == 2) begin : local_read_decode
            for (read_nibble = 0; read_nibble < 8; read_nibble = read_nibble + 1) begin : nibble
                (* preserve = 1, dont_merge = 1 *) reg [7:0] mib_lane;
                wire [7:0] lane = cfg_addr[6] ? (8'b1 << cfg_addr[5:3]) : mib_lane;
                always @(posedge clk) begin
                    if (reset) begin
                        mib_lane <= 8'b1;
                        cfg_control_data[read_nibble * 4 +: 4] <= 0;
                        cfg_status_data[read_nibble * 4 +: 4] <= 0;
                        cfg_descr_data[read_nibble * 4 +: 4] <= 0;
                    end
                    else begin
                        mib_lane <= 8'b1 << cfg_addr[2:0];
                        cfg_control_data[read_nibble * 4 +: 4] <= ({4{lane[0]}} & word_cfg_control_data_0[read_nibble * 4 +: 4]) |
                            ({4{lane[1]}} & word_cfg_control_data_1[read_nibble * 4 +: 4]) |
                            ({4{lane[2]}} & word_cfg_control_data_2[read_nibble * 4 +: 4]) |
                            ({4{lane[3]}} & word_cfg_control_data_3[read_nibble * 4 +: 4]) |
                            ({4{lane[4]}} & word_cfg_control_data_4[read_nibble * 4 +: 4]) |
                            ({4{lane[5]}} & word_cfg_control_data_5[read_nibble * 4 +: 4]) |
                            ({4{lane[6]}} & word_cfg_control_data_6[read_nibble * 4 +: 4]) |
                            ({4{lane[7]}} & word_cfg_control_data_7[read_nibble * 4 +: 4]);
                        cfg_status_data[read_nibble * 4 +: 4] <= ({4{lane[0]}} & word_cfg_status_data_0[read_nibble * 4 +: 4]) |
                            ({4{lane[1]}} & word_cfg_status_data_1[read_nibble * 4 +: 4]) |
                            ({4{lane[2]}} & word_cfg_status_data_2[read_nibble * 4 +: 4]) |
                            ({4{lane[3]}} & word_cfg_status_data_3[read_nibble * 4 +: 4]) |
                            ({4{lane[4]}} & word_cfg_status_data_4[read_nibble * 4 +: 4]);
                        cfg_descr_data[read_nibble * 4 +: 4] <= ({4{lane[0]}} & word_cfg_descr_data_0[read_nibble * 4 +: 4]) |
                            ({4{lane[1]}} & word_cfg_descr_data_1[read_nibble * 4 +: 4]) |
                            ({4{lane[2]}} & word_cfg_descr_data_2[read_nibble * 4 +: 4]) |
                            ({4{lane[3]}} & word_cfg_descr_data_3[read_nibble * 4 +: 4]);
                    end
                end
            end
        end
    endgenerate

endmodule
