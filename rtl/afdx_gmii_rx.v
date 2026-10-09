// 缓存完整GMII帧，再以核心每八拍一字节的节拍重放。
// GMII输入无反压；慢线输出连接接收核心，gdrop报告整帧丢弃。
// 写满即撤销本帧并丢到帧尾；仅完整有效帧进入重放描述队列。
// GMII整帧缓存后重放。空间在慢线字节首次可见的周期释放。
module afdx_gmii_rx #(
    parameter GMII_RX_AW = 12) (
    input wire clk,
    input wire reset,
    input wire enable,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg [7:0] slow_data,
    output reg slow_valid,
    output reg gdrop);
    localparam CAPACITY = 1 << GMII_RX_AW;
    localparam DESC_WIDTH = 2 * GMII_RX_AW + 33;
    localparam [31:0] R = 32'd16;
    reg [31:0] tick;
    reg input_active, input_discard, wait_low;
    reg [GMII_RX_AW:0] write_ptr, read_ptr, frame_start, frame_length;
    wire [GMII_RX_AW:0] occupied = write_ptr - read_ptr;
    reg byte_we, byte_re;
    reg [GMII_RX_AW - 1:0] byte_wa, byte_ra;
    reg [7:0] byte_wdata;
    wire [7:0] byte_rdata;
    reg byte_rvalid, byte_pending, byte_valid;
    reg [7:0] byte_q;
    // 一帧至少有一个字节；与字节环等深的描述队列不会先满。
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
            // 复位时线路可能正在帧中，必须先看到低电平再认新帧。
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
                        // 未完整的尾帧尚未进入描述队列，回退不会碰已交出的帧。
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
                    // 本拍E存到RAM，启动寄存器于E+R-1置位，外部E+R可见。
                    desc_wdata <= { tick + (R - 32'd1), frame_length, frame_start[GMII_RX_AW - 1:0] };
                    desc_write_ptr <= desc_write_ptr + 1'b1;
                end
            end
            // 两张RAM的输出分别直接进入寄存器，再供后级使用。
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
                    // 饱和倒计时不会因长时间空闲后的32位计时回绕重新阻塞。
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
