// 本测试按“VLID + 应用数据”激励文件驱动两个端系统，只使用公开端口。
// 本文件读取原始 VL 配置并经 cfg 写入；调度以两端配置完成后的时刻为零点。
// 交付、时延和抖动由外层脚本从记录计算；本文件只统计自身检查项和错误数。
`timescale 1ns/1ps
module tb_app_entry #(parameter TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,
    RX_RING_AW=12,RX_DQ_AW=5,LINK_FRAMES=20000,MAX_MESSAGES=4096,MAX_CYCLES=20000000);
    reg clk=0;always #4 clk=~clk;
    reg reset1=1,reset2=1;
    integer sf,cf,pf,rc,cycle=0,checks=0,errors=0,quiet=0;
    wire [7:0] t1a,t1b,t2a,t2b,r1a,r1b,r2a,r2b;
    wire v1a,v1b,v2a,v2b,i1a,i1b,i2a,i2b,ready1,ready2;
    wire [31:0] c1,c2,e1,e2,l0e,l1e,l2e,l3e;
    sys_endpoint #(1,TX_PAGE_AW,TX_OFF_AW,LOOKAHEAD,RX_RING_AW,RX_DQ_AW)
        es1(clk,reset1,r1a,i1a,r1b,i1b,sf,t1a,v1a,t1b,v1b,ready1,c1,e1);
    sys_endpoint #(2,TX_PAGE_AW,TX_OFF_AW,LOOKAHEAD,RX_RING_AW,RX_DQ_AW)
        es2(clk,reset2,r2a,i2a,r2b,i2b,sf,t2a,v2a,t2b,v2b,ready2,c2,e2);
    link_model l0(clk,reset1,t1a,v1a,r2a,i2a,sf,l0e);
    link_model l1(clk,reset1,t1b,v1b,r2b,i2b,sf,l1e);
    link_model l2(clk,reset2,t2a,v2a,r1a,i1a,sf,l2e);
    link_model l3(clk,reset2,t2b,v2b,r1b,i1b,sf,l3e);
    integer due[0:MAX_MESSAGES-1],wl[0:MAX_MESSAGES-1];
    integer blen[0:MAX_MESSAGES-1],boff[0:MAX_MESSAGES-1];
    integer messages=0,win_begin=0,win_end=0;
    integer i,es,addr,value,cfg_count=0,epoch=0,vlid,bag,lmax,sport,dport,vi=0;
    integer wire_fd,wire_n=0,wire_start=0,wire_last=0,wj;
    reg wire_previous=0;reg [7:0] wire_bytes[0:1472];
    reg [8*40-1:0] command;
    task tick;begin @(posedge clk);#2;end endtask
    task check;input ok;input [8*100-1:0] label;
    begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;
        if(errors<20)$display("[APP_FAIL] cycle=%0d %0s",cycle,label);end end endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(v1a||v1b||v2a||v2b||i1a||i1b||i2a||i2b||es1.d_valid||es2.d_valid||
           es1.ev_tx||es2.ev_tx||es1.ev_a||es1.ev_b||es2.ev_a||es2.ev_b||
           es1.ev_rm_drop||es2.ev_rm_drop||es1.ev_deliver||es2.ev_deliver||
           es1.ev_gdrop||es2.ev_gdrop||es1.line_activity||es2.line_activity)quiet=cycle;
        if(cycle>MAX_CYCLES || errors+e1+e2+l0e+l1e+l2e+l3e>100)begin
            #1;$display("[RESULT] tb_app_entry FAIL checks=%0d errors=%0d",checks+c1+c2,
                errors+e1+e2+l0e+l1e+l2e+l3e+1);$finish;
        end
    end
    // rx.txt 直接记录 ES2 新顶层输出，VLID 来自头两字节，不由配置表重建。
    always @(posedge clk)if(!reset2)begin
        if(es2.dut.stream_rv)begin
            if(!wire_previous)begin wire_n=0;wire_start=cycle;end
            if(wire_n<1473)wire_bytes[wire_n]=es2.dut.stream_rx;
            wire_n=wire_n+1;wire_last=cycle;
        end else if(wire_previous)begin
            $fwrite(wire_fd,"%0d %0d %02x%02x ",wire_start,wire_last,wire_bytes[0],wire_bytes[1]);
            for(wj=2;wj<wire_n;wj=wj+1)$fwrite(wire_fd,"%02x",wire_bytes[wj]);
            $fwrite(wire_fd,"\n");$fflush(wire_fd);
        end
        wire_previous=es2.dut.stream_rv;
    end
    initial begin
        sf=$fopen("sys_events.txt","w");
        if(!sf)begin $display("[APP_FAIL] cannot open sys_events.txt");$finish;end
        wire_fd=$fopen("rx.txt","w");
        cf=$fopen("vectors/vl_config.txt","r");
        if(!cf)begin $display("[APP_FAIL] cannot open app_config.txt");$finish;end
        pf=$fopen("vectors/app_schedule.txt","r");
        if(!pf)begin $display("[APP_FAIL] cannot open app_schedule.txt");$finish;end
        rc=$fscanf(pf,"%d",messages);
        check(rc==1 && messages>0 && messages<=MAX_MESSAGES,"schedule header");
        for(i=0;i<messages;i=i+1)begin
            rc=$fscanf(pf,"%d %d %d %d",due[i],wl[i],blen[i],boff[i]);
            check(rc==4,"schedule row");
            check(blen[i]>=1 && blen[i]<=1471 && wl[i]>=0 && wl[i]<65536,"schedule bounds");
        end
        $fclose(pf);
        pf=$fopen("vectors/app_window.txt","r");
        if(!pf)begin $display("[APP_FAIL] cannot open app_window.txt");$finish;end
        rc=$fscanf(pf,"%d %d",win_begin,win_end);
        check(rc==2,"window file");
        $fclose(pf);
        $fwrite(sf,"G 0 CLOCK_NS 8\nG 0 GMII_TX_DELAY 0\nG 0 GMII_RX_REPLAY_R 0\n");
        $fwrite(sf,"P 0 app\n");
        #2;
        l0.set_delay(0);l1.set_delay(0);l2.set_delay(0);l3.set_delay(0);
        repeat(4)tick;@(negedge clk);reset1=0;
        repeat(13)tick;@(negedge clk);reset2=0;
        while(!ready1||!ready2)tick;repeat(64)tick;
        es1.stage("app");es2.stage("app");
        while(!$feof(cf))begin
            rc=$fscanf(cf,"%h %d %d %d %d",vlid,bag,lmax,sport,dport);
            if(rc==5)begin
                es1.write_cfg(18'h1000+vi*8,lmax*512+63*8+7,0);
                es1.write_cfg(18'h1001+vi*8,bag*125,0);
                es1.write_cfg(18'h1002+vi*8,vlid,0);
                es1.write_cfg(18'h1003+vi*8,32'h0a000101+vi,0);
                es1.write_cfg(18'h1004+vi*8,32'he0e00000|vlid,0);
                es1.write_cfg(18'h1005+vi*8,(sport<<16)|dport,0);
                es2.write_cfg(18'h10000+vlid,4096+vi,0);
                es2.write_cfg(18'h20000+vi,lmax*131072+20*32+31,0);
                es2.write_cfg(18'h1000+vi*8,lmax*512+63*8+7,0);
                es2.write_cfg(18'h1001+vi*8,bag*125,0);
                es2.write_cfg(18'h1002+vi*8,vlid,0);
                es2.write_cfg(18'h1003+vi*8,32'h0a000201+vi,0);
                es2.write_cfg(18'h1004+vi*8,32'he0e00000|vlid,0);
                es2.write_cfg(18'h1005+vi*8,(sport<<16)|dport,0);
                es1.write_cfg(18'h10000+vlid,4096+vi,0);
                es1.write_cfg(18'h20000+vi,lmax*131072+20*32+31,0);
                vi=vi+1;cfg_count=cfg_count+16;
            end else rc=$fgets(command,cf);
        end
        $fclose(cf);
        check(cfg_count>0,"configuration rows present");
        epoch=cycle+16;win_begin=win_begin+epoch;win_end=win_end+epoch;
        $fwrite(sf,"G %0d OFFER_VLID 1\nG %0d STIMULUS_EPOCH %0d\n",cycle,cycle,epoch);
        for(i=0;i<messages;i=i+1)begin
            due[i]=due[i]+epoch;
            $fwrite(sf,"O %0d %0d %0d %0d %0d\n",cycle,1,wl[i],blen[i],due[i]);
            es1.send_vlid_at(due[i],wl[i],blen[i],boff[i]);
        end
        es1.wait_idle;es2.wait_idle;
        while(l0.next_regular<=l0.frame_count || l1.next_regular<=l1.frame_count ||
              l2.next_regular<=l2.frame_count || l3.next_regular<=l3.frame_count ||
              l0.next_extra<=l0.extra_count || l1.next_extra<=l1.extra_count ||
              l2.next_extra<=l2.extra_count || l3.next_extra<=l3.extra_count)tick;
        repeat(20001)tick;
        while(cycle-quiet<20001)tick;
        check(l0e+l1e+l2e+l3e==0,"link model errors");
        check(e1+e2==0,"endpoint errors");
        if(win_end>win_begin)$fwrite(sf,"F %0d begin app\nF %0d end app\n",win_begin,win_end);
        $fflush(sf);$fflush(es1.tf);$fflush(es1.rf);$fflush(es2.tf);$fflush(es2.rf);
        $display("[COVERAGE] cycles=%0d messages=%0d",cycle,messages);
        $display("[RESULT] tb_app_entry %0s checks=%0d errors=%0d",
            errors+e1+e2+l0e+l1e+l2e+l3e==0?"PASS":"FAIL",checks+c1+c2,
            errors+e1+e2+l0e+l1e+l2e+l3e);
        $finish;
    end
endmodule
