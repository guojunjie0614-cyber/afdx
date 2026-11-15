// 本模块接收应用消息，把消息分成若干页存入发送缓存。
// 页是发送缓存的分配单位，每页 2^TX_OFF_AW 字节，默认 512 字节。
// afdx_svc 提供字节，整条消息存好后通知 afdx_tx_engine 排队。
// 本模块实现发送侧消息缓存管理，接收失败时归还本条消息占用的页。
module afdx_tx_buf #(
    parameter TX_PAGE_AW = 8,
    TX_OFF_AW            = 9,
    EARLY_ENQUEUE        = 0
) (
    // init_done 为高时才允许接收新消息。
    input  wire                    clk, reset, init_done,

    // m_valid 和 m_ready 同为高时接收 m_data，m_last 标记末字节。
    // m_vl 是发送配置表的 7 位索引。
    input  wire                    m_valid,
    output wire                    m_ready,
    input  wire [7:0]              m_data,
    input  wire                    m_last,
    input  wire [6:0]              m_vl,

    // m_port_en 为高时使用本消息的端口，否则使用配置中的端口。
    input  wire                    m_port_en,
    input  wire [15:0]             m_sport, m_dport,

    // pop_* 申请一个空闲页，ret_* 归还接收失败的消息所占用的页。
    output reg                     pop_req,
    input  wire                    pop_ready, pop_ack, pop_ok,
    input  wire [7:0]              pop_page,
    output reg                     ret_valid,
    output reg  [7:0]              ret_page,
    input  wire                    ret_ready,

    // payload_* 写消息字节，pnext_* 保存同一消息的下一页。
    // desc_* 在首页对应位置保存消息长度和端口。
    output reg                     payload_we,
    output reg  [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_wa,
    output reg  [7:0]              payload_wd,
    output reg                     pnext_we,
    output reg  [TX_PAGE_AW - 1:0] pnext_wa,
    output reg  [7:0]              pnext_wd,
    output reg                     desc_we,
    output reg  [TX_PAGE_AW - 1:0] desc_wa,
    output reg  [46:0]             desc_wd,

    // 整条消息存好后，enq_* 请求加入发送队列。
    // enq_ack 为高时，enq_result 给出接纳或拒绝的原因。
    (* preserve = 1, dont_merge = 1, maxfan = 16 *)
    output reg                     enq_valid,
    output reg  [6:0]              enq_vl,
    output reg  [7:0]              enq_head,
    output reg  [13:0]             enq_len,
    input  wire                    enq_ack,
    input  wire [2:0]              enq_result,

    // ev_* 每次输出一个结果脉冲，表示接纳或本次拒绝原因。
    output reg                     ev_accept, ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage
);

    localparam [2:0] ENQ_ACCEPTED = 3'd0;
    localparam ENQ_DISABLED = 1;
    localparam ENQ_FULL = 2;
    localparam [2:0] ENQ_TOO_LONG = 3'd3;
    localparam [2:0] ENQ_NO_PAGE = 3'd4;

    // 单条数据报最大载荷字节数上限；入队后由发送引擎执行分片。
    localparam MAX_PAYLOAD = 8192;
    localparam MAX_PAGES = (MAX_PAYLOAD + (1 << TX_OFF_AW) - 1) >> TX_OFF_AW;
    localparam IDLE = 0, ALLOC = 1, WAIT_PAGE = 2, RECV = 3, DESC = 4,
        ENQUEUE = 5, REPLY = 6, RETURN = 7, DRAIN = 8, EVENT = 9;
    reg [3:0] state;
    // 从前一拍预告等待页状态，页号写使能和地址选择不再直接扇出独热态位。
    (* preserve = 1, dont_merge = 1 *) reg wait_page_q;

    // 回滚页表使用独立双端口同步 RAM：已受理的页分配写请求延迟一拍于本地提交，
    // 读回滚则采用显式应答相位，避免读写共用随状态切换的地址多路器。
    localparam PAGE_COUNT_W = TX_OFF_AW >= 13 ? 1 : 14 - TX_OFF_AW;
    reg [PAGE_COUNT_W-1:0] used, returned;
    wire [7:0] allocated_page_q;
    reg return_read_pending;
    wire return_read = state == RETURN && !ret_valid && !return_read_pending && returned < used;
    afdx_tx_rollback_ram #(.AW(PAGE_COUNT_W), .DEPTH(MAX_PAGES)) allocated_pages (
        .clk   (clk),
        .reset (reset),
        .we    (wait_page_q && pop_ack && pop_ok),
        .wa    (used),
        .wd    (pop_page),
        .re    (return_read),
        .ra    (returned),
        .q     (allocated_page_q)
    );
    reg [2:0] reason;

    // held_data/held_last 保存等待新页时的第一个字节。
    // boundary 表示上一页已满，ended 表示已收到消息末字节。
    reg [7:0] current_page, held_data;
    reg [TX_OFF_AW - 1:0] offset;
    reg boundary, ended, held_last, port_en;
    reg [15:0] sport, dport;

    // 输入先无条件寄存；地址、写使能和页首选择同步保存原拍信息。
    (* preserve = 1, dont_merge = 1 *) reg [7:0] m_data_q;
    (* preserve = 1, dont_merge = 1 *) reg held_capture_q, payload_wait_d;
    reg payload_we_d;
    reg [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_wa_d;
    // 页首缓存贯穿 WAIT_PAGE 及紧接的一拍保持不变，选择位必须随写口延迟。
    wire [7:0] payload_wd_d = payload_wait_d ? held_data : m_data_q;

    // init_q 是 init_done 的本地副本；远端 init_done 只进一次寄存器。
    (* preserve = 1, dont_merge = 1 *) reg init_q;
    // 入口两级实存储缓冲槽用于本地隔离服务仲裁的 valid/data；预留槽填满后即撤回
    // 上游信用，保证此前已输出的 ready 在页分配阻塞 RECV 时仍有实际容量承接。
    reg message_closed;
    // 对 init_q && !message_closed 做同拍边沿预测，由单个本地触发器驱动对外 ready，
    // 避免初始化与关闭标志的跨层组合逻辑链。
    (* preserve = 1, dont_merge = 1 *) reg ingress_open;
    wire input_valid, input_ready, ingress_ready;

    always @(posedge clk) begin
        if (reset) ingress_open <= 0;
        else ingress_open <= init_done && (state == EVENT ||
            (!message_closed && !(m_valid && m_ready && m_last)));
    end
`ifdef AFDX_CE_DIV
    always @(negedge clk)
        if (!reset && ingress_open !== (init_q && !message_closed))
            $fatal(1, "ingress ready qualification prediction differs");
`endif
    // 同消息内写入可领先队列分配推进，但新消息必须等前一条提交结果；
    // 严格在外部末字节握手受理拍置起关闭标志。
    always @(posedge clk) begin
        if (reset || state == EVENT) message_closed <= 0;
        else if (m_valid && m_ready && m_last) message_closed <= 1;
    end
    wire [7:0] input_data;
    wire input_last, input_port_en;
    wire [6:0] input_vl;
    wire [15:0] input_sport, input_dport;
    afdx_tx_ingress_elastic ingress (
        .clk     (clk),
        .reset   (reset),
        .s_valid (m_valid && ingress_open),
        .s_ready (ingress_ready),
        .s_word  ({m_data, m_last, m_vl, m_port_en, m_sport, m_dport}),
        .m_valid (input_valid),
        .m_ready (input_ready),
        .m_word  ({input_data, input_last, input_vl, input_port_en, input_sport, input_dport})
    );
    wire m_accept = input_valid && init_q;
    assign input_ready = init_q && (state == IDLE || state == RECV || state == DRAIN);
    assign m_ready = ingress_open && ingress_ready;

    // 预先判断已受理 RECV 字节长度是否达到上限，使 14 位全等比较脱离偏移、
    // 页分配、载荷写及拒绝路径的寄存器使能扇入逻辑。
    reg length_full;
    always @(posedge clk) begin
        if (reset || state == IDLE) length_full <= 0;
        else if (state == RECV && m_accept && !length_full)
            length_full <= enq_len == MAX_PAYLOAD - 1;
    end

    // 每条新报文在申请页面前都会先经过 IDLE，因此错误分支
    // 无需再次复位回滚读游标。
    always @(posedge clk) begin
        if (reset || state == IDLE) returned <= 0;
        else if (state == RETURN && ret_valid && ret_ready) returned <= returned + 1'b1;
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            wait_page_q <= 0;
            pop_req <= 0;
            enq_valid <= 0;
            payload_we <= 0;
            payload_we_d <= 0;
            pnext_we <= 0;
            desc_we <= 0;
            ret_valid <= 0;
            ret_page <= 0;
            payload_wa <= 0;
            payload_wd <= 0;
            payload_wa_d <= 0;
            payload_wait_d <= 0;
            m_data_q <= 0;
            held_capture_q <= 0;
            pnext_wa <= 0;
            pnext_wd <= 0;
            desc_wa <= 0;
            desc_wd <= 0;
            enq_vl <= 0;
            enq_head <= 0;
            enq_len <= 0;
            used <= 0;
            return_read_pending <= 0;
            reason <= ENQ_ACCEPTED;
            current_page <= 0;
            held_data <= 0;
            offset <= 0;
            boundary <= 0;
            ended <= 0;
            held_last <= 0;
            port_en <= 0;
            sport <= 0;
            dport <= 0;
            ev_accept <= 0;
            ev_drop_dis <= 0;
            ev_drop_full <= 0;
            ev_drop_long <= 0;
            ev_drop_nopage <= 0;
            init_q <= 0;
        end
        else begin
            init_q <= init_done;
            wait_page_q <= (state == ALLOC) || (state == WAIT_PAGE && !pop_ack);
            m_data_q <= input_data;
            held_capture_q <= state == IDLE || state == RECV;
            // 首字节和跨页字节晚一拍进入缓存；ALLOC 留出这一拍，进入 WAIT_PAGE 前已就绪。
            if (held_capture_q) held_data <= m_data_q;
            payload_wait_d <= wait_page_q;
            payload_wa_d <= wait_page_q
                ? {pop_page[TX_PAGE_AW - 1:0], {TX_OFF_AW{1'b0}}}
                : {current_page[TX_PAGE_AW - 1:0], offset};
            // 三个写口信号统一比原来晚一拍，末字节在 ENQUEUE 拍与描述符同时写入同步 RAM。
            // tx_core 的提前入队请求还须采样、读表后才可调度，故握手拍次不必改变。
            payload_we <= payload_we_d;
            payload_wa <= payload_wa_d;
            payload_wd <= payload_wd_d;
            return_read_pending <= return_read;
            if (state == RECV) begin
                held_last <= input_last;
            end
            payload_we_d <= 0;
            pnext_we <= 0;
            desc_we <= 0;
            ev_accept <= 0;
            ev_drop_dis <= 0;
            ev_drop_full <= 0;
            ev_drop_long <= 0;
            ev_drop_nopage <= 0;
            case (state)

                // IDLE：接收首字节，握手后转 ALLOC；数据经输入寄存器在下一拍存入缓存。
                // 空闲时预存首字节标志和端口；只有握手改变状态。
                IDLE: begin
                    enq_vl <= input_vl;
                    port_en <= input_port_en;
                    sport <= input_sport;
                    dport <= input_dport;
                    held_last <= input_last;
                    ended <= input_last;
                    enq_len <= 1;
                    used <= 0;
                    reason <= ENQ_ACCEPTED;
                    boundary <= 0;
                    if (m_accept) state <= ALLOC;
                end

                // ALLOC：发出页申请，下一拍转 WAIT_PAGE。
                ALLOC: begin
                    pop_req <= 1;
                    state <= WAIT_PAGE;
                end

                // WAIT_PAGE：取得页后写首字节，再转 RECV 或 DESC；无页转 RETURN。
                WAIT_PAGE: begin
                    if (pop_req && pop_ready) pop_req <= 0;
                    if (pop_ack) begin
                        if (!pop_ok) begin
                            reason <= ENQ_NO_PAGE;
                            state <= RETURN;
                        end
                        else begin
                            used <= used + 1'b1;
                            if (used == 0) enq_head <= pop_page;
                            else begin
                                pnext_we <= 1;
                                pnext_wa <= current_page;
                                pnext_wd <= pop_page;
                            end
                            current_page <= pop_page;
                            offset <= 1;
                            boundary <= 0;
                            payload_we_d <= 1;
                            state <= held_last ? DESC : RECV;
                        end
                    end
                end

                // RECV：存入字节，跨页转 ALLOC，末字节转 DESC，过长转 RETURN。
                RECV: if (m_accept) begin
                    ended <= input_last;
                    if (length_full) begin
                        reason <= ENQ_TOO_LONG;
                        state <= RETURN;
                    end
                    else begin
                        enq_len <= enq_len + 1'b1;
                        if (boundary) begin
                            state <= ALLOC;
                        end
                        else begin
                            payload_we_d <= 1;
                            offset <= offset + 1'b1;
                            if (&offset) boundary <= 1;
                            if (input_last) state <= DESC;
                        end
                    end
                end

                // DESC：保存消息长度和端口，下一拍转 ENQUEUE。
                DESC: begin
                    if (EARLY_ENQUEUE) enq_valid <= 1;
                    desc_we <= 1;
                    desc_wa <= enq_head;
                    desc_wd <= {enq_len, port_en, sport, dport};
                    state <= ENQUEUE;
                end

                // ENQUEUE：提交入队请求，下一拍转 REPLY。
                ENQUEUE: begin
                    enq_valid <= 1;
                    state <= REPLY;
                end

                // REPLY：等待调度结果，接纳转 EVENT，拒绝转 RETURN。
                REPLY: if (enq_ack) begin
                    enq_valid <= 0;
                    reason <= enq_result;
                    if (enq_result == ENQ_ACCEPTED) state <= EVENT;
                    else begin
                        state <= RETURN;
                    end
                end

                // RETURN：逐页归还空间，完成后按消息是否结束转 EVENT 或 DRAIN。
                RETURN: begin
                    // 先归还已经占用的页，再丢弃尚未接收完的字节。
                    // reason 保持第一次出现的错误原因。
                    if (return_read_pending) begin
                        ret_valid <= 1;
                        ret_page <= allocated_page_q;
                    end
                    if (ret_valid && ret_ready) begin
                        ret_valid <= 0;
                    end
                    if (returned == used) state <= ended ? EVENT : DRAIN;
                end

                // DRAIN：继续接收但不保存字节，收到末字节后转 EVENT。
                DRAIN: if (m_accept && input_last) state <= EVENT;

                // EVENT：输出一拍结果脉冲，下一拍转 IDLE。
                EVENT: begin
                    case (reason)
                        ENQ_ACCEPTED: ev_accept <= 1;
                        ENQ_DISABLED: ev_drop_dis <= 1;
                        ENQ_FULL: ev_drop_full <= 1;
                        ENQ_TOO_LONG: ev_drop_long <= 1;
                        ENQ_NO_PAGE: ev_drop_nopage <= 1;
                        default: ;
                    endcase
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

// 双槽弹性缓冲：已寄存的上游信用直接指代预留槽空余（非延迟后级就绪信号），
// 支持每拍全速同时写入读出；下游反压时，已接收但尚未下发的字节暂存于 skid_word 中。
module afdx_tx_ingress_elastic (
    input  wire        clk, reset, s_valid,
    output reg         s_ready,
    input  wire [48:0] s_word,
    output reg         m_valid,
    input  wire        m_ready,
    output reg  [48:0] m_word
);

    reg skid_valid;
    reg [48:0] skid_word;
    wire main_free = !m_valid || m_ready;
    wire take = s_valid && s_ready;

    always @(posedge clk) begin
        if (reset) begin
            s_ready <= 1;
            m_valid <= 0;
            skid_valid <= 0;
            m_word <= 0;
            skid_word <= 0;
        end else begin
            // 不变量 s_ready == !skid_valid 保证本式即为预留槽空余的精确次态，
            // 绝不虚报未落地的缓存容量。
            s_ready <= main_free || (!skid_valid && !s_valid);
            // 数据寄存器仅依赖本地归属权：空预留槽可自由预采样未握手字节，仅在
            // 实际受理时切换归属；已占用槽即使在转入主槽当拍也锁存原值，使远端
            // valid/使能条件只驱动两个状态令牌触发器，而不进入 49 位宽数据使能端。
            if (!skid_valid) skid_word <= s_word;
            if (main_free) begin
                m_valid <= skid_valid || take;
                m_word <= skid_valid ? skid_word : s_word;
                skid_valid <= 0;
            end else if (take) begin
                skid_valid <= 1;
            end
        end
    end
endmodule

// 将块 RAM 推断与写数据隔离保留在独立模块层次中，延续本工具链能完整保留
// 隔离输入 LUT 的存储器结构。
module afdx_tx_rollback_ram #(
    parameter AW = 5,
    DEPTH        = 16
) (
    input  wire          clk, reset, we,
    input  wire [AW-1:0] wa,
    input  wire [7:0]    wd,
    input  wire          re,
    input  wire [AW-1:0] ra,
    output reg  [7:0]    q
);

    (* preserve = 1, dont_merge = 1 *) reg write_command;
    (* preserve = 1, dont_merge = 1 *) reg [AW-1:0] write_address;
    (* preserve = 1, dont_merge = 1 *) reg [7:0] write_data;
    (* ramstyle = "M4K,no_rw_check" *) reg [7:0] memory[0:DEPTH-1];

    always @(posedge clk) begin
        if (reset) write_command <= 0;
        else write_command <= we;
        write_address <= wa;
        write_data <= wd;
    end

    always @(posedge clk)
        if (write_command)
            memory[write_address] <= write_command ? write_data : 8'b0;
    always @(posedge clk)
        if (re) q <= memory[ra];
endmodule
