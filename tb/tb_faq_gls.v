`timescale 1ns/1ps
// One complete end system, public A/B GMII loopback; no hierarchy inside DUT.
// Configuration and schedule use the fragment_integration capture contract.
module tb_faq_gls;
reg clk=0,reset=1;
always #4 clk=~clk;
reg [7:0] input_data=0;
reg input_valid=0,wr=0;
reg [17:0] address=0;
reg [31:0] wdata=0;
wire input_ready,output_valid,cfg_ready,cfg_rvalid,va,vb,rm,deliver;
wire [7:0] output_data,a,b,ev_a,ev_b;
wire [31:0] cfg_rdata;
wire [6:0] ev_tx;
wire [2:0] ev_app;
integer cycle=0,checks=0,errors=0,received=0,frames_a=0,frames_b=0,duplicates=0;
integer fd_a,fd_b,fd_rx,fd_tx,fd_ev,cf,sf,rc,configs,msgs,payload_count,target;
integer idx,vl,bag,lmax,sport,dport,due,n,off,epoch,start,j;
integer rn=0,an=0,bn=0,rs=0,as_=0,bs=0;
reg prev_rx=0,prev_a=0,prev_b=0;
reg [7:0] payload[0:1552],rx_bytes[0:1473],a_bytes[0:1525],b_bytes[0:1525];
AFDX_top dut(.clk(clk),.reset(reset),.tx_data(input_data),.tx_valid(input_valid),.tx_ready(input_ready),
 .rx_data(output_data),.rx_valid(output_valid),.rx_ready(1'b1),
 .gmii_txd_a(a),.gmii_tx_en_a(va),.gmii_txd_b(b),.gmii_tx_en_b(vb),
 .gmii_rxd_a(a),.gmii_rx_dv_a(va),.gmii_rxd_b(b),.gmii_rx_dv_b(vb),
 .cfg_wr(wr),.cfg_rd(1'b0),.cfg_addr(address),.cfg_wdata(wdata),
 .cfg_rdata(cfg_rdata),.cfg_rvalid(cfg_rvalid),.cfg_ready(cfg_ready),
 .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(rm),.ev_deliver(deliver),.ev_app(ev_app));
task check;input ok;input [8*100-1:0] why;begin
 checks=checks+1;
 if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[FAIL] %0s cycle=%0d",why,cycle);end
end endtask
task finish_result;begin
 $fwrite(fd_ev,"FINAL %0d 0 0\n",received);$fflush(fd_ev);
 $display("[RESULT] tb_faq_gls %0s checks=%0d errors=%0d deliveries=%0d frames_a=%0d frames_b=%0d duplicates=%0d",
 errors==0?"PASS":"FAIL",checks,errors,received,frames_a,frames_b,duplicates);
 if(errors)$fatal(1);else $finish;
end endtask
always @(posedge clk)begin
 cycle=cycle+1;
 if(cycle>450000)begin check(0,"bounded liveness watchdog");finish_result;end
 if(!reset)begin
  check((^{input_ready,output_valid,cfg_ready,cfg_rvalid,va,vb,rm,deliver})!==1'bx,"public control signals have no X/Z");
  check((^{ev_tx,ev_a,ev_b,ev_app})!==1'bx,"public event signals have no X/Z");
  check((ev_tx[4:1]==0)&&(ev_a[7:1]==0)&&(ev_b[7:1]==0)&&(ev_app==0),"no business drop or corrupt frame");
  if(rm===1'b1)duplicates=duplicates+1;
  if(output_valid===1'b1)begin
   check((^output_data)!==1'bx,"valid application data has no X/Z");
   if(!prev_rx)begin rn=0;rs=cycle;end
   check(rn<1474,"bounded application capture");if(rn<1474)rx_bytes[rn]=output_data;rn=rn+1;
  end else if(prev_rx)begin
   $fwrite(fd_rx,"%0d %0d %02x%02x ",rs,cycle-1,rx_bytes[0],rx_bytes[1]);
   for(j=2;j<rn&&j<1474;j=j+1)$fwrite(fd_rx,"%02x",rx_bytes[j]);$fwrite(fd_rx,"\n");$fflush(fd_rx);received=received+1;
  end
  prev_rx=output_valid;
  if(va===1'b1)begin
   check((^a)!==1'bx,"valid A frame data has no X/Z");
   if(!prev_a)begin an=0;as_=cycle;end
   check(an<1526,"bounded A capture");if(an<1526)a_bytes[an]=a;an=an+1;
  end else if(prev_a)begin
   $fwrite(fd_a,"%0d ",as_);for(j=0;j<an&&j<1526;j=j+1)$fwrite(fd_a,"%02x",a_bytes[j]);$fwrite(fd_a,"\n");$fflush(fd_a);frames_a=frames_a+1;
  end
  prev_a=va;
  if(vb===1'b1)begin
   check((^b)!==1'bx,"valid B frame data has no X/Z");
   if(!prev_b)begin bn=0;bs=cycle;end
   check(bn<1526,"bounded B capture");if(bn<1526)b_bytes[bn]=b;bn=bn+1;
  end else if(prev_b)begin
   $fwrite(fd_b,"%0d ",bs);for(j=0;j<bn&&j<1526;j=j+1)$fwrite(fd_b,"%02x",b_bytes[j]);$fwrite(fd_b,"\n");$fflush(fd_b);frames_b=frames_b+1;
  end
  prev_b=vb;
  if(ev_app||ev_tx[4:1]||ev_a[7:1]||ev_b[7:1]||rm)
   $fwrite(fd_ev,"%0d %02x %02x %02x %02x %01x\n",cycle,ev_tx,ev_a,ev_b,ev_app,rm);
 end
end
task cfg;input [17:0] addr;input [31:0] data;begin
 @(negedge clk);while(!cfg_ready)@(negedge clk);address=addr;wdata=data;wr=1;
 @(negedge clk);wr=0;while(!cfg_ready)@(negedge clk);
end endtask
task send;input integer id,len,offset;integer p;begin
 while(!input_ready)@(negedge clk);
 @(negedge clk);start=cycle+1;input_valid=1;input_data=id>>8;
 @(negedge clk);input_data=id;
 for(p=0;p<len;p=p+1)begin @(negedge clk);input_data=payload[offset+p];end
 @(negedge clk);input_valid=0;
 $fwrite(fd_tx,"%0d %0d %0d %0d\n",start,cycle,id,len);$fflush(fd_tx);
end endtask
initial begin
 fd_a=$fopen("tx_a.txt","w");fd_b=$fopen("tx_b.txt","w");fd_rx=$fopen("rx.txt","w");
 fd_tx=$fopen("tx_messages.txt","w");fd_ev=$fopen("events.txt","w");
 cf=$fopen("vectors/config.txt","r");sf=$fopen("vectors/schedule.txt","r");
 if(!fd_a||!fd_b||!fd_rx||!fd_tx||!fd_ev||!cf||!sf)begin check(0,"all capture and input files open");finish_result;end
 rc=$fscanf(cf,"%d",configs);check(rc==1&&configs==2,"exact two-VL configuration");
 rc=$fscanf(sf,"%d %d %d",msgs,payload_count,target);
 check(rc==3&&msgs==3&&target==3&&payload_count==1553,"exact representative workload");
 $readmemh("vectors/payload.hex",payload,0,1552);
 repeat(8)@(negedge clk);reset=0;
 for(idx=0;idx<configs;idx=idx+1)begin
  rc=$fscanf(cf,"%d %d %d %d %d",vl,bag,lmax,sport,dport);check(rc==5,"configuration row");
  cfg(18'h1000+idx*8,lmax*512+63*8+7);cfg(18'h1001+idx*8,bag*125);cfg(18'h1002+idx*8,vl);
  cfg(18'h1003+idx*8,32'h0a000101+idx);cfg(18'h1004+idx*8,32'he0e00000|vl);cfg(18'h1005+idx*8,(sport<<16)|dport);
  cfg(18'h10000+vl,4096+idx);cfg(18'h20000+idx,lmax*131072+20*32+31);
 end
 epoch=cycle+16;$fwrite(fd_tx,"E %0d\n",epoch);
 for(idx=0;idx<msgs;idx=idx+1)begin
  rc=$fscanf(sf,"%d %d %d %d",due,vl,n,off);
  check(rc==4&&n>0&&n<=1472&&off>=0&&off+n<=payload_count,"valid scheduled input row");
  while(cycle<epoch+due)@(negedge clk);send(vl,n,off);
 end
 wait(received>=target);
 repeat(2048)@(negedge clk);
 check(received==3&&!output_valid&&!prev_rx,"exactly three complete deliveries and quiet tail");
 check(frames_a==4&&frames_b==4,"both networks carry two long fragments and two short frames");
 check(duplicates==4,"one redundancy rejection per physical A/B pair");
 finish_result;
end
endmodule
