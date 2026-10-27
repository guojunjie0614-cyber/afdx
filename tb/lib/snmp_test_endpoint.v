// 本模块通过应用口发送网络管理报文，通过配置口读取预期值。
// 它把比较结果计入网络管理测试。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
module snmp_test_endpoint #(parameter ES=1)(
    input wire clk,reset,input wire [7:0] ra,input wire rva,input wire [7:0] rb,input wire rvb,
    output wire [7:0] ta,output wire tva,output wire [7:0] tb,output wire tvb,output wire ready,
    output reg [31:0] checks=0,errors=0
);
    reg m_valid=0,m_last=0;reg [7:0] m_data=0;wire m_ready;
    reg [6:0] m_vl=1;reg [15:0] m_sp=3001,m_dp=4001;
    wire d_valid,d_last,d_net;wire [7:0] d_data;wire [11:0] d_vl;wire [15:0] d_sp,d_dp;
    reg wr=0,rd=0;reg [17:0] address=0;reg [31:0] wdata=0;
    wire [31:0] rdata;wire rvalid,bready;
    wire [6:0] ev_tx;wire [7:0] ev_a,ev_b;wire [1:0] gdrop=2'b00;wire rm_drop,deliver;
    integer received=0,sent=0,byte_index=0,replies=0,traps=0,reply_length=0,log_fd,current_case,j;
    reg [7:0] expected_byte,reply_bytes[0:255],request_bytes[0:16383];
    reg [31:0] sample_values[0:262143],sample_tags[0:262143],read_tag0=0,read_tag1=0;
    wire [31:0] sample_now;wire sample_en;wire [15:0] sample_coarse;
    afdx_timebase test_clock(clk,reset,sample_now,sample_en,sample_coarse);
    initial $readmemh("vectors/bytes.hex",request_bytes);
    top_stream_endpoint dut(
        .raw_mode(1'b0),.raw_vlid(16'd0),.initialized(),.clk(clk),.reset(reset),.tx_data(ta),.tx_valid(tva),.rx_data(ra),.rx_valid(rva),.tx_ready(ready),.rx_ready(1'b0),
        .tx_data_b(tb),.tx_valid_b(tvb),.rx_data_b(rb),.rx_valid_b(rvb),
        .app_tx_valid(m_valid),.app_tx_ready(m_ready),.app_tx_data(m_data),.app_tx_last(m_last),.app_tx_vl(m_vl),
        .app_tx_port_en(1'b1),.app_tx_sport(m_sp),.app_tx_dport(m_dp),
        .app_rx_valid(d_valid),.app_rx_data(d_data),.app_rx_last(d_last),.app_rx_vl(d_vl),
        .app_rx_sport(d_sp),.app_rx_port(d_dp),.app_rx_net(d_net),
        .cfg_wr(wr),.cfg_rd(rd),.cfg_addr(address),.cfg_wdata(wdata),.cfg_rdata(rdata),.cfg_rvalid(rvalid),.cfg_ready(bready),
        .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(rm_drop),.ev_deliver(deliver)
    );
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[SNMP_ENDPOINT_FAIL] ES%0d %0s",ES,why);end end
    endtask
    always @(posedge clk)begin
        read_tag0<=sample_now;read_tag1<=read_tag0;
        if(!reset)begin
            if(rvalid)begin sample_values[read_tag1[17:0]]=rdata;sample_tags[read_tag1[17:0]]=read_tag1;end
            if(|ev_tx[4:1] || |ev_a[7:1] || |ev_b[7:1] || |gdrop)check(0,"unexpected drop/error pulse");
            if(d_valid)begin
                if(ES==1 && d_sp==161)begin
                    check(d_vl==2 && reply_length<256,"SNMP response metadata and bounded length");
                    reply_bytes[reply_length]=d_data;reply_length=reply_length+1;
                    if(d_last)begin
                        if(d_dp==162)$fwrite(log_fd,"T %0d %0d %0d %0d %0d ",traps,sample_now,d_sp,d_dp,reply_length);
                        else $fwrite(log_fd,"D %0d %0d %0d %0d ",current_case,d_sp,d_dp,reply_length);
                        for(j=0;j<reply_length;j=j+1)$fwrite(log_fd,"%02x",reply_bytes[j]);
                        $fwrite(log_fd,"\n");reply_length=0;if(d_dp==162)traps=traps+1;else replies=replies+1;
                    end
                end else begin
                    expected_byte=byte_index+received*19+(3-ES)*37;
                    check(d_dp==4001 && d_sp==3001 && d_vl==1,"SNMP hidden from agent application and user metadata intact");
                    check(d_data==expected_byte,"user bytes and sequence intact");
                    byte_index=byte_index+1;
                    if(d_last)begin check(byte_index==64,"complete user message");received=received+1;byte_index=0;end
                end
            end
        end
    end
    task write_cfg;
        input [17:0] a;input [31:0] v;
        begin
            @(negedge clk);while(!bready)@(negedge clk);address=a;wdata=v;wr=1;
            @(posedge clk);#1;wr=0;while(!bready)begin @(posedge clk);#1;end
        end
    endtask
    task read_cfg;
        input [17:0] a;output [31:0] value;
        begin
            @(negedge clk);address=a;rd=1;@(posedge clk);#1;rd=0;
            @(posedge clk);#1;check(rvalid,"configuration read valid");value=rdata;
        end
    endtask
    task configure;
        integer v,maximum,vlid,peer_vlid;
        begin
            write_cfg(2,16'h2343+ES);
            for(v=0;v<3;v=v+1)begin
                maximum=v==1 ? 64 : 256;vlid=ES*100+v;peer_vlid=(3-ES)*100+v;
                write_cfg(18'h1000+v*8,maximum*512+63*8+7);write_cfg(18'h1001+v*8,1);
                write_cfg(18'h1002+v*8,vlid);write_cfg(18'h1003+v*8,32'h0a000001+ES);
                write_cfg(18'h1004+v*8,32'he0e00000+vlid);write_cfg(18'h1005+v*8,32'h0bb90fa1);
                write_cfg(18'h10000+peer_vlid,4096+v);write_cfg(18'h20000+v,maximum*131072+20*32+31);
            end
        end
    endtask
    task send_byte;
        input [7:0] value;input last;
        reg accepted;
        begin
            @(negedge clk);m_valid=1;m_last=last;m_data=value;accepted=0;
            while(!accepted)begin @(posedge clk);accepted=m_ready;#1;end
        end
    endtask
    task user_message;
        integer n;
        begin
            m_vl=1;m_sp=3001;m_dp=4001;
            for(n=0;n<64;n=n+1)send_byte(n+sent*19+ES*37,n==63);
            m_valid=0;m_last=0;sent=sent+1;
        end
    endtask
    task request_message;
        input integer offset,length,sport;integer n;
        begin
            write_cfg(18'h1005,(sport<<16)|161);m_vl=0;m_sp=sport;m_dp=161;
            for(n=0;n<length;n=n+1)send_byte(request_bytes[offset+n],n+1==length);
            m_valid=0;m_last=0;
        end
    endtask
endmodule
