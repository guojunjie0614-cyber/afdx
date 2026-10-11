// 将核心慢线字节转成帧内连续valid的GMII输出。
// 输入核心的慢线data/valid；输出每拍一字节的GMII帧。
// 固定起始偏移D=10688拍；数据RAM、描述队列和预取队列独立推进。
// 慢线每八拍一字节，GMII 每拍一字节；每帧 SOF 保持相同的固定延迟。
module afdx_gmii_tx (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // slow_data/valid 为每八拍一字节的慢线输入，帧内 valid 连续；本适配器不接入当前原生 GMII 顶层。
    input wire [7:0] slow_data,
    input wire slow_valid,
    // tx_data/valid 为每拍一字节的 GMII 输出，起帧相对输入延迟固定。
    output reg [7:0] tx_data,
    output reg tx_valid);
    // 保留前一字节以便写入 last：最坏可用时间 S+8*k+13。
    // ceil64(7*1525+13)=10688；G2 的变异入口是此常量。
    localparam TX_DELAY = 10688;
    localparam DATA_AW = 11, DATA_DEPTH = 2048, DUE_DEPTH = 16;
    // clock_count 给每帧生成发送截止点；input_active/byte_phase 捕获慢线字节并给尾字节加 last。
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
    // 字节环同时区分已写、已发读请求和已释放位置，避免预取阶段重复计入空闲空间。
    reg [DATA_AW:0] write_ptr, read_issue_ptr, read_release_ptr;
    wire [DATA_AW:0] occupied = write_ptr - read_release_ptr;
    afdx_ram_sdp #(.WIDTH(9), .DEPTH(DATA_DEPTH)) bytes_ram (clk, data_we, data_wa, data_wd, data_re, data_ra, data_q);
    // 最多16个尚未开始输出的帧；开始时出队，输出中的帧由 sending 独立保存。
    reg due_we, due_re;
    reg [3:0] due_wa, due_ra, due_write_ptr, due_read_ptr;
    reg [31:0] due_wd;
    wire [31:0] due_q;
    reg [4:0] due_count;
    // due_phase=0 发队头读请求，1 等 RAM，2 锁存 head_due 后回 0；到期且未发送时 launch_frame。
    reg [1:0] due_phase;
    reg head_valid;
    reg [31:0] head_due;
    reg sending;
    wire launch_frame = head_valid && ! sending && clock_count == head_due;
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(DUE_DEPTH)) due_ram (clk, due_we, due_wa, due_wd, due_re, due_ra, due_q);
    // 四项寄存器预取队列，保留跨帧预取的数据，不另推断 RAM。
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
            // 输入缓存与定时描述：新帧登记截止点，上一字节延迟保存以识别真实帧尾。
            if (frame_start) begin
                input_active <= 1;
                byte_phase <= 0;
                held_byte <= slow_data;
                due_we <= 1;
                due_wa <= due_write_ptr;
                // 本沿装输出寄存器，端口在下一可观察周期 S+D 开始有效。
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
            // 写指针提前一拍公布，但本拍装读口后再过一拍才读 RAM，避免同拍同址。
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
            // 发送阶段：launch_frame 启动，sending 持续逐拍输出，取到 last 后停止。
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
