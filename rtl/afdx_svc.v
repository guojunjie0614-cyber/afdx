// 本模块让应用和三个服务共用端系统的收发通道。
// 发送时每次选中一条完整消息，再交给发送核心。
// 接收时按端口交给对应服务，其余消息交给应用。
// 它连接赛题的用户收发、时钟同步、网络管理和加卸载功能。
module afdx_svc (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // app_tx_* 提供应用消息，m_* 把选中的消息交给发送核心。
    // valid 和 ready 同为高时传输一个字节，last 标记消息结束。
    input wire app_tx_valid,
    output wire app_tx_ready,
    input wire [7:0] app_tx_data,
    input wire app_tx_last,
    input wire [6:0] app_tx_vl,
    input wire app_tx_port_en,
    input wire [15:0] app_tx_sport, app_tx_dport,

    // svc_tx_* 从低位到高位依次连接时钟同步、网络管理和加卸载。
    // 各组字段都按这个服务顺序拼接。
    input wire [2:0] svc_tx_valid,
    output reg [2:0] svc_tx_ready,
    input wire [23:0] svc_tx_data,
    input wire [2:0] svc_tx_last,
    input wire [20:0] svc_tx_vl,
    input wire [2:0] svc_tx_port_en,
    input wire [47:0] svc_tx_sport, svc_tx_dport,
    output reg m_valid,
    input wire m_ready,
    output reg [7:0] m_data,
    output reg m_last,
    output reg [6:0] m_vl,
    output reg m_port_en,
    output reg [15:0] m_sport, m_dport,

    // d_* 提供接收核心交付的用户字节、配置索引和端口。
    input wire d_valid,
    input wire [7:0] d_data,
    input wire d_last,
    input wire [11:0] d_vl,
    input wire [15:0] d_sport, d_dport,
    input wire d_net,

    // 三个服务在首字节到来时用 svc_rx_claim 表示是否接收此消息。
    // 没有服务接收时，app_rx_* 把消息交给应用。
    input wire [2:0] svc_rx_claim,
    output wire svc_rx_valid,
    output wire [7:0] svc_rx_data,
    output wire svc_rx_last,
    output wire [11:0] svc_rx_vl,
    output wire [15:0] svc_rx_sport, svc_rx_dport,
    output wire svc_rx_net,
    output wire app_rx_valid,
    output wire [7:0] app_rx_data,
    output wire app_rx_last,
    output wire [11:0] app_rx_vl,
    output wire [15:0] app_rx_sport, app_rx_dport,
    output wire app_rx_net,
    output wire snmp_rx_valid,
    output wire [7:0] snmp_rx_data,
    output wire snmp_rx_last,
    output wire [15:0] snmp_rx_sport, snmp_rx_dport,
    output wire load_rx_valid,
    output wire [7:0] load_rx_data,
    output wire load_rx_last,
    output wire [15:0] load_rx_sport, load_rx_dport);

    // 四个发送方的编号，也是 request 里对应的位：应用、时钟同步、网络管理、加卸载。
    localparam SRC_APP = 0, SRC_RTC = 1, SRC_SNMP = 2, SRC_LOAD = 3;

    // busy 为高时，served 的独热位保持当前消息的发送方。
    // turn 指定下次从哪一方开始查找待发消息。
    // rx_active/rx_claimed 保存首字节时的选择，直到消息结束。
    reg busy, rx_active, rx_claimed;
    reg reselect, select_pending;
    reg completed_message;
    (* preserve = 1, dont_merge = 1 *) reg [3:0] request_local;
    // Separate service and application capture points keep the incoming
    // byte/control fanout local. Metadata and bytes both gain one cycle.
    (* preserve = 1, dont_merge = 1 *) reg service_valid, application_valid, snmp_valid_q, load_valid_q;
    (* preserve = 1, dont_merge = 1 *) reg service_last, application_last, snmp_last_q, load_last_q;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] service_data, application_data, snmp_data_q, load_data_q;
    (* preserve = 1, dont_merge = 1 *) reg [11:0] service_vl, application_vl;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] service_sport, service_dport, application_sport, application_dport;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] snmp_sport_q, snmp_dport_q, load_sport_q, load_dport_q;
    (* preserve = 1, dont_merge = 1 *) reg service_net, application_net;
    reg [1:0] turn, selected;
    (* preserve = 1, dont_merge = 1 *) reg [3:0] served;
    reg [3:0] next_granted;
    wire [3:0] request = { svc_tx_valid, app_tx_valid };
    wire source_valid = |(request & served);
    wire finishing = m_valid && m_ready && m_last;
    wire [3:0] eff_request = request_local;
    wire [1:0] base_turn = turn;
    wire arbitrating = reselect || select_pending;

    // After a completed message, capture fresh requests in the first quiet
    // cycle and choose from that local snapshot in the second. A source holds
    // its byte until ready, so arbitration never consumes a speculative byte.
    always @* begin
        next_granted = 4'b0001;
        case (base_turn)
            2'd0 : begin
                next_granted[0] = (eff_request[0]) || !(|eff_request);
                next_granted[1] = eff_request[1] && !eff_request[0];
                next_granted[2] = eff_request[2] && !eff_request[0] && !eff_request[1];
                next_granted[3] = eff_request[3] && !eff_request[0] && !eff_request[1] && !eff_request[2];
            end
            2'd1 : begin
                next_granted[0] = (eff_request[0] && !eff_request[1] && !eff_request[2] && !eff_request[3]) || !(|eff_request);
                next_granted[1] = eff_request[1];
                next_granted[2] = eff_request[2] && !eff_request[1];
                next_granted[3] = eff_request[3] && !eff_request[1] && !eff_request[2];
            end
            2'd2 : begin
                next_granted[0] = (eff_request[0] && !eff_request[2] && !eff_request[3]) || !(|eff_request);
                next_granted[1] = eff_request[1] && !eff_request[2] && !eff_request[3] && !eff_request[0];
                next_granted[2] = eff_request[2];
                next_granted[3] = eff_request[3] && !eff_request[2];
            end
            2'd3 : begin
                next_granted[0] = (eff_request[0] && !eff_request[3]) || !(|eff_request);
                next_granted[1] = eff_request[1] && !eff_request[3] && !eff_request[0];
                next_granted[2] = eff_request[2] && !eff_request[3] && !eff_request[0] && !eff_request[1];
                next_granted[3] = eff_request[3];
            end
        endcase
    end

    // Keep the source fixed throughout a message, including backpressure.
    // Remote valid feeds only the request capture and the small idle detector;
    // priority selection and the grant update use registered local inputs.
    always @(posedge clk) begin
        if (reset) begin
            served <= 4'b0001;reselect <= 0;select_pending <= 0;request_local <= 0;
        end else begin
            request_local <= request;
            reselect <= !arbitrating && (finishing || (!busy && !source_valid));
            select_pending <= reselect;
            if (select_pending) served <= next_granted;
        end
    end

    // 消费端只使用寄存后的独热位，隔断 turn 到跨模块数据和 ready 的译码链。
    always @* begin
        selected = {served[2] | served[3], served[1] | served[3]};
        m_valid = source_valid && !arbitrating;
        svc_tx_ready = served[3:1] & {3{m_ready && !arbitrating}};
        m_data = ({8{served[0]}} & app_tx_data) |
            ({8{served[1]}} & svc_tx_data[0 +: 8]) |
            ({8{served[2]}} & svc_tx_data[8 +: 8]) |
            ({8{served[3]}} & svc_tx_data[16 +: 8]);
        m_last = ({1{served[0]}} & app_tx_last) |
            ({1{served[1]}} & svc_tx_last[0]) |
            ({1{served[2]}} & svc_tx_last[1]) |
            ({1{served[3]}} & svc_tx_last[2]);
        m_vl = ({7{served[0]}} & app_tx_vl) |
            ({7{served[1]}} & svc_tx_vl[0 +: 7]) |
            ({7{served[2]}} & svc_tx_vl[7 +: 7]) |
            ({7{served[3]}} & svc_tx_vl[14 +: 7]);
        m_port_en = ({1{served[0]}} & app_tx_port_en) |
            ({1{served[1]}} & svc_tx_port_en[0]) |
            ({1{served[2]}} & svc_tx_port_en[1]) |
            ({1{served[3]}} & svc_tx_port_en[2]);
        m_sport = ({16{served[0]}} & app_tx_sport) |
            ({16{served[1]}} & svc_tx_sport[0 +: 16]) |
            ({16{served[2]}} & svc_tx_sport[16 +: 16]) |
            ({16{served[3]}} & svc_tx_sport[32 +: 16]);
        m_dport = ({16{served[0]}} & app_tx_dport) |
            ({16{served[1]}} & svc_tx_dport[0 +: 16]) |
            ({16{served[2]}} & svc_tx_dport[16 +: 16]) |
            ({16{served[3]}} & svc_tx_dport[32 +: 16]);
    end

    assign app_tx_ready = served[0] && m_ready && !arbitrating;
    assign svc_rx_valid = service_valid;
    assign svc_rx_data = service_data;
    assign svc_rx_last = service_last;
    assign svc_rx_vl = service_vl;
    assign svc_rx_sport = service_sport;
    assign svc_rx_dport = service_dport;
    assign svc_rx_net = service_net;
    assign snmp_rx_valid = snmp_valid_q;
    assign snmp_rx_data = snmp_data_q;
    assign snmp_rx_last = snmp_last_q;
    assign snmp_rx_sport = snmp_sport_q;
    assign snmp_rx_dport = snmp_dport_q;
    assign load_rx_valid = load_valid_q;
    assign load_rx_data = load_data_q;
    assign load_rx_last = load_last_q;
    assign load_rx_sport = load_sport_q;
    assign load_rx_dport = load_dport_q;
    assign app_rx_valid = application_valid && ! (rx_active ? rx_claimed : | svc_rx_claim);
    // Like data, last is consumed only with valid. Keep claim/configuration
    // qualification on that token instead of feeding the last data register.
    assign app_rx_last = application_last;
    assign app_rx_data = application_data;
    assign app_rx_vl = application_vl;
    assign app_rx_sport = application_sport;
    assign app_rx_dport = application_dport;
    assign app_rx_net = application_net;

    always @(posedge clk) begin
        if (reset) begin
            service_valid<=0;service_last<=0;service_data<=0;service_vl<=0;
            service_sport<=0;service_dport<=0;service_net<=0;
            snmp_valid_q<=0;snmp_last_q<=0;snmp_data_q<=0;snmp_sport_q<=0;snmp_dport_q<=0;
            load_valid_q<=0;load_last_q<=0;load_data_q<=0;load_sport_q<=0;load_dport_q<=0;
            application_valid<=0;application_last<=0;application_data<=0;application_vl<=0;
            application_sport<=0;application_dport<=0;application_net<=0;
        end else begin
            service_valid<=d_valid;service_last<=d_last;service_data<=d_data;service_vl<=d_vl;
            service_sport<=d_sport;service_dport<=d_dport;service_net<=d_net;
            snmp_valid_q<=d_valid;snmp_last_q<=d_last;snmp_data_q<=d_data;snmp_sport_q<=d_sport;snmp_dport_q<=d_dport;
            load_valid_q<=d_valid;load_last_q<=d_last;load_data_q<=d_data;load_sport_q<=d_sport;load_dport_q<=d_dport;
            application_valid<=d_valid;application_last<=d_last;application_data<=d_data;application_vl<=d_vl;
            application_sport<=d_sport;application_dport<=d_dport;application_net<=d_net;
        end
    end

    // 发送末字节握手后，模块允许下一来源发送。
    // 接收时在首字节保存去向，在末字节释放这个选择。
    always @(posedge clk) begin
        if (reset) begin
            busy <= 0;
            turn <= 0;
            completed_message <= 0;
            rx_active <= 0;
            rx_claimed <= 0;
        end
        else begin
            // Retire the turn during the first existing quiet arbitration
            // clock. served is still the completed source until the second
            // quiet clock, so the actual next-grant edge remains unchanged.
            completed_message <= finishing;
            if (completed_message) turn <= selected + 2'd1;
            if (m_valid) begin
                if (m_ready && m_last) begin
                    busy <= 0;
                end
                else begin
                    busy <= 1;
                end
            end
            if (application_valid) begin
                if ( ! rx_active) rx_claimed <= | svc_rx_claim;
                rx_active <= ! application_last;
            end
        end
    end

endmodule
