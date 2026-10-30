"""Embed deterministic wire bytes in new T65 Verilog-2001 source files."""
from pathlib import Path
from afdx_ref import build_frame, line_bytes

ROOT=Path(__file__).resolve().parents[1]

HEADER=r'''`timescale 1ns/1ps
module @NAME@ #(parameter T65_MUTANT=0);
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
            $display("[RESULT] @NAME@ %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);
            $finish;
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>2000000)begin check(0,"bounded test timeout");finish_test;end
    end
    initial fd=$fopen("t65_trace.txt","w");
'''

def header(name): return HEADER.replace('@NAME@',name)

def wire_rom(specs):
    data=[]; entries=[]
    for n,tag,vl,sn in specs:
        wire=line_bytes(build_frame(bytes((tag+j)&255 for j in range(n)),vlid=vl,sn=sn,dst_ip=0x0a000002,sport=3001,dport=4001))
        entries.append((len(data),len(wire)))
        data.extend(wire)
    s=f'    reg [7:0] wire_bytes[0:{len(data)-1}];\n    integer offsets[0:{len(entries)-1}],lengths[0:{len(entries)-1}];\n    initial begin\n'
    for i,(off,n) in enumerate(entries):s+=f'        offsets[{i}]={off};lengths[{i}]={n};\n'
    # Compact source lines; no runtime read of out/ or external vector files.
    for i in range(0,len(data),8):s+='        '+''.join(f"wire_bytes[{j}]=8'h{data[j]:02x};" for j in range(i,min(i+8,len(data))))+'\n'
    return s+'    end\n'

def write(name,text):
    (ROOT/'tb'/f'{name}.v').write_text(text,encoding='utf-8')

def g1():
    name='tb_t65_queue_a'
    text=header(name)+wire_rom([(1471,0x31,0x4000,0)]+[(1,0x50+i,0x4000,i) for i in range(1,11)]+[(64,0x90,0x4000,11)])+r'''
    reg reset=1;
    reg [7:0] rx=0;reg rv=0,mw=0,cw=0;
    reg [15:0] ca=0;reg [31:0] cd=0;
    wire init,ok,dv,dl,dn,rm,de;wire [7:0] dd,ea,eb;
    wire [11:0] di;wire [15:0] sp,dp;
    afdx_rx_core #(.RX_DQ_AW(1)) dut(clk,reset,16'd0,rx,rv,8'd0,1'b0,mw,cw,ca,cd,
        dv,dd,dl,di,sp,dp,dn,init,ea,eb,rm,de,ok);
    integer good=0,ovf=0,b_events=0,parse_ovf=0,delivers=0,got=0,pos=0,j;
    reg [7:0] expected_byte;
    reg [7:0] captured[0:2047];integer k,start_cycle=0;
    always @(posedge clk)begin
        #1;
        if(!reset)begin
            if(ea[0])good=good+1;
            if(ea[7])ovf=ovf+1;
            if(eb!=0)b_events=b_events+1;
            if(dut.parse_ev_a[7])parse_ovf=parse_ovf+1;
            if(de)delivers=delivers+1;
            if(dv)begin
                if(pos==0)start_cycle=cycle;
                if(got==0)expected_byte=8'h31+pos;
                else if(got==1)expected_byte=8'h51+pos;
                else if(got==2)expected_byte=8'h52+pos;
                else expected_byte=8'h90+pos;
                if(T65_MUTANT==1 && got==3 && pos==7)expected_byte=expected_byte^1;
                check(got<4 && dd==expected_byte,"accepted payload byte and order");
                check(!dn && di==0 && sp==3001 && dp==4001,"A delivery metadata");
                captured[pos]=dd;pos=pos+1;
                if(dl)begin
                    check(pos==(got==0?1471:got==3?64:1),"complete message length");
                    $fwrite(fd,"M rx %0d %0d ",start_cycle,pos);
                    for(k=0;k<pos;k=k+1)$fwrite(fd,"%02x",captured[k]);$fwrite(fd,"\n");
                    got=got+1;pos=0;
                end
            end
        end
    end
    task config_word;input integer map,address,value;
        begin
            @(negedge clk);while(!ok)@(negedge clk);
            mw=map;cw=!map;ca=address;cd=value;
            @(negedge clk);mw=0;cw=0;repeat(12)@(negedge clk);
        end
    endtask
    task send_frame;input integer idx;integer b;
        begin
            for(b=0;b<lengths[idx];b=b+1)begin
                @(negedge clk);rv=1;rx=wire_bytes[offsets[idx]+b];
            end
            @(negedge clk);rv=0;rx=0;repeat(12)@(negedge clk);
        end
    endtask
    task idle_resources;
        begin
            check(dut.parse_a.committed==dut.ptr_a && dut.parse_a.trial==dut.ptr_a,"A ring reclaimed");
            check(dut.parse_b.committed==dut.ptr_b && dut.parse_b.trial==dut.ptr_b,"B ring unchanged");
            check(dut.da_valid==0 && dut.db_valid==0 && dut.dq_count==0,"all descriptors reclaimed");
            $fwrite(fd,"Q idle %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                dut.parse_a.committed,dut.parse_a.trial,dut.ptr_a,dut.parse_b.committed,dut.parse_b.trial,dut.ptr_b,
                dut.da_valid,dut.db_valid,dut.dq_count);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset=0;wait(init);
        config_word(1,16'h4000,4096);
        config_word(0,0,1471*131072+20*32+31);
        send_frame(0);
        wait(dv);
        for(j=1;j<=10;j=j+1)send_frame(j);
        repeat(3000)@(negedge clk);
        check(good==11 && ovf==8+(T65_MUTANT==2?1:0),"one queue event for each rejected A frame");
        check(got==3 && delivers==3 && pos==0,"one long plus two queued short deliveries");
        check(parse_ovf==0 && b_events==0,"no ring overflow or B event");idle_resources;
        send_frame(11);repeat(1000)@(negedge clk);
        check(got==4 && delivers==4 && good==12 && ovf==8,"post-drain recovery exact");idle_resources;
        $fwrite(fd,"E good %0d\nE overflow %0d\nE parse_overflow %0d\nE b_events %0d\nE deliver %0d\n",good,ovf,parse_ovf,b_events,delivers);
        finish_test;
    end
'''
    text+='endmodule\n'
    write(name,text)

