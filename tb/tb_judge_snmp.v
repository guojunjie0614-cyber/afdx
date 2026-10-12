// 本测试通过两个完整端系统发送 SNMP（Simple Network Management Protocol，简单网络管理协议）报文。
// Get 读取端系统编号，GetNext 从前一个对象找到该编号，Set 修改该编号，Trap 报告启动事件。
// 测试自行构造请求并解码收到的字节，检查请求号、错误状态、对象编号和配置口读回值。
// 最后的 [RESULT] 必须为 PASS 且 errors=0；测试不读取输入文件。
`timescale 1ns/1ps
module tb_judge_snmp;
    reg clk = 0, reset = 1;
    always #4 clk = ~clk;
    wire [7:0] a12, b12, a21, b21;
    wire va12, vb12, va21, vb21, ready1, ready2;
    wire [31:0] checks1, checks2, errors1, errors2;
    integer cycle = 0, pos, cursor, i;
    integer outer_end, pdu_end, list_end, binding_end, start, finish;
    reg [31:0] number, register_value;
    // 对象编号依次是端系统编号、运行时间、通知对象和启动通知。
    localparam [87:0] USER_OID = 88'h2b0601040199f232030200;
    localparam [87:0] UPTIME_OID = 64'h2b06010201010300;
    localparam [87:0] TRAP_OID = 80'h2b060106030101040100;
    localparam [87:0] COLDSTART_OID = 72'h2b0601060301010501;

    judge_endpoint #(.ES(1)) manager (
        .clk(clk), .reset(reset), .ra(a21), .rb(b21), .rva(va21), .rvb(vb21),
        .ta(a12), .tb(b12), .tva(va12), .tvb(vb12), .ready(ready1), .checks(checks1), .errors(errors1)
    );
    judge_endpoint #(.ES(2)) agent (
        .clk(clk), .reset(reset), .ra(a12), .rb(b12), .rva(va12), .rvb(vb12),
        .ta(a21), .tb(b21), .tva(va21), .tvb(vb21), .ready(ready2), .checks(checks2), .errors(errors2)
    );
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (cycle > 4000000 || errors1 + errors2 > 20) begin
            $display("[RESULT] tb_judge_snmp FAIL checks=%0d errors=%0d",
                checks1 + checks2, errors1 + errors2 + 1);
            $finish;
        end
    end

    task put;
        input [7:0] value;
        begin manager.tx_bytes[pos] = value; pos = pos + 1; end
    endtask

    // 所有请求均使用 public 团体名和一个变量绑定，长度由实际字节数回填。
    task request;
        input [7:0] operation, object_number;
        input [15:0] request_id;
        integer pdu_length, list_length, binding_length, j;
        reg [87:0] oid;
        begin
            pos = 0;
            put(8'h30); put(0);
            put(2); put(1); put(1);
            put(4); put(6); put("p"); put("u"); put("b"); put("l"); put("i"); put("c");
            put(operation); pdu_length = pos; put(0);
            put(2); put(2); put(request_id[15:8]); put(request_id[7:0]);
            put(2); put(1); put(0); put(2); put(1); put(0);
            put(8'h30); list_length = pos; put(0);
            put(8'h30); binding_length = pos; put(0);
            oid = 88'h2b0601040199f232030000 | (object_number << 8);
            put(6); put(11);
            for (j = 10; j >= 0; j = j - 1) put(oid >> (j*8));
            if (operation == 8'ha3) begin put(8'h42); put(2); put(8'h34); put(8'h56); end
            else begin put(5); put(0); end
            manager.tx_bytes[1] = pos - 2;
            manager.tx_bytes[pdu_length] = pos - pdu_length - 1;
            manager.tx_bytes[list_length] = pos - list_length - 1;
            manager.tx_bytes[binding_length] = pos - binding_length - 1;
            manager.send_packet(0, pos, 41000, 161);
        end
    endtask

    // BER（Basic Encoding Rules，基本编码规则）用类型、长度和值描述字段。
    // 此任务只读字段头；外层按各字段的结束位置检查嵌套边界。
    task field;
        input [7:0] tag;
        output integer first, last;
        integer count, length, j;
        begin
            manager.check(cursor + 2 <= manager.rx_length, "BER field header is within message");
            manager.check(manager.rx_bytes[cursor] === tag, "BER field type");
            cursor = cursor + 1;
            length = manager.rx_bytes[cursor]; cursor = cursor + 1;
            if (length >= 128) begin
                count = length - 128; length = 0;
                manager.check(count >= 1 && count <= 2, "bounded definite BER length");
                for (j = 0; j < count && j < 2; j = j + 1) begin
                    length = length*256 + manager.rx_bytes[cursor]; cursor = cursor + 1;
                end
            end
            first = cursor; last = cursor + length;
            manager.check(last <= manager.rx_length, "BER field body is within message");
        end
    endtask

    task integer_value;
        input [7:0] tag;
        output [31:0] value;
        integer first, last, j;
        begin
            field(tag, first, last);
            manager.check(last > first && last - first <= 5, "bounded integer length");
            value = 0;
            for (j = first; j < last && j < manager.rx_length; j = j + 1)
                value = (value << 8) | manager.rx_bytes[j];
            cursor = last;
        end
    endtask

    task object_id;
        input [87:0] expected;
        input integer length;
        integer first, last, j;
        reg [7:0] expected_byte;
        begin
            field(6, first, last);
            manager.check(last - first == length, "object identifier length");
            for (j = 0; j < length; j = j + 1) begin
                expected_byte = expected >> ((length - j - 1)*8);
                manager.check(manager.rx_bytes[first + j] === expected_byte, "object identifier byte");
            end
            cursor = last;
        end
    endtask

    task envelope;
        input integer count;
        input [7:0] pdu;
        input [31:0] request_id;
        reg [47:0] community;
        begin
            manager.wait_message(count);
            manager.check(manager.rx_vl == 2 && manager.rx_sport == 161 &&
                manager.rx_dport == (pdu == 8'ha7 ? 162 : 41000), "SNMP UDP ports and receive index");
            cursor = 0;
            field(8'h30, start, outer_end);
            manager.check(outer_end == manager.rx_length, "outer BER length");
            integer_value(2, number); manager.check(number == 1, "SNMP version 2c");
            field(4, start, finish);
            manager.check(finish - start == 6, "community length");
            community = 0;
            for (i = start; i < finish && i < manager.rx_length; i = i + 1)
                community = (community << 8) | manager.rx_bytes[i];
            manager.check(community == "public", "community matches request"); cursor = finish;
            field(pdu, start, pdu_end); manager.check(pdu_end == outer_end, "PDU end");
            integer_value(2, number); manager.check(number == request_id, "request ID");
            integer_value(2, number); manager.check(number == 0, "error status is zero");
            integer_value(2, number); manager.check(number == 0, "error index is zero");
            field(8'h30, start, list_end); manager.check(list_end == pdu_end, "binding list end");
            field(8'h30, start, binding_end);
        end
    endtask

    task response;
        input integer count;
        input [31:0] request_id;
        begin
            envelope(count, 8'ha2, request_id);
            object_id(USER_OID, 11);
            integer_value(8'h42, number);
            agent.read_cfg(2, register_value);
            manager.check(number == register_value, "returned value equals configuration register");
            manager.check(cursor == binding_end && binding_end == list_end, "exactly one complete binding");
            $display("[SNMP_RESPONSE] request_id=%0d error=0 returned=%0d cfg=%0d",
                request_id, number, register_value);
        end
    endtask

    initial begin
        repeat (8) @(negedge clk); reset = 0;
        wait (ready1 && ready2);
        manager.configure_tx(0, 100, 256); agent.configure_rx(0, 100, 256);
        agent.configure_tx(2, 202, 256); manager.configure_rx(2, 202, 256);
        agent.write_cfg(2, 16'h2345);
        agent.write_cfg(18'h91, 2); agent.write_cfg(18'h90, 1);
        request(8'ha0, 2, 1001); response(1, 1001);
        manager.check(number == 16'h2345, "Get reads initial identifier");
        request(8'ha1, 1, 1002); response(2, 1002);
        manager.check(number == 16'h2345, "GetNext selects the following object");
        request(8'ha3, 2, 1003); response(3, 1003);
        manager.check(number == 16'h3456, "Set changes identifier");
        // 等运行时间非零后启用通知，Trap 的时间值也必须与配置口一致。
        while (cycle < 1400000) @(negedge clk);
        agent.write_cfg(18'h90, 0); agent.write_cfg(18'h9b, 1); agent.write_cfg(18'h90, 1);
        // Trap 是主动通知，没有待回显的请求号；本实现的通知请求号为零。
        envelope(4, 8'ha7, 0);
        object_id(UPTIME_OID, 8); integer_value(8'h43, number);
        agent.read_cfg(18'h98, register_value);
        manager.check(number > 0 && number == register_value, "Trap uptime equals configuration register");
        manager.check(cursor == binding_end, "Trap first binding end");
        field(8'h30, start, binding_end);
        object_id(TRAP_OID, 10); object_id(COLDSTART_OID, 9);
        manager.check(cursor == binding_end && binding_end == list_end, "two complete Trap bindings");
        agent.read_cfg(18'h9c, register_value);
        manager.check(register_value == 1, "one Trap reported by configuration counter");
        repeat (1000) @(negedge clk);
        manager.check(manager.received == 4 && agent.received == 0, "no extra response or leaked service message");
        manager.check(manager.duplicates == 4 && agent.duplicates == 3, "both networks deliver once per message");
        $display("[SNMP_SUMMARY] Get=1 GetNext=1 Set=1 Trap=1 request_id=PASS error_status=0 register_values=PASS");
        $display("[RESULT] tb_judge_snmp %0s checks=%0d errors=%0d",
            errors1 + errors2 == 0 ? "PASS" : "FAIL", checks1 + checks2, errors1 + errors2);
        $finish;
    end
endmodule
