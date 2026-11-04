// 本模块在接收引擎忙时推进时间，检查旧的重复帧记录仍会失效。
// 它把完成标记和错误数交给跨计时边界测试。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
// 测试每 128 拍推进一次输入时间，让变化发生在帧处理期间。
module rm_age_probe(input wire clk,output reg done=0,output reg [31:0] checks=0,output reg [31:0] errors=0);
    reg reset=1;reg [15:0] now_c=0;reg [94:0] desc=0;reg valid=0;
    wire init,take,resolve,commit,mre,cre,sre,swe,dwe,rm,deliver,ok;
    wire [15:0] ma;wire [11:0] ca,sa,wa;wire [42:0] wd;
    reg [12:0] mq=0;reg [31:0] cq=0;reg [42:0] sq=0,states[0:4095];
    wire [4:0] dwa;wire [67:0] dwd;wire [5:0] count;wire [7:0] ea,eb;
    integer cycle=0,origin=0,sent=0,delivered=0,limit,before_d;reg running=0;
    afdx_rx_engine dut(clk,reset,1'b1,now_c,init,valid,1'b0,desc,95'b0,
        take,,resolve,,commit,,mre,ma,mq,cre,ca,cq,sre,swe,sa,wa,wd,sq,
        dwe,dwe,dwa,dwd,count,ea,eb,rm,deliver,ok);
    always @(posedge clk)begin
        cycle=cycle+1;
        if(mre)mq<={1'b1,ma[11:0]};
        if(cre)cq<=(17<<17)|(31<<5)|7|(ca==0?16:0);
        if(sre)sq<=states[sa];if(swe)states[wa]<=wd;
        if(deliver)delivered=delivered+1;
    end
    task check;input condition;input [8*100-1:0] why;
        begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;$display("[AGE_FAIL] %0s",why);end end
    endtask
    task send;input [15:0] idx;input [7:0] sn;
        begin @(negedge clk);desc={idx,sn,16'd3001,16'd4001,11'd17,12'd0,now_c};valid=1;
            while(!take)@(negedge clk);valid=0;while(!resolve)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;wait(init);send(0,55);
        repeat(20)@(negedge clk);check(states[0][24],"initial duplicate record valid");
        origin=cycle;
        while(now_c<16'h9000)begin
            // 描述先开始；第8拍切粗时钟，原实现每次都会错过老化触发。
            @(negedge clk);desc={16'd1,8'd1,16'd3001,16'd4001,11'd17,12'd0,now_c};valid=1;
            while(!take)@(negedge clk);valid=0;
            repeat(6)@(negedge clk);check(dut.op==dut.FRAME,"coarse change is under engine load");
            now_c=now_c+1'b1;sent=sent+1;limit=origin+sent*128;
            while(cycle<limit)@(negedge clk);
            if(now_c==16'h5002)check(!states[0][24],"old record aged before signed half-wrap");
        end
        before_d=delivered;send(0,55);repeat(20)@(negedge clk);
        check(delivered==before_d+1,"same SN after long inactivity is accepted");
        $display("[AGE_COVERAGE] busy_ticks=%0d delivered=%0d cycles=%0d",sent,delivered,cycle);
        done=1;
    end
endmodule
