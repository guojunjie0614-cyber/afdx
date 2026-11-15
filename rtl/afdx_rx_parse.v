// 接收协议解析模块：逐字节校验以太网、IPv4 与 UDP 首部及校验和，并将有效载荷写入接收环形缓存。
// 接收 afdx_mac_rx 去 FCS 后的字节流与帧尾检查状态，校验通过后向接收引擎提交帧描述符；
// 若校验出错或缓存溢出，则在帧尾自动回退试探写指针以释放本帧暂占空间。
module afdx_rx_parse #(
    parameter RX_RING_AW = 12,
    DESC_COPIES          = 1
) (
    // enable 为高时允许接收新帧；rx_valid 指示线路字节流有效。
    input  wire                      clk, reset, enable, rx_valid,

    // f_end 有效时采存 now_c，作为双网到达时间差比对的时间戳。
    input  wire [15:0]               now_c,

    // m_valid 为高时，m_data 为剥离 FCS 后的帧内容；
    // m_first 标记首字节，f_end 有效时 f_err 与 f_len 给出 MAC 检查结果。
    input  wire                      m_valid, m_first,
    input  wire [7:0]                m_data,
    input  wire                      f_end,
    input  wire [1:0]                f_err,
    input  wire [10:0]               f_len,

    // read_ptr 指向下游已读位置，ring_* 接口将用户载荷写入环形缓存。
    input  wire [RX_RING_AW:0]       read_ptr,
    output reg                       ring_we,
    output reg  [RX_RING_AW - 1:0]   ring_wa,
    output reg  [7:0]                ring_wd,

    // desc_valid 拉高提交完整帧描述符，desc_take 表示引擎已取走；
    // resolve_valid 为高时，resolve_commit 决定保留还是回退释放本帧载荷。
    (* preserve = 1, dont_merge = 1, maxfan = 32 *)
    output reg  [DESC_COPIES - 1:0]  desc_valid,
    (* preserve = 1, dont_merge = 1, maxfan = 16 *)
    output reg  [RX_RING_AW + 208:0] desc_data,
    input  wire                      desc_take,
    input  wire                      resolve_valid, resolve_commit,

    // 解析事件位定义：
    //   ev[0]：帧校验通过
    //   ev[1]：FCS 校验错误
    //   ev[2]：帧长或前导码错误
    //   ev[3]：协议首部或校验和错误
    //   ev[7]：用户数据缓存溢出
    output reg  [7:0]                ev
);

    // ModelSim 要求信号先声明后引用；综合分支保持原声明位置以固定网表与布局锚点。