TX_COMMON=r'''
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
    // First-byte admission is sampled before the sequential RTL update.
    // policy 1 is the deliberately overlength/space-exhausting input;
    // policy 2 is observation-only input sent after ready has fallen.
    always @(posedge clk)begin
        admission_ready=dut.initialized && dut.application_tx.used<=2616 && dut.application_tx.descriptors<31;
        if(!reset && dut.application_tx.vq && !dut.application_tx.active)begin
            $fwrite(fd,"I %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,current_n,current_id,current_tag,
                dut.initialized,dut.application_tx.descriptors,dut.application_tx.used,ready,current_policy,sent);
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
            repeat(2)@(negedge clk);
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
'''

def tx_tests():
    scenarios={
      'ready':r'''
        setup;i=0;
        while(ready && i<200)begin
            check(ready,"legal message starts with ready");send(3,16'h4000,i,0);i=i+1;
        end
        check(!ready && i>0,"legal burst reaches conservative ready withdrawal");
        $fwrite(fd,"S withdrawal %0d %0d %0d\n",cycle,dut.application_tx.used,dut.application_tx.descriptors);
        drain;send(66,16'h4000,8'h90,0);conclude(1);
''',
      'hint':r'''
        setup;i=0;
        while(ready && i<200)begin send(3,16'h4000,i,0);i=i+1;end
        check(!ready && dut.application_tx.descriptors<32 && dut.application_tx.used<4096,"ready low while resources remain");
        // The additional input's output/drop is reported as an observation.
        optional_last=1;send(3,16'h4000,8'he1,2);conclude(0);
''',
      'space':r'''
        setup;send(9002,16'h4000,8'h22,1);repeat(20)@(negedge clk);
        check(max_used==4096 && max_count==8191,"real data exhaustion and saturated count reached");
        check(dut.application_tx.write_ptr==0 && dut.application_tx.committed==0,"whole oversized message rolls back write pointer");
        send(1473,16'h4000,8'h80,0);drain;send(66,16'h4000,8'h90,0);conclude(1);
''',
      'space_edge':r'''
        setup;send(4099,16'h4000,8'h22,1);repeat(20)@(negedge clk);
        check(max_used==4096,"space exhausted exactly at final rejected byte");
        check(dut.application_tx.write_ptr==0 && dut.application_tx.committed==0,"boundary rejection rolls back whole message");
        send(66,16'h4000,8'h90,0);conclude(1);
''',
      'desc':r'''
        setup;fill32;send(19,16'h4000,8'he2,0);drain;
        check(full>=1,"descriptor exhaustion rejects a complete payload message");
        send(66,16'h4000,8'h90,0);conclude(1);
''',
      'init':r'''
        send(19,16'h4000,8'he3,0);
        check(!dut.initialized,"input fully overlaps initialization");
        setup;send(66,16'h4000,8'h90,0);conclude(1);
''',
      'unmapped':r'''
        wait(ready);
        // Fixed schedule: drain the unconfigured descriptor before writing TX word 2.
        send(19,16'h4000,8'h33,0);repeat(300)@(negedge clk);
        check(miss==1 && wire_frames==0,"unconfigured VLID drops at descriptor lookup");
        expected=0;got=0;setup;send(66,16'h4000,8'h90,0);conclude(0);
''',
      'short_normal':r'''
        observation_mode=1;setup;send(1,16'h4000,0,0);repeat(40)@(negedge clk);
        $fwrite(fd,"S short_observation %0d %0d %0d\n",cycle,full,miss);
        two_full=full;two_miss=miss;send(2,16'h4000,0,0);repeat(20)@(negedge clk);
        check(miss-two_miss==1 && full==two_full,"VLID-only message reports exactly one empty event");
        $fwrite(fd,"S two_result %0d %0d\n",full-two_full,miss-two_miss);short_recovery;
''',
      'short_init':r'''
        observation_mode=1;send(1,16'h4000,0,0);repeat(20)@(negedge clk);
        $fwrite(fd,"S short_observation %0d %0d %0d\n",cycle,full,miss);
        two_full=full;two_miss=miss;send(2,16'h4000,0,0);repeat(20)@(negedge clk);
        check(!dut.initialized && full-two_full==1 && miss==two_miss,"VLID-only initialization rejects once");
        $fwrite(fd,"S two_result %0d %0d\n",full-two_full,miss-two_miss);setup;short_recovery;
''',
      'short_full':r'''
        observation_mode=1;setup;fill32;send(1,16'h4000,0,0);repeat(20)@(negedge clk);
        $fwrite(fd,"S short_observation %0d %0d %0d\n",cycle,full,miss);
        fill32;two_full=full;two_miss=miss;send(2,16'h4000,0,0);
        repeat(20)@(negedge clk);
        check(full-two_full==1 && miss==two_miss,"VLID-only descriptor-full rejects once");
        $fwrite(fd,"S two_result %0d %0d\n",full-two_full,miss-two_miss);short_recovery;
'''
    }
    for suffix,body in scenarios.items():
        name='tb_t65_tx_'+suffix
        write(name,header(name)+TX_COMMON+r'''
    initial begin
        repeat(5)@(negedge clk);reset=0;
'''+body+'    end\nendmodule\n')

