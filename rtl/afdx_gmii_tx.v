// 本模块把每八拍一个字节的输入转换为连续的千兆以太网输出。
// 输入来自低速发送核心，输出每拍发送一个字节。
// 这是一个备用的速率转换模块，只有发送核心每八拍出一个字节时才需要它。
// 当前发送核心每拍出一个字节，所以 AFDX_top 没有例化本模块。
// tb_gmii_tx 单独测试本模块，检查每帧首字节固定延后 10688 拍。
module afdx_gmii_tx (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // slow_valid 在帧内持续为高，slow_data 每八拍提供一个新字节。
    input wire [7:0] slow_data,
    input wire slow_valid,
    // tx_valid 为高时，tx_data 每拍输出一个字节。
    // 首字节比输入首字节固定延后 10688 拍。
    output reg [7:0] tx_data,
    output reg tx_valid);
    // 先保留上一字节，看到下一拍输入后才能确定它是否为帧尾。
    // 固定延迟按最长帧的缓存时间向上取 64 的整数倍，得到 10688 拍。
    localparam TX_DELAY = 10688;
    localparam DATA_AW = 11, DATA_DEPTH = 2048, DUE_DEPTH = 16;
    // clock_count 用于确定本帧应从哪一拍开始输出。
    // input_active/byte_phase 判断何时保存字节和末字节标记。
    reg [31:0] clock_count;
    reg input_active;
    reg [2:0] byte_phase;
    reg [7:0] held_byte;
    wire frame_start = slow_valid && ! input_active;
    wire store_byte = input_active && (! slow_valid || byte_phase == 7);
    reg data_we, data_re;
    reg [DATA_AW - 1:0] data_wa, data_ra;
    reg [8:0] data_wd;
    wire [8:0] data_q;
    // 缓存分别记录写入、发出读请求和释放的位置，避免重复计算空闲空间。
    reg [DATA_AW:0] write_ptr, read_issue_ptr, read_release_ptr;
    wire [DATA_AW:0] occupied = write_ptr - read_release_ptr;
    afdx_ram_sdp #(.WIDTH(9), .DEPTH(DATA_DEPTH)) bytes_ram (clk, data_we, data_wa, data_wd, data_re, data_ra, data_q);
    // 队列最多容纳 16 个尚未开始输出的帧。
    // 输出开始后，sending 单独记录当前帧的进度。
    reg due_we, due_re;
    reg [3:0] due_wa, due_ra, due_write_ptr, due_read_ptr;
    reg [31:0] due_wd;
    wire [31:0] due_q;
    reg [4:0] due_count;
    // due_phase=0：发出队首时间的读请求，然后转 1。
    // due_phase=1：等待同步读取，然后转 2。
    // due_phase=2：保存读结果，然后转 0。
    // 时间已到且当前未发送时，launch_frame 启动下一帧。
    reg [1:0] due_phase;
    reg head_valid;
    reg [31:0] head_due;
    reg sending;
    wire launch_frame = head_valid && ! sending && clock_count == head_due;
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(DUE_DEPTH)) due_ram (clk, due_we, due_wa, due_wd, due_re, due_ra, due_q);
    // 四个寄存器提前保存读出的字节，跨帧时保留尚未使用的数据。
    reg [8:0] prefetch0, prefetch1, prefetch2, prefetch3;
    reg [1:0] prefetch_write, prefetch_read;
    reg [2:0] prefetch_count;
    reg return_valid;
    wire [8:0] front_word = prefetch_read == 0 ? prefetch0 : prefetch_read == 1 ? prefetch1 : prefetch_read == 2 ? prefetch2 : prefetch3;
    wire [3:0] reserved_count = { 1'b0, prefetch_count } + data_re + return_valid;
    wire request_word = read_issue_ptr != write_ptr && reserved_count < 4;
    wire pop_word = (sending || launch_frame) && prefetch_count != 0;
    always @(posedge clk) begin
        if (reset) begin
            clock_count <= 0;
            input_active <= 0;
            byte_phase <= 0;
            held_byte <= 0;
            data_we <= 0;
            data_re <= 0;
            data_wa <= 0;
            data_ra <= 0;
            data_wd <= 0;
            write_ptr <= 0;
            read_issue_ptr <= 0;
            read_release_ptr <= 0;
            due_we <= 0;
            due_re <= 0;
            due_wa <= 0;
            due_ra <= 0;
            due_wd <= 0;
            due_write_ptr <= 0;
            due_read_ptr <= 0;
            due_count <= 0;
            due_phase <= 0;
            head_valid <= 0;
            head_due <= 0;
            sending <= 0;
            prefetch0 <= 0;
            prefetch1 <= 0;
            prefetch2 <= 0;
            prefetch3 <= 0;
            prefetch_write <= 0;
            prefetch_read <= 0;
            prefetch_count <= 0;
            return_valid <= 0;
            tx_data <= 0;
            tx_valid <= 0;
        end
        else begin
            clock_count <= clock_count + 1'b1;
            data_we <= 0;
            due_we <= 0;
            due_re <= 0;
            tx_data <= 0;
            tx_valid <= 0;
            // 新帧登记规定的输出时间，输入字节延迟保存以确定帧尾。
            if (frame_start) begin
                input_active <= 1;
                byte_phase <= 0;
                held_byte <= slow_data;
                due_we <= 1;
                due_wa <= due_write_ptr;
                // 本拍写输出寄存器，下一可观察周期 S+D 才出现首字节。
                due_wd <= clock_count + TX_DELAY - 1;
                due_write_ptr <= due_write_ptr + 1'b1;
            end
            else if (input_active) begin
                if (! slow_valid) begin
                    input_active <= 0;
                    byte_phase <= 0;
                end
                else if (byte_phase == 7) begin
                    byte_phase <= 0;
                    held_byte <= slow_data;
                end
                else byte_phase <= byte_phase + 1'b1;
            end
            if (store_byte) begin
                data_we <= 1;
                data_wa <= write_ptr[DATA_AW - 1:0];
                data_wd <= { ! slow_valid, held_byte };
                write_ptr <= write_ptr + 1'b1;
            end
            // 读请求比写入晚到存储器一拍，避免同拍读取刚写的地址。
            data_re <= request_word;
            if (request_word) begin
                data_ra <= read_issue_ptr[DATA_AW - 1:0];
                read_issue_ptr <= read_issue_ptr + 1'b1;
            end
            if (data_re) read_release_ptr <= read_release_ptr + 1'b1;
            return_valid <= data_re;
            if (return_valid) begin
                case (prefetch_write)
                    2'd0 : prefetch0 <= data_q;
                    2'd1 : prefetch1 <= data_q;
                    2'd2 : prefetch2 <= data_q;
                    2'd3 : prefetch3 <= data_q;
                endcase
                prefetch_write <= prefetch_write + 1'b1;
            end
            case ({ return_valid, pop_word })
                2'b10 : prefetch_count <= prefetch_count + 1'b1;
                2'b01 : prefetch_count <= prefetch_count - 1'b1;
                default :;
            endcase
            // launch_frame 启动一帧，随后每拍输出一字节，读到 last 时停止。
            if (pop_word) begin
                tx_data <= front_word[7:0];
                tx_valid <= 1;
                prefetch_read <= prefetch_read + 1'b1;
                sending <= ! front_word[8];
            end
            case ({ frame_start, launch_frame })
                2'b10 : due_count <= due_count + 1'b1;
                2'b01 : due_count <= due_count - 1'b1;
                default :;
            endcase
            if (launch_frame) begin
                head_valid <= 0;
                due_read_ptr <= due_read_ptr + 1'b1;
            end
            case (due_phase)
                0 : if (! head_valid && due_count != 0) begin
                    due_re <= 1;
                    due_ra <= due_read_ptr;
                    due_phase <= 1;
                end
                1 : due_phase <= 2;
                2 : begin
                    head_due <= due_q;
                    head_valid <= 1;
                    due_phase <= 0;
                end
                default : due_phase <= 0;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (! reset) begin
            if (store_byte && occupied >= DATA_DEPTH) $display ("** Error: [GMIITX] %m data overflow time=%0t occupied=%0d",
                $time, occupied);
            if (frame_start && due_count == DUE_DEPTH && ! launch_frame) $display ("** Error: [GMIITX] %m descriptor overflow time=%0t",
                $time);
            if ((sending || launch_frame) && prefetch_count == 0) $display ("** Error: [GMIITX] %m read empty time=%0t",
                $time);
            if (prefetch_count > 4 || (return_valid && prefetch_count == 4 && ! pop_word)) $display ("** Error: [GMIITX] %m prefetch overflow time=%0t",
                $time);
        end
    end
`endif
endmodule
