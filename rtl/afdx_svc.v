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
    output wire app_rx_net);
    // 四个发送方的编号，也是 request 里对应的位：应用、时钟同步、网络管理、加卸载。
    localparam SRC_APP = 0, SRC_RTC = 1, SRC_SNMP = 2, SRC_LOAD = 3;
    // busy 为高时，owner 保存当前消息的发送方。
    // turn 指定下次从哪一方开始查找待发消息。
    // rx_active/rx_claimed 保存首字节时的选择，直到消息结束。
    reg busy, rx_active, rx_claimed;
    reg [1:0] owner, turn, selected;
    wire [3:0] request = { svc_tx_valid, app_tx_valid };
    // 模块从 turn 开始查找待发消息，选中后保持到整条消息发完。
    // 只有选中的发送方能收到 ready。
    always @ * begin
        selected = SRC_APP;
        case (turn)
            SRC_APP : if (request[SRC_APP]) selected = SRC_APP;
            else if (request[SRC_RTC]) selected = SRC_RTC;
            else if (request[SRC_SNMP]) selected = SRC_SNMP;
            else if (request[SRC_LOAD]) selected = SRC_LOAD;
            SRC_RTC : if (request[SRC_RTC]) selected = SRC_RTC;
            else if (request[SRC_SNMP]) selected = SRC_SNMP;
            else if (request[SRC_LOAD]) selected = SRC_LOAD;
            else if (request[SRC_APP]) selected = SRC_APP;
            SRC_SNMP : if (request[SRC_SNMP]) selected = SRC_SNMP;
            else if (request[SRC_LOAD]) selected = SRC_LOAD;
            else if (request[SRC_APP]) selected = SRC_APP;
            else if (request[SRC_RTC]) selected = SRC_RTC;
            SRC_LOAD : if (request[SRC_LOAD]) selected = SRC_LOAD;
            else if (request[SRC_APP]) selected = SRC_APP;
            else if (request[SRC_RTC]) selected = SRC_RTC;
            else if (request[SRC_SNMP]) selected = SRC_SNMP;
        endcase
        if (busy) selected = owner;
        m_valid = app_tx_valid;
        m_data = app_tx_data;
        m_last = app_tx_last;
        m_vl = app_tx_vl;
        m_port_en = app_tx_port_en;
        m_sport = app_tx_sport;
        m_dport = app_tx_dport;
        svc_tx_ready = 0;
        case (selected)
            SRC_RTC : begin
                m_valid = svc_tx_valid[0];
                m_data = svc_tx_data[7:0];
                m_last = svc_tx_last[0];
                m_vl = svc_tx_vl[6:0];
                m_port_en = svc_tx_port_en[0];
                m_sport = svc_tx_sport[15:0];
                m_dport = svc_tx_dport[15:0];
                svc_tx_ready[0] = m_ready;
            end
            SRC_SNMP : begin
                m_valid = svc_tx_valid[1];
                m_data = svc_tx_data[15:8];
                m_last = svc_tx_last[1];
                m_vl = svc_tx_vl[13:7];
                m_port_en = svc_tx_port_en[1];
                m_sport = svc_tx_sport[31:16];
                m_dport = svc_tx_dport[31:16];
                svc_tx_ready[1] = m_ready;
            end
            SRC_LOAD : begin
                m_valid = svc_tx_valid[2];
                m_data = svc_tx_data[23:16];
                m_last = svc_tx_last[2];
                m_vl = svc_tx_vl[20:14];
                m_port_en = svc_tx_port_en[2];
                m_sport = svc_tx_sport[47:32];
                m_dport = svc_tx_dport[47:32];
                svc_tx_ready[2] = m_ready;
            end
        endcase
    end
    assign app_tx_ready = (selected == SRC_APP) && m_ready;
    assign svc_rx_valid = d_valid;
    assign svc_rx_data = d_data;
    assign svc_rx_last = d_last;
    assign svc_rx_vl = d_vl;
    assign svc_rx_sport = d_sport;
    assign svc_rx_dport = d_dport;
    assign svc_rx_net = d_net;
    assign app_rx_valid = d_valid && ! (rx_active ? rx_claimed : | svc_rx_claim);
    assign app_rx_last = d_last && app_rx_valid;
    assign app_rx_data = d_data;
    assign app_rx_vl = d_vl;
    assign app_rx_sport = d_sport;
    assign app_rx_dport = d_dport;
    assign app_rx_net = d_net;
    // 发送末字节握手后，模块允许下一来源发送。
    // 接收时在首字节保存去向，在末字节释放这个选择。
    always @(posedge clk) begin
        if (reset) begin
            busy <= 0;
            owner <= 0;
            turn <= 0;
            rx_active <= 0;
            rx_claimed <= 0;
        end
        else begin
            if (m_valid) begin
                if (m_ready && m_last) begin
                    busy <= 0;
                    turn <= selected + 2'd1;
                end
                else begin
                    busy <= 1;
                    owner <= selected;
                end
            end
            if (d_valid) begin
                if (! rx_active) rx_claimed <= | svc_rx_claim;
                rx_active <= ! d_last;
            end
        end
    end
endmodule
