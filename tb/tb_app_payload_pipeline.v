`timescale 1ns/1ps

// 端口级字节记分板：覆盖跨体/回绕访问、满容量测试、
// 超长回退、连续传输以及在途读期间的下游反压停顿。
module tb_app_payload_pipeline;
    reg clk = 0;
    always #4 clk = ~clk;

    reg reset = 1;
    integer cycle = 0, errors = 0, command_checks = 0;

    function [7:0] pattern;
        input integer n, seed;
        begin
            pattern = (n * 37 + (n / 251) * 19 + seed * 53) & 255;
        end
    endfunction

    task fail;
        input [8*96-1:0] reason;
        begin
            errors = errors + 1;
            if (errors < 20)
                $display("[FAIL] cycle=%0d %0s", cycle, reason);
        end
    endtask

    // 在现有流量与反压场景下检查信用守恒定律：
    // pending 响应与队列/输出字节为实际占用；take_q 为外部握手后唯一保守保留的信用。
    task check_credit;
        input [3:0] reserved, queued, pending;
        input [1:0] outputs;
        input take_retiring;
        integer occupied, k;
        begin
            occupied = queued + outputs + take_retiring;
            for (k = 0; k < 4; k = k + 1)
                occupied = occupied + pending[k];
            command_checks = command_checks + 1;
            if (occupied > 8 || reserved !== occupied[3:0])
                fail("reader credit conservation/overflow mismatch");
            if (take_retiring && reserved == 0)
                fail("reader returned a credit from zero");
        end
    endtask

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (cycle > 250000) begin
            $display(
                "[RESULT] tb_app_payload_pipeline FAIL checks=%0d errors=%0d timeout",
                p_seen + tx_seen + rx_seen + command_checks + equivalence_checks,
                errors
            );
            $fatal(1);
        end
    end

    // 分体 RAM 与预取读出器直测，覆盖完整 32768 字节环形空间。
    reg p_reset = 1, p_reader_reset = 1, p_write = 0, p_ready = 0;
    reg [14:0] p_address = 0;
    reg [8:0] p_wdata = 0;
    reg [15:0] p_limit = 0;
    wire [15:0] p_pointer;
    wire p_re, p_valid;
    wire [14:0] p_ra;
    wire [8:0] p_q, p_data;

    afdx_app_payload #(.SPLIT_RETURN(1)) p_ram (
        .clk           (clk),
        .reset         (p_reset),
        .write_enable  (p_write),
        .write_address (p_address),
        .write_data    (p_wdata),
        .read_enable   (p_re),
        .read_address  (p_ra),
        .read_data     (p_q),
        .raw_write_data()
    );

    // E0 发出本地读命令，E1 读 RAM，E2 返回结果，E3 多路选择，E4 完成读出。
    afdx_app_read #(.AW(15), .READ_LATENCY(4)) p_reader (
        .clk          (clk),
        .reset        (p_reader_reset),
        .limit        (p_limit),
        .pointer      (p_pointer),
        .read_enable  (p_re),
        .read_address (p_ra),
        .read_data    (p_q),
        .valid        (p_valid),
        .ready        (p_ready),
        .data         (p_data),
        .next_limit   ()
    );

    integer p_seen = 0, p_target = 0, p_continuous = 0;
    reg p_hold = 0;
    reg [8:0] p_held;
    reg p_check_rate = 0, p_started = 0;

    always @(posedge clk)
        if (!p_reader_reset) begin
            check_credit(
                p_reader.reserved, p_reader.queued, p_reader.pending,
                p_reader.output_count, p_reader.take_q
            );
            if (p_hold && (!p_valid || p_data !== p_held))
                fail("prefetch output changed under backpressure");
            p_hold = p_valid && !p_ready;
            p_held = p_data;
            if (p_valid && p_ready) begin
                if (p_seen >= p_target)
                    fail("prefetch duplicated/excess byte");
                if (p_data !== {(p_seen % 997) == 996, pattern(p_seen, 3)})
                    fail("prefetch byte/last mismatch");
                p_seen = p_seen + 1;
                if (p_check_rate) begin
                    p_started = 1;
                    p_continuous = p_continuous + 1;
                end
            end
            else if (p_check_rate && p_started && p_seen < p_target)
                fail("prefetch failed one byte per clock");
        end

    reg tx_valid = 0, tx_ready = 0, tx_cfg = 0;
    reg [7:0] tx_data = 0;
    reg [6:0] tx_cfg_index = 7;
    reg [15:0] tx_cfg_vlid = 16'hbeef;
    wire tx_in_ready, tx_valid_out, tx_last;
    wire [7:0] tx_out;
    wire [6:0] tx_vl;
    wire [1:0] tx_drop;

    afdx_app_tx tx (
        clk, reset, 1'b1,
        tx_data, tx_valid, tx_in_ready,
        tx_cfg, tx_cfg_index, tx_cfg_vlid,
        tx_valid_out, tx_ready, tx_out, tx_last, tx_vl, tx_drop
    );

    reg [8:0] expected_tx[0:99999];
    integer tx_expected = 0, tx_seen = 0, tx_overflow = 0, tx_miss = 0;
    reg tx_hold = 0;
    reg [15:0] tx_held;
    reg tx_throttle = 0, tx_check_rate = 0, tx_started = 0;

    always @(negedge clk)
        if (tx_throttle)
            tx_ready = (cycle % 101 >= 37) && (cycle % 7 != 0);

    always @(posedge clk)
        if (!reset) begin
            check_credit(
                tx.reader.reserved, tx.reader.queued, tx.reader.pending,
                tx.reader.output_count, tx.reader.take_q
            );
            if (tx_drop[1])
                tx_overflow = tx_overflow + 1;
            if (tx_drop[0])
                tx_miss = tx_miss + 1;
            if (tx_hold && (!tx_valid_out || {tx_vl, tx_last, tx_out} !== tx_held))
                fail("TX output changed under backpressure");
            tx_hold = tx_valid_out && !tx_ready;
            tx_held = {tx_vl, tx_last, tx_out};
            if (tx_valid_out && tx_ready) begin
                if (tx_seen >= tx_expected)
                    fail("TX excess byte or rejected message escaped");
                else if ({tx_last, tx_out} !== expected_tx[tx_seen])
                    fail("TX byte/last mismatch");
                if (tx_vl !== 7)
                    fail("TX changed lowest matching VL index");
                tx_seen = tx_seen + 1;
                if (tx_check_rate) begin
                    if (tx_last)
                        tx_started = 0;
                    else
                        tx_started = 1;
                end
            end
            else if (tx_check_rate && tx_started)
                fail("TX message contains throughput bubble");
        end

    task tx_message;
        input integer length, seed, accept;
        integer j;
        begin
            while (!tx_in_ready)
                @(negedge clk);
            if (accept)
                for (j = 0; j < length; j = j + 1) begin
                    expected_tx[tx_expected] = {(j == length - 1), pattern(j, seed)};
                    tx_expected = tx_expected + 1;
                end
            @(negedge clk);
            tx_valid = 1;
            tx_data = 8'hbe;
            @(negedge clk);
            tx_data = 8'hef;
            for (j = 0; j < length; j = j + 1) begin
                @(negedge clk);
                tx_data = pattern(j, seed);
            end
            @(negedge clk);
            tx_valid = 0;
            tx_data = 0;
        end
    endtask

    reg rx_cfg = 0, rx_in = 0, rx_last = 0;
    reg [7:0] rx_byte = 0;
    reg [15:0] rx_cfg_vlid = 16'h1234;
    wire rx_valid, rx_drop;
    wire [7:0] rx_data;

    afdx_app_rx rx (
        clk, reset,
        rx_cfg, 12'd21, rx_cfg_vlid,
        rx_in, rx_byte, rx_last, 12'd21,
        rx_valid, rx_data, rx_drop
    );

    reg [7:0] expected_rx[0:99999];
    reg rx_end[0:99999];
    integer rx_expected = 0, rx_seen = 0;
    reg rx_was_valid = 0, rx_end_seen = 0;

    always @(posedge clk)
        if (!reset) begin
            check_credit(
                rx.reader.reserved, rx.reader.queued, rx.reader.pending,
                rx.reader.output_count, rx.reader.take_q
            );
            if (rx_drop)
                fail("RX rejected reserved message");
            if (rx_valid) begin
                if (rx_end_seen && rx_was_valid)
                    fail("RX did not separate message streams");
                if (rx_seen >= rx_expected)
                    fail("RX excess byte");
                else if (rx_data !== expected_rx[rx_seen])
                    fail("RX VLID/payload mismatch");
                rx_end_seen = rx_end[rx_seen];
                rx_seen = rx_seen + 1;
            end
            else if (rx_was_valid && !rx_end_seen)
                fail("RX bubble within message");
            rx_was_valid = rx_valid;
        end

    task rx_message;
        input integer length, seed;
        integer j;
        begin
            expected_rx[rx_expected] = 8'h12;
            rx_end[rx_expected] = 0;
            rx_expected = rx_expected + 1;
            expected_rx[rx_expected] = 8'h34;
            rx_end[rx_expected] = 0;
            rx_expected = rx_expected + 1;
            for (j = 0; j < length; j = j + 1) begin
                expected_rx[rx_expected] = pattern(j, seed);
                rx_end[rx_expected] = (j == length - 1);
                rx_expected = rx_expected + 1;
            end
            for (j = 0; j < length; j = j + 1) begin
                @(negedge clk);
                rx_in = 1;
                rx_last = (j == length - 1);
                rx_byte = pattern(j, seed);
            end
            @(negedge clk);
            rx_in = 0;
            rx_last = 0;
            // 匹配实际发送端的帧间服务裕量；每条消息内部的载荷仍保持每拍一字节。
            repeat (32) @(negedge clk);
        end
    endtask

    // 在相同有界激励下保持与 054632 基线公开时序轨迹一致。
    // 无效拍的数据/VL 不属于 valid-ready 协议；复位之外无条件比对 valid、last、input-ready 与 drop。
    integer equivalence_checks = 0;
`ifdef APP_COMPARE_054632
    wire old_tx_ready, old_tx_valid, old_tx_last;
    wire [7:0] old_tx_data;
    wire [6:0] old_tx_vl;
    wire [1:0] old_tx_drop;
    wire old_rx_valid, old_rx_drop;
    wire [7:0] old_rx_data;

    afdx_app_tx_054632 old_tx (
        clk, reset, 1'b1,
        tx_data, tx_valid, old_tx_ready,
        tx_cfg, tx_cfg_index, tx_cfg_vlid,
        old_tx_valid, tx_ready, old_tx_data, old_tx_last, old_tx_vl, old_tx_drop
    );

    afdx_app_rx_054632 old_rx (
        clk, reset,
        rx_cfg, 12'd21, rx_cfg_vlid,
        rx_in, rx_byte, rx_last, 12'd21,
        old_rx_valid, old_rx_data, old_rx_drop
    );

    always @(posedge clk)
        if (!reset) begin
            equivalence_checks = equivalence_checks + 1;
            if ({tx_in_ready, tx_valid_out, tx_last, tx_drop} !==
                {old_tx_ready, old_tx_valid, old_tx_last, old_tx_drop})
                fail("054632 TX public control changed cycle");
            if (tx_valid_out && {tx_vl, tx_out} !== {old_tx_vl, old_tx_data})
                fail("054632 TX valid data/VL changed cycle");
            if (tx.q_ready !== old_tx.q_ready)
                fail("054632 TX reader ownership changed cycle");
            if ({rx_valid, rx_drop} !== {old_rx_valid, old_rx_drop})
                fail("054632 RX public control changed cycle");
            if (rx_valid && rx_data !== old_rx_data)
                fail("054632 RX valid data changed cycle");
        end