RX_COMMON=r'''
    reg reset=1,cw=0,av=0,al=0;reg [7:0] ad=0;
    wire ov,drop;wire [7:0] od;
    afdx_app_rx dut(.clk(clk),.reset(reset),.cfg_write(cw),.cfg_index(12'd0),.cfg_vlid(16'h4000),
        .app_valid(av),.app_data(ad),.app_last(al),.app_index(12'd0),.valid(ov),.data(od),.drop(drop));
    integer current_n=0,current_tag=0,sent=0,expected=0,got=0,pos=0,drop_count=0,rejected=0;
    integer ns[0:2047],tags[0:2047];integer i,k,start_cycle=0;
    integer prev_used=0,prev_desc=0,max_used=0,max_desc=0,desc_reject=0,data_reject=0;
    reg predicted_reject,was_valid=0;reg [7:0] captured[0:2047],expected_byte;
    always @(posedge clk)begin
        if(!reset)begin
            predicted_reject=prev_used>2624 || prev_desc>=30;
            if(av && !dut.active)begin
                check(dut.reject==predicted_reject,"RX registered admission threshold");
                $fwrite(fd,"J %0d %0d %0d %0d %0d %0d %0d %0d\n",cycle,current_n,current_tag,sent,
                    dut.reject,prev_used,prev_desc,dut.used);
                if(!predicted_reject)begin ns[expected]=current_n;tags[expected]=current_tag;expected=expected+1;end
                else begin
                    rejected=rejected+1;
                    if(prev_used>2624)data_reject=data_reject+1;
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
            repeat(8000)@(negedge clk);
            check(got==expected && pos==0,"RX complete accepted sequence drains");
            check(dut.descriptors==0 && dut.write_ptr==dut.read_ptr,"RX storage and descriptors reclaimed");
            $fwrite(fd,"Q rx %0d %0d %0d\n",dut.write_ptr,dut.read_ptr,dut.descriptors);
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);reset=0;cw=1;
        @(negedge clk);cw=0;repeat(5)@(negedge clk);
@BODY@
        drain;send(64,8'h90);drain;
        check(drop_count==rejected+(T65_MUTANT==2?1:0),"one drop per rejected complete message");
        $fwrite(fd,"E overflow %0d\nE max_used %0d\nE max_desc %0d\nE data_reject %0d\nE desc_reject %0d\n",drop_count,max_used,max_desc,data_reject,desc_reject);
        finish_test;
    end
'''

