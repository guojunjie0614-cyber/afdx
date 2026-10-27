// 新顶层公开接口：128 项查表、长度边界、未知 VLID 和忽略 ready 的 32 条突发。
`timescale 1ns/1ps
module tb_top_wrap;
    reg clk=0;always #4 clk=~clk;
    reg reset=1;
    reg [7:0] tx=0;
    reg tv=0;
    wire ready,ready2,rv;
    wire [7:0] rx;
    wire [7:0] a,b,c,d;
    wire av,bv,cv,dv;
    reg w1=0,w2=0;
    reg [17:0] ca=0;
    reg [31:0] cw=0;
    wire cr1,cr2;
    wire [2:0] ev1,ev2;
    AFDX_top es1(.clk(clk),.reset(reset),.tx_data(tx),.tx_valid(tv),.tx_ready(ready),
        .rx_data(),.rx_valid(),.rx_ready(1'b0),
        .gmii_txd_a(a),.gmii_tx_en_a(av),.gmii_rxd_a(c),.gmii_rx_dv_a(cv),
        .gmii_txd_b(b),.gmii_tx_en_b(bv),.gmii_rxd_b(d),.gmii_rx_dv_b(dv),
        .cfg_wr(w1),.cfg_rd(1'b0),.cfg_addr(ca),.cfg_wdata(cw),.cfg_ready(cr1),.cfg_rdata(),.cfg_rvalid(),.ev_tx(),.ev_a(),.ev_b(),.ev_rm_drop(),.ev_deliver(),.ev_app(ev1));
    AFDX_top es2(.clk(clk),.reset(reset),.tx_data(8'd0),.tx_valid(1'b0),.tx_ready(ready2),
        .rx_data(rx),.rx_valid(rv),.rx_ready(1'b0),
        .gmii_txd_a(c),.gmii_tx_en_a(cv),.gmii_rxd_a(a),.gmii_rx_dv_a(av),
        .gmii_txd_b(d),.gmii_tx_en_b(dv),.gmii_rxd_b(b),.gmii_rx_dv_b(bv),
        .cfg_wr(w2),.cfg_rd(1'b0),.cfg_addr(ca),.cfg_wdata(cw),.cfg_ready(cr2),.cfg_rdata(),.cfg_rvalid(),.ev_tx(),.ev_a(),.ev_b(),.ev_rm_drop(),.ev_deliver(),.ev_app(ev2));
    integer checks=0,errors=0,cycle=0,received=0,expected=0,pos=0;
    integer ids[0:511],lens[0:511],tags[0:511];
    integer unknown=0,overflow=0,rxoverflow=0,i;
    reg was_valid=0;
    task check;input ok;input [8*80-1:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[WRAP_FAIL] cycle=%0d %0s",cycle,label);end end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!reset)begin
            if(ev1[0])unknown=unknown+1;
            if(ev1[1])overflow=overflow+1;
            if(ev2[2])rxoverflow=rxoverflow+1;
            if(rv)begin
                check(received<expected,"no unexpected delivery");
                if(pos==0)check(rx==((ids[received]>>8)&255),"VLID high byte");
                else if(pos==1)check(rx==(ids[received]&255),"VLID low byte");
                else check(rx==((tags[received]+pos-2)&255),"payload exact");
                pos=pos+1;
            end else if(was_valid)begin
                check(pos==lens[received]+2,"whole message length, no valid bubble");
                received=received+1;pos=0;
            end
            was_valid=rv;
        end
        if(cycle>3000000)begin $display("[RESULT] tb_top_wrap FAIL checks=%0d errors=%0d timeout",checks,errors+1);$finish;end
    end
    task configure;input integer endpoint,address,value;
        begin
            @(negedge clk);while(!(endpoint==1?cr1:cr2))@(negedge clk);
            ca=address;cw=value;w1=endpoint==1;w2=endpoint==2;
            @(negedge clk);w1=0;w2=0;
            while(!(endpoint==1?cr1:cr2))@(negedge clk);
        end
    endtask
    task send;input integer id,n,tag,ignore_ready,expect_delivery;
        integer j;
        begin
            @(negedge clk);
            if(!ignore_ready)while(!ready)@(negedge clk);
            if(expect_delivery)begin ids[expected]=id;lens[expected]=n;tags[expected]=tag;expected=expected+1;end
            tv=1;tx=id>>8;
            @(negedge clk);tx=id;
            for(j=0;j<n;j=j+1)begin @(negedge clk);tx=tag+j;end
            @(negedge clk);tv=0;
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;
        wait(ready && ready2);
        configure(1,2,1);configure(2,2,2);
        for(i=0;i<128;i=i+1)begin
            configure(1,18'h1000+i*8,1471*512+63*8+7);
            configure(1,18'h1001+i*8,1);
            configure(1,18'h1002+i*8,16'h4000+i*17);
            configure(1,18'h1003+i*8,32'h0a000001);
            configure(1,18'h1004+i*8,32'h0a000002);
            configure(1,18'h1005+i*8,32'h0bb90fa1);
            configure(2,18'h10000+16'h4000+i*17,4096+i);
            configure(2,18'h20000+i,1471*131072+20*32+31);
        end
        for(i=0;i<128;i=i+1)begin
            send(16'h4000+i*17,i==127?1471:1+(i%16),i,0,1);
            wait(received==expected);
        end
        send(16'hffff,16,3,0,0);repeat(200)@(negedge clk);
        check(unknown==1,"one unknown VLID drop");
        send(16'h4000,1471,5,1,1);
        for(i=1;i<=30;i=i+1)send(16'h4000+i*17,1+(i%16),i+5,1,1);
        send(16'h4000+31*17,1471,36,1,1);
        wait(received==expected);repeat(200)@(negedge clk);
        check(expected==160 && received==160,"all 128 indices and 32 burst messages delivered once");
        check(overflow==0 && rxoverflow==0,"no buffer overflow");
        check(unknown==1,"no extra unknown drops");
        $display("[RESULT] tb_top_wrap %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);$finish;
    end
endmodule
