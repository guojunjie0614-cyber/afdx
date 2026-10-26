// 本模块检查收到的以太网头、IPv4 头和 UDP 头，并暂存用户数据。
// afdx_mac_rx 提供帧内容和校验结果，完整帧的信息交给接收引擎。
// 本模块对应赛题的接收协议检查，检查失败时释放本帧暂占的空间。
module afdx_rx_parse #(
    parameter RX_RING_AW = 12, DESC_COPIES = 1) (

    // enable 为高时允许接收新帧，rx_valid 标记线路有数据。
    input wire clk, reset, enable, rx_valid,

    // f_end 有效时记录 now_c，作为比较两网到达时间的依据。
    input wire [15:0] now_c,

    // m_valid 为高时，m_data 是已去掉帧校验值的内容。
    // m_first 标记首字节，f_end 有效时 f_err/f_len 给出检查结果。
    input wire m_valid, m_first,
    input wire [7:0] m_data,
    input wire f_end,
    input wire [1:0] f_err,
    input wire [10:0] f_len,

    // read_ptr 指向已读完的位置，ring_* 暂存本帧用户数据。
    input wire [RX_RING_AW:0] read_ptr,
    output reg ring_we,
    output reg [RX_RING_AW - 1:0] ring_wa,
    output reg [7:0] ring_wd,

    // desc_valid 为高时提交完整帧信息，desc_take 表示引擎已取走。
    // resolve_valid 为高时，commit 决定保留还是释放本帧数据。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *) output reg [DESC_COPIES - 1:0] desc_valid,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *) output reg [RX_RING_AW + 82:0] desc_data,
    input wire desc_take,
    input wire resolve_valid, resolve_commit,

    // ev[0] 表示帧校验通过。
    // ev[1] 表示帧校验值错误。
    // ev[2] 表示长度或前导码错误。
    // ev[3] 表示协议头错误。
    // ev[7] 表示用户数据缓存已满。
    output reg [7:0] ev);

    localparam [RX_RING_AW:0] CAPACITY = {1'b1, {RX_RING_AW{1'b0}}};

    // 帧内字节位置，从目的以太网地址的首字节数起（首字节为 0）。
    localparam POS_VLID_LOW = 5, POS_ETHERTYPE_HIGH = 12, POS_ETHERTYPE_LOW = 13;
    localparam POS_IP_HEADER = 14, POS_IP_LENGTH_LOW = 17, POS_IP_FLAGS = 20, POS_IP_OFFSET_LOW = 21;
    localparam POS_IP_PROTOCOL = 23, POS_IP_ADDRESSES = 26, POS_IP_HEADER_END = 33;
    localparam POS_SPORT_LOW = 35, POS_DPORT_LOW = 37, POS_UDP_LENGTH_LOW = 39, POS_UDP_CHECK_LOW = 41;
    localparam POS_PAYLOAD = 42;

    // 协议头里固定的字节：目的地址首字节、IPv4 类型高字节、版本与头长、UDP 协议号。
    // IP_FRAGMENT_MASK 选出“还有分片”标志和分片偏移的高位，这些位必须为零。
    localparam DMAC_BYTE0 = 8'h03, ETHERTYPE_HIGH = 8'h08, IP_VERSION_IHL = 8'h45, IP_PROTOCOL_UDP = 8'h11;
    localparam IP_FRAGMENT_MASK = 8'h3f;

    // 各段长度：UDP 头 8 字节，IPv4 头 20 字节，用户数据之前共 42 字节。
    // 用户数据不足 17 字节时补到 17 字节，所以序号最早在第 59 字节，整帧最短 64 字节。
    // FRAME_OVERHEAD 是用户数据之外的字节数：42 字节协议头、1 字节序号、4 字节校验值。
    localparam UDP_HEADER_LENGTH = 16'd8, IP_HEADER_LENGTH = 16'd20, HEADER_LENGTH = 16'd42;
    localparam MIN_UDP_LENGTH = 9, MAX_UDP_LENGTH = 1479, MIN_PAYLOAD = 17;
    localparam MIN_SN_POSITION = 16'd59, MIN_FRAME_LENGTH = 16'd64, FRAME_OVERHEAD = 16'd47;

    // UDP 校验和从伪头里的协议号 17 开始累加；累加并处理进位后应为 CHECKSUM_GOOD。
    localparam UDP_SUM_SEED = 26'h0000011, CHECKSUM_GOOD = 16'hffff;

    // afdx_mac_rx 给出的 f_err 取值，以及本模块报告的事件位。
    localparam ERR_NONE = 0, ERR_FCS = 1, ERR_LENGTH = 2, ERR_PREAMBLE = 3;
    localparam EV_GOOD = 8'h01, EV_FCS = 8'h02, EV_LENGTH = 8'h04, EV_HEADER = 8'h08, EV_OVERFLOW = 8'h80;

    // length_phase 和 finish_phase 的取值。
    localparam LEN_WAIT = 0, LEN_SIZES = 1, LEN_LIMITS = 2;
    localparam [1:0] FIN_WAIT = 2'd0, FIN_SETTLE = 2'd1, FIN_REPORT = 2'd2;

    // committed 指向已接纳数据的末端，trial 指向本帧暂存位置。
    // frame_begin 记录本帧起点，失败时写位置退回这里。
    // desc_finish 保存等待引擎确认的帧末位置。
    reg [RX_RING_AW:0] committed, trial, frame_begin, desc_finish;
    wire [RX_RING_AW:0] occupied = committed - read_ptr;
    reg prev_line, allowed, overflow, header_bad, n_ok, has_payload;

    // position 从目的以太网地址的首字节开始计数。
    // 第 4–5 字节保存虚拟链路编号。
    // 第 14–33 字节是 IPv4 头。
    // 第 34–41 字节是 UDP 头。
    reg [10:0] position;
    // 随 position 的有效步进提前译码下一字节，停顿时一起保持。
    // 字段写使能只使用本地标志；首字节重置时二者均为假。
    (* preserve = 1, dont_merge = 1 *) reg at_udp_check_low, at_payload;
    // in_payload 等价于 n_ok && POS_PAYLOAD <= position < end_data，随 position 提前一拍登记：
    // 进入首个用户字节时取 n_ok（长度相在第 41 字节前已算完），之后到 last_data 为止保持。
    reg in_payload;
    reg [7:0] high_byte, sn;
    reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, ip_expected, end_data, sn_position, expected_len;
    reg [RX_RING_AW:0] space_limit;
    // 长度是否超过整环容量提前登记；占用量仍按首个用户字节提交拍的读指针判断。
    (* preserve = 1, dont_merge = 1 *) reg fits_q;
    reg [15:0] last_data;

    // IPv4 头校验和与 UDP 校验和分别累加。
    // 两次处理进位后，结果应为 0xffff。
    // UDP 校验和字段为零表示发送方没有计算，此时跳过这项检查。
    reg [19:0] ip_sum;
    reg [25:0] udp_sum;
    reg ip_add_valid, ip_seed;
    reg [15:0] ip_add_word;
    wire ip_checksum_good = (&ip_sum[15:4]) && ((ip_sum[3:0] ^ ip_sum[19:16]) == 4'hf);
    reg udp_add_valid, udp_seed;
    reg [15:0] udp_add_word;
    // low16 + high10 == 0xffff 等价于这组补码比较，无需串接两次进位相加。
    wire udp_checksum_good = (&udp_sum[15:10]) && ((udp_sum[9:0] ^ udp_sum[25:16]) == 10'h3ff);
    (* preserve = 1, dont_merge = 1 *) reg udp_bad_q;

    // LEN_WAIT：等到报文长度字段，收到后转 LEN_SIZES。
    // LEN_SIZES：计算用户数据和网络报文长度，然后转 LEN_LIMITS。
    // LEN_LIMITS：计算序号位置与所需缓存空间，并登记容量比较，然后转 LEN_WAIT。
    reg [2:0] length_phase;

    // FIN_WAIT：等待帧结束，收到后转 FIN_SETTLE。
    // FIN_SETTLE：合并已寄存的 UDP 校验结论，然后转 FIN_REPORT。
    // FIN_REPORT：报告错误或提交完整帧信息，然后转 FIN_WAIT。
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [1:0] finish_phase, err_saved;
    reg end_bad, end_overflow, end_alloc;
    reg [RX_RING_AW + 82:0] end_desc;

    // 先登记本拍校验字，再累加；帧尾检查直接使用累加值的补码关系。
    // 字段检查先寄存成单比特结论，header_bad 只粘滞合并已寄存的值；
    // 受检位置都在帧头前段，合并结果远早于帧尾读取。
    reg header_byte_bad;
    always @(posedge clk) begin
        if (reset) header_byte_bad <= 0;
        else if (m_valid && allowed && ! m_first) begin
            case (position)
                1, 2, 3, POS_ETHERTYPE_LOW, POS_IP_OFFSET_LOW : header_byte_bad <= m_data != 0;
                POS_ETHERTYPE_HIGH : header_byte_bad <= m_data != ETHERTYPE_HIGH;
                POS_IP_HEADER : header_byte_bad <= m_data != IP_VERSION_IHL;
                POS_IP_FLAGS : header_byte_bad <= (m_data & IP_FRAGMENT_MASK) != 0;
                POS_IP_PROTOCOL : header_byte_bad <= m_data != IP_PROTOCOL_UDP;
                default : header_byte_bad <= 0;
            endcase
        end
        else header_byte_bad <= 0;
    end
    always @(posedge clk) begin
        if (reset) header_bad <= 0;
        else if (m_valid && allowed) begin
            if (m_first) header_bad <= m_data != DMAC_BYTE0;
            else header_bad <= header_bad || header_byte_bad;
        end
    end

    always @(posedge clk) begin
        if (reset) ip_sum <= 0;
        else if (ip_add_valid) begin
            if (ip_seed) ip_sum <= 0;
            else ip_sum <= ip_sum + ip_add_word;
        end
    end

    always @(posedge clk) begin
        if (reset) udp_sum <= 0;
        else if (udp_add_valid) begin
            if (udp_seed) udp_sum <= UDP_SUM_SEED;
            else udp_sum <= udp_sum + udp_add_word;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            committed <= 0;
            trial <= 0;
            frame_begin <= 0;
            desc_finish <= 0;
            prev_line <= rx_valid;
            allowed <= 0;
            ring_we <= 0;
            ring_wa <= 0;
            ring_wd <= 0;
            desc_valid <= 0;
            desc_data <= 0;
            ev <= 0;
            position <= 0;
            at_udp_check_low <= 0;
            at_payload <= 0;
            in_payload <= 0;
            high_byte <= 0;
            sn <= 0;
            vlid <= 0;
            sport <= 0;
            dport <= 0;
            ip_len <= 0;
            udp_len <= 0;
            udp_check <= 0;
            n <= 0;
            n_ok <= 0;
            ip_expected <= 0;
            end_data <= 0;
            last_data <= 0;
            sn_position <= 0;
            expected_len <= 0;
            space_limit <= 0;
            fits_q <= 0;
            overflow <= 0;
            has_payload <= 0;
            ip_add_valid <= 0;
            ip_seed <= 0;
            ip_add_word <= 0;
            udp_add_valid <= 0;
            udp_seed <= 0;
            udp_add_word <= 0;
            udp_bad_q <= 0;
            length_phase <= LEN_WAIT;
            finish_phase <= FIN_WAIT;
            err_saved <= 0;
            end_bad <= 0;
            end_overflow <= 0;
            end_alloc <= 0;
            end_desc <= 0;
        end
        else begin
            ring_we <= 0;
            ip_add_valid <= 0;
            ip_seed <= 0;
            udp_add_valid <= 0;
            udp_seed <= 0;
            ev <= 0;
            prev_line <= rx_valid;
            if (rx_valid && ! prev_line) begin
                allowed <= enable;
                has_payload <= 0;
            end
            if ( ! enable) allowed <= 0;
            if (desc_take) desc_valid <= 0;
            // 只有引擎决定接纳本帧后，才更新有效数据的末端指针。
            if (resolve_valid) begin
                if (resolve_commit) committed <= desc_finish;
                else trial <= committed;
            end
            case (length_phase)
                LEN_SIZES : begin
                    n <= udp_len - UDP_HEADER_LENGTH;
                    n_ok <= udp_len >= MIN_UDP_LENGTH && udp_len <= MAX_UDP_LENGTH;
                    ip_expected <= udp_len + IP_HEADER_LENGTH;
                    begin udp_add_valid <= 1; udp_add_word <= udp_len; end
                    length_phase <= LEN_LIMITS;
                end
                LEN_LIMITS : begin
                    end_data <= n + HEADER_LENGTH;
                    last_data <= n + HEADER_LENGTH - 16'd1;
                    sn_position <= n < MIN_PAYLOAD ? MIN_SN_POSITION : n + HEADER_LENGTH;
                    expected_len <= n < MIN_PAYLOAD ? MIN_FRAME_LENGTH : n + FRAME_OVERHEAD;
                    space_limit <= CAPACITY - n;
                    fits_q <= n <= CAPACITY;
                    length_phase <= LEN_WAIT;
                end
                default : ;
            endcase
            // 本模块只接受不带选项的 20 字节 IPv4 头和未分片的 UDP 报文。
            // 一字节序号位于帧的最后（补零之后），不计入 UDP 长度。
            if (m_valid && allowed) begin
                if (m_first) begin
                    position <= 1;
                    at_udp_check_low <= 0;
                    at_payload <= 0;
                    in_payload <= 0;
                    high_byte <= m_data;
                    overflow <= 0;
                    begin ip_add_valid <= 1; ip_seed <= 1; ip_add_word <= 0; end
                    begin udp_add_valid <= 1; udp_seed <= 1; udp_add_word <= 0; end
                    n_ok <= 0;
                    fits_q <= 0;
                    length_phase <= LEN_WAIT;
                    vlid <= 0;
                    sport <= 0;
                    dport <= 0;
                    ip_len <= 0;
                    udp_len <= 0;
                    udp_check <= 0;
                    sn <= 0;
                end
                else begin
                    position <= position + 1'b1;
                    at_udp_check_low <= position == POS_UDP_CHECK_LOW - 1;
                    at_payload <= position == POS_PAYLOAD - 1;
                    in_payload <= position == POS_PAYLOAD - 1 ? n_ok : in_payload && position != last_data;
                    // 环写口的数据和地址随字节自由运行，只在 ring_we 提交拍生效；
                    // 位置比较不再进入写数据与写地址的使能锥。
                    ring_wd <= m_data;
                    ring_wa <= has_payload ? trial[RX_RING_AW - 1:0] : committed[RX_RING_AW - 1:0];
                    if ( ! position[0]) high_byte <= m_data;
                    if (at_udp_check_low) udp_check <= { high_byte, m_data };
                    // at_payload 等价于 position==42，范围判断可直接比较常数，
                    // 不再让外层 position 范围译码进入 frame_begin 的使能。
                    if (at_payload && n_ok && HEADER_LENGTH < end_data) frame_begin <= committed;
                    case (position)
                        // 目的地址的第 1–3 字节和类型字段的低字节必须为零。






                        POS_VLID_LOW : vlid <= { high_byte, m_data };
                        POS_IP_LENGTH_LOW : ip_len <= { high_byte, m_data };
                        POS_SPORT_LOW : sport <= { high_byte, m_data };
                        POS_DPORT_LOW : dport <= { high_byte, m_data };
                        POS_UDP_LENGTH_LOW : begin
                            udp_len <= { high_byte, m_data };
                            length_phase <= LEN_SIZES;
                        end
                        default : ;
                    endcase
                    if (position >= POS_IP_HEADER && position <= POS_IP_HEADER_END && position[0])
                        begin ip_add_valid <= 1; ip_add_word <= { high_byte, m_data }; end
                    if (position >= POS_IP_ADDRESSES && position <= POS_UDP_CHECK_LOW && position[0])
                        begin udp_add_valid <= 1; udp_add_word <= { high_byte, m_data }; end
                    if (in_payload) begin
                        if (position[0]) begin udp_add_valid <= 1; udp_add_word <= { high_byte, m_data }; end
                        else if (position == last_data) begin udp_add_valid <= 1; udp_add_word <= { m_data, 8'b0 }; end
                        if (position == POS_PAYLOAD) begin
                            // 容量比较已在前一相登记；本拍新释放的空间仍立即参与接纳判断。
                            has_payload <= 1;
                            overflow <= !fits_q || occupied > space_limit;
                            if (fits_q && occupied <= space_limit) begin
                                ring_we <= 1;
                                trial <= committed + 1'b1;
                            end
                        end
                        else if ( ! overflow) begin
                            ring_we <= 1;
                            trial <= trial + 1'b1;
                        end
                    end
                    if (n_ok && position == sn_position) sn <= m_data;
                end
            end
            // 帧信息包含虚拟链路编号和序号。
            // 源端口和目的端口随帧信息一起交给接收引擎。
            // 帧信息还包含用户数据长度、缓存起点和到达时间。
            if (f_end && allowed) begin
                err_saved <= f_err;
                end_overflow <= overflow;
                end_alloc <= has_payload;
                end_bad <= header_bad || ! n_ok || !ip_checksum_good || ip_len != ip_expected
                    || f_len != expected_len;
                // 有效长度帧的末次 UDP 累加在序号拍完成，f_end 拍的 udp_sum 已稳定。
                // 截短帧即使还有待累加字，也已被上述长度检查拒绝，不影响报告拍次。
                udp_bad_q <= udp_check != 0 && !udp_checksum_good;
                end_desc <= { vlid, sn, sport, dport, n[10:0], frame_begin[RX_RING_AW - 1:0], now_c };
                desc_finish <= trial;
                finish_phase <= FIN_SETTLE;
            end
            else if (finish_phase != FIN_WAIT) begin
                finish_phase <= finish_phase + 1'b1;
                // 校验结论提前一拍登记，报告与描述符提交仍保持原来的相位。
                if (finish_phase == FIN_SETTLE && udp_bad_q) end_bad <= 1;
                if (finish_phase == FIN_REPORT) begin
                    finish_phase <= FIN_WAIT;
                    if (err_saved == ERR_FCS) ev <= EV_FCS;
                    else if (err_saved == ERR_LENGTH || err_saved == ERR_PREAMBLE) ev <= EV_LENGTH;
                    else if (end_bad) ev <= EV_HEADER;
                    else if (end_overflow) ev <= EV_OVERFLOW;
                    else begin
                        ev <= EV_GOOD;
                        desc_valid <= {DESC_COPIES{1'b1}};
                        desc_data <= end_desc;
                    end
                    // 坏帧在这里释放暂占空间。
                    // 没有用户数据的前导码错误，不影响尚待判定的完整帧。
                    if ((err_saved != ERR_NONE || end_bad || end_overflow) && end_alloc) trial <= frame_begin;
                end
            end
        end
    end

endmodule
