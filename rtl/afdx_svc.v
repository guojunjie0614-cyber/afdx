// 在应用和RTC、SNMP、615A之间复用消息通道。
// 发送按整条消息轮询；接收按服务认领分发，未认领消息交应用。
// 握手完成前保持当前来源，消息内部不能混入其他来源字节。
// 应用及三个服务按整条消息轮询；接收广播，首字节认领结果保持到末字节。
module afdx_svc (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // app_tx_* 为用户消息，m_* 为发往发送核心的共用消息；valid/ready 握手、last 结束消息。
    input wire app_tx_valid,
    output wire app_tx_ready,
    input wire [7:0] app_tx_data,
    input wire app_tx_last,
    input wire [6:0] app_tx_vl,
    input wire app_tx_port_en,
    input wire [15:0] app_tx_sport, app_tx_dport,
    // svc_tx_* 低位到高位依次为 RTC、SNMP、615A；各字段按相同服务顺序拼接。
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
    // d_* 为接收核心的无反压载荷和 VL/UDP 端口/来源网络。
    input wire d_valid,
    input wire [7:0] d_data,
    input wire d_last,
    input wire [11:0] d_vl,
    input wire [15:0] d_sport, d_dport,
    input wire d_net,
    // svc_rx_claim 在首字节认领服务；svc_rx_* 广播给三个服务，未认领消息通过 app_rx_* 交用户。
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
    // busy/owner 锁住一条发送消息；turn 指定下轮首选来源，selected 为组合选择结果。
    // rx_active/rx_claimed 保存首字节认领，避免消息中途流向应用口。
    reg busy, rx_active, rx_claimed;
    reg [1:0] owner, turn, selected;
    wire [3:0] request = { svc_tx_valid, app_tx_valid };
    // 整消息轮询：从 turn 开始寻找有效来源；busy 时只选 owner，反压传给选中来源。
    always @ * begin
        selected = 0;
        case (turn)
            0 : if (request[0]) selected = 0;
            else if (request[1]) selected = 1;
            else if (request[2]) selected = 2;
            else if (request[3]) selected = 3;
            1 : if (request[1]) selected = 1;
            else if (request[2]) selected = 2;
            else if (request[3]) selected = 3;
            else if (request[0]) selected = 0;
            2 : if (request[2]) selected = 2;
            else if (request[3]) selected = 3;
            else if (request[0]) selected = 0;
            else if (request[1]) selected = 1;
            3 : if (request[3]) selected = 3;
            else if (request[0]) selected = 0;
            else if (request[1]) selected = 1;
            else if (request[2]) selected = 2;
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
            1 : begin
                m_valid = svc_tx_valid[0];
                m_data = svc_tx_data[7:0];
                m_last = svc_tx_last[0];
                m_vl = svc_tx_vl[6:0];
                m_port_en = svc_tx_port_en[0];
                m_sport = svc_tx_sport[15:0];
                m_dport = svc_tx_dport[15:0];
                svc_tx_ready[0] = m_ready;
            end
            2 : begin
                m_valid = svc_tx_valid[1];
                m_data = svc_tx_data[15:8];
                m_last = svc_tx_last[1];
                m_vl = svc_tx_vl[13:7];
                m_port_en = svc_tx_port_en[1];
                m_sport = svc_tx_sport[31:16];
                m_dport = svc_tx_dport[31:16];
                svc_tx_ready[1] = m_ready;
            end
            3 : begin
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
    assign app_tx_ready = (selected == 0) && m_ready;
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
    // 发送在末字节握手后解除占用并轮转；接收在首字节锁存认领，在末字节解除。
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