def rx_tests():
    bodies={
      'desc':r'''
        for(i=0;i<150;i=i+1)send(1,i);
        send(8,8'he0);
        check(desc_reject>0 && data_reject==0,"descriptor pressure isolated from data pressure");
''',
      'data':r'''
        i=0;
        while(data_reject==0 && i<1000)begin send(1471,i);i=i+1;end
        check(data_reject>0 && desc_reject==0,"data pressure isolated from descriptor pressure");
'''
    }
    for suffix,body in bodies.items():
        name='tb_t65_rx_'+suffix
        write(name,header(name)+RX_COMMON.replace('@BODY@',body)+'endmodule\n')

CAPTURE=r'''
// Capture exactly the bytes sampled by the connected receiver at the active edge.
module t65_capture #(parameter CHANNEL="wire")(
    input wire clk, valid,input wire [7:0] data,input wire [31:0] file_handle,
    output reg [31:0] messages=0,output reg [31:0] byte_count=0);
    reg old_valid=0;reg [7:0] bytes[0:4095];integer n=0,j,c=0,start=0;
    always @(posedge clk)begin
        c=c+1;
        if(valid)begin
            if(!old_valid)start=c;
            bytes[n]=data;n=n+1;byte_count=byte_count+1;
        end else if(old_valid)begin
            $fwrite(file_handle,"M %0s %0d %0d ",CHANNEL,start,n);
            for(j=0;j<n;j=j+1)$fwrite(file_handle,"%02x",bytes[j]);$fwrite(file_handle,"\n");
            messages=messages+1;n=0;
        end
        old_valid=valid;
    end
endmodule
'''

