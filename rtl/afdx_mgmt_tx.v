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
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg tx_valid,
    input wire tx_ready,
    output wire [7:0] tx_data,
    output wire tx_last,
    output reg [6:0] tx_vl,
    output reg [15:0] tx_sport, tx_dport
);
    // 协议引擎与本模块可能相距很远，跨段输入整组经两级寄存，后续控制只使用第二级。
    // 请求与元数据同样晚两拍，元数据在请求翻转前已稳定并保持到 complete，对齐关系不变。
    (* preserve = 1, dont_merge = 1 *) reg request_p, mode_p;
    (* preserve = 1, dont_merge = 1 *) reg [AW:0] length_p;
    (* preserve = 1, dont_merge = 1 *) reg [6:0] vl_p;
    (* preserve = 1, dont_merge = 1 *) reg [15:0] sport_p, dport_p;
    reg request_q, mode_q;
    reg [AW:0] length_q;
    reg [6:0] vl_q;
    reg [15:0] sport_q, dport_q;
    always @(posedge clk) begin
        if (reset) begin
            request_p <= 0;
            length_p <= 0;
            vl_p <= 0;
            sport_p <= 0;
            dport_p <= 0;
            mode_p <= 0;
            request_q <= 0;
            length_q <= 0;
            vl_q <= 0;
            sport_q <= 0;
            dport_q <= 0;
            mode_q <= 0;
        end else begin
            request_p <= request;
            length_p <= length;
            vl_p <= vl;
            sport_p <= sport;
            dport_p <= dport;
            mode_p <= mode;
            request_q <= request_p;
            length_q <= length_p;
            vl_q <= vl_p;
            sport_q <= sport_p;
            dport_q <= dport_p;
            mode_q <= mode_p;
        end
    end

    // Eight queue credits still cover all pending reads and queued bytes.
    // A take is retired locally one clock later. Subtracting the registered
    // debt reconstructs exactly the original current credit/head values, so
    // read issue and public valid retain every original clock under backpressure.
    reg active, packet_request, return_valid;
    reg [AW:0] packet_length, issued;
    (* preserve = 1, dont_merge = 1 *) reg [AW:0] output_left;
    reg [3:0] queued, reserved;
    reg [2:0] write_pos, read_pos;
    reg [7:0] bytes [0:7];
    (* preserve = 1, dont_merge = 1 *) reg take_q;
    wire [3:0] queued_current = queued - {3'b0,take_q};
    wire [3:0] reserved_current = reserved - {3'b0,take_q};
    wire [2:0] queue_head = read_pos + {2'b0,take_q};
    wire [AW:0] left_current = output_left - {{AW{1'b0}},take_q};
    wire issue = active && issued < packet_length && reserved_current < 8;
    wire take_armed = active && queued_current != 0;
    wire take = take_armed && (!tx_valid || tx_ready);
    wire pop = tx_valid && tx_ready;

    // There is still only ONE owned public output byte. The other physical
    // candidate bank samples the queue head while free. A take changes only
    // ownership/pointers; remote ready never enters either byte FF enable.
    // Alternating banks allow an occupied byte to stay stable through stalls
    // and allow a simultaneous pop/take every clock without extra capacity.
    reg output_read;
    // With at most one public byte, valid plus the head bit fully encode
    // ownership. The next free candidate is the opposite bank while valid.
    // Removing redundant ownership FFs also removes remote-ready D cones.
    wire output_write = output_read ^ tx_valid;
    wire [1:0] output_owned = tx_valid ? (2'b01 << output_read) : 2'b00;
    wire [7:0] output_data [0:1];
    wire [1:0] output_last;
    assign tx_data = output_data[output_read];
    assign tx_last = tx_valid && output_last[output_read];
    genvar output_bank;
    generate for (output_bank=0; output_bank<2; output_bank=output_bank+1) begin : candidate
        (* preserve = 1, dont_merge = 1 *) reg [7:0] data;
        (* preserve = 1, dont_merge = 1 *) reg last;
        assign output_data[output_bank] = data;
        assign output_last[output_bank] = last;
        always @(posedge clk) begin
            if (reset) begin
                data <= 0;
                last <= 0;
            end else begin
                if (!output_owned[output_bank]) begin
                    data <= bytes[queue_head];
                    last <= left_current == 1;
                end
                end
        end
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            packet_request <= 0;
            packet_length <= 0;
            issued <= 0;
            output_left <= 0;
            queued <= 0;
            reserved <= 0;
            write_pos <= 0;
            read_pos <= 0;
            take_q <= 0;
            output_read <= 0;
            read_enable <= 0;
            read_address <= 0;
            return_valid <= 0;
            complete <= 0;
            read_mode <= 0;
            tx_valid <= 0;
            tx_vl <= 0;
            tx_sport <= 0;
            tx_dport <= 0;
        end else begin
            read_enable <= issue;
            return_valid <= read_enable;
            take_q <= take;
            read_pos <= queue_head;
            if (take_q) output_left <= output_left - 1'b1;
            if (pop) output_read <= !output_read;
            if (issue) begin
                read_address <= issued[AW - 1:0];
                issued <= issued + 1'b1;
            end
            case ({issue, take_q})
                2'b10 : reserved <= reserved + 1'b1;
                2'b01 : reserved <= reserved - 1'b1;
            endcase
            case ({return_valid, take_q})
                2'b10 : queued <= queued + 1'b1;
                2'b01 : queued <= queued - 1'b1;
            endcase
            if (return_valid) begin
                bytes[write_pos] <= read_data;
                write_pos <= write_pos + 1'b1;
            end
            if (!tx_valid || tx_ready) tx_valid <= take;
            if (pop && tx_last) begin
                tx_valid <= 0;
                active <= 0;
                complete <= packet_request;
            end
            if (!active && request_q != complete) begin
                active <= 1;
                packet_request <= request_q;
                packet_length <= length_q;
                issued <= 0;
                output_left <= length_q;
                queued <= 0;
                reserved <= 0;
                write_pos <= 0;
                read_pos <= 0;
                take_q <= 0;
                output_read <= 0;
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
