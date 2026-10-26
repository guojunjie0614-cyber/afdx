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
    output reg [7:0] tx_data,
    output reg tx_last,
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
        end
        else begin
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

    // 八字节预取队列包含在途读请求；反压时仍为已发出的读保留位置。
    reg active, packet_request, return_valid;
    reg [AW:0] packet_length, issued;
    // 字节严格按发起顺序出队，剩余数量可在前一次出队时预判下一字节是否为末字节。
    // 标志不再随八项小 RAM 寻址读取；反压时计数与标志一起保持。
    (* preserve = 1, dont_merge = 1 *) reg [AW:0] output_left;
    (* preserve = 1, dont_merge = 1 *) reg at_last;
    reg [3:0] queued, reserved;
    reg [2:0] write_pos, read_pos;
    (* ramstyle = "no_rw_check" *) reg [7:0] bytes [0:7];
    wire issue = active && issued < packet_length && reserved < 8;
    // 远端 tx_ready 只进末级与门，本地项先行会合。
    wire take_armed = active && queued != 0;
    wire take = take_armed && (!tx_valid || tx_ready);
    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            packet_request <= 0;
            packet_length <= 0;
            issued <= 0;
            output_left <= 0;
            at_last <= 0;
            queued <= 0;
            reserved <= 0;
            write_pos <= 0;
            read_pos <= 0;
            read_enable <= 0;
            read_address <= 0;
            return_valid <= 0;
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
            if (issue) begin
                read_address <= issued[AW - 1:0];
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
                write_pos <= write_pos + 1'b1;
            end
            if (!tx_valid || tx_ready) begin
                tx_valid <= take;
                if (take) begin
                    tx_data <= bytes[read_pos];
                    tx_last <= at_last;
                    output_left <= output_left - 1'b1;
                    at_last <= output_left == 2;
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
                output_left <= length_q;
                at_last <= length_q == 1;
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

    // 空队列不出队，满队列没有在途返回；同拍同址读写不属于有效操作。
`ifndef SYNTHESIS
    always @(posedge clk) if (!reset && return_valid && take
        && write_pos == read_pos) $display ("** Error: [RAMCOLL] %m time=%0t address=%0d",
        $time, write_pos);
`endif
endmodule