`ifdef MODEL_TECH
    reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, ip_expected, end_data, sn_position, expected_len;
`endif

    localparam [RX_RING_AW:0] CAPACITY = {1'b1, {RX_RING_AW{1'b0}}};

    // 帧内字节偏移索引（从目的 MAC 地址首字节 0 起算）。
    localparam POS_VLID_LOW = 5, POS_ETHERTYPE_HIGH = 12, POS_ETHERTYPE_LOW = 13;
    localparam POS_IP_HEADER = 14, POS_IP_LENGTH_LOW = 17, POS_IP_FLAGS = 20, POS_IP_OFFSET_LOW = 21;
    localparam POS_IP_PROTOCOL = 23, POS_IP_ADDRESSES = 26, POS_IP_HEADER_END = 33;
    localparam POS_SPORT_LOW = 35, POS_DPORT_LOW = 37, POS_UDP_LENGTH_LOW = 39, POS_UDP_CHECK_LOW = 41;
    localparam POS_PAYLOAD = 42;

    // 协议首部固定字段常量：目的 MAC 首字节、IPv4 以太网类型高字节、版本与头长、UDP 协议号；
    // IP_FRAGMENT_MASK 为分片标志与分片偏移高位的掩码。
    localparam DMAC_BYTE0 = 8'h03, ETHERTYPE_HIGH = 8'h08, IP_VERSION_IHL = 8'h45, IP_PROTOCOL_UDP = 8'h11;
    localparam IP_FRAGMENT_MASK = 8'h3f;

    // 各段固定长度：UDP 首部 8 字节、IPv4 首部 20 字节、以太网至 UDP 净荷前共 42 字节；
    // 非分片短帧净荷不足 17 字节时补零至 17 字节，故 1 字节序号最早位于偏移 59，整帧最短 64 字节；
    // FRAME_OVERHEAD 为净荷之外开销（42 字节协议首部 + 1 字节序号 + 4 字节 FCS）。
    localparam UDP_HEADER_LENGTH = 16'd8, IP_HEADER_LENGTH = 16'd20, HEADER_LENGTH = 16'd42;
    localparam MIN_UDP_LENGTH = 9, MAX_UDP_LENGTH = 1479, MIN_PAYLOAD = 17;
    localparam MIN_SN_POSITION = 16'd59, MIN_FRAME_LENGTH = 16'd64, FRAME_OVERHEAD = 16'd47;

    // UDP 校验和从伪首部协议号 17（0x11）起步累加，折叠进位后应等于 CHECKSUM_GOOD（0xffff）。
    localparam UDP_SUM_SEED = 26'h0000011, CHECKSUM_GOOD = 16'hffff;

    // afdx_mac_rx 上报的 f_err 错误码及本模块事件位编码。
    localparam ERR_NONE = 0, ERR_FCS = 1, ERR_LENGTH = 2, ERR_PREAMBLE = 3;
    localparam EV_GOOD = 8'h01, EV_FCS = 8'h02, EV_LENGTH = 8'h04, EV_HEADER = 8'h08, EV_OVERFLOW = 8'h80;

    // 长度计算阶段（length_phase）与帧尾收尾阶段（finish_phase）状态编码。
    localparam LEN_WAIT = 0, LEN_SIZES = 1, LEN_LIMITS = 2;
    localparam [1:0] FIN_WAIT = 2'd0, FIN_SETTLE = 2'd1, FIN_REPORT = 2'd2;

    // committed 指向已接纳数据末端，trial 为当前帧试探写指针；
    // frame_begin 记录本帧起始位置以便失败回退，desc_finish 保存待引擎确认的帧尾指针。
    reg [RX_RING_AW:0] committed, trial, frame_begin, desc_finish;
    wire [RX_RING_AW:0] occupied = committed - read_ptr;
    reg prev_line, allowed, overflow, header_bad, n_ok, has_payload;

    // position 从目的 MAC 首字节起计：字节 4～5 为 VL 编号，字节 14～33 为 IPv4 首部，字节 34～41 为 UDP 首部。
    reg [10:0] position;
    // 随 position 有效步进提前一拍译码关键偏移标志，停顿时保持不变；
    // 字段写使能仅依赖本地标志，首字节到来时同步复位。
    (* preserve = 1, dont_merge = 1 *) reg at_udp_check_low, at_payload;
    (* preserve = 1, dont_merge = 1 *) reg at_ip_offset_low, at_udp_length_low;
    // in_payload 等价于 n_ok && 净荷起始偏移 <= position < end_data，提前一拍随 position 寄存：
    // 进入首个用户字节时采样 n_ok（长度参数已于第 41 字节前算完），随后保持至末字节 last_data。
    reg in_payload;
    reg [7:0] high_byte, sn;
    reg [15:0] ip_id, frag_word;
    reg [31:0] ip_src, ip_dst;
    (* preserve = 1, dont_merge = 1 *) reg frame_fragmented, frame_later;
    wire fragmented = frame_fragmented;
    wire later_fragment = frame_later;
    wire [15:0] ip_data_len = ip_len - 16'd20;
