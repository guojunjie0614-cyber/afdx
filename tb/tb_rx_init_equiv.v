`timescale 1ns/1ps
// 与固定 R5 逐拍比较：复位、全部 bank 清零、配置提交和对外初始化时刻。
module tb_rx_init_equiv #(parameter COPIES = 32);
    reg clk = 0, reset = 1;
    always #4 clk = !clk;
    reg cfg_map_write = 0, cfg_cfg_write = 0;
    reg [15:0] cfg_address = 0;
    reg [31:0] cfg_data = 0;
    wire [COPIES-1:0] cfg_ok_new;
    wire [31:0] cfg_ok_old;
    wire init_new, init_old;
    wire [84:0] outputs_new, outputs_old;
    integer cycle = 0, epoch = 0, errors = 0, checks = 0;
    integer rise_new = -1, rise_old = -1;
    reg was_new = 0, was_old = 0;
    // 新核只让目标 bank 所属副本写入，其余副本给出另一 bank 的干扰地址，映射错误即与 R5 不符。
    integer owner_copy = 0;
    wire [COPIES-1:0] owner_we;
    wire [COPIES*16-1:0] owner_address;
    wire [COPIES*32-1:0] owner_data;
    genvar copy;
    generate for (copy=0;copy<COPIES;copy=copy+1) begin : owner
        assign owner_we[copy] = cfg_map_write && copy == owner_copy;
        assign owner_address[copy*16 +: 16] = copy == owner_copy ? cfg_address : cfg_address ^ 16'h8040;
        assign owner_data[copy*32 +: 32] = copy == owner_copy ? cfg_data : 32'h00001fff;
    end endgenerate

    afdx_rx_core #(.CFG_COPIES(COPIES)) dut (
        .clk(clk),.reset(reset),.now_c(16'b0),
        .rx_data_a(8'b0),.rx_valid_a(1'b0),.rx_data_b(8'b0),.rx_valid_b(1'b0),
        .cfg_map_we(owner_we),.cfg_cfg_we(cfg_cfg_write),
        .cfg_addr(owner_address),.cfg_wdata(owner_data),
        .d_valid(outputs_new[84]),.d_data(outputs_new[83:76]),.d_last(outputs_new[75]),
        .d_vl(outputs_new[74:63]),.d_sport(outputs_new[62:47]),.d_dport(outputs_new[46:31]),
        .d_net(outputs_new[30]),.init_done(init_new),.cfg_ok(cfg_ok_new),
        .ev_a(outputs_new[29:22]),.ev_b(outputs_new[21:14]),
        .ev_rm_drop(outputs_new[13]),.ev_deliver(outputs_new[12]));
    assign outputs_new[11:0] = 0;
    afdx_rx_core_r5 #(.CFG_COPIES(32)) reference (
        .clk(clk),.reset(reset),.now_c(16'b0),
        .rx_data_a(8'b0),.rx_valid_a(1'b0),.rx_data_b(8'b0),.rx_valid_b(1'b0),
        .cfg_map_we({32{cfg_map_write}}),.cfg_cfg_we(cfg_cfg_write),
        .cfg_addr({32{cfg_address}}),.cfg_wdata({32{cfg_data}}),
        .d_valid(outputs_old[84]),.d_data(outputs_old[83:76]),.d_last(outputs_old[75]),
        .d_vl(outputs_old[74:63]),.d_sport(outputs_old[62:47]),.d_dport(outputs_old[46:31]),
        .d_net(outputs_old[30]),.init_done(init_old),.cfg_ok(cfg_ok_old),
        .ev_a(outputs_old[29:22]),.ev_b(outputs_old[21:14]),
        .ev_rm_drop(outputs_old[13]),.ev_deliver(outputs_old[12]));
    assign outputs_old[11:0] = 0;

    // 三十多个进程同拍调用；静态任务共享 condition，会漏记不一致。
    task automatic check;
        input condition;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                if (errors < 20) $display("INIT_EQUIV MISMATCH epoch=%0d cycle=%0d time=%0t",epoch,cycle,$time);
            end
        end
    endtask

    genvar bank;
    generate for (bank=0;bank<32;bank=bank+1) begin : monitor
        integer cleared_words = 0;
        integer word;
        reg memory_checked = 0;
        always @(posedge clk) begin
            if (reset) begin
                cleared_words = 0;
                memory_checked = 0;
            end
            else begin
                check(dut.map_bank[bank].memory.write_enable === reference.map_bank[bank].memory.write_enable);
                if (dut.map_bank[bank].memory.write_enable) begin
                    check(dut.map_bank[bank].memory.write_address === reference.map_bank[bank].memory.write_address);
                    check(dut.map_bank[bank].memory.write_data === reference.map_bank[bank].memory.write_data);
                    if (cleared_words < 2048) begin
                        check(dut.map_bank[bank].memory.write_address === cleared_words[10:0]);
                        check(dut.map_bank[bank].memory.write_data === 13'b0);
                        cleared_words = cleared_words + 1;
                    end
                end
                if (init_new && !memory_checked) begin
                    check(cleared_words == 2048);
                    for (word=0;word<2048;word=word+1)
                        check(dut.map_bank[bank].memory.memory[word] === 13'b0);
                    memory_checked = 1;
                end
            end
            #1;
            check(dut.map_bank[bank].cleared === reference.map_bank[bank].cleared);
        end
    end endgenerate

    integer bit_index;
    always @(posedge clk) begin
        cycle = cycle + 1;
        #1;
        check(init_new === init_old);
        check(outputs_new === outputs_old);
        for (bit_index=0;bit_index<COPIES;bit_index=bit_index+1)
            check(cfg_ok_new[bit_index] === cfg_ok_old[bit_index*(32/COPIES)]);
        if (reset) begin
            was_new = 0;was_old = 0;rise_new = -1;rise_old = -1;
        end
        else begin
            if (init_new && !was_new) begin
                rise_new = cycle;
                $display("INIT_EDGE new epoch=%0d cycle=%0d time_ns=%0t",epoch,cycle,$time);
            end
            if (init_old && !was_old) begin
                rise_old = cycle;
                $display("INIT_EDGE R5 epoch=%0d cycle=%0d time_ns=%0t",epoch,cycle,$time);
            end
            was_new = init_new;was_old = init_old;
        end
    end

    integer round_index, slot, timeout;
    initial begin
        $timeformat(-9,0," ns",0);
        // 第一轮在清零中途复位；后两轮完整初始化，并夹入配置写后再复位。
        for (round_index=1;round_index<=3;round_index=round_index+1) begin
            @(negedge clk);epoch=round_index;reset=1;cfg_map_write=0;
            repeat(3) @(negedge clk);
            reset=0;
            if (round_index==1) repeat(1000) @(negedge clk);
            else begin
                timeout=0;
                while (!init_new && timeout<70000) begin @(negedge clk);timeout=timeout+1;end
                check(timeout<70000);
                repeat(3) @(negedge clk);
                check(rise_new==rise_old && rise_new>=0);
                for (slot=0;slot<32;slot=slot+1) begin
                    timeout=0;
                    while (!(&cfg_ok_new) && timeout<1000) begin @(negedge clk);timeout=timeout+1;end
                    check(timeout<1000);
                    owner_copy=slot/(32/COPIES);
                    cfg_address=slot*2048+13;cfg_data=32'h00001000+slot;cfg_map_write=1;
                    @(negedge clk);cfg_map_write=0;
                    repeat(6) @(negedge clk);
                end
            end
        end
        repeat(5) @(negedge clk);
        if (errors==0) $display("INIT_EQUIV PASS copies=%0d checks=%0d errors=0",COPIES,checks);
        else $display("INIT_EQUIV FAIL copies=%0d checks=%0d errors=%0d",COPIES,checks,errors);
        $finish;
    end
endmodule
