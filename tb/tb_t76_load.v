`timescale 1ns/1ps
// Each run is independent. Long runs require the line-1 confirmation gate.
module tb_t76_load #(
    parameter VL_COUNT=81,GROUP_LENGTH=1471,MIXED=0,DUPLEX=1,
    DURATION=12500000,SMOKE=0,SWAP=0,BAG_BURST=0,LONG_COUNT=1
);
    reg clk=0,reset=1;
    always #4 clk=~clk;
    wire [7:0] a0,b0,a1,b1;
    wire av0,bv0,av1,bv1,c0,c1;
    t76_load_endpoint #(0,VL_COUNT,GROUP_LENGTH,MIXED,SWAP,LONG_COUNT) ep0(clk,reset,a1,b1,av1,bv1,a0,b0,av0,bv0,c0);
    t76_load_endpoint #(1,VL_COUNT,GROUP_LENGTH,MIXED,!SWAP,LONG_COUNT) ep1(clk,reset,a0,b0,av0,bv0,a1,b1,av1,bv1,c1);
    integer epoch,fd,cycles=0;
    // Mode 2 changes only the order among equally due VLs. Three adjacent
    // VLs rotate each round; message lengths, counts and due times are fixed.
    function integer tie_rank;
        input integer vl,planned;
        integer round_number,base;
        begin
            round_number=(planned-epoch)/250000;base=(vl/3)*3;
            tie_rank=base+(vl-base+round_number)%3;
        end
    endfunction
    task source0;
        integer due[0:127],seq[0:127];integer i,selected,next,n,fragments;
        begin:traffic
            for(i=0;i<VL_COUNT;i=i+1)begin due[i]=epoch;seq[i]=0;end
            while(1)begin
                selected=0;next=due[0];
                for(i=1;i<VL_COUNT;i=i+1)if(due[i]<next ||
                    (BAG_BURST==2 && due[i]==next && tie_rank(i,due[i])<tie_rank(selected,next)))begin selected=i;next=due[i];end
                if(next>=epoch+DURATION)disable traffic;
                while(ep0.cycle<next)@(negedge clk);
                n=ep0.message_length(selected,seq[selected]);
                ep0.send_message(selected,n,seq[selected],next);
                fragments=n<=1471 ? 1 : (n+8+1471)/1472;
                if(BAG_BURST)begin
                    ep0.send_message(selected,n,seq[selected]+1,next);
                    due[selected]=due[selected]+250000;seq[selected]=seq[selected]+2;
                end else begin
                    due[selected]=due[selected]+fragments*125000;seq[selected]=seq[selected]+1;
                end
            end
        end
    endtask
    task source1;
        integer due[0:127],seq[0:127];integer i,selected,next,n,fragments;
        begin:traffic
            if(!DUPLEX)disable traffic;
            for(i=0;i<VL_COUNT;i=i+1)begin due[i]=epoch;seq[i]=0;end
            while(1)begin
                selected=0;next=due[0];
                for(i=1;i<VL_COUNT;i=i+1)if(due[i]<next ||
                    (BAG_BURST==2 && due[i]==next && tie_rank(i,due[i])<tie_rank(selected,next)))begin selected=i;next=due[i];end
                if(next>=epoch+DURATION)disable traffic;
                while(ep1.cycle<next)@(negedge clk);
                n=ep1.message_length(selected,seq[selected]);
                ep1.send_message(selected,n,seq[selected],next);
                fragments=n<=1471 ? 1 : (n+8+1471)/1472;
                if(BAG_BURST)begin
                    ep1.send_message(selected,n,seq[selected]+1,next);
                    due[selected]=due[selected]+250000;seq[selected]=seq[selected]+2;
                end else begin
                    due[selected]=due[selected]+fragments*125000;seq[selected]=seq[selected]+1;
                end
            end
        end
    endtask
    always @(negedge clk)begin
        cycles=cycles+1;
        if(cycles>DURATION+2000000)$fatal(1,"T76 bounded simulation cycle timeout");
    end
    initial begin
        if(!SMOKE && DURATION<12500000)$display("[T76_WINDOW] short netlist window, not 100ms RTL acceptance");
        fd=$fopen("window.txt","w");
        repeat(8)@(negedge clk);reset=0;
        wait(c0 && c1);@(negedge clk);epoch=ep0.cycle+16;
        if(MIXED==3)$fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d %0d\n",epoch,epoch+DURATION,VL_COUNT,GROUP_LENGTH,MIXED,DUPLEX,BAG_BURST,LONG_COUNT);
        else $fwrite(fd,"%0d %0d %0d %0d %0d %0d %0d\n",epoch,epoch+DURATION,VL_COUNT,GROUP_LENGTH,MIXED,DUPLEX,BAG_BURST);$fclose(fd);
        fork source0;source1;join
        while(ep0.cycle<epoch+DURATION || ep1.received<ep0.sent || ep0.received<ep1.sent)@(negedge clk);
        repeat(SMOKE ? 64 : 20000)@(negedge clk);
        if(ep1.received!=ep0.sent || ep0.received!=ep1.sent ||
           ep1.duplicates<ep0.sent || ep0.duplicates<ep1.sent)
            $fatal(1,"T76 exact delivery count mismatch");
        $display("[T76_COUNTS] sent0=%0d received1=%0d sent1=%0d received0=%0d x_cycles0=%0d x_cycles1=%0d",ep0.sent,ep1.received,ep1.sent,ep0.received,ep0.x_checked,ep1.x_checked);
        $display("[RESULT] tb_t76_load PASS checks=%0d errors=0",ep0.sent+ep1.sent);$finish;
    end
endmodule
