// 本模块先存下一整帧，再按每八拍一个字节读出。
// 输入来自千兆以太网，输出供低速接收核心使用。
// 这是一个备用的速率转换模块，只有接收核心每八拍收一个字节时才需要它。
// 当前接收核心每拍收一个字节，所以 AFDX_top 没有例化本模块。
// tb_gmii_rx 单独测试本模块，检查缓存满时的丢帧处理和读出顺序。
module afdx_gmii_rx #(
    parameter GMII_RX_AW = 12) (
    // reset 为高时同步复位，enable 决定是否接收新帧。
    input wire clk,
    input wire reset,
    input wire enable,
    // rx_valid 为高时，rx_data 是线路本拍收到的字节。
    // 线路发送方不会等待本模块就绪。
    input wire [7:0] rx_data,
    input wire rx_valid,
    // slow_valid 为高时，slow_data 每八拍换一个字节。
    // 缓存满而丢弃整帧时，gdrop 输出一拍脉冲。
    output reg [7:0] slow_data,
    output reg slow_valid,
    output reg gdrop);
    localparam CAPACITY = 1 << GMII_RX_AW;
    localparam DESC_WIDTH = 2 * GMII_RX_AW + 33;
    localparam [31:0] R = 32'd16;
    // tick 记录时间，wait_low 要求复位后先看到线路空闲。
    reg [31:0] tick;
    reg input_active, input_discard, wait_low;
    // write_ptr/read_ptr 用于计算缓存占用，frame_start 保存本帧起点。
    // 本帧存不下时，写位置退回 frame_start。
    reg [GMII_RX_AW:0] write_ptr, read_ptr, frame_start, frame_length;
    wire [GMII_RX_AW:0] occupied = write_ptr - read_ptr;
    reg byte_we, byte_re;
    reg [GMII_RX_AW - 1:0] byte_wa, byte_ra;
    reg [7:0] byte_wdata;
    wire [7:0] byte_rdata;
    reg byte_rvalid, byte_pending, byte_valid;
    reg [7:0] byte_q;
    // 每帧至少占一个字节，因此与字节缓存等深的消息队列不会先满。
    reg [GMII_RX_AW:0] desc_write_ptr, desc_read_ptr;
    reg desc_we, desc_re;
    reg [GMII_RX_AW - 1:0] desc_wa, desc_ra;
    reg [DESC_WIDTH - 1:0] desc_wdata;
    wire [DESC_WIDTH - 1:0] desc_rdata;
    reg [DESC_WIDTH - 1:0] desc_q;
    reg desc_rvalid, desc_qvalid, desc_pending, head_valid;
    reg [31:0] head_deadline;
    reg [4:0] gap_count;
    reg [GMII_RX_AW - 1:0] head_start, active_address;
    reg [GMII_RX_AW:0] head_length, remaining;
    // phase 从 0 数到 7，表示一个输出字节保持的八拍。
    // phase=7 时取下一字节，remaining=0 时结束本帧。
    reg [2:0] phase;
    wire due = ! ((tick - head_deadline) & 32'h80000000) && gap_count == 0;
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(CAPACITY)) bytes_ram (.clk(clk), .write_enable(byte_we), .write_address(byte_wa),
        .write_data(byte_wdata), .read_enable(byte_re), .read_address(byte_ra), .read_data(byte_rdata));
    afdx_ram_sdp #(.WIDTH(DESC_WIDTH), .DEPTH(CAPACITY)) frames_ram (.clk(clk), .write_enable(desc_we),
        .write_address(desc_wa), .write_data(desc_wdata), .read_enable(desc_re), .read_address(desc_ra),
        .read_data(desc_rdata));
    always @(posedge clk) begin
        if (reset) begin
            tick <= 0;
            input_active <= 0;
            input_discard <= 0;
            wait_low <= 1;
            write_ptr <= 0;
            read_ptr <= 0;
            frame_start <= 0;
            frame_length <= 0;
            byte_we <= 0;
            byte_re <= 0;
            byte_wa <= 0;
            byte_ra <= 0;
            byte_wdata <= 0;
            byte_rvalid <= 0;
            byte_pending <= 0;
            byte_valid <= 0;
            byte_q <= 0;
            desc_write_ptr <= 0;
            desc_read_ptr <= 0;
            desc_we <= 0;
            desc_re <= 0;
            desc_wa <= 0;
            desc_ra <= 0;
            desc_wdata <= 0;
            desc_q <= 0;
            desc_rvalid <= 0;
            desc_qvalid <= 0;
            desc_pending <= 0;
            head_valid <= 0;
            head_deadline <= 0;
            gap_count <= 0;
            head_start <= 0;
            active_address <= 0;
            head_length <= 0;
            remaining <= 0;
            phase <= 0;
            slow_data <= 0;
            slow_valid <= 0;
            gdrop <= 0;
        end
        else begin
            tick <= tick + 1'b1;
            byte_we <= 0;
            byte_re <= 0;
            desc_we <= 0;
            desc_re <= 0;
            gdrop <= 0;
            if (gap_count != 0) gap_count <= gap_count - 1'b1;
            // 复位后先等 rx_valid 拉低，再接收新帧，避免收到半帧。
            if (wait_low) begin
                if (! rx_valid) wait_low <= 0;
            end
            else if (rx_valid) begin
                if (! input_active) begin
                    input_active <= 1;
                    frame_start <= write_ptr;
                    frame_length <= 0;
                    input_discard <= ! enable;
                    if (enable) begin
                        if (occupied == CAPACITY) begin
                            input_discard <= 1;
                            gdrop <= 1;
                        end
                        else begin
                            byte_we <= 1;
                            byte_wa <= write_ptr[GMII_RX_AW - 1:0];
                            byte_wdata <= rx_data;
                            write_ptr <= write_ptr + 1'b1;
                            frame_length <= 1;
                        end
                    end
                end
                else if (! input_discard) begin
                    if (occupied == CAPACITY) begin
                        // 失败的帧尚未提交，释放它不会影响已经排队的完整帧。
                        input_discard <= 1;
                        write_ptr <= frame_start;
                        gdrop <= 1;
                    end
                    else begin
                        byte_we <= 1;
                        byte_wa <= write_ptr[GMII_RX_AW - 1:0];
                        byte_wdata <= rx_data;
                        write_ptr <= write_ptr + 1'b1;
                        frame_length <= frame_length + 1'b1;
                    end
                end
            end
            else if (input_active) begin
                input_active <= 0;
                if (! input_discard) begin
                    desc_we <= 1;
                    desc_wa <= desc_write_ptr[GMII_RX_AW - 1:0];
                    // 若帧尾在 E 拍写入，读出过程会在 E+R 拍对外开始有效。
                    desc_wdata <= { tick + (R - 32'd1), frame_length, frame_start[GMII_RX_AW - 1:0] };
                    desc_write_ptr <= desc_write_ptr + 1'b1;
                end
            end
            // 两块存储器的读结果先分别寄存，再交给后级选择。
            desc_rvalid <= desc_re;
            desc_qvalid <= desc_rvalid;
            if (desc_rvalid) desc_q <= desc_rdata;
            if (desc_qvalid) begin
                head_start <= desc_q[GMII_RX_AW - 1:0];
                head_length <= desc_q[2 * GMII_RX_AW:GMII_RX_AW];
                head_deadline <= desc_q[DESC_WIDTH - 1:2 * GMII_RX_AW + 1];
                head_valid <= 1;
                desc_pending <= 0;
            end
            if (! head_valid && ! desc_pending && desc_write_ptr != desc_read_ptr) begin
                desc_re <= 1;
                desc_ra <= desc_read_ptr[GMII_RX_AW - 1:0];
                desc_read_ptr <= desc_read_ptr + 1'b1;
                desc_pending <= 1;
            end
            byte_rvalid <= byte_re;
            if (byte_rvalid) begin
                byte_q <= byte_rdata;
                byte_valid <= 1;
                byte_pending <= 0;
            end
            // 完整帧信息、首字节和规定时间都就绪后，才开始每八拍读一个字节。
            if (! slow_valid) begin
                if (head_valid && ! byte_valid && ! byte_pending) begin
                    byte_re <= 1;
                    byte_ra <= head_start;
                    byte_pending <= 1;
                end
                if (head_valid && byte_valid && due) begin
                    slow_valid <= 1;
                    slow_data <= byte_q;
                    phase <= 0;
                    remaining <= head_length - 1'b1;
                    active_address <= head_start + 1'b1;
                    read_ptr <= read_ptr + 1'b1;
                    head_valid <= 0;
                    byte_valid <= 0;
                    if (head_length > 1) begin
                        byte_re <= 1;
                        byte_ra <= head_start + 1'b1;
                        byte_pending <= 1;
                    end
                end
            end
            else if (phase == 7) begin
                phase <= 0;
                if (remaining == 0) begin
                    slow_valid <= 0;
                    slow_data <= 0;
                    // 倒计时减到零就停止，避免空闲过久后因计数回绕而重新等待。
                    gap_count <= 15;
                end
                else begin
                    slow_data <= byte_q;
                    byte_valid <= 0;
                    remaining <= remaining - 1'b1;
                    read_ptr <= read_ptr + 1'b1;
                    active_address <= active_address + 1'b1;
                    if (remaining > 1) begin
                        byte_re <= 1;
                        byte_ra <= active_address + 1'b1;
                        byte_pending <= 1;
                    end
                end
            end
            else phase <= phase + 1'b1;
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if (! reset) begin
        if (occupied > CAPACITY) $display ("** Error: [GMIIRX] %m byte ring accounting overflow");
        if (desc_we && (desc_write_ptr - desc_read_ptr) > CAPACITY) $display ("** Error: [GMIIRX] %m descriptor capacity invariant");
        if (slow_valid && phase == 7 && remaining != 0 && ! byte_valid) $display ("** Error: [GMIIRX] %m replay prefetch unavailable");
    end
`endif
endmodule
