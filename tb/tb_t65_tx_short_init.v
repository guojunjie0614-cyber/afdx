`timescale 1ns/1ps
module tb_t65_tx_short_init #(parameter T65_MUTANT=0);
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
            $display("[RESULT] tb_t65_tx_short_init %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);
            $finish;
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>2000000)begin check(0,"bounded test timeout");finish_test;end
    end
    initial fd=$fopen("t65_trace.txt","w");

    reg reset=1,tv=0,cw=0;reg [7:0] td=0;
    reg [17:0] ca=0;reg [31:0] cd=0;
    wire ready,ok,av,bv;wire [7:0] ad,bd;wire [2:0] ev;
    AFDX_top dut(.clk(clk),.reset(reset),.tx_data(td),.tx_valid(tv),.tx_ready(ready),
        .rx_data(),.rx_valid(),.rx_ready(1'b0),.gmii_txd_a(ad),.gmii_tx_en_a(av),
        .gmii_txd_b(bd),.gmii_tx_en_b(bv),.gmii_rxd_a(8'd0),.gmii_rx_dv_a(1'b0),
        .gmii_rxd_b(8'd0),.gmii_rx_dv_b(1'b0),.cfg_wr(cw),.cfg_rd(1'b0),.cfg_addr(ca),
        .cfg_wdata(cd),.cfg_ready(ok),.cfg_rdata(),.cfg_rvalid(),.ev_tx(),.ev_a(),.ev_b(),
        .ev_rm_drop(),.ev_deliver(),.ev_app(ev));
    integer sent=0,expected=0,got=0,pos=0,miss=0,full=0,exp_full=0,exp_miss=0;
    integer current_n=0,current_id=0,current_tag=0,current_policy=0;
    integer ns[0:1023],tags[0:1023],ids[0:1023];
    integer max_used=0,max_desc=0,max_count=0,wire_frames=0;
    integer i,k,wpos=0,wstart=0,start_cycle=0,optional_last=0,observation_mode=0;
    integer two_full=0,two_miss=0;
    reg [7:0] bytes[0:4095],wbytes[0:2047];reg wav=0;
    reg admission_ready;
    reg public_ready=0,public_valid=0;
    always @(posedge clk)begin
        if(reset)begin public_valid<=0;public_ready<=0;end
        else begin
            if(tv && !public_valid)public_ready<=ready;
            public_valid<=tv;
        end
    end
    // First-byte admission is sampled before the sequential RTL update.
    // policy 1 is the deliberately overlength/space-exhausting input;
    // policy 2 is observation-only input sent after ready has fallen.
    always @(posedge clk)begin
        admission_ready=dut.initialized && dut.application_tx.used<=24576 && dut.application_tx.descriptors<31;
        if(!reset && dut.application_tx.vq && !dut.application_tx.active)begin
            $fwrite(fd,"I %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,current_n,current_id,current_tag,
                dut.initialized,dut.application_tx.descriptors,dut.application_tx.used,public_ready,current_policy,sent);
            if(current_n>=3 && current_policy!=1 && dut.initialized && dut.application_tx.descriptors<32)begin
                ns[expected]=current_n-2;tags[expected]=current_tag;ids[expected]=current_id;expected=expected+1;
            end
            if(current_n>=2)begin
                if(current_policy==1 || !dut.initialized || dut.application_tx.descriptors==32)exp_full=exp_full+1;
                else if(current_n==2 || current_id!=16'h4000)exp_miss=exp_miss+1;
            end
        end
        #1;
        if(!reset)begin
            check(ready==admission_ready,"ready registers exact conservative admission predicate");
            if(ev[0])miss=miss+1;
            if(ev[1])full=full+1;
            if(dut.application_tx.used>max_used)max_used=dut.application_tx.used;
            if(dut.application_tx.descriptors>max_desc)max_desc=dut.application_tx.descriptors;
            if(dut.application_tx.count>max_count)max_count=dut.application_tx.count;
            check(dut.application_tx.descriptors<=32,"descriptor capacity never exceeded");
            if(dut.m_valid && dut.m_ready)begin
                if(pos==0)start_cycle=cycle;
                // The handshake at the following edge uses these settled values.
            end
        end
    end
    // Consumer capture at the active edge, before NBA, matches the real handshake.
    always @(posedge clk)begin
        if(!reset && dut.m_valid && dut.m_ready)begin
            if(!observation_mode)check(got<expected,"no partial or unexpected application message");
            if(got<expected || observation_mode)begin
                if(!observation_mode)begin
                    check(dut.m_data==((tags[got]+pos+(T65_MUTANT==1 && got==0 && pos==0?1:0))&255),"TX consumer payload exact");
                    check(dut.m_vl==0,"TX selected VL index");
                end
                bytes[pos]=dut.m_data;pos=pos+1;
                if(!observation_mode)check(dut.m_last==(pos==ns[got]),"TX complete message boundary");
                if(dut.m_last)begin
                    $fwrite(fd,"M core %0d %0d ",cycle,pos);
                    for(k=0;k<pos;k=k+1)$fwrite(fd,"%02x",bytes[k]);$fwrite(fd,"\n");
                    got=got+1;pos=0;
                end
            end
        end
        if(!reset)begin
            if(av)begin
                if(!wav)wstart=cycle;
                wbytes[wpos]=ad;wpos=wpos+1;
            end else if(wav)begin
                $fwrite(fd,"M wire %0d %0d ",wstart,wpos);
                for(k=0;k<wpos;k=k+1)$fwrite(fd,"%02x",wbytes[k]);$fwrite(fd,"\n");
                wire_frames=wire_frames+1;wpos=0;
            end
            check(!bv,"B is disabled in fixed TX configuration");wav=av;
        end
    end
    task config_word;input integer address,value;
        begin
            @(negedge clk);while(!ok)@(negedge clk);ca=address;cd=value;cw=1;
            @(negedge clk);cw=0;while(!ok)@(negedge clk);
        end
    endtask
    task setup;
        begin
            wait(ready);config_word(2,1);
            config_word(18'h1000,1471*512+63*8+3);
            config_word(18'h1001,1);config_word(18'h1002,16'h4000);
            config_word(18'h1003,32'h0a000001);config_word(18'h1004,32'h0a000002);
            config_word(18'h1005,32'h0bb90fa1);repeat(20)@(negedge clk);
        end
    endtask
    task send;input integer n,id,tag,policy;integer j;
        begin
            @(negedge clk);
            current_n=n;current_id=id;current_tag=tag;current_policy=policy;sent=sent+1;
            tv=1;td=id>>8;
            if(n>=2)begin @(negedge clk);td=id;end
            for(j=2;j<n;j=j+1)begin @(negedge clk);td=tag+j-2;end
            @(negedge clk);tv=0;td=0;
            // Include the added descriptor publication clock before next admission.
            repeat(3)@(negedge clk);
        end
    endtask
    task fill32;
        integer tries;
        begin
            tries=0;
            while((dut.application_tx.descriptors<32 || dut.application_tx.state==5) && tries<600)begin
                if(dut.application_tx.descriptors<32)send(3,16'h4000,tries,0);
                else @(negedge clk);
                tries=tries+1;
            end
            check(dut.application_tx.descriptors==32,"reach actual 32 outstanding descriptors");
        end
    endtask
    task drain;
        integer waited;
        begin
            waited=0;
            while(((!observation_mode && (got<expected-optional_last || wire_frames<expected-optional_last)) ||
                    dut.application_tx.descriptors!=0 || av) && waited<600000)begin
                @(negedge clk);waited=waited+1;
            end
            // During the one-byte observation window, allow all prior core frames
            // to finish before starting a separately checked recovery message.
            if(observation_mode)repeat(100000)@(negedge clk);
            else repeat(300)@(negedge clk);
            if(!observation_mode)check(got>=expected-optional_last && got<=expected && wire_frames==got && pos==0,"legal messages emitted; optional ready-low input observed whole or absent");
            check(dut.application_tx.descriptors+(T65_MUTANT==2?1:0)==0 &&
                dut.application_tx.write_ptr==dut.application_tx.read_ptr,"TX drain releases descriptors and data");
            check(ready,"ready recovers after drain");
            $fwrite(fd,"Q tx %0d %0d %0d\n",dut.application_tx.write_ptr,dut.application_tx.read_ptr,dut.application_tx.descriptors);
        end
    endtask
    task conclude;input integer exact_events;
        begin
            drain;
            if(exact_events)begin
                check(full==exp_full+(T65_MUTANT==2?1:0),"capacity drop count matches complete rejected inputs");
                check(miss==exp_miss,"unknown/empty message count");
            end
            $fwrite(fd,"E overflow %0d\nE miss %0d\nE max_used %0d\nE max_desc %0d\nE max_count %0d\nE expected %0d\n",full,miss,max_used,max_desc,max_count,expected);
            finish_test;
        end
    endtask
    task short_recovery;
        begin
            drain;
            $fwrite(fd,"S recovery %0d\n",cycle);
            observation_mode=0;got=0;expected=0;wire_frames=0;pos=0;
            send(66,16'h4000,8'h90,0);conclude(0);
        end
    endtask

    initial begin
        repeat(5)@(negedge clk);reset=0;

        observation_mode=1;send(1,16'h4000,0,0);repeat(20)@(negedge clk);
        $fwrite(fd,"S short_observation %0d %0d %0d\n",cycle,full,miss);
        two_full=full;two_miss=miss;send(2,16'h4000,0,0);repeat(20)@(negedge clk);
        check(!dut.initialized && full-two_full==1 && miss==two_miss,"VLID-only initialization rejects once");
        $fwrite(fd,"S two_result %0d %0d\n",full-two_full,miss-two_miss);setup;short_recovery;
    end
endmodule
