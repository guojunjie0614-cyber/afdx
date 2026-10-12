// 本测试把两个完整端系统通过 A、B 两网直接相连。
// 每端配置全部 4096 条接收虚拟链路，128 条发送虚拟链路各发送一条消息。
// 接收索引覆盖 0、4095 和中间的 126 项，逐字节检查并确认双网只交付一次。
// 最后的 [RESULT] 必须为 PASS 且 errors=0；测试不读取输入文件。
`timescale 1ns/1ps
module tb_judge_capacity;
    reg clk = 0, reset = 1;
    always #4 clk = ~clk;
    wire [7:0] a12, b12, a21, b21;
    wire va12, vb12, va21, vb21, ready1, ready2;
    wire [31:0] checks1, checks2, errors1, errors2;
    integer v, index, cycle = 0;
    judge_endpoint #(.ES(1)) es1 (
        .clk(clk), .reset(reset), .ra(a21), .rb(b21), .rva(va21), .rvb(vb21),
        .ta(a12), .tb(b12), .tva(va12), .tvb(vb12), .ready(ready1), .checks(checks1), .errors(errors1)
    );
    judge_endpoint #(.ES(2)) es2 (
        .clk(clk), .reset(reset), .ra(a12), .rb(b12), .rva(va12), .rvb(vb12),
        .ta(a21), .tb(b21), .tva(va21), .tvb(vb21), .ready(ready2), .checks(checks2), .errors(errors2)
    );
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (cycle > 3000000 || errors1 + errors2 > 20) begin
            // 等检查计数传到端口后，再汇总结果。
            #1;
            $display("[RESULT] tb_judge_capacity FAIL checks=%0d errors=%0d",
                checks1 + checks2, errors1 + errors2 + 1);
            $finish;
        end
    end
    initial begin
        repeat (8) @(negedge clk); reset = 0;
        wait (ready1 && ready2);
        for (v = 0; v < 4096; v = v + 1) begin
            es1.configure_rx(v, 8192 + v, 64);
            es2.configure_rx(v, 4096 + v, 64);
        end
        for (v = 0; v < 128; v = v + 1) begin
            index = v == 127 ? 4095 : v*32;
            es1.configure_tx(v, 4096 + index, 64);
            es2.configure_tx(v, 8192 + index, 64);
        end
        for (v = 0; v < 128; v = v + 1) begin
            index = v == 127 ? 4095 : v*32;
            fork
                es1.send_payload(v, 64, v + 17);
                es2.send_payload(v, 64, v + 93);
            join
            es1.expect_payload(v + 1, index, 64, v + 93);
            es2.expect_payload(v + 1, index, 64, v + 17);
            $display("[CAPACITY] tx_vl=%0d rx_index=%0d both_directions=PASS", v, index);
        end
        repeat (1000) @(negedge clk);
        es1.check(es1.received == 128 && es1.accepted == 128 && es1.duplicates == 128,
            "128 messages accepted, delivered once and duplicate copies rejected");
        es2.check(es2.received == 128 && es2.accepted == 128 && es2.duplicates == 128,
            "128 messages accepted, delivered once and duplicate copies rejected");
        es1.check(es1.frames_a == 128 && es1.frames_b == 128, "all VLs sent on both networks");
        es2.check(es2.frames_a == 128 && es2.frames_b == 128, "all VLs sent on both networks");
        $display("[CAPACITY_SUMMARY] tx_vls_each=128 rx_configured_each=4096 rx_sampled_each=128 first=0 last=4095");
        // 等检查计数传到端口后，再汇总结果。
        #1;
        $display("[RESULT] tb_judge_capacity %0s checks=%0d errors=%0d",
            errors1 + errors2 == 0 ? "PASS" : "FAIL", checks1 + checks2, errors1 + errors2);
        $finish;
    end
endmodule
