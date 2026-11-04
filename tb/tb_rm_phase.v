// 本测试让双网的同序号帧跨过粗计时边界，并交换处理顺序。
// 两份帧应只交付一次，旧的重复帧记录也应按时失效。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
`timescale 1ns/1ps
// 帧使用真实以太网格式；内部状态只用于统计测试覆盖情况。
module tb_rm_phase;
    reg clk=0,reset=1;always #4 clk=~clk;
    wire [31:0] ticks;wire [15:0] coarse;wire byte_en;
    afdx_timebase clock_base(clk,reset,ticks,byte_en,coarse);
    reg [7:0] a=0,b=0,pa[0:71],pb[0:71];reg av=0,bv=0,mwe=0,cwe=0;
    reg [15:0] addr=0;reg [31:0] data=0;
    wire ready,cfg_ok,dv,dl,dnet,rm,delivery;wire [7:0] dd,ea,eb;
    wire [11:0] vl;wire [15:0] sp,dp;
    integer checks=0,errors=0,pairs=0,received=0,dpos=0,drops=0,good=0;
    integer gap,phase,order,j,start_a,start_b,before_d,before_rm,case_id=0;
    integer skew_case,skew,delta,expected;
    integer busy_arrivals=0,reverse_pairs=0,cross_pairs=0,first_net=-1,seen_a,seen_b;
    reg old_da=0,old_db=0;reg [15:0] arrived_a,arrived_b;
    wire age_done;wire [31:0] age_checks,age_errors;
    rm_age_current aging(clk,age_done,age_checks,age_errors);
    afdx_rx_core dut(clk,reset,coarse,a,av,b,bv,mwe,cwe,addr,data,
        dv,dd,dl,vl,sp,dp,dnet,ready,ea,eb,rm,delivery,cfg_ok);
    task check;
        input ok;input [8*100-1:0] msg;
        begin checks=checks+1;if(ok!==1'b1)begin
            errors=errors+1;if(errors<20)$display("[FAIL] pair=%0d phase=%0d gap=%0d order=%0d %0s",pairs,phase,gap,order,msg);
        end end
    endtask
    function [31:0] crc_byte;
        input [31:0] crc;input [7:0] value;reg [31:0] c;integer n;
        begin c=crc^value;for(n=0;n<8;n=n+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    task packet;
        input [7:0] sn;reg [31:0] ca,cb;integer n;
        begin
            for(n=0;n<72;n=n+1)begin pa[n]=0;pb[n]=0;end
            for(n=0;n<7;n=n+1)pa[n]=8'h55;pa[7]=8'hd5;
            pa[8]=3;pa[13]=100;pa[14]=2;pa[17]=8'h23;pa[18]=8'h44;pa[19]=8'h20;
            pa[20]=8'h08;pa[22]=8'h45;pa[25]=45;pa[30]=1;pa[31]=17;
            pa[32]=8'hce;pa[33]=8'h7b;pa[34]=10;pa[37]=1;
            pa[38]=224;pa[39]=224;pa[41]=100;pa[42]=8'h0b;pa[43]=8'hb9;
            pa[44]=8'h0f;pa[45]=8'ha1;pa[47]=25;
            for(n=0;n<17;n=n+1)pa[50+n]=(case_id+n)&255;
            pa[67]=sn;for(n=0;n<68;n=n+1)pb[n]=pa[n];pb[19]=8'h40;
            ca=32'hffffffff;cb=32'hffffffff;
            for(n=8;n<68;n=n+1)begin ca=crc_byte(ca,pa[n]);cb=crc_byte(cb,pb[n]);end
            ca=~ca;cb=~cb;
            for(n=0;n<4;n=n+1)begin pa[68+n]=ca>>(8*n);pb[68+n]=cb>>(8*n);end
        end
    endtask
    task configure;
        input map;input [15:0] address;input [31:0] value;
        begin @(negedge clk);while(!cfg_ok)@(negedge clk);
            addr=address;data=value;mwe=map;cwe=!map;
            @(negedge clk);mwe=0;cwe=0;repeat(4)@(negedge clk);
        end
    endtask
    task automatic drive;
        input net;input integer start;integer n;
        begin while(ticks<start)@(negedge clk);
            for(n=0;n<72;n=n+1)begin
                if(net)begin b=pb[n];bv=1;end else begin a=pa[n];av=1;end
                @(negedge clk);
            end
            if(net)bv=0;else av=0;
        end
    endtask
    always @(posedge clk)if(!reset)begin
        if(dv)begin
            check(dd==((case_id+dpos)&255),"payload byte from exactly this message");
            check(vl==0 && sp==3001 && dp==4001,"delivery metadata");
            check(dl==(dpos==16),"message boundary");
            if(dl)begin received=received+1;dpos=0;end else dpos=dpos+1;
        end
        if(rm)drops=drops+1;
        if(ea[0])good=good+1;if(eb[0])good=good+1;
        if(|ea[7:1] || |eb[7:1])check(0,"no frame, integrity, configuration or overflow error");
        if((dut.da_valid&&!old_da)||(dut.db_valid&&!old_db))
            if(dut.engine.op!=1)busy_arrivals=busy_arrivals+1;
        old_da=dut.da_valid;old_db=dut.db_valid;
        if(dut.fa_end)begin arrived_a=coarse;seen_a=1;end
        if(dut.fb_end)begin arrived_b=coarse;seen_b=1;end
        if((dut.take_a||dut.take_b)&&first_net<0)first_net=dut.take_b?1:0;
        if(ticks>30000000 || errors>30)begin
            $display("[RESULT] tb_rm_phase FAIL checks=%0d errors=%0d",checks,errors+1);$finish;
        end
    end
    initial begin
        repeat(8)@(negedge clk);reset=0;wait(ready);
        configure(1,100,32'h1000);
        // 最大相差20拍，帧尾扫粗边界前后各32拍，包含全部跨边界相位。
        // SkewMax=0 同时检查超过窗口的两份仍按原规则分别交付。
        for(skew_case=0;skew_case<2;skew_case=skew_case+1)begin
        skew=skew_case==0?31:0;configure(0,0,(17<<17)|(skew<<5)|31);
        for(order=0;order<2;order=order+1)
            for(gap=0;gap<=20;gap=gap+1)
                for(phase=-32;phase<=32;phase=phase+1)begin
                    case_id=pairs;packet((pairs%255)+1);before_d=received;before_rm=drops;
                    seen_a=0;seen_b=0;first_net=-1;
                    start_a=((ticks/4096)+1)*4096-72+phase;
                    start_b=start_a;
                    if(order==0)start_b=start_b+gap;else start_a=start_a+gap;
                    fork drive(0,start_a);drive(1,start_b);join
                    repeat(160)@(negedge clk);
                    delta=(arrived_a-arrived_b)&65535;if(delta>32767)delta=65536-delta;
                    expected=delta>skew?2:1;
                    check(received==before_d+expected,"one delivery within SkewMax, two outside");
                    check(drops==before_rm+2-expected,"duplicate rejection matches window");
                    check(seen_a&&seen_b,"both valid frames reached MAC end");
                    if(arrived_a!=arrived_b)cross_pairs=cross_pairs+1;
                    if(gap!=0 && first_net!=order)reverse_pairs=reverse_pairs+1;
                    pairs=pairs+1;
                end
        end
        check(good==2*pairs,"all injected frames are valid");
        check(busy_arrivals>0 && reverse_pairs>0 && cross_pairs>0,"busy, reversed processing and coarse-boundary coverage");
        wait(age_done);#1;check(age_errors==0,"busy-load aging probe");
        $display("[COVERAGE] pairs=%0d cross=%0d reverse=%0d busy=%0d cycles=%0d aging_checks=%0d",pairs,cross_pairs,reverse_pairs,busy_arrivals,ticks,age_checks);
        $display("[RESULT] tb_rm_phase %0s checks=%0d errors=%0d",errors+age_errors==0?"PASS":"FAIL",checks+age_checks,errors+age_errors);$finish;
    end
endmodule
