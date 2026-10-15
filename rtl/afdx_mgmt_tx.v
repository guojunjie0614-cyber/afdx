// 协议引擎提交完整报文后，本模块在主时钟下连续读取并发送。
// request/complete 是翻转握手；提交者保持报文和元数据，直到 complete 返回。
module afdx_mgmt_tx #(parameter AW = 10) (
    input wire clk, reset,
    input wire request,
    input wire [AW:0] length,
    input wire [6:0] vl,
    input wire [15:0] sport, dport,
    input wire mode,
    output reg complete,
    output reg read_enable,
    output reg [AW - 1:0] read_address,
    input wire [7:0] read_data,
    output reg read_mode,
    output reg tx_valid,
    input wire tx_ready,
    output reg [7:0] tx_data,
    output reg tx_last,
    output reg [6:0] tx_vl,
    output reg [15:0] tx_sport, tx_dport
);
    // 跨段输入先直接寄存，后续控制只使用本地副本。
    reg request_q, mode_q;
    reg [AW:0] length_q;
    reg [6:0] vl_q;
    reg [15:0] sport_q, dport_q;
    always @(posedge clk) begin
        if (reset) begin
            request_q <= 0;
            length_q <= 0;
            vl_q <= 0;
            sport_q <= 0;
            dport_q <= 0;
            mode_q <= 0;
        end
        else begin
            request_q <= request;
            length_q <= length;
            vl_q <= vl;
            sport_q <= sport;
            dport_q <= dport;
            mode_q <= mode;
        end
    end

    // 八字节预取队列包含在途读请求；反压时仍为已发出的读保留位置。
    reg active, packet_request, read_last, return_valid, return_last;
    reg [AW:0] packet_length, issued;
    reg [3:0] queued, reserved;
    reg [2:0] write_pos, read_pos;
    reg [7:0] bytes [0:7];
    reg last_byte [0:7];
    wire issue = active && issued < packet_length && reserved < 8;
    wire take = active && (!tx_valid || tx_ready) && queued != 0;
    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            packet_request <= 0;
            packet_length <= 0;
            issued <= 0;
            queued <= 0;
            reserved <= 0;
            write_pos <= 0;
            read_pos <= 0;
            read_enable <= 0;
            read_address <= 0;
            read_last <= 0;
            return_valid <= 0;
            return_last <= 0;
            complete <= 0;
            read_mode <= 0;
            tx_valid <= 0;
            tx_data <= 0;
            tx_last <= 0;
            tx_vl <= 0;
            tx_sport <= 0;
            tx_dport <= 0;
        end
        else begin
            read_enable <= issue;
            return_valid <= read_enable;
            return_last <= read_last;
            if (issue) begin
                read_address <= issued[AW - 1:0];
                read_last <= issued + 1'b1 == packet_length;
                issued <= issued + 1'b1;
            end
            case ({issue, take})
                2'b10 : reserved <= reserved + 1'b1;
                2'b01 : reserved <= reserved - 1'b1;
            endcase
            case ({return_valid, take})
                2'b10 : queued <= queued + 1'b1;
                2'b01 : queued <= queued - 1'b1;
            endcase
            if (return_valid) begin
                bytes[write_pos] <= read_data;
                last_byte[write_pos] <= return_last;
                write_pos <= write_pos + 1'b1;
            end
            if (!tx_valid || tx_ready) begin
                tx_valid <= take;
                if (take) begin
                    tx_data <= bytes[read_pos];
                    tx_last <= last_byte[read_pos];
                    read_pos <= read_pos + 1'b1;
                end
            end
            if (tx_valid && tx_ready && tx_last) begin
                tx_valid <= 0;
                tx_last <= 0;
                active <= 0;
                complete <= packet_request;
            end
            if (!active && request_q != complete) begin
                active <= 1;
                packet_request <= request_q;
                packet_length <= length_q;
                issued <= 0;
                queued <= 0;
                reserved <= 0;
                write_pos <= 0;
                read_pos <= 0;
                return_valid <= 0;
                read_enable <= 0;
                read_mode <= mode_q;
                tx_vl <= vl_q;
                tx_sport <= sport_q;
                tx_dport <= dport_q;
            end
        end
    end
endmodule
