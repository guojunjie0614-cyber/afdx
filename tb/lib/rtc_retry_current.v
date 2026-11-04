// Current-interface copy of rtc_retry_suite for native four-state replay.
// Original stimulus/assertions are preserved. Optional configuration inputs are
// explicitly open (Z), as in the original fixture's default parameter branches.
// Keep the original shared helper stable for already-running frozen captures.
`timescale 1ns/1ps
module rtc_retry_current #(parameter NAME="tb_rtc_recovery", NEGATIVE=0);
    reg clk=0,reset=1;always #4 clk=~clk;
    reg sw=0,mw=0,pass_reply=0,inject=0,iv=0,il=0;
    reg [3:0] sa=0,ma=0;reg [31:0] sd=0,md=0;reg [7:0] id=0;
    wire stv,stl,mtv,mtl;wire [7:0] std,mtd;wire [31:0] sq,mq,sc,mc;
    wire [6:0] svl,mvl;wire [15:0] sport,mport;wire sclaim,mclaim;
    integer cycle=0,checks=0,errors=0,requests=0,replies=0,spos=0;
    integer phase=0,j,limit,first_start,last_start,previous_start,period=5000,base_sync,sweep;
    integer calc_crossings=0;reg [7:0] request[0:47],response[0:47],old_origin[0:7];
    afdx_rtc slave(.clk(clk),.reset(reset),.enable(1'b1),.cfg_we(sw),.cfg_re(1'b0),.cfg_addr(sa),.cfg_wdata(sd),.cfg_rdata(sq),.sync_count(sc),
        .tx_valid(stv),.tx_ready(1'b1),.tx_data(std),.tx_last(stl),.tx_vl(svl),.tx_port(sport),
        .rx_valid(inject?iv:(mtv&&pass_reply)),.rx_data(inject?id:mtd),.rx_last(inject?il:mtl),.rx_port(16'd123),.rx_claim(sclaim),
        .cfg_ready_base(),.cfg_ready_rx_term(),.cfg_ready_rx_ack(),.cfg_write_request());
    afdx_rtc master(.clk(clk),.reset(reset),.enable(1'b1),.cfg_we(mw),.cfg_re(1'b0),.cfg_addr(ma),.cfg_wdata(md),.cfg_rdata(mq),.sync_count(mc),
        .tx_valid(mtv),.tx_ready(1'b1),.tx_data(mtd),.tx_last(mtl),.tx_vl(mvl),.tx_port(mport),
        .rx_valid(stv),.rx_data(std),.rx_last(stl),.rx_port(16'd123),.rx_claim(mclaim),
        .cfg_ready_base(),.cfg_ready_rx_term(),.cfg_ready_rx_ack(),.cfg_write_request());
    task check;input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;
            $display("[RTC_FAIL] %0s phase=%0d cycle=%0d %0s",NAME,phase,cycle,why);end end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(reset)begin requests=0;replies=0;spos=0;first_start=0;last_start=0;previous_start=0;end
        else begin
            if(stv)begin
                if(spos==0)begin
                    if(first_start==0)first_start=cycle;
                    previous_start=last_start;last_start=cycle;
                    check(slave.calc_state==0,"request must not interrupt active correction");
                    if(sc==0 && previous_start!=0 && !NEGATIVE)
                        check(last_start-previous_start==period+1,"lost reply retried at next configured period");
                end
                request[spos]=std;spos=spos+1;
                if(stl)begin check(spos==48,"complete 48-byte request");requests=requests+1;spos=0;end
            end
            if(mtv&&mtl)replies=replies+1;
            if(slave.calc_state!=0 && slave.countdown==0)calc_crossings=calc_crossings+1;
        end
        if(cycle>150000 || errors>20)begin
            $display("[RESULT] %0s FAIL checks=%0d errors=%0d",NAME,checks,errors+1);$finish;
        end
    end
    task cfg;input server;input [3:0] address;input [31:0] value;
        begin @(negedge clk);if(server)begin ma=address;md=value;mw=1;end
            else begin sa=address;sd=value;sw=1;end
            @(negedge clk);sw=0;mw=0;
        end
    endtask
    task initialize;
        begin @(negedge clk);reset=1;sw=0;mw=0;iv=0;il=0;pass_reply=0;
            repeat(5)@(negedge clk);reset=0;
            cfg(0,4,10);cfg(0,5,0);cfg(0,0,4);cfg(0,1,period);
            cfg(1,4,20);cfg(1,5,0);cfg(1,0,6);
        end
    endtask
    task wait_requests;input integer target;
        begin limit=cycle+3*period;while(requests<target&&cycle<limit)@(negedge clk);
            check(requests>=target,"expected subsequent request arrived");end
    endtask
    task wait_sync;
        begin limit=cycle+3*period;while(sc==base_sync&&cycle<limit)@(negedge clk);
            check(sc==base_sync+1,"valid reply completes exactly one synchronization");end
    endtask
    task make_reply;input stale;input integer flip;
        reg [31:0] seconds;integer n;
        begin
            for(n=0;n<48;n=n+1)response[n]=0;
            response[0]=8'h24;response[1]=1;seconds=32'd3155673620;
            for(n=0;n<8;n=n+1)response[24+n]=stale?old_origin[n]:request[40+n];
            for(n=0;n<4;n=n+1)begin response[32+n]=seconds>>(24-8*n);response[40+n]=seconds>>(24-8*n);end
            if(flip>=0)response[24+flip]=response[24+flip]^1;
        end
    endtask
    task send_reply;
        integer n;begin for(n=0;n<48;n=n+1)begin
            @(negedge clk);iv=1;id=response[n];il=(n==47);end
            @(negedge clk);iv=0;il=0;
        end
    endtask
    initial begin
        if(!NEGATIVE)begin
            phase=1;initialize;cfg(1,0,3);cfg(0,0,1);
            wait_requests(1);limit=cycle+period;
            while(replies<1&&cycle<limit)@(negedge clk);
            check(replies==1&&sc==0,"first actual master reply dropped");
            pass_reply=1;base_sync=0;wait_sync;
            check(requests==2,"second request recovers the lost reply");
            phase=2;initialize;cfg(0,0,1);wait_requests(3);
            check(sc==0&&replies==0,"slave waits and retries while master disabled");
            pass_reply=1;cfg(1,0,3);base_sync=0;wait_sync;
            check(requests==4&&replies==1,"late master enable recovers on next request");
            phase=3;initialize;cfg(1,0,3);pass_reply=1;cfg(0,0,1);
            base_sync=0;wait_sync;check(requests==1&&replies==1,"master-first enable unchanged");
        end else begin
            inject=1;phase=1;initialize;cfg(0,0,1);wait_requests(1);
            for(j=0;j<8;j=j+1)old_origin[j]=request[40+j];
            make_reply(0,0);send_reply;repeat(220)@(negedge clk);
            check(sc==0,"wrong Originate seconds rejected");
            make_reply(0,7);send_reply;repeat(220)@(negedge clk);
            check(sc==0,"wrong Originate fraction rejected");
            phase=2;wait_requests(2);
            check({request[40],request[41],request[42],request[43],request[44],request[45],request[46],request[47]}!=
                {old_origin[0],old_origin[1],old_origin[2],old_origin[3],old_origin[4],old_origin[5],old_origin[6],old_origin[7]},"retry has a fresh transmit timestamp");
            make_reply(1,-1);send_reply;repeat(220)@(negedge clk);
            check(sc==0,"expired first request reply rejected during second request");
            make_reply(0,-1);send_reply;base_sync=0;wait_sync;
            phase=3;initialize;cfg(0,0,1);wait_requests(1);make_reply(0,-1);
            while(cycle<first_start+period-70)@(negedge clk);
            send_reply;base_sync=0;wait_sync;
            check(calc_crossings>0,"correction straddled the request deadline without interruption");
            // 旧回应跨过重发起点：分别落在首字节前和小数编码尚未完成的窗口。
            for(sweep=0;sweep<2;sweep=sweep+1)begin
                phase=4+sweep;initialize;cfg(0,0,1);wait_requests(1);make_reply(0,-1);
                while(cycle<first_start+period-(sweep==0?50:30))@(negedge clk);
                send_reply;check(slave.tx_state!=0&&requests==1,"old reply overlaps retry packet transmission");
                repeat(220)@(negedge clk);check(sc==0,"expired reply during retry timestamp update rejected");
                wait_requests(2);make_reply(0,-1);send_reply;base_sync=0;wait_sync;
            end
        end
        $display("[COVERAGE] phase=%0d requests=%0d replies=%0d sync=%0d calculation_deadline_cycles=%0d cycles=%0d",phase,requests,replies,sc,calc_crossings,cycle);
        $display("[RESULT] %0s %0s checks=%0d errors=%0d",NAME,errors==0?"PASS":"FAIL",checks,errors);$finish;
    end
endmodule