RESET_COMMON=r'''
    reg r1=1,r2=1,tv1=0,tv2=0,w1=0,w2=0;
    reg [7:0] td1=0,td2=0;reg [17:0] ca=0;reg [31:0] cd=0;
    wire ready1,ready2,ok1,ok2,ov1,ov2,av1,av2,bv1,bv2;
    wire [7:0] od1,od2,ad1,ad2,bd1,bd2,ea1,ea2,eb1,eb2;
    wire de1,de2;wire [2:0] app1,app2;
    reg inject=0,iv=0;reg [7:0] idata=0;
    wire [7:0] peer_data=inject?idata:ad1;
    wire peer_valid=inject?iv:av1;
    AFDX_top e1(.clk(clk),.reset(r1),.tx_data(td1),.tx_valid(tv1),.tx_ready(ready1),
        .rx_data(od1),.rx_valid(ov1),.rx_ready(1'b0),.gmii_txd_a(ad1),.gmii_tx_en_a(av1),
        .gmii_txd_b(bd1),.gmii_tx_en_b(bv1),.gmii_rxd_a(ad2),.gmii_rx_dv_a(av2),
        .gmii_rxd_b(bd2),.gmii_rx_dv_b(bv2),.cfg_wr(w1),.cfg_rd(1'b0),.cfg_addr(ca),
        .cfg_wdata(cd),.cfg_ready(ok1),.cfg_rdata(),.cfg_rvalid(),.ev_tx(),.ev_a(ea1),.ev_b(eb1),
        .ev_rm_drop(),.ev_deliver(de1),.ev_app(app1));
    AFDX_top #(.RX_RING_AW(9)) e2(.clk(clk),.reset(r2),.tx_data(td2),.tx_valid(tv2),.tx_ready(ready2),
        .rx_data(od2),.rx_valid(ov2),.rx_ready(1'b0),.gmii_txd_a(ad2),.gmii_tx_en_a(av2),
        .gmii_txd_b(bd2),.gmii_tx_en_b(bv2),.gmii_rxd_a(peer_data),.gmii_rx_dv_a(peer_valid),
        .gmii_rxd_b(bd1),.gmii_rx_dv_b(bv1),.cfg_wr(w2),.cfg_rd(1'b0),.cfg_addr(ca),
        .cfg_wdata(cd),.cfg_ready(ok2),.cfg_rdata(),.cfg_rvalid(),.ev_tx(),.ev_a(ea2),.ev_b(eb2),
        .ev_rm_drop(),.ev_deliver(de2),.ev_app(app2));
    wire [31:0] om1,om2,wm1,wm2,pm,ob1,ob2,wb1,wb2,pbytes;
    t65_capture #(.CHANNEL("target")) c1(clk,ov1,od1,fd,om1,ob1);
    t65_capture #(.CHANNEL("peer")) c2(clk,ov2,od2,fd,om2,ob2);
    t65_capture #(.CHANNEL("wire_target")) c3(clk,av1,ad1,fd,wm1,wb1);
    t65_capture #(.CHANNEL("wire_peer")) c4(clk,av2,ad2,fd,wm2,wb2);
    t65_capture #(.CHANNEL("peer_input")) c5(clk,peer_valid,peer_data,fd,pm,pbytes);
    integer peer_good=0,peer_ovf=0,peer_len=0,peer_fcs=0,peer_hdr=0,peer_deliver=0;
    integer peer_other=0,peer_b=0,target_deliver=0;
    integer i,j,k,baseline_bytes=0,baseline_good=0,baseline_deliver=0,baseline_len=0;
    integer before_vector[0:3],after_vector[0:3];integer old_good,old_ovf,old_deliver,old_messages;
    reg old_reset=1;
    always @(posedge clk)begin
        #1;
        if(!r2)begin
            if(ea2[0])peer_good=peer_good+1;
            if(ea2[1])peer_fcs=peer_fcs+1;
            if(ea2[2])peer_len=peer_len+1;
            if(ea2[3])peer_hdr=peer_hdr+1;
            if(ea2[7])peer_ovf=peer_ovf+1;
            if(ea2[6:4]!=0)peer_other=peer_other+1;
            if(eb2!=0)peer_b=peer_b+1;
            if(de2)peer_deliver=peer_deliver+1;
        end
        if(!r1 && de1)target_deliver=target_deliver+1;
        if(r1)begin
            check(!av1 && !bv1 && !ov1,"reset target suppresses old TX/RX output immediately");
        end
        if(r1 && !old_reset)$fwrite(fd,"S reset_effect %0d %0d %0d\n",cycle,av1,ov1);
        old_reset=r1;
    end
    task config_word;input integer ep,address,value;
        begin
            @(negedge clk);while(!(ep==1?ok1:ok2))@(negedge clk);
            ca=address;cd=value;w1=ep==1;w2=ep==2;
            @(negedge clk);w1=0;w2=0;while(!(ep==1?ok1:ok2))@(negedge clk);
        end
    endtask
    task configure;input integer ep;
        begin
            wait(ep==1?ready1:ready2);
            config_word(ep,2,ep);
            config_word(ep,18'h1000,1471*512+63*8+3);config_word(ep,18'h1001,1);
            config_word(ep,18'h1002,16'h4000);config_word(ep,18'h1003,32'h0a000001);
            config_word(ep,18'h1004,32'h0a000002);config_word(ep,18'h1005,32'h0bb90fa1);
            config_word(ep,18'h14000,4096);config_word(ep,18'h20000,1471*131072+20*32+7);
            if(ep==2)for(k=0;k<4;k=k+1)begin
                config_word(ep,18'h14100+k,4097+k);
                config_word(ep,18'h20001+k,1471*131072+20*32+7);
            end
            repeat(20)@(negedge clk);
        end
    endtask
    task send;input integer ep,n,tag;integer b;
        begin
            @(negedge clk);while(!(ep==1?ready1:ready2))@(negedge clk);
            if(ep==1)begin tv1=1;td1=8'h40;end else begin tv2=1;td2=8'h40;end
            @(negedge clk);if(ep==1)td1=0;else td2=0;
            for(b=0;b<n;b=b+1)begin
                @(negedge clk);if(ep==1)td1=tag+b;else td2=tag+b;
            end
            @(negedge clk);if(ep==1)begin tv1=0;td1=0;end else begin tv2=0;td2=0;end
            $fwrite(fd,"S sent %0d %0d %0d %0d\n",cycle,ep,n,tag);
        end
    endtask
    task peer_idle;
        begin
            check(e2.es.rx_core.parse_a.committed==e2.es.rx_core.ptr_a &&
                e2.es.rx_core.parse_a.trial==e2.es.rx_core.ptr_a,"unreset peer A ring reclaimed");
            check(e2.es.rx_core.parse_b.committed==e2.es.rx_core.ptr_b &&
                e2.es.rx_core.parse_b.trial==e2.es.rx_core.ptr_b,"unreset peer B ring idle");
            check(e2.es.rx_core.da_valid==0 && e2.es.rx_core.db_valid==0 &&
                e2.es.rx_core.dq_count==(T65_MUTANT==2?1:0),"unreset peer all descriptors reclaimed");
            $fwrite(fd,"Q peer %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                e2.es.rx_core.parse_a.committed,e2.es.rx_core.parse_a.trial,e2.es.rx_core.ptr_a,
                e2.es.rx_core.parse_b.committed,e2.es.rx_core.parse_b.trial,e2.es.rx_core.ptr_b,
                e2.es.rx_core.da_valid,e2.es.rx_core.db_valid,e2.es.rx_core.dq_count);
        end
    endtask
    task pressure;input integer phase;integer f,b,outcome;
        begin
            inject=1;
            for(f=0;f<4;f=f+1)begin
                check(!av1,"capacity probe starts with target wire idle");
                old_good=peer_good;old_ovf=peer_ovf;old_deliver=peer_deliver;old_messages=om2;
                for(b=0;b<lengths[f];b=b+1)begin
                    @(negedge clk);iv=1;idata=wire_bytes[offsets[f]+b];
                end
                @(negedge clk);iv=0;idata=0;
                repeat(2000)@(negedge clk);
                check(peer_good-old_good==(f==1?0:1) && peer_ovf-old_ovf==(f==1?1:0),"512-byte peer capacity boundary events");
                check(peer_deliver-old_deliver==(f==1?0:1) && om2-old_messages==(f==1?0:1),"capacity accepted or rejected entire frame");
                outcome=(peer_ovf-old_ovf)*10+(peer_deliver-old_deliver);
                if(phase==0)before_vector[f]=outcome;else after_vector[f]=outcome;
                $fwrite(fd,"P %0d %0d %0d %0d %0d %0d\n",phase,f,peer_good-old_good,peer_ovf-old_ovf,peer_deliver-old_deliver,om2-old_messages);
                peer_idle;
            end
            inject=0;
        end
    endtask
    initial begin
        repeat(5)@(negedge clk);r1=0;r2=0;wait(ready1 && ready2);
        configure(1);configure(2);pressure(0);
        baseline_bytes=wb1;baseline_good=peer_good;baseline_deliver=peer_deliver;baseline_len=peer_len;
@TRIGGER@
        check(r2==0,"peer reset never asserted");
        repeat(4)@(negedge clk);r1=0;
        wait(ready1);repeat(200)@(negedge clk);
        check(!av1 && !ov1 && target_deliver==0,"no old message replay during reinitialization");
        configure(1);
        repeat(1000)@(negedge clk);
        check(peer_good==baseline_good && peer_deliver==baseline_deliver,"peer never delivers old or partial message");
@ERROR_CHECK@
        peer_idle;pressure(1);
        for(i=0;i<4;i=i+1)check(before_vector[i]==after_vector[i],"unreset peer capacity outcome vector unchanged");
        send(1,64,8'h90);send(2,64,8'ha0);repeat(6000)@(negedge clk);
        check(om1==1 && om2==7,"fresh bidirectional messages delivered once after target reconfiguration");
        check(peer_good==7 && peer_deliver==7 && peer_ovf==2 && peer_other==0 && peer_b==0 && peer_fcs==0 && peer_hdr==0,"final peer event ledger");
        check(e1.es.rx_core.parse_a.committed==e1.es.rx_core.ptr_a && e1.es.rx_core.dq_count==0,"reset target fresh receive drains");
        check(c2.bytes[0]==8'h40 && c2.bytes[1]==0 && c1.bytes[0]==8'h40 && c1.bytes[1]==0,"fresh bidirectional VLID bytes");
        for(j=0;j<64;j=j+1)begin
            check(c2.bytes[j+2]==((8'h90+j+(T65_MUTANT==1 && j==7?1:0))&255),"unreset peer recovery payload exact");
            check(c1.bytes[j+2]==((8'ha0+j)&255),"reset target recovery payload exact");
        end
        peer_idle;
        $fwrite(fd,"E good %0d\nE overflow %0d\nE length %0d\nE fcs %0d\nE header %0d\nE deliver %0d\nE other %0d\nE b_events %0d\n",peer_good,peer_ovf,peer_len,peer_fcs,peer_hdr,peer_deliver,peer_other,peer_b);
        finish_test;
    end
'''

