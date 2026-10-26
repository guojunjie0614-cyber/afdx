// 本模块通过公开配置口和应用口驱动一个加卸载端系统。
// 它核对报文和加载区内容，把检查数和错误数交给外层测试。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
module load_test_endpoint #(parameter ES=1,ALLOW_A_IC=0)(
    input wire clk,reset,input wire [7:0] ra,input wire rva,input wire [7:0] rb,input wire rvb,
    output wire [7:0] ta,output wire tva,output wire [7:0] tb,output wire tvb,output wire ready,
    output reg [31:0] checks=0,errors=0
);
    reg m_valid=0,m_last=0;reg [7:0] m_data=0;wire m_ready;
    reg [6:0] m_vl=1;reg [15:0] m_sp=3001,m_dp=4001;
    wire d_valid,d_last,d_net;wire [7:0] d_data;wire [11:0] d_vl;wire [15:0] d_sp,d_dp;
    reg wr=0,rd=0;reg [17:0] address=0;reg [31:0] wdata=0;
    wire [31:0] rdata;wire rvalid,bready;wire [6:0] ev_tx;wire [7:0] ev_a,ev_b;wire [1:0] gdrop=2'b00;wire rm_drop,deliver;
    integer received=0,sent=0,byte_index=0,head=0,tail=0,reply_length=0,log_fd,current_case,j;
    reg [7:0] expected_byte,queue[0:65535],send_bytes[0:1023];
    integer lengths[0:63],sports[0:63],dports[0:63];
    AFDX_top dut(
        .clk(clk),.reset(reset),.tx_data(ta),.tx_valid(tva),.rx_data(ra),.rx_valid(rva),.tx_ready(ready),.rx_ready(1'b0),
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
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[LOAD_ENDPOINT_FAIL] ES%0d %0s",ES,why);end end
    endtask
    always @(posedge clk)if(!reset)begin
        if(|ev_tx[4:1] || |(ev_a[7:1] & (ALLOW_A_IC ? 7'b1011111 : 7'b1111111)) || |ev_b[7:1] || |gdrop)check(0,"unexpected drop/error pulse");
        if(d_valid)begin
            if(ES==1 && d_vl==2)begin
                check(reply_length<1024 && tail-head<64,"bounded packet queue");queue[(tail%64)*1024+reply_length]=d_data;reply_length=reply_length+1;
                if(d_last)begin
                    lengths[tail%64]=reply_length;sports[tail%64]=d_sp;dports[tail%64]=d_dp;
                    $fwrite(log_fd,"D %0d %0d %0d %0d ",current_case,d_sp,d_dp,reply_length);
                    for(j=0;j<reply_length;j=j+1)$fwrite(log_fd,"%02x",queue[(tail%64)*1024+j]);
                    $fwrite(log_fd,"\n");$fflush(log_fd);reply_length=0;tail=tail+1;
                end
            end else begin
                expected_byte=byte_index+received*19+(3-ES)*37;
                check(d_dp==4001 && d_sp==3001 && d_vl==1,"615A hidden from target application; user metadata");
                check(d_data==expected_byte,"user bytes and sequence intact");byte_index=byte_index+1;
                if(d_last)begin check(byte_index==64,"complete user message");received=received+1;byte_index=0;end
            end
        end
    end
    task write_cfg;
        input [17:0] a;input [31:0] v;
        begin @(negedge clk);while(!bready)@(negedge clk);address=a;wdata=v;wr=1;
            @(posedge clk);#1;wr=0;while(!bready)begin @(posedge clk);#1;end end
    endtask
    task read_cfg;
        input [17:0] a;output [31:0] value;
        begin @(negedge clk);address=a;rd=1;@(posedge clk);#1;rd=0;
            @(posedge clk);#1;check(rvalid,"configuration read valid");value=rdata;end
    endtask
    task configure;
        integer v,maximum,vlid,peer_vlid;
        begin
            write_cfg(2,16'h2343+ES);
            for(v=0;v<3;v=v+1)begin
                maximum=v==1 ? 64 : 516;vlid=ES*100+v;peer_vlid=(3-ES)*100+v;
                write_cfg(18'h1000+v*8,maximum*512+63*8+7);write_cfg(18'h1001+v*8,1);
                write_cfg(18'h1002+v*8,vlid);write_cfg(18'h1003+v*8,32'h0a000001+ES);
                // 服务 VL 用双方单播 IP，TFTP 请求与回应形成真实的反向 IP 会话。
                write_cfg(18'h1004+v*8,v==1 ? 32'he0e00000+vlid : 32'h0a000004-ES);write_cfg(18'h1005+v*8,32'h0bb90fa1);
                write_cfg(18'h10000+peer_vlid,4096+v);write_cfg(18'h20000+v,maximum*131072+20*32+31);
            end
        end
    endtask
    task send_byte;
        input [7:0] value;input last;reg accepted;
        begin @(negedge clk);m_valid=1;m_last=last;m_data=value;accepted=0;
            while(!accepted)begin @(posedge clk);accepted=m_ready;#1;end end
    endtask
    task user_message;
        integer n;
        begin m_vl=1;m_sp=3001;m_dp=4001;
            for(n=0;n<64;n=n+1)send_byte(n+sent*19+ES*37,n==63);
            m_valid=0;m_last=0;sent=sent+1;end
    endtask
    task packet;
        input integer length,sport,dport;integer n;
        begin m_vl=0;m_sp=sport;m_dp=dport;
            for(n=0;n<length;n=n+1)send_byte(send_bytes[n],n+1==length);
            m_valid=0;m_last=0;end
    endtask
endmodule
