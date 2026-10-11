// 发送核心外壳，连接消息缓冲、VL调度、组帧和页回收。
// m_*接收应用/服务消息；配置口设置VL，双网输出慢线帧。
// 页池、配置表和各队列的RAM读写口分配保持独立。
// 发送核心外壳：配置清表、六张共享 RAM 与各端口唯一主人连接。
module afdx_tx_core #(
    parameter TX_PAGE_AW = 8, TX_OFF_AW = 9, LOOKAHEAD = 512) (
    // clk 为工作时钟，reset 为同步高有效复位。
    input wire clk, reset,
    // now/byte_en 连接时基；当前顶层 byte_en 逐拍有效，输出为原生 GMII。
    input wire [31:0] now,
    input wire byte_en,
    // m_* 传送完整 UDP 消息；valid/ready 为字节握手，last 为消息尾，vl 为配置表索引。
    input wire m_valid,
    output wire m_ready,
    input wire [7:0] m_data,
    input wire m_last,
    input wire [6:0] m_vl,
    // m_port_en 选择消息自带 sport/dport 或 VL 默认端口。
    input wire m_port_en,
    input wire [15:0] m_sport, m_dport,
    // cfg_* 写 128 个 VL、每 VL 八字的配置表；cfg_ok 为可写窗口，user_id 为源 MAC 编号。
    input wire cfg_we,
    input wire [9:0] cfg_addr,
    input wire [31:0] cfg_wdata,
    input wire [15:0] user_id,
    // tx_data_a/b、tx_valid_a/b 是双网线路；init_done 表示配置表、状态表、空闲池均已初始化。
    output wire [7:0] tx_data_a,
    output wire tx_valid_a,
    output wire [7:0] tx_data_b,
    output wire tx_valid_b,
    output reg init_done,
    // ev_* 依次报告接纳、各类丢弃和两网正常发完帧；事件均为单拍。
    output wire ev_accept, ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage, ev_tx_a, ev_tx_b,
    output wire cfg_ok);
    localparam PAGES = (1 << TX_PAGE_AW), PAYLOAD_DEPTH = (1 << (TX_PAGE_AW + TX_OFF_AW));
    // init_addr 顺序清配置表，init_flush 等最后写入；初始化结束后写口归外部配置。
    reg cfg_write, init_flush, cfg_initialized;
    reg [9:0] cfg_write_addr, init_addr;
    reg [31:0] cfg_write_data;
    wire free_initialized, engine_initialized;
    wire cfg_read, state_write, state_read, mnext_write, mnext_read, desc_write, desc_read, pnext_write, pnext_read,
        payload_write, payload_read;
    wire [9:0] cfg_read_addr;
    wire [31:0] cfg_data;
    wire [6:0] state_write_addr, state_read_addr;
    wire [62:0] state_write_data, state_data;
    wire [TX_PAGE_AW - 1:0] mnext_write_addr, mnext_read_addr, desc_write_addr, desc_read_addr, pnext_write_addr,
        pnext_read_addr;
    wire [7:0] mnext_write_data, mnext_data, pnext_write_data, pnext_data, payload_write_data, payload_data;
    wire [43:0] desc_write_data, desc_data;
    wire [TX_PAGE_AW + TX_OFF_AW - 1:0] payload_write_addr, payload_read_addr;
    wire pop_req, pop_ready, pop_ack, pop_ok, ret1_valid, ret1_ready, ret2_valid, ret2_ready;
    wire [7:0] pop_page, ret1_page, ret2_page;
    wire enq_valid, enq_ack;
    wire [6:0] enq_vl;
    wire [7:0] enq_head;
    wire [10:0] enq_len;
    wire [2:0] enq_result;
    wire start_valid, grant_ready, grant_valid, grant_a, grant_b, grant_timed;
    wire [31:0] t_start, grant_time, grant_src, grant_dst;
    wire [15:0] grant_vlid, grant_sport, grant_dport;
    wire [10:0] grant_len;
    wire [7:0] grant_sn, grant_page;
    wire s_valid, s_ready, s_last, s_en_a, s_en_b, tx_sof, tx_eof, tx_underrun;
    wire [7:0] s_data_a, s_data_b;
    // 初始化屏障：三个子资源全部就绪后才接受消息和配置。
    always @(posedge clk) begin
        if (reset) begin
            cfg_write <= 0;
            cfg_write_addr <= 0;
            cfg_write_data <= 0;
            init_addr <= 0;
            init_flush <= 0;
            cfg_initialized <= 0;
            init_done <= 0;
        end
        else begin
            cfg_write <= 0;
            if (! cfg_initialized) begin
                if (! init_flush) begin
                    cfg_write <= 1;
                    cfg_write_addr <= init_addr;
                    cfg_write_data <= 0;
                    init_addr <= init_addr + 1'b1;
                    if (init_addr == 1023) init_flush <= 1;
                end
                else cfg_initialized <= 1;
            end
            else if (init_done) begin
                cfg_write <= cfg_we && cfg_ok;
                cfg_write_addr <= cfg_addr;
                cfg_write_data <= cfg_wdata;
            end
            if (cfg_initialized && free_initialized && engine_initialized) init_done <= 1;
        end
    end
    // 共享存储：cfg=VL 静态配置，state=队列/SN/BAG，mnext=消息链，desc=消息元数据。
    afdx_ram_sdp #(.WIDTH(32), .DEPTH(1024)) tx_cfg (clk, cfg_write, cfg_write_addr, cfg_write_data, cfg_read, cfg_read_addr,
        cfg_data);
    afdx_ram_sdp #(.WIDTH(63), .DEPTH(128)) tx_state (clk, state_write, state_write_addr, state_write_data, state_read,
        state_read_addr, state_data);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_mnext (clk, mnext_write, mnext_write_addr, mnext_write_data, mnext_read,
        mnext_read_addr, mnext_data);
    afdx_ram_sdp #(.WIDTH(44), .DEPTH(PAGES)) tx_desc (clk, desc_write, desc_write_addr, desc_write_data, desc_read,
        desc_read_addr, desc_data);
    // pnext 连接同一消息的载荷页；payload 保存字节，各表仅有一个明确的写口主人。
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAGES)) tx_pnext (clk, pnext_write, pnext_write_addr, pnext_write_data, pnext_read,
        pnext_read_addr, pnext_data);
    afdx_ram_sdp #(.WIDTH(8), .DEPTH(PAYLOAD_DEPTH)) tx_payload (clk, payload_write, payload_write_addr, payload_write_data,
        payload_read, payload_read_addr, payload_data);
    // 数据路径：空闲池供页 → 消息缓冲入队 → VL 调度授权 → 组帧/MAC 发送并归还页。
    afdx_tx_free #(.TX_PAGE_AW(TX_PAGE_AW)) free_pages (clk, reset, free_initialized, pop_req, pop_ready, pop_ack, pop_ok,
        pop_page, ret1_valid, ret1_page, ret1_ready, ret2_valid, ret2_page, ret2_ready);
    afdx_tx_buf #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW)) buffer (clk, reset, init_done, m_valid, m_ready, m_data,
        m_last, m_vl, m_port_en, m_sport, m_dport, pop_req, pop_ready, pop_ack, pop_ok, pop_page, ret2_valid, ret2_page,
        ret2_ready, payload_write, payload_write_addr, payload_write_data, pnext_write, pnext_write_addr, pnext_write_data,
        desc_write, desc_write_addr, desc_write_data, enq_valid, enq_vl, enq_head, enq_len, enq_ack, enq_result, ev_accept,
        ev_drop_dis, ev_drop_full, ev_drop_long, ev_drop_nopage);
    afdx_tx_engine #(.TX_PAGE_AW(TX_PAGE_AW), .LOOKAHEAD(LOOKAHEAD)) engine (clk, reset, init_done, now, engine_initialized,
        cfg_read, cfg_read_addr, cfg_data, state_write, state_read, state_write_addr, state_read_addr, state_write_data,
        state_data, mnext_write, mnext_read, mnext_write_addr, mnext_read_addr, mnext_write_data, mnext_data, desc_read,
        desc_read_addr, desc_data, enq_valid, enq_vl, enq_head, enq_len, enq_ack, enq_result, start_valid, t_start,
        grant_ready, grant_valid, grant_a, grant_b, grant_timed, grant_time, grant_vlid, grant_sport, grant_dport, grant_src,
        grant_dst, grant_len, grant_sn, grant_page, cfg_ok);
    afdx_tx_builder #(.TX_PAGE_AW(TX_PAGE_AW), .TX_OFF_AW(TX_OFF_AW)) builder (clk, reset, now, user_id, grant_ready,
        grant_valid, grant_a, grant_b, grant_timed, grant_time, grant_src, grant_dst, grant_vlid, grant_sport, grant_dport,
        grant_len, grant_sn, grant_page, start_valid, t_start, payload_read, payload_read_addr, payload_data, pnext_read,
        pnext_read_addr, pnext_data, ret1_valid, ret1_page, ret1_ready, s_valid, s_ready, s_data_a, s_data_b, s_last, s_en_a,
        s_en_b, tx_sof, tx_eof, tx_underrun, ev_tx_a, ev_tx_b);
    afdx_mac_tx mac (clk, reset, byte_en, s_valid, s_ready, s_data_a, s_data_b, s_last, s_en_a, s_en_b, tx_sof, tx_eof,
        tx_underrun, tx_data_a, tx_valid_a, tx_data_b, tx_valid_b);
endmodule