def reset_tests():
    scenarios={
      'rx':(r'''
        send(2,200,8'h33);
        @(negedge clk);while(e1.es.rx_core.engine.op!=2)@(negedge clk);
        check(!av2 && !ov1,"RX target descriptor complete but delivery has not started");
        $fwrite(fd,"R rx %0d FRAME %0d %0d %0d\n",cycle,e1.es.rx_core.engine.op,e1.es.rx_core.engine.phase,wb1-baseline_bytes);
        r1=1;
''',r'''
        check(peer_len==baseline_len && wb1==baseline_bytes,"RX reset sends no truncated frame to peer; no peer error required");
'''),
      'mac':(r'''
        send(1,200,8'h33);
        @(negedge clk);while(!(e1.es.tx_core.mac.state==1 && e1.es.tx_core.mac.pre_index==3))@(negedge clk);
        check(av1 && wb1-baseline_bytes>0,"peer has received actual preamble prefix");
        $fwrite(fd,"R mac %0d PREAMBLE %0d %0d %0d\n",cycle,e1.es.tx_core.mac.state,e1.es.tx_core.mac.pre_index,wb1-baseline_bytes);
        r1=1;
''',r'''
        check(peer_len==baseline_len+1 && wb1-baseline_bytes==4,"four-byte preamble truncation increments peer length/preamble error once");
'''),
      'app':(r'''
        send(1,200,8'h33);
        @(negedge clk);while(e1.application_tx.state!=6)@(negedge clk);
        check(wb1==baseline_bytes,"application lookup reset precedes any wire byte");
        $fwrite(fd,"R app %0d st1 %0d 0 %0d\n",cycle,e1.application_tx.state,wb1-baseline_bytes);
        r1=1;
''',r'''
        check(peer_len==baseline_len && wb1==baseline_bytes,"lookup reset sends no truncated frame; no peer error required");
''')
    }
    for suffix,(trigger,err) in scenarios.items():
        name='tb_t65_reset_'+suffix
        rom=wire_rom([(320,0x10,0x4100,0),(513,0x20,0x4101,0),(512,0x30,0x4102,0),(17,0x40,0x4103,0)])
        body=RESET_COMMON.replace('@TRIGGER@',trigger).replace('@ERROR_CHECK@',err)
        write(name,header(name)+rom+body+'endmodule\n'+CAPTURE)

if __name__=='__main__':
    g1();tx_tests();rx_tests();reset_tests()

if __name__=='__main__':
    g1();tx_tests()