`endif

    reg [5:0] tx_head_model = 0;
    reg cfg_restart_covered = 0, cfg_retire_busy_covered = 0;

    always @(posedge clk) begin
        if (reset)
            tx_head_model = 0;
        else begin
            command_checks = command_checks + 2;
            if (tx.reader.available !== (tx.reader.pointer != tx.committed))
                fail("predicted availability differs from published committed");
            if (tx.descriptor_head !== tx_head_model)
                fail("effective descriptor head skipped or retired twice");
            if (tx.q_valid && tx.q_ready && tx.q_data[8])
                tx_head_model = tx_head_model + 1'b1;
            if (tx.state == 6 && tx.configuration_busy)
                cfg_restart_covered = 1;
            if (tx.state == 5 && tx.descriptor_retire && tx.configuration_busy)
                cfg_retire_busy_covered = 1;
        end
    end

    // 在在途消息期间施加两次配置扰动：一次查表重启、
    // 一次末字节提取/下一描述符首部边界；写入值仍维持原已配置 VLID。
    initial begin
        wait (!reset);
        wait (tx.state == 6);
        @(negedge clk);
        tx_cfg = 1;
        tx_cfg_index = 7;
        tx_cfg_vlid = 16'hbeef;
        @(negedge clk);
        tx_cfg = 0;
        tx_cfg_index = 0;
        tx_cfg_vlid = 0;
        @(negedge clk);
        #1;
        while (!(tx_valid_out && tx_ready && tx_last)) begin
            @(negedge clk);
            #1;
        end
        tx_cfg = 1;
        tx_cfg_index = 7;
        tx_cfg_vlid = 16'hbeef;
        @(negedge clk);
        tx_cfg = 0;
        tx_cfg_index = 0;
        tx_cfg_vlid = 0;
    end

    integer j;
    reg direct_done = 0, tx_done = 0, rx_done = 0;

    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        p_reset = 0;
        // 允许读出前先写满全部地址。
        for (j = 0; j < 32768; j = j + 1) begin
            p_write = 1;
            p_address = j;
            p_wdata = {(j % 997) == 996, pattern(j, 3)};
            @(negedge clk);
        end
        p_write = 0;
        repeat (3) @(negedge clk);
        p_target = 32768;
        p_limit = 32768;
        p_reader_reset = 0;
        // 下游反压阻塞期间，等待所有在途读请求返回。
        repeat (100) @(negedge clk);
        command_checks = command_checks + 1;
        if (p_pointer !== 16'd8 || p_reader.reserved !== 4'd8 ||
            p_reader.queued + p_reader.output_count != 8)
            fail("prefetch did not share eight total credits across queue/output slots");
        for (j = 0; j < 3000; j = j + 1) begin
            p_ready = (j % 83 > 31) && (j % 5 != 0);
            @(negedge clk);
        end
        p_ready = 1;
        p_check_rate = 1;
        while (p_seen < 32768)
            @(negedge clk);
        p_check_rate = 0;
        p_started = 0;
        // 跨环形回绕边界写入；写操作生效前读出器不可见。
        p_ready = 0;
        for (j = 32768; j < 45113; j = j + 1) begin
            p_write = 1;
            p_address = j;
            p_wdata = {(j % 997) == 996, pattern(j, 3)};
            @(negedge clk);
        end
        p_write = 0;
        repeat (3) @(negedge clk);
        p_target = 45113;
        p_limit = 45113;
        repeat (30) @(negedge clk);
        p_ready = 1;
        p_check_rate = 1;
        while (p_seen < 45113)
            @(negedge clk);
        p_check_rate = 0;
        repeat (20) @(negedge clk);
        if (p_valid)
            fail("prefetch valid remained after limit");
        direct_done = 1;
    end

    initial begin
        wait (!reset);
        @(negedge clk);
        tx_cfg = 1;
        @(negedge clk);
        tx_cfg_index = 11;
        @(negedge clk);
        tx_cfg_index = 5;
        tx_cfg_vlid = 16'hcafe;
        @(negedge clk);
        tx_cfg = 0;
        tx_cfg_index = 0;
        tx_cfg_vlid = 0;
        command_checks = command_checks + 1;
        if (tx.enabled[7] !== 0)
            fail("TX configuration published before E3 retirement");
        @(negedge clk);
        command_checks = command_checks + 1;
        if (tx.enabled[7] !== 1 || tx.vlids[7] !== 16'hbeef || tx.enabled[11] !== 0)
            fail("TX first configuration command retirement mismatch");
        @(negedge clk);
        command_checks = command_checks + 1;
        if (tx.enabled[11] !== 1 || tx.vlids[11] !== 16'hbeef || tx.enabled[5] !== 0)
            fail("TX back-to-back configuration index/data misaligned");
        @(negedge clk);
        command_checks = command_checks + 1;
        if (tx.enabled[5] !== 1 || tx.vlids[5] !== 16'hcafe)
            fail("TX configuration used live fields after acceptance");
        // 失败消息的最后一次在途写入不得破坏紧随其后的短消息；超长消息绝不可被外部观测到。
        tx_message(8193, 5, 0);
        tx_message(1, 6, 1);
        tx_message(8192, 7, 1);
        tx_message(8192, 8, 1);
        tx_message(8192, 9, 1);
        tx_throttle = 1;
        tx_message(33, 10, 1);
        tx_message(8192, 11, 1);
        tx_message(3, 12, 1);
        tx_message(8192, 13, 1);
        tx_message(1, 14, 1);
        while (tx_seen < tx_expected)
            @(negedge clk);
        tx_throttle = 0;
        tx_ready = 1;
        tx_check_rate = 1;
        tx_message(8192, 15, 1);
        tx_message(2, 16, 1);
        while (tx_seen < tx_expected)
            @(negedge clk);
        repeat (30) @(negedge clk);
        if (tx_overflow != 1 || tx_miss != 0)
            fail("TX incorrect overflow/miss count");
        tx_done = 1;
    end

    initial begin
        wait (!reset);
        // 单字节消息与其映射表写命令同拍被接收；随后立即改写配置总线数据，
        // 证明本地旁路使用的是锁存后的配置命令而非后续总线值。
        expected_rx[rx_expected] = 8'h12;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = 8'h34;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = pattern(0, 29);
        rx_end[rx_expected] = 1;
        rx_expected = rx_expected + 1;
        @(negedge clk);
        rx_cfg = 1;
        rx_in = 1;
        rx_last = 1;
        rx_byte = pattern(0, 29);
        @(negedge clk);
        rx_cfg = 0;
        rx_cfg_vlid = 16'h5678;
        rx_in = 0;
        rx_last = 0;
        command_checks = command_checks + 1;
        if (rx.write_ptr !== 0 || rx.committed !== 0)
            fail("RX input capture allocated before local command");
        @(negedge clk);
        command_checks = command_checks + 1;
        if (rx.write_ptr !== 1 || rx.committed !== 0)
            fail("RX exposed byte before physical retirement");
        @(negedge clk);
        command_checks = command_checks + 1;
        if (rx.committed !== 1 || rx.dw !== 1)
            fail("RX payload/descriptor did not retire together");
        repeat (32) @(negedge clk);
        // 晚于该字节一拍接收的配置写不得向后前递到该描述符中：本事务应读出 1234。
        expected_rx[rx_expected] = 8'h12;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = 8'h34;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = pattern(0, 28);
        rx_end[rx_expected] = 1;
        rx_expected = rx_expected + 1;
        @(negedge clk);
        rx_in = 1;
        rx_last = 1;
        rx_byte = pattern(0, 28);
        @(negedge clk);
        rx_in = 0;
        rx_last = 0;
        rx_cfg = 1;
        rx_cfg_vlid = 16'h5678;
        @(negedge clk);
        rx_cfg = 0;
        rx_cfg_vlid = 0;
        repeat (32) @(negedge clk);
        // 早于该字节一拍接收的配置写必须已对该读操作可见，即便此时写总线上的实时值已改变。
        expected_rx[rx_expected] = 8'h9a;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = 8'hbc;
        rx_end[rx_expected] = 0;
        rx_expected = rx_expected + 1;
        expected_rx[rx_expected] = pattern(0, 27);
        rx_end[rx_expected] = 1;
        rx_expected = rx_expected + 1;
        @(negedge clk);
        rx_cfg = 1;
        rx_cfg_vlid = 16'h9abc;
        @(negedge clk);
        rx_cfg = 0;
        rx_cfg_vlid = 0;
        rx_in = 1;
        rx_last = 1;
        rx_byte = pattern(0, 27);
        @(negedge clk);
        rx_in = 0;
        rx_last = 0;
        repeat (32) @(negedge clk);
        // 继续执行原有的持续配置写入与长消息测试用例。
        rx_cfg = 1;
        rx_cfg_vlid = 16'h1234;
        rx_message(8192, 30);
        rx_cfg = 0;
        rx_message(1, 31);
        rx_message(8192, 32);
        rx_message(7, 33);
        rx_message(8192, 34);
        rx_message(8192, 35);
        rx_message(1, 36);
        rx_message(8192, 37);
        rx_message(3, 38);
        while (rx_seen < rx_expected)
            @(negedge clk);
        repeat (20) @(negedge clk);
        rx_done = 1;
    end

    initial begin
        wait (direct_done && tx_done && rx_done);
        if (p_continuous < 10000)
            fail("insufficient sustained transfer coverage");
        if (!cfg_restart_covered || !cfg_retire_busy_covered)
            fail("configuration restart/retirement boundary was not exercised");
        $display(
            "[COVERAGE] direct=%0d tx=%0d rx=%0d sustained=%0d rollback=%0d",
            p_seen, tx_seen, rx_seen, p_continuous, tx_overflow
        );
        $display(
            "[EQUIVALENCE] baseline=054632 cycles=%0d cfg_restart=%0d cfg_retire_busy=%0d",
            equivalence_checks, cfg_restart_covered, cfg_retire_busy_covered
        );
        $display(
            "[RESULT] tb_app_payload_pipeline %0s checks=%0d errors=%0d",
            errors == 0 ? "PASS" : "FAIL",
            p_seen + tx_seen + rx_seen + command_checks + equivalence_checks,
            errors
        );
        if (errors != 0)
            $fatal(1);
        $finish;
    end
endmodule
