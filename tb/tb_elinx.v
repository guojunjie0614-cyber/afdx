// 本测试供 eLinx 的 Run Behavioral Simulation 直接运行，不读取输入文件。
// 两个完整端系统通过 A、B 两网互发三条不同长度的用户消息。
// 测试逐字节检查消息和端口，并确认每条消息从双网发送后只交付一次。
// 最后的 [RESULT] 必须为 PASS 且 errors=0；超时或内容错误都会打印 FAIL。
`timescale 1ns/1ps
module tb_elinx;
    reg clk = 0, reset = 1;
    always #4 clk = ~clk;
    wire [7:0] a12, b12, a21, b21;
    wire va12, vb12, va21, vb21, ready1, ready2;
    wire [31:0] checks1, checks2, errors1, errors2;
    integer cycle = 0, message, length;
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
        if (cycle > 1000000 || errors1 + errors2 > 20) begin
            // 等检查计数传到端口后，再汇总结果。
            #1;
            $display("[RESULT] tb_elinx FAIL checks=%0d errors=%0d",
                checks1 + checks2, errors1 + errors2 + 1);
            $finish;
        end
    end
    initial begin
        repeat (8) @(negedge clk); reset = 0;
        wait (ready1 && ready2);
        es1.configure_tx(0, 100, 1471); es2.configure_rx(0, 100, 1471);
        es2.configure_tx(0, 200, 1471); es1.configure_rx(0, 200, 1471);
        for (message = 0; message < 3; message = message + 1) begin
            case (message)
                0: length = 1;
                1: length = 64;
                default: length = 1471;
            endcase
            fork
                es1.send_payload(0, length, 17 + message);
                es2.send_payload(0, length, 93 + message);
            join
            es1.expect_payload(message + 1, 0, length, 93 + message);
            es2.expect_payload(message + 1, 0, length, 17 + message);
            $display("[ELINX_MESSAGE] length=%0d both_directions=PASS", length);
        end
        repeat (1000) @(negedge clk);
        es1.check(es1.received == 3 && es1.accepted == 3 && es1.duplicates == 3,
            "three complete messages and exactly one delivery per redundant pair");
        es2.check(es2.received == 3 && es2.accepted == 3 && es2.duplicates == 3,
            "three complete messages and exactly one delivery per redundant pair");
        es1.check(es1.frames_a == 3 && es1.frames_b == 3, "both transmit networks carry all messages");
        es2.check(es2.frames_a == 3 && es2.frames_b == 3, "both transmit networks carry all messages");
        // 等检查计数传到端口后，再汇总结果。
        #1;
        $display("[RESULT] tb_elinx %0s checks=%0d errors=%0d",
            errors1 + errors2 == 0 ? "PASS" : "FAIL", checks1 + checks2, errors1 + errors2);
        $finish;
    end
endmodule