`ifndef MODEL_TECH
    reg [15:0] vlid, sport, dport, ip_len, udp_len, udp_check, n, ip_expected, end_data, sn_position, expected_len;
`endif
    // 在末级范围校验与选择前，先将分片与非分片两种长度表示归一化。
    reg [15:0] data_end_q, wire_length_q;
    reg pad_sn_q, pad_wire_q;
    reg [RX_RING_AW:0] space_limit;
    wire [(RX_RING_AW > 15 ? RX_RING_AW : 15):0] space_limit_value = CAPACITY - n;
    // 长度是否超出环形缓存总容量提前寄存判断；实际剩余空间仍于首个净荷字节提交拍结合读指针判别。
    (* preserve = 1, dont_merge = 1 *) reg fits_q;
    reg [15:0] last_data;

    // IPv4 首部校验和与 UDP 校验和分别累加，折叠进位后应为 0xffff；
    // UDP 校验和字段为 0 表示发送端未启用，跳过该项校验。
    reg [19:0] ip_sum;
    reg [25:0] udp_sum;
    reg ip_add_valid, ip_seed;
    reg [15:0] ip_add_word;
    wire ip_checksum_good = (&ip_sum[15:4]) && ((ip_sum[3:0] ^ ip_sum[19:16]) == 4'hf);
    reg udp_add_valid, udp_seed;
    reg [15:0] udp_add_word;
    // 低 16 位与高 10 位相加等于 0xffff 等价于上述补码位匹配关系，无需串接两次进位加法。
    wire udp_checksum_good = (&udp_sum[15:10]) && ((udp_sum[9:0] ^ udp_sum[25:16]) == 10'h3ff);
    (* preserve = 1, dont_merge = 1 *) reg udp_bad_q;

    // length_phase 状态说明：
    //   LEN_WAIT   ：等待长度字段就绪后转入 LEN_SIZES
    //   LEN_SIZES  ：计算用户净荷与整帧长度，随后转入 LEN_LIMITS
    //   LEN_LIMITS ：计算序号偏移、缓存占用上限并寄存容量比较，随后返回 LEN_WAIT
    reg [2:0] length_phase;

    // finish_phase 状态说明：
    //   FIN_WAIT   ：等待帧结束沿，收到后转入 FIN_SETTLE
    //   FIN_SETTLE ：合入已寄存的 UDP 校验和结论，随后转入 FIN_REPORT
    //   FIN_REPORT ：上报事件或提交完整描述符，随后返回 FIN_WAIT
    (* preserve = 1, dont_merge = 1, maxfan = 8 *) reg [1:0] finish_phase, err_saved;
    reg end_bad, end_overflow, end_alloc;
    reg [RX_RING_AW + 208:0] end_desc;
    reg [15:0] ip_data_length_q;
    reg [16:0] fragment_end_q;
    reg fragment_geometry_bad, ip_length_matches;
    (* preserve=1, dont_merge=1 *) reg [15:0] arrival_snapshot;
    // 帧长与分片边界参数在末段序号及 FCS 到达前早已稳定，将加减与比较拆至前拍寄存，避免挤入帧尾使能路径。
    always @(posedge clk) begin
        arrival_snapshot <= now_c;
        ip_data_length_q <= ip_len - 16'd20;
        fragment_end_q <= {1'b0, frag_word[12:0], 3'b0} + {1'b0, ip_data_length_q};
        ip_length_matches <= ip_len == ip_expected;
        fragment_geometry_bad <= frag_word[14] || (frag_word[13] && ip_data_length_q[2:0] != 0)
            || fragment_end_q > 17'd8200
            || (!later_fragment && (udp_len < 9 || udp_len > 8200 || udp_len < ip_data_length_q));
    end

    // FIN_SETTLE 拍为每个有效标志副本及每组 24 比特数据分别寄存发布指令，
    // FIN_REPORT 拍对外维持与原设计完全一致的报告沿。
    localparam DESC_WIDTH = RX_RING_AW + 209, DATA_GROUPS = (DESC_WIDTH + 23) / 24;
    wire publish_next = finish_phase == FIN_SETTLE && !(f_end && allowed)
        && err_saved == ERR_NONE && !end_bad && !udp_bad_q && !end_overflow;
    genvar publish_copy, data_group;
    generate
        for (publish_copy = 0; publish_copy < DESC_COPIES; publish_copy = publish_copy + 1) begin : valid_publish
            (* preserve=1, dont_merge=1 *) reg command;
            always @(posedge clk) begin
                if (reset) begin
                    command <= 0;
                    desc_valid[publish_copy] <= 0;
                end
                else begin
                    command <= publish_next;
                    if (command && !(f_end && allowed)) desc_valid[publish_copy] <= 1;
                    else if (desc_take) desc_valid[publish_copy] <= 0;
                end
            end
        end
        for (data_group = 0; data_group < DATA_GROUPS; data_group = data_group + 1) begin : data_publish
            localparam GROUP_WIDTH = DESC_WIDTH - data_group * 24 >= 24 ? 24 : DESC_WIDTH - data_group * 24;
            (* preserve=1, dont_merge=1 *) reg command;
            always @(posedge clk) begin
                if (reset) begin
                    command <= 0;
                    desc_data[data_group*24+:GROUP_WIDTH] <= 0;
                end
                else begin
                    command <= publish_next;
                    if (command && !(f_end && allowed))
                        desc_data[data_group*24+:GROUP_WIDTH] <= end_desc[data_group*24+:GROUP_WIDTH];
                end
            end
        end
    endgenerate

    // 校验字先寄存再累加，帧尾直接依据补码关系判定；
    // 固定首部字节检查先寄存为单比特结果，header_bad 仅作保持置位合并，结论远早于帧尾读取。
    reg header_byte_bad;
    always @(posedge clk) begin
        if (reset) header_byte_bad <= 0;
        else if (m_valid && allowed && !m_first) begin
            case (position)
                1, 2, 3, POS_ETHERTYPE_LOW : header_byte_bad <= m_data != 0;
                POS_ETHERTYPE_HIGH : header_byte_bad <= m_data != ETHERTYPE_HIGH;
                POS_IP_HEADER : header_byte_bad <= m_data != IP_VERSION_IHL;
                POS_IP_FLAGS : header_byte_bad <= m_data[7];
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
            ev <= 0;
            position <= 0;
            at_udp_check_low <= 0;
            at_payload <= 0;
            at_ip_offset_low <= 0;
            at_udp_length_low <= 0;
            frame_fragmented <= 0;
            frame_later <= 0;
            data_end_q <= 0;
            wire_length_q <= 0;
            pad_sn_q <= 0;
            pad_wire_q <= 0;
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
            if (rx_valid && !prev_line) begin
                allowed <= enable;
                has_payload <= 0;
            end
            if (!enable) allowed <= 0;
            // 仅当接收引擎确认接纳本帧后才推进已提交末端指针，否则回退试探指针。
            if (resolve_valid) begin
                if (resolve_commit) committed <= desc_finish;
                else trial <= committed;
            end
            case (length_phase)
                LEN_SIZES : begin
                    n <= fragmented ? ip_data_len - (later_fragment ? 16'd0 : 16'd8) : udp_len - UDP_HEADER_LENGTH;
                    n_ok <= fragmented ? (ip_data_len <= 1479 && ip_data_len >= (later_fragment ? 1 : 8)) :
                        (udp_len >= MIN_UDP_LENGTH && udp_len <= MAX_UDP_LENGTH);
                    ip_expected <= fragmented ? ip_len : udp_len + IP_HEADER_LENGTH;
                    data_end_q <= fragmented ? ip_len + 16'd14 : udp_len + 16'd34;
                    wire_length_q <= fragmented ? ip_len + 16'd19 : udp_len + 16'd39;
                    // 保留原设计中畸形 IPv4 长度发生 16 位回绕时的异常判决边界；正常报文仅使用低段范围。
                    pad_sn_q <= fragmented ? (ip_len < 16'd45 || ip_len >= 16'd65522) :
                        (udp_len >= 16'd8 && udp_len < 16'd25);
                    pad_wire_q <= fragmented ? (ip_len < 16'd45 || ip_len >= 16'd65517) :
                        (udp_len >= 16'd8 && udp_len < 16'd25);
                    if (!fragmented) begin
                        udp_add_valid <= 1;
                        udp_add_word <= udp_len;
                    end
                    length_phase <= LEN_LIMITS;
                end
                LEN_LIMITS : begin
                    end_data <= data_end_q;
                    last_data <= data_end_q - 16'd1;
                    sn_position <= pad_sn_q ? MIN_SN_POSITION : data_end_q;
                    expected_len <= pad_wire_q ? MIN_FRAME_LENGTH : wire_length_q;
                    space_limit <= space_limit_value[RX_RING_AW:0];
                    fits_q <= n <= CAPACITY;
                    length_phase <= LEN_WAIT;
                end
                default :;
            endcase
            // 本模块仅支持不带选项的 20 字节 IPv4 首部；非分片报文与首分片含完整 UDP 首部，后续分片仅含分片载荷；
            // 1 字节帧序号位于净荷或补零之后（FCS 之前），不计入 UDP 长度。
            if (m_valid && allowed) begin
                if (m_first) begin
                    position <= 1;
                    at_udp_check_low <= 0;
                    at_payload <= 0;
                    at_ip_offset_low <= 0;
                    at_udp_length_low <= 0;
                    frame_fragmented <= 0;
                    frame_later <= 0;
                    in_payload <= 0;
                    high_byte <= m_data;
                    overflow <= 0;
                    begin
                        ip_add_valid <= 1;
                        ip_seed <= 1;
                        ip_add_word <= 0;
                    end
                    begin
                        udp_add_valid <= 1;
                        udp_seed <= 1;
                        udp_add_word <= 0;
                    end
                    n_ok <= 0;
                    fits_q <= 0;
                    length_phase <= LEN_WAIT;
                    vlid <= 0;
                    sport <= 0;
                    dport <= 0;
                    ip_len <= 0;
                    ip_id <= 0;
                    frag_word <= 0;
                    ip_src <= 0;
                    ip_dst <= 0;
                    udp_len <= 0;
                    udp_check <= 0;
                    sn <= 0;
                end
                else begin
                    position <= position + 1'b1;
                    at_udp_check_low <= position == POS_UDP_CHECK_LOW - 1;
                    at_payload <= position == POS_PAYLOAD - 1;
                    at_ip_offset_low <= position == POS_IP_OFFSET_LOW - 1;
                    at_udp_length_low <= position == POS_UDP_LENGTH_LOW - 1;
                    if (at_ip_offset_low && (high_byte[5] || |high_byte[4:0] || m_data != 0))
                        length_phase <= LEN_SIZES;
                    if (at_udp_length_low && !fragmented) length_phase <= LEN_SIZES;
                    in_payload <= position == ((fragmented && later_fragment) ? 33 : 41)
                        ? (n_ok && n != 0) : in_payload && position != last_data;
                    // 环形缓存写口数据与地址随字节自由推进，仅由 ring_we 提交脉冲控制写入，
                    // 使位置比较逻辑脱离写数据与写地址路径。
                    ring_wd <= m_data;
                    ring_wa <= has_payload ? trial[RX_RING_AW - 1:0] : committed[RX_RING_AW - 1:0];
                    if (!position[0]) high_byte <= m_data;
                    if (at_udp_check_low) udp_check <= {high_byte, m_data};
                    // 直接用常数比较触发 frame_begin 锁存，避免外层范围译码逻辑进入其使能端。
                    if (position == ((fragmented && later_fragment) ? 33 : 41) && n_ok) frame_begin <= committed;
                    case (position)
                        // 按字节偏移提取 VL 编号、IPv4 长度/分片/地址及 UDP 端口与长度字段。
                        POS_VLID_LOW : vlid <= {high_byte, m_data};
                        POS_IP_LENGTH_LOW : ip_len <= {high_byte, m_data};
                        19 : ip_id <= {high_byte, m_data};
                        21 : begin
                            frag_word <= {high_byte, m_data};
                            frame_fragmented <= high_byte[5] || |high_byte[4:0] || m_data != 0;
                            frame_later <= |high_byte[4:0] || m_data != 0;
                        end
                        27 : ip_src[31:16] <= {high_byte, m_data};
                        29 : ip_src[15:0] <= {high_byte, m_data};
                        31 : ip_dst[31:16] <= {high_byte, m_data};
                        33 : ip_dst[15:0] <= {high_byte, m_data};
                        POS_SPORT_LOW : sport <= {high_byte, m_data};
                        POS_DPORT_LOW : dport <= {high_byte, m_data};
                        POS_UDP_LENGTH_LOW : begin
                            udp_len <= {high_byte, m_data};
                        end
                        default :;
                    endcase
                    if (position >= POS_IP_HEADER && position <= POS_IP_HEADER_END && position[0]) begin
                        ip_add_valid <= 1;
                        ip_add_word <= {high_byte, m_data};
                    end
                    if (position >= POS_IP_ADDRESSES && position <= POS_UDP_CHECK_LOW && position[0]) begin
                        udp_add_valid <= 1;
                        udp_add_word <= {high_byte, m_data};
                    end
                    if (in_payload) begin
                        if (position[0]) begin
                            udp_add_valid <= 1;
                            udp_add_word <= {high_byte, m_data};
                        end
                        else if (position == last_data) begin
                            udp_add_valid <= 1;
                            udp_add_word <= {m_data, 8'b0};
                        end
                        if (position == ((fragmented && later_fragment) ? 34 : 42)) begin
                            // 总容量比较已于前一阶段寄存，本拍下游新释放的空间仍立即参与接纳判别。
                            has_payload <= 1;
                            overflow <= !fits_q || occupied > space_limit;
                            if (fits_q && occupied <= space_limit) begin
                                ring_we <= 1;
                                trial <= committed + 1'b1;
                            end
                        end
                        else if (!overflow) begin
                            ring_we <= 1;
                            trial <= trial + 1'b1;
                        end
                    end
                    if (n_ok && position == sn_position) sn <= m_data;
                end
            end
            // 帧尾快照封装 VL 编号、序号、UDP 端口、净荷长度、缓存起点及到达时间并提交给接收引擎。
            if (f_end && allowed) begin
                err_saved <= f_err;
                end_overflow <= overflow;
                end_alloc <= has_payload;
                end_bad <= header_bad || !n_ok || !ip_checksum_good || !ip_length_matches
                    || f_len != expected_len || (fragmented && fragment_geometry_bad);
                // 合法长度帧的末次 UDP 校验累加已在序号拍完成，f_end 拍 udp_sum 已稳定；
                // 截短帧虽可能尚余未累加字，但已被长度检查拒收，不影响报告拍次。
                udp_bad_q <= !fragmented && udp_check != 0 && !udp_checksum_good;
                end_desc <= {ip_src, ip_dst, ip_id, frag_word[12:0], frag_word[13], udp_len, udp_check,
                    vlid, sn, sport, dport, n[10:0], frame_begin[RX_RING_AW - 1:0], 16'b0};
                desc_finish <= trial;
                finish_phase <= FIN_SETTLE;
            end
            else if (finish_phase != FIN_WAIT) begin
                finish_phase <= finish_phase + 1'b1;
                // 校验结论提前一拍寄存，最终事件报告与描述符发布仍维持原有相位。
                if (finish_phase == FIN_SETTLE) begin
                    if (udp_bad_q) end_bad <= 1;
                    // 帧尾快照已精确采样上一拍 f_end 有效沿上的到达时刻。
                    end_desc[15:0] <= arrival_snapshot;
                end
                if (finish_phase == FIN_REPORT) begin
                    finish_phase <= FIN_WAIT;
                    if (err_saved == ERR_FCS) ev <= EV_FCS;
                    else if (err_saved == ERR_LENGTH || err_saved == ERR_PREAMBLE) ev <= EV_LENGTH;
                    else if (end_bad) ev <= EV_HEADER;
                    else if (end_overflow) ev <= EV_OVERFLOW;
                    else begin
                        ev <= EV_GOOD;
                    end
                    // 检查失败或缓存溢出且本帧曾分配缓存时，在此回退试探指针释放暂占空间；
                    // 无净荷写入的前导码错误不会误回退尚待判定的完整帧。
                    if ((err_saved != ERR_NONE || end_bad || end_overflow) && end_alloc) trial <= frame_begin;
                end
            end
        end
    end

endmodule
