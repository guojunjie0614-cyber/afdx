`timescale 1ns/1ps
module tb_t65_rx_desc #(parameter T65_MUTANT=0);
    localparam DATA_CAPACITY=32768, DATA_ADMIT_LIMIT=24575, DESC_ADMIT_LIMIT=30;
    localparam MAX_INPUTS=2048, MAX_MESSAGE=8192, MAX_CYCLES=2000000;
    reg clk=0; always #4 clk=~clk;
    integer cycle=0,checks=0,errors=0,fd;
    task check; input ok; input [8*120-1:0] label;
        begin
            checks=checks+1;
            if(ok!==1'b1)begin errors=errors+1;
                if(errors<40)$display("[FAIL] cycle=%0d %0s",cycle,label);
            end
        end
    endtask
    task finish_test;
        begin
            $fflush(fd);$fclose(fd);
            $display("[RESULT] tb_t65_rx_desc %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);
            $finish;
        end
    endtask
    initial fd=$fopen("t65_trace.txt","w");

    reg reset=1,cw=0,av=0,al=0;reg [7:0] ad=0;
    wire ov,drop;wire [7:0] od;
    afdx_app_rx dut(.clk(clk),.reset(reset),.cfg_write(cw),.cfg_index(12'd0),.cfg_vlid(16'h4000),
        .app_valid(av),.app_data(ad),.app_last(al),.app_index(12'd0),.valid(ov),.data(od),.drop(drop));
    integer current_n=0,current_tag=0,sent=0,expected=0,got=0,pos=0,drop_count=0,rejected=0;
    integer ns[0:MAX_INPUTS-1],tags[0:MAX_INPUTS-1];integer i,k,start_cycle=0;
    integer prev_used=0,prev_desc=0,max_used=0,max_desc=0,desc_reject=0,data_reject=0;
    integer input_n_q=0,input_tag_q=0,input_serial_q=0,admissions=0,model_write_ptr=0;
    reg input_valid_q=0,input_last_q=0,host_active=0,host_discard=0;
    reg predicted_reject,was_valid=0;reg [7:0] captured[0:MAX_MESSAGE+1],expected_byte;
    // Host-owned input boundaries and metadata follow the public one-clock
    // capture stage. Neither DUT active nor observed output selects golden.
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>MAX_CYCLES)begin check(0,"bounded test timeout");finish_test;end
        if(reset)begin
            input_valid_q=0;input_last_q=0;host_active=0;host_discard=0;
            prev_used=0;prev_desc=0;model_write_ptr=0;
        end else begin
            predicted_reject=prev_used>DATA_ADMIT_LIMIT || prev_desc>=DESC_ADMIT_LIMIT;
            if(input_valid_q)begin
                if(!host_active)begin
                    admissions=admissions+1;host_discard=predicted_reject;
                    check(dut.reject==predicted_reject,"RX registered admission threshold");
                    $fwrite(fd,"J %0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,input_n_q,input_tag_q,input_serial_q,
                        dut.reject,prev_used,prev_desc,dut.used);
                    if(!predicted_reject)begin
                        check(expected<MAX_INPUTS,"RX host ledger capacity");
                        if(expected<MAX_INPUTS)begin ns[expected]=input_n_q;tags[expected]=input_tag_q;end
                        expected=expected+1;
                    end else begin
                        rejected=rejected+1;
                        if(prev_used>DATA_ADMIT_LIMIT)data_reject=data_reject+1;
                        if(prev_desc>=DESC_ADMIT_LIMIT)desc_reject=desc_reject+1;
                    end
                end
                if(!host_discard)model_write_ptr=(model_write_ptr+1)&65535;
                host_active=!input_last_q;
            end
            prev_used=dut.used;prev_desc=dut.descriptors;
            if(dut.used>max_used)max_used=dut.used;
            if(dut.descriptors>max_desc)max_desc=dut.descriptors;
            input_valid_q=av;input_last_q=al;
            input_n_q=current_n;input_tag_q=current_tag;input_serial_q=sent;
        end
        #1;
        if(!reset)begin
            check(dut.write_ptr==model_write_ptr[15:0],"RX only admitted source bytes allocate storage");
            check(dut.used<=DATA_CAPACITY && dut.descriptors<=32,"RX bounded physical capacities");
            if(drop)drop_count=drop_count+1;
            if(ov)begin
                if(pos==0)start_cycle=cycle;
                check(got<expected && got<MAX_INPUTS,"RX rejected message never appears");
                if(got<expected && got<MAX_INPUTS)begin
                    check(pos<ns[got]+2,"RX accepted message has no extra byte");
                    if(pos==0)expected_byte=8'h40;
                    else if(pos==1)expected_byte=0;
                    else expected_byte=tags[got]+pos-2;
                    if(T65_MUTANT==1 && got==0 && pos==2)expected_byte=expected_byte^1;
                    check(od==expected_byte,"RX VLID and payload exact");
                end
                check(pos<MAX_MESSAGE+2,"RX output capture capacity");
                if(pos<MAX_MESSAGE+2)captured[pos]=od;
                pos=pos+1;
            end else if(was_valid)begin
                if(got<expected && got<MAX_INPUTS)check(pos==ns[got]+2,"RX no half message or valid hole");
                $fwrite(fd,"M rx %0d %0d ",start_cycle,pos);
                for(k=0;k<pos && k<MAX_MESSAGE+2;k=k+1)$fwrite(fd,"%02x",captured[k]);$fwrite(fd,"\n");
                got=got+1;pos=0;
            end
            was_valid=ov;
        end
    end
    task send;input integer n,tag;integer b;
        begin
            for(b=0;b<n;b=b+1)begin
                @(negedge clk);av=1;ad=tag+b;al=b==n-1;
                if(b==0)begin current_n=n;current_tag=tag;sent=sent+1;end
            end
        end
    endtask
    task drain;integer wait_cycles;
        begin
            @(negedge clk);av=0;al=0;ad=0;
            repeat(4)@(negedge clk);
            wait_cycles=0;
            while((got!=expected || pos!=0 || dut.descriptors!=0 || dut.write_ptr!=dut.read_ptr) && wait_cycles<40000)begin
                @(negedge clk);wait_cycles=wait_cycles+1;
            end
            repeat(32)@(negedge clk);
            check(admissions==sent && !input_valid_q && !host_active,"RX every public input accounted once");
            check(expected+rejected==sent,"RX host admission conservation");
            check(got==expected && pos==0,"RX complete accepted sequence drains");
            check(drop_count==rejected,"RX one drop for each rejected source message");
            check(dut.descriptors==0 && dut.write_ptr==dut.read_ptr,"RX storage and descriptors reclaimed");
            $fwrite(fd,"Q rx %0d %0d %0d\n",dut.write_ptr,dut.read_ptr,dut.descriptors);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset=0;cw=1;
        @(negedge clk);cw=0;repeat(5)@(negedge clk);

        for(i=0;i<150;i=i+1)send(1,i);
        send(8,8'he0);
        check(desc_reject>0 && data_reject==0,"descriptor pressure isolated from data pressure");
        check(max_desc>=DESC_ADMIT_LIMIT && max_desc<=32,"RX descriptor pressure reaches actual admission boundary");
        check(max_used<=DATA_ADMIT_LIMIT,"RX descriptor exhaustion precedes data threshold");

        drain;send(64,8'h90);drain;
        check(drop_count==rejected+(T65_MUTANT==2?1:0),"one drop per rejected complete message");
        $fwrite(fd,"E overflow %0d\nE max_used %0d\nE max_desc %0d\nE data_reject %0d\nE desc_reject %0d\nE sent %0d\nE accepted %0d\nE data_capacity %0d\nE data_limit %0d\nE desc_limit %0d\n",drop_count,max_used,max_desc,data_reject,desc_reject,sent,expected,DATA_CAPACITY,DATA_ADMIT_LIMIT,DESC_ADMIT_LIMIT);
        finish_test;
    end
endmodule
