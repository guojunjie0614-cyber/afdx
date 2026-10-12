// 本模块为评委测试连接一个完整端系统，只使用顶层公开端口。
// 外层测试通过这里的任务配置虚拟链路、发送消息和检查收到的消息。
// 收到的最后一条消息保存在 rx_bytes 中，供外层检查协议字段。
// 本文件不读取输入文件；外层必须把 checks 和 errors 计入最终结果。
`timescale 1ns/1ps
module judge_endpoint #(parameter ES = 1) (
    input wire clk, reset,
    input wire [7:0] ra, rb,
    input wire rva, rvb,
    output wire [7:0] ta, tb,
    output wire tva, tvb, ready,
    output reg [31:0] checks = 0, errors = 0
);
    reg m_valid = 0, m_last = 0;
    reg [7:0] m_data = 0;
    reg [6:0] m_vl = 0;
    reg [15:0] m_sp = 3001, m_dp = 4001;
    wire m_ready, d_valid, d_last, d_net;
    wire [7:0] d_data;
    wire [11:0] d_vl;
    wire [15:0] d_sp, d_dp;
    reg wr = 0, rd = 0;
    reg [17:0] address = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rdata;
    wire rvalid, bready, rm_drop, deliver;
    wire [6:0] ev_tx;
    wire [7:0] ev_a, ev_b;
    wire [1:0] gdrop;
    reg [7:0] tx_bytes[0:2047], rx_bytes[0:2047];
    integer received = 0, rx_length = 0, rx_pos = 0;
    integer accepted = 0, duplicates = 0, frames_a = 0, frames_b = 0;
    reg [11:0] rx_vl;
    reg [15:0] rx_sport, rx_dport;
    reg previous_a = 0, previous_b = 0;

    AFDX_top dut (
        .clk(clk), .reset(reset),
        .tx_data(ta), .tx_valid(tva), .rx_data(ra), .rx_valid(rva),
        .tx_ready(ready), .rx_ready(1'b0),
        .tx_data_b(tb), .tx_valid_b(tvb), .rx_data_b(rb), .rx_valid_b(rvb),
        .app_tx_valid(m_valid), .app_tx_ready(m_ready), .app_tx_data(m_data),
        .app_tx_last(m_last), .app_tx_vl(m_vl), .app_tx_port_en(1'b1),
        .app_tx_sport(m_sp), .app_tx_dport(m_dp),
        .app_rx_valid(d_valid), .app_rx_data(d_data), .app_rx_last(d_last),
        .app_rx_vl(d_vl), .app_rx_sport(d_sp), .app_rx_port(d_dp), .app_rx_net(d_net),
        .cfg_wr(wr), .cfg_rd(rd), .cfg_addr(address), .cfg_wdata(wdata),
        .cfg_rdata(rdata), .cfg_rvalid(rvalid), .cfg_ready(bready),
        .ev_tx(ev_tx), .ev_a(ev_a), .ev_b(ev_b),
        .ev_rm_drop(rm_drop), .ev_deliver(deliver), .ev_gdrop(gdrop)
    );

    task check;
        input ok;
        input [8*100-1:0] why;
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                errors = errors + 1;
                if (errors < 20) $display("[JUDGE_ENDPOINT_FAIL] ES%0d %0s", ES, why);
            end
        end
    endtask

    always @(posedge clk) if (!reset) begin
        if ((|ev_tx[4:1]) || (|ev_a[7:1]) || (|ev_b[7:1]) || (|gdrop))
            check(0, "no allocation, framing, mapping or receive error");
        if (ev_tx[0]) accepted = accepted + 1;
        if (rm_drop) duplicates = duplicates + 1;
        if (tva && !previous_a) frames_a = frames_a + 1;
        if (tvb && !previous_b) frames_b = frames_b + 1;
        previous_a = tva;
        previous_b = tvb;
        if (d_valid) begin
            if (rx_pos == 0) begin
                rx_vl = d_vl;
                rx_sport = d_sp;
                rx_dport = d_dp;
            end
            check(d_vl == rx_vl && d_sp == rx_sport && d_dp == rx_dport,
                "metadata remains constant within a message");
            check(rx_pos < 2048, "message fits capture buffer");
            if (rx_pos < 2048) rx_bytes[rx_pos] = d_data;
            rx_pos = rx_pos + 1;
            if (d_last) begin
                rx_length = rx_pos;
                rx_pos = 0;
                received = received + 1;
            end
        end
    end

    task write_cfg;
        input [17:0] a;
        input [31:0] value;
        begin
            @(negedge clk);
            while (!bready) @(negedge clk);
            address = a; wdata = value; wr = 1;
            @(posedge clk); #1; wr = 0;
            while (!bready) begin @(posedge clk); #1; end
        end
    endtask

    task read_cfg;
        input [17:0] a;
        output [31:0] value;
        begin
            @(negedge clk); address = a; rd = 1;
            @(posedge clk); #1; rd = 0;
            @(posedge clk); #1;
            check(rvalid, "configuration read is valid");
            value = rdata;
        end
    endtask

    // 每条发送虚拟链路占八个配置字，BAG 设为一毫秒。
    task configure_tx;
        input integer index, vlid, maximum;
        begin
            write_cfg(18'h1000 + index*8, maximum*512 + 63*8 + 7);
            write_cfg(18'h1001 + index*8, 125000);
            write_cfg(18'h1002 + index*8, vlid);
            write_cfg(18'h1003 + index*8, 32'h0a000000 + ES);
            write_cfg(18'h1004 + index*8, 32'he0e00000 + vlid);
            write_cfg(18'h1005 + index*8, 32'h0bb90fa1);
        end
    endtask

    // 接收配置同时打开完整性检查和双网去重。
    task configure_rx;
        input integer index, vlid, maximum;
        begin
            write_cfg(18'h10000 + vlid, 4096 + index);
            write_cfg(18'h20000 + index, maximum*131072 + 20*32 + 31);
        end
    endtask

    task send_packet;
        input integer index, length, sport, dport;
        integer i;
        reg taken;
        begin
            m_vl = index; m_sp = sport; m_dp = dport;
            for (i = 0; i < length; i = i + 1) begin
                @(negedge clk);
                m_valid = 1; m_last = (i + 1 == length); m_data = tx_bytes[i];
                taken = 0;
                while (!taken) begin @(posedge clk); taken = m_ready; #1; end
            end
            m_valid = 0; m_last = 0;
        end
    endtask

    task send_payload;
        input integer index, length, tag;
        integer i;
        begin
            for (i = 0; i < length; i = i + 1) tx_bytes[i] = tag + i;
            send_packet(index, length, 3001, 4001);
        end
    endtask

    task wait_message;
        input integer expected_count;
        integer cycles;
        begin
            cycles = 0;
            while (received < expected_count && cycles < 300000) begin
                @(negedge clk); cycles = cycles + 1;
            end
            check(received == expected_count, "one complete message received before timeout");
        end
    endtask

    task expect_payload;
        input integer count, index, length, tag;
        integer i;
        reg [7:0] expected;
        begin
            wait_message(count);
            check(rx_length == length, "payload length");
            check(rx_vl == index && rx_sport == 3001 && rx_dport == 4001, "payload metadata");
            for (i = 0; i < length; i = i + 1) begin
                expected = tag + i;
                check(rx_bytes[i] === expected, "payload byte");
            end
        end
    endtask
endmodule
