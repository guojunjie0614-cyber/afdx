`timescale 1ns/1ps
// 字节和时刻的期望从慢线端口独立记录，不读适配器内部状态。
module tb_gmii_tx;
    localparam EXPECTED_DELAY=10688;
    reg clk=0;
    always #4 clk=~clk;
    reg reset=1,slow_valid=0;
    reg [7:0] slow_data=0;
    wire [7:0] tx_data;
    wire tx_valid;
    afdx_gmii_tx dut(clk,reset,slow_data,slow_valid,tx_data,tx_valid);

    reg [7:0] bytes_expected[0:262143];
    integer frame_start[0:2047],frame_length[0:2047],frame_offset[0:2047];
    reg frame_done[0:2047];
    integer cycle=0,checks=0,errors=0,head=0,tail=0,bytes_stored=0,current_input=0;
    integer input_cycles=0,output_bytes=0,last_end=-100000;
    integer completed_inputs=0,completed_outputs=0,discarded_complete=0,resets_in_output=0;
    integer i,j,n,seed=20261008,deadline;
    reg was_reset=0,input_seen=0,output_seen=0;

    task check;
        input ok;
        input [8*96-1:0] label;
        begin
            checks=checks+1;
            if(ok!==1'b1)begin
                errors=errors+1;
                if(errors<30)$display("[FAIL] tb_gmii_tx cycle=%0d %0s",cycle,label);
            end
        end
    endtask

    function [7:0] pattern;
        input integer identity,position;
        begin pattern=(identity*37+position*13+(position>>3))&255;end
    endfunction

    always @(posedge clk)begin
        cycle=cycle+1;
        if(reset)begin
            if(!was_reset)begin
                if(output_seen)resets_in_output=resets_in_output+1;
                for(j=head;j<tail;j=j+1)
                    if(frame_done[j])discarded_complete=discarded_complete+1;
                head=tail;
            end
            if(was_reset)check(!tx_valid && tx_data==0,"reset suppresses GMII outputs");
            input_seen=0;output_seen=0;input_cycles=0;output_bytes=0;last_end=-100000;
        end else begin
            if(slow_valid)begin
                if(!input_seen)begin
                    current_input=tail;
                    frame_start[tail]=cycle;
                    frame_length[tail]=0;
                    frame_offset[tail]=bytes_stored;
                    frame_done[tail]=0;
                    tail=tail+1;
                    input_cycles=0;
                    input_seen=1;
                end
                if(input_cycles%8==0)begin
                    bytes_expected[bytes_stored]=slow_data;
                    bytes_stored=bytes_stored+1;
                    frame_length[current_input]=frame_length[current_input]+1;
                end else check(slow_data===bytes_expected[bytes_stored-1],"input byte lasts eight cycles");
                input_cycles=input_cycles+1;
            end else if(input_seen)begin
                check(input_cycles%8==0,"input frame ends on a byte boundary");
                frame_done[current_input]=1;
                completed_inputs=completed_inputs+1;
                input_seen=0;
            end
            if(head<tail && cycle==frame_start[head]+EXPECTED_DELAY)
                check(tx_valid,"frame starts on scheduled S+D cycle");
            if(tx_valid)begin
                if(!output_seen)begin
                    check(head<tail,"GMII frame has an input frame");
                    check(cycle==frame_start[head]+EXPECTED_DELAY,"fixed delay for every frame");
                    check(cycle-last_end>=96,"GMII interframe gap at least 96 cycles");
                    output_seen=1;output_bytes=0;
                end
                check(output_bytes<frame_length[head],"output never reads before input byte exists");
                check(tx_data===bytes_expected[frame_offset[head]+output_bytes],"GMII byte matches slow input");
                output_bytes=output_bytes+1;
            end else if(output_seen)begin
                check(frame_done[head] && output_bytes==frame_length[head],"complete contiguous frame, including final byte");
                completed_outputs=completed_outputs+1;
                output_seen=0;head=head+1;last_end=cycle;
            end else check(tx_data==0,"inactive output data is zero");
        end
        was_reset=reset;
        if(errors>50 || cycle>2000000)begin
            $display("[RESULT] tb_gmii_tx FAIL checks=%0d errors=%0d",checks,errors+1);$finish;
        end
    end

    task tick;
        begin @(posedge clk);#1;end
    endtask

    task send_frame;
        input integer length,identity;
        integer index;
        begin
            @(negedge clk);slow_valid=1;
            for(index=0;index<length;index=index+1)begin
                slow_data=pattern(identity,index);
                repeat(8)tick;
            end
            slow_valid=0;
            repeat(96)tick;
        end
    endtask

    task drain;
        integer stop_cycle;
        begin:wait_empty
            stop_cycle=cycle+EXPECTED_DELAY+20000;
            while(head<tail || output_seen || tx_valid)begin
                tick;
                if(cycle>stop_cycle)begin check(0,"scheduled queue drains");disable wait_empty;end
            end
            repeat(96)tick;
        end
    endtask

    task abort_frame;
        input integer identity,cut_cycles,expect_active;
        integer index;
        begin
            @(negedge clk);slow_valid=1;
            for(index=0;index<cut_cycles;index=index+1)begin
                slow_data=pattern(identity,index/8);
                tick;
            end
            if(expect_active)check(tx_valid,"reset test interrupts active GMII frame");
            else check(!tx_valid,"reset test interrupts only queued slow data");
            @(negedge clk);reset=1;slow_valid=0;
            repeat(4)tick;
            @(negedge clk);reset=0;
        end
    endtask

    initial begin
        repeat(4)tick;
        @(negedge clk);reset=0;
        // 最短帧连续32次，明确覆盖 D 窗口内16项描述和数据地址回绕。
        for(i=0;i<32;i=i+1)send_frame(72,i);
        send_frame(73,40);
        send_frame(1526,41);
        for(i=0;i<32;i=i+1)begin
            seed=(seed*1103515245+12345)&32'h7fffffff;
            n=72+seed%1455;
            send_frame(n,50+i);
        end
        drain;
        check(completed_outputs==66,"normal matrix has 66 complete frames");

        send_frame(72,100);
        abort_frame(101,800,0);
        send_frame(73,102);
        send_frame(1526,103);
        drain;

        abort_frame(110,EXPECTED_DELAY+40,1);
        send_frame(72,111);
        send_frame(1526,112);
        send_frame(73,113);
        drain;
        check(completed_outputs==71,"complete frame count after reset recovery");
        check(completed_inputs-discarded_complete==completed_outputs,"only reset-discarded frames are missing");
        check(discarded_complete==1 && resets_in_output==1,"both queued and transmitting reset cases covered");
        $display("[COVERAGE] delay=%0d depth=2048 pending=16 prefetch=4 outputs=%0d reset_discarded=%0d",EXPECTED_DELAY,completed_outputs,discarded_complete);
        $display("[RESULT] tb_gmii_tx %0s checks=%0d errors=%0d",errors==0 ? "PASS" : "FAIL",checks,errors);
        $finish;
    end
endmodule
