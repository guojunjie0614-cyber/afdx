`timescale 1ns/1ps
module tb_t65_rx_data #(parameter T65_MUTANT=0);
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
            $display("[RESULT] tb_t65_rx_data %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);
            $finish;
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>20000000)begin check(0,"bounded test timeout");finish_test;end
    end
    initial fd=$fopen("t65_trace.txt","w");

    reg reset=1,cw=0,av=0,al=0;reg [7:0] ad=0;
    wire ov,drop;wire [7:0] od;
    afdx_app_rx dut(.clk(clk),.reset(reset),.cfg_write(cw),.cfg_index(12'd0),.cfg_vlid(16'h4000),
        .app_valid(av),.app_data(ad),.app_last(al),.app_index(12'd0),.valid(ov),.data(od),.drop(drop));
    integer current_n=0,current_tag=0,sent=0,expected=0,got=0,pos=0,drop_count=0,rejected=0;
    integer ns[0:16383],tags[0:16383];integer i,k,start_cycle=0;
    integer prev_used=0,prev_desc=0,max_used=0,max_desc=0,desc_reject=0,data_reject=0;
    reg ref_valid=0,ref_last=0,ref_active=0;
    integer ref_n=0,ref_tag=0,ref_sent=0;
    always @(posedge clk)begin
        if(reset)begin ref_valid<=0;ref_active<=0;end
        else begin
            ref_valid<=av;ref_last<=al;
            ref_n<=current_n;ref_tag<=current_tag;ref_sent<=sent;
            if(ref_valid)ref_active<=!ref_last;
        end
    end
    reg predicted_reject,was_valid=0;reg [7:0] captured[0:2047],expected_byte;
    always @(posedge clk)begin
        if(!reset)begin
            predicted_reject=prev_used>24575 || prev_desc>=30;
            if(ref_valid && !ref_active)begin
                check(dut.reject==predicted_reject,"RX registered admission threshold");
                $fwrite(fd,"J %0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,ref_n,ref_tag,ref_sent,
                    dut.reject,prev_used,prev_desc,dut.used);
                if(!predicted_reject)begin ns[expected]=ref_n;tags[expected]=ref_tag;expected=expected+1;end
                else begin
                    rejected=rejected+1;
                    if(prev_used>24575)data_reject=data_reject+1;
                    if(prev_desc>=30)desc_reject=desc_reject+1;
                end
            end
            if(dut.used>max_used)max_used=dut.used;
            if(dut.descriptors>max_desc)max_desc=dut.descriptors;
        end
        prev_used=dut.used;prev_desc=dut.descriptors;
        #1;
        if(!reset)begin
            if(drop)drop_count=drop_count+1;
            if(ov)begin
                if(pos==0)start_cycle=cycle;
                check(got<expected,"RX rejected message never appears");
                if(pos==0)expected_byte=8'h40;
                else if(pos==1)expected_byte=0;
                else expected_byte=tags[got]+pos-2;
                if(T65_MUTANT==1 && got==0 && pos==2)expected_byte=expected_byte^1;
                check(od==expected_byte,"RX VLID and payload exact");
                captured[pos]=od;pos=pos+1;
            end else if(was_valid)begin
                check(pos==ns[got]+2,"RX no half message or valid hole");
                $fwrite(fd,"M rx %0d %0d ",start_cycle,pos);
                for(k=0;k<pos;k=k+1)$fwrite(fd,"%02x",captured[k]);$fwrite(fd,"\n");
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
    task drain;
        begin
            @(negedge clk);av=0;al=0;ad=0;
            repeat(33768)@(negedge clk);
            check(got==expected && pos==0,"RX complete accepted sequence drains");
            check(dut.descriptors==0 && dut.write_ptr==dut.read_ptr,"RX storage and descriptors reclaimed");
            $fwrite(fd,"Q rx %0d %0d %0d\n",dut.write_ptr,dut.read_ptr,dut.descriptors);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset=0;cw=1;
        @(negedge clk);cw=0;repeat(5)@(negedge clk);

        i=0;
        while(data_reject==0 && i<10000)begin send(1471,i);i=i+1;end
        check(data_reject>0 && desc_reject==0,"data pressure isolated from descriptor pressure");

        drain;send(64,8'h90);drain;
        check(drop_count==rejected+(T65_MUTANT==2?1:0),"one drop per rejected complete message");
        $fwrite(fd,"E overflow %0d\nE max_used %0d\nE max_desc %0d\nE data_reject %0d\nE desc_reject %0d\n",drop_count,max_used,max_desc,data_reject,desc_reject);
        finish_test;
    end
endmodule
