// 管理发送载荷页的空闲链表和回收流程。
// 分配端取得空闲页；回收端归还已发送或撤销消息的页链。
// 链表RAM访问分拍执行，计数与头尾更新跟随真实分配/回收。
// 空闲页 FIFO：装表、同步取页、返回。两个返回同时到时优先 builder。
module afdx_tx_free #(
    parameter TX_PAGE_AW = 8) (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // init_done 表示全部页号已写入空闲 FIFO。
    output reg init_done,
    // pop_req/pop_ready 接受分配请求；pop_ack 返回结果，pop_ok=1 时 pop_page 有效。
    input wire pop_req,
    output wire pop_ready,
    output reg pop_ack, pop_ok,
    output reg [7:0] pop_page,
    // ret1_* 接收组帧器归还的页；ret2_* 接收消息缓冲回滚的页，均以 valid/ready 握手。
    input wire ret1_valid,
    input wire [7:0] ret1_page,
    output wire ret1_ready,
    input wire ret2_valid,
    input wire [7:0] ret2_page,
    output wire ret2_ready);
    localparam PAGES = (1 << TX_PAGE_AW);
    // rd_ptr/wr_ptr 管理空闲页号队列，init_ptr 逐项装入；count 为可分配页数。
    reg [TX_PAGE_AW - 1:0] rd_ptr, wr_ptr, init_ptr, ra, wa;
    reg [TX_PAGE_AW:0] count;
    reg we, re, init_flush;
    reg [7:0] wd, captured;
    wire [7:0] q;
    // phase=0 接受请求；1 等同步读；2 锁存页号；3 发 pop_ack 后回 0；空队列在 0 直接回失败。
    reg [2:0] phase;
    // 每个返回口一项输入寄存器；唯一 RAM 写口始终先处理口 1。
    reg ret1_pending, ret2_pending;
    reg [7:0] ret1_saved, ret2_saved;
    wire take = pop_req && pop_ready;
    wire put = (ret1_pending || ret2_pending) && count < PAGES;
    assign pop_ready = init_done && phase == 0;
    assign ret1_ready = init_done && ! ret1_pending;
    assign ret2_ready = init_done && ! ret2_pending;
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_free (clk, we, wa, wd, re, ra, q);
    always @(posedge clk) begin
        if (reset) begin
            init_done <= 0;
            init_ptr <= 0;
            init_flush <= 0;
            rd_ptr <= 0;
            wr_ptr <= 0;
            count <= 0;
            we <= 0;
            re <= 0;
            wa <= 0;
            ra <= 0;
            wd <= 0;
            phase <= 0;
            pop_ack <= 0;
            pop_ok <= 0;
            pop_page <= 0;
            captured <= 0;
            ret1_pending <= 0;
            ret2_pending <= 0;
            ret1_saved <= 0;
            ret2_saved <= 0;
        end
        else begin
            we <= 0;
            re <= 0;
            pop_ack <= 0;
            // 初始化逐拍写入全部页号，init_flush 等最后一次 RAM 写入生效。
            if (! init_done) begin
                if (! init_flush) begin
                    we <= 1;
                    wa <= init_ptr;
                    wd <= init_ptr;
                    init_ptr <= init_ptr + 1'b1;
                    if (init_ptr == PAGES - 1) init_flush <= 1;
                end
                else begin
                    init_done <= 1;
                    count <= PAGES;
                end
            end
            else begin
                if (ret1_valid && ret1_ready) begin
                    ret1_pending <= 1;
                    ret1_saved <= ret1_page;
                end
                if (ret2_valid && ret2_ready) begin
                    ret2_pending <= 1;
                    ret2_saved <= ret2_page;
                end
                // 分配和归还同时发生时项数不变；两个归还口先各自暂存，再共用 RAM 写口。
                case ({ put, take && count != 0 })
                    2'b10 : count <= count + 1'b1;
                    2'b01 : count <= count - 1'b1;
                    default :;
                endcase
                if (put) begin
                    we <= 1;
                    wa <= wr_ptr;
                    wd <= ret1_pending ? ret1_saved : ret2_saved;
                    if (ret1_pending) ret1_pending <= 0;
                    else ret2_pending <= 0;
                    wr_ptr <= wr_ptr + 1'b1;
                end
                case (phase)
                    0 : if (take) begin
                        pop_ok <= count != 0;
                        if (count != 0) begin
                            re <= 1;
                            ra <= rd_ptr;
                            rd_ptr <= rd_ptr + 1'b1;
                            phase <= 1;
                        end
                        else begin
                            pop_ack <= 1;
                            pop_page <= 0;
                        end
                    end
                    1 : phase <= 2;
                    2 : begin
                        captured <= q;
                        phase <= 3;
                    end
                    3 : begin
                        pop_page <= captured;
                        pop_ack <= 1;
                        phase <= 0;
                    end
                    default : phase <= 0;
                endcase
            end
        end
    end
endmodule
