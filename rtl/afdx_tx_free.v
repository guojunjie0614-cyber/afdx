// 本模块记录哪些发送缓存页还空着，并分配或收回这些页。
// afdx_tx_buf 申请页，发送完成或接收失败后由相应模块归还页。
// 本模块为赛题的发送缓存管理空间，避免两条消息使用同一页。
module afdx_tx_free #(
    parameter TX_PAGE_AW = 8) (

    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,

    // 所有空闲页号装入队列后，init_done 变高。
    output reg init_done,

    // pop_req 和 pop_ready 同为高时接收页申请。
    // pop_ack 为高时返回结果，pop_ok 为高才表示 pop_page 有效。
    input wire pop_req,
    output wire pop_ready,
    output reg pop_ack, pop_ok,
    output reg [7:0] pop_page,

    // ret1_* 接收组帧模块归还的页，ret2_* 接收消息缓冲归还的页。
    // 对应 valid 和 ready 同为高时，完成一个页号的归还。
    input wire ret1_valid,
    input wire [7:0] ret1_page,
    output wire ret1_ready,
    input wire ret2_valid,
    input wire [7:0] ret2_page,
    output wire ret2_ready);

    localparam [TX_PAGE_AW:0] PAGES = {1'b1, {TX_PAGE_AW{1'b0}}};

    // phase 的取值：取一个空闲页要经过的四步。
    localparam POP_IDLE = 0, POP_READ = 1, POP_CAPTURE = 2, POP_REPLY = 3;

    // rd_ptr/wr_ptr 指向空闲页号队列的读写位置。
    // init_ptr 用于初始化，count 表示目前可分配的页数。
    reg [TX_PAGE_AW - 1:0] rd_ptr, wr_ptr, init_ptr, ra, wa;
    reg [TX_PAGE_AW:0] count;
    reg we, re, init_flush;
    reg [7:0] wd, captured;
    wire [7:0] q;

    // POP_IDLE：接收申请，有空闲页转 POP_READ；队列为空时直接报告失败。
    // POP_READ：等待存储器读出，下一拍转 POP_CAPTURE。
    // POP_CAPTURE：保存读出的页号，下一拍转 POP_REPLY。
    // POP_REPLY：输出 pop_ack，下一拍转 POP_IDLE。
    reg [2:0] phase;

    // 每个归还口先保存一个页号，共用写口优先处理 ret1。
    reg ret1_pending, ret2_pending;
    reg [7:0] ret1_saved, ret2_saved;
    wire take = pop_req && pop_ready;
    wire put = (ret1_pending || ret2_pending) && count < PAGES;

    assign pop_ready = init_done && phase == POP_IDLE;
    assign ret1_ready = init_done && ! ret1_pending;
    assign ret2_ready = init_done && ! ret2_pending;
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_free (
        .clk(clk),
        .write_enable(we),
        .write_address(wa),
        .write_data(wd),
        .read_enable(re),
        .read_address(ra),
        .read_data(q)
    );

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
            phase <= POP_IDLE;
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
            // 初始化时逐拍写入所有页号，再等最后一次写入完成。
            if ( ! init_done) begin
                if ( ! init_flush) begin
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
                // 分配和归还同时完成时，空闲页数不变。
                // 两个归还口先各自保存页号，再依次写入空闲队列。
                case ({ put, take && count != 0 })
                    2'b10 : count <= count + 1'b1;
                    2'b01 : count <= count - 1'b1;
                    default : ;
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

                    POP_IDLE : if (take) begin
                        pop_ok <= count != 0;
                        if (count != 0) begin
                            re <= 1;
                            ra <= rd_ptr;
                            rd_ptr <= rd_ptr + 1'b1;
                            phase <= POP_READ;
                        end
                        else begin
                            pop_ack <= 1;
                            pop_page <= 0;
                        end
                    end

                    POP_READ : phase <= POP_CAPTURE;

                    POP_CAPTURE : begin
                        captured <= q;
                        phase <= POP_REPLY;
                    end

                    POP_REPLY : begin
                        pop_page <= captured;
                        pop_ack <= 1;
                        phase <= POP_IDLE;
                    end

                    default : phase <= POP_IDLE;
                endcase
            end
        end
    end

endmodule
