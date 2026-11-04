// Test-only endpoint: configuration, captures and deterministic payload checks.
// No DUT internals are used. NET_RX selects a separately compiled RTL receiver.
`timescale 1ns/1ps
module t76_load_endpoint #(
    parameter ID=0,VL_COUNT=81,GROUP_LENGTH=1471,MIXED=0,NET_RX=0,LONG_COUNT=1
)(input wire clk,reset,input wire [7:0] ra,rb,input wire rva,rvb,
   output wire [7:0] ta,tb,output wire tva,tvb,output reg configured=0);
    reg [7:0] data=0;
    reg valid=0,wr=0,rd=0;
    reg [17:0] address=0;
    reg [31:0] wdata=0;
    wire ready,rv,crv,crdy,rm,deliver;
    wire [7:0] rx,ea,eb;
    wire [6:0] et;
    wire [2:0] app;
    wire [31:0] rdata;
    generate if(NET_RX)begin:rtl_receiver
        AFDX_top_rtl dut(
            .clk(clk),.reset(reset),.tx_data(data),.tx_valid(valid),.tx_ready(ready),
            .rx_data(rx),.rx_valid(rv),.rx_ready(1'b0),
            .gmii_txd_a(ta),.gmii_txd_b(tb),.gmii_tx_en_a(tva),.gmii_tx_en_b(tvb),
            .gmii_rxd_a(ra),.gmii_rxd_b(rb),.gmii_rx_dv_a(rva),.gmii_rx_dv_b(rvb),
            .cfg_wr(wr),.cfg_rd(rd),.cfg_addr(address),.cfg_wdata(wdata),
            .cfg_rdata(rdata),.cfg_rvalid(crv),.cfg_ready(crdy),
            .ev_tx(et),.ev_a(ea),.ev_b(eb),.ev_rm_drop(rm),.ev_deliver(deliver),.ev_app(app));
    end else begin:primary
        AFDX_top dut(
            .clk(clk),.reset(reset),.tx_data(data),.tx_valid(valid),.tx_ready(ready),
            .rx_data(rx),.rx_valid(rv),.rx_ready(1'b0),
            .gmii_txd_a(ta),.gmii_txd_b(tb),.gmii_tx_en_a(tva),.gmii_tx_en_b(tvb),
            .gmii_rxd_a(ra),.gmii_rxd_b(rb),.gmii_rx_dv_a(rva),.gmii_rx_dv_b(rvb),
            .cfg_wr(wr),.cfg_rd(rd),.cfg_addr(address),.cfg_wdata(wdata),
            .cfg_rdata(rdata),.cfg_rvalid(crv),.cfg_ready(crdy),
            .ev_tx(et),.ev_a(ea),.ev_b(eb),.ev_rm_drop(rm),.ev_deliver(deliver),.ev_app(app));
    end endgenerate
    // Every bit of all sixteen public output ports is included (90 bits).
    wire [89:0] public_outputs={ready,rx,rv,ta,tva,tb,tvb,et,ea,eb,rm,deliver,app,rdata,crv,crdy};
    wire [31:0] x_checked;
    afdx_x_monitor #(.WIDTH(90),.LABEL("T76 complete endpoint outputs")) monitor(
        clk,reset,configured,public_outputs,x_checked);
    integer cycle=0,received=0,sent=0,errors=0,duplicates=0;
    integer txfd,rxfd,afd,bfd,efd,ci,j,rn=0,rs=0,an=0,bs=0,bn=0,as_=0;
    integer receive_seq[0:127];
    reg previous_rx=0,previous_a=0,previous_b=0;
    reg [7:0] receive_bytes[0:8193],a_bytes[0:2047],b_bytes[0:2047];
    integer rid,seq,n;
    function integer message_length;
        input integer vl,sequence;
        begin
            message_length=GROUP_LENGTH;
            if(MIXED==1 && sequence>0)begin
                if(vl==VL_COUNT-3)message_length=1472;
                if(vl==VL_COUNT-2)message_length=3000;
                if(vl==VL_COUNT-1)message_length=8192;
            end
            if(MIXED==2 && vl==VL_COUNT-1)message_length=1472;
            if(MIXED==3 && sequence>0 && vl>=VL_COUNT-LONG_COUNT)message_length=8192;
        end
    endfunction
    function [7:0] payload_byte;
        input integer vl,sequence,position;
        begin payload_byte=(vl*31+sequence*17+position*7+(position/256))&255;end
    endfunction
    task write_cfg;
        input [17:0] a;
        input [31:0] d;
        begin
            @(negedge clk);while(!crdy)@(negedge clk);
            address=a;wdata=d;wr=1;
            @(negedge clk);wr=0;
            while(!crdy)@(negedge clk);
        end
    endtask
    initial begin
        if(ID==0)begin
            txfd=$fopen("ep0_tx.txt","w");rxfd=$fopen("ep0_rx.txt","w");
            afd=$fopen("ep0_a.txt","w");bfd=$fopen("ep0_b.txt","w");efd=$fopen("ep0_events.txt","w");
        end else begin
            txfd=$fopen("ep1_tx.txt","w");rxfd=$fopen("ep1_rx.txt","w");
            afd=$fopen("ep1_a.txt","w");bfd=$fopen("ep1_b.txt","w");efd=$fopen("ep1_events.txt","w");
        end
        if(!txfd||!rxfd||!afd||!bfd||!efd)$fatal(1,"T76 capture file open");
        for(ci=0;ci<128;ci=ci+1)receive_seq[ci]=0;
        wait(!reset);wait(crdy && ready);
        for(ci=0;ci<VL_COUNT;ci=ci+1)begin
            write_cfg(18'h1000+ci*8,1471*512+63*8+7);
            write_cfg(18'h1001+ci*8,125000);
            write_cfg(18'h1002+ci*8,256+ci);
            write_cfg(18'h1003+ci*8,32'h0a000101+ci);
            write_cfg(18'h1004+ci*8,32'he0e00100+ci);
            write_cfg(18'h1005+ci*8,32'h12344321);
            write_cfg(18'h10000+256+ci,4096+ci);
            write_cfg(18'h20000+ci,1471*131072+20*32+31);
        end
        // Read a defined register before arming the all-bits X monitor.
        @(negedge clk);address=0;rd=1;
        @(negedge clk);rd=0;
        repeat(8)@(negedge clk);
        configured=1;
    end
    task send_message;
        input integer vl,length,sequence,planned;
        integer p,first;
        begin
            @(negedge clk);while(!ready)@(negedge clk);
            first=cycle+1;valid=1;data=(256+vl)>>8;
            @(negedge clk);data=256+vl;
            for(p=0;p<length;p=p+1)begin
                @(negedge clk);data=payload_byte(vl,sequence,p);
            end
            @(negedge clk);valid=0;sent=sent+1;
            $fwrite(txfd,"T %0d %0d %0d %0d %0d %0d ",first,cycle,vl,length,sequence,planned);
            for(p=0;p<length;p=p+1)$fwrite(txfd,"%02x",payload_byte(vl,sequence,p));
            $fwrite(txfd,"\n");$fflush(txfd);
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!reset)begin
            if(rv)begin
                if(!previous_rx)begin rn=0;rs=cycle;end
                if(rn>=8194)$fatal(1,"T76 receive capture overflow");
                receive_bytes[rn]=rx;rn=rn+1;
            end else if(previous_rx)begin
                rid={receive_bytes[0],receive_bytes[1]}-256;
                if(rid<0 || rid>=VL_COUNT)$fatal(1,"T76 unknown receive VLID");
                seq=receive_seq[rid];n=message_length(rid,seq);
                if(rn!=n+2)$fatal(1,"T76 receive length vl=%0d seq=%0d got=%0d expected=%0d",rid,seq,rn,n+2);
                for(j=0;j<n;j=j+1)if(receive_bytes[j+2]!==payload_byte(rid,seq,j))
                    $fatal(1,"T76 payload mismatch vl=%0d seq=%0d byte=%0d",rid,seq,j);
                $fwrite(rxfd,"R %0d %0d %0d %0d %0d ",rs,cycle-1,rid,n,seq);
                for(j=2;j<rn;j=j+1)$fwrite(rxfd,"%02x",receive_bytes[j]);
                $fwrite(rxfd,"\n");$fflush(rxfd);
                receive_seq[rid]=seq+1;received=received+1;
            end
            if(tva)begin
                if(!previous_a)begin an=0;as_=cycle;end
                if(an>=2048)$fatal(1,"T76 A capture overflow");
                a_bytes[an]=ta;an=an+1;
            end else if(previous_a)begin
                $fwrite(afd,"%0d %0d ",as_,cycle-1);
                for(j=0;j<an;j=j+1)$fwrite(afd,"%02x",a_bytes[j]);
                $fwrite(afd,"\n");$fflush(afd);
            end
            if(tvb)begin
                if(!previous_b)begin bn=0;bs=cycle;end
                if(bn>=2048)$fatal(1,"T76 B capture overflow");
                b_bytes[bn]=tb;bn=bn+1;
            end else if(previous_b)begin
                $fwrite(bfd,"%0d %0d ",bs,cycle-1);
                for(j=0;j<bn;j=j+1)$fwrite(bfd,"%02x",b_bytes[j]);
                $fwrite(bfd,"\n");$fflush(bfd);
            end
            if(configured)begin
                if((|et)||(|ea)||(|eb)||rm||deliver||(|app))begin
                    $fwrite(efd,"%0d %02x %02x %02x %0d %0d %0d\n",cycle,et,ea,eb,rm,deliver,app);$fflush(efd);
                end
                if((|et[4:1])||(|ea[7:1])||(|eb[7:1])||(|app))
                    $fatal(1,"T76 unexpected event endpoint=%0d tx=%h a=%h b=%h app=%h",ID,et,ea,eb,app);
                if(rm)duplicates=duplicates+1;
            end
            previous_rx=rv;previous_a=tva;previous_b=tvb;
        end
    end
endmodule
