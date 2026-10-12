// 本模块按测试文件驱动两个端系统和四条单向网络连接。
// 它记录线路字节、消息交付和事件，由外层测试与参考检查器核对。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
// 测试指令只描述公开端口操作，不访问被测模块的内部状态。
module sys_suite #(parameter NAME="tb_sys_basic",TX_PAGE_AW=8,TX_OFF_AW=9,
 LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5,LINK_FRAMES=2048);
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
 link_model #(.LINK_ID(0),.MAX_FRAMES(LINK_FRAMES)) l0(clk,reset1,t1a,v1a,r2a,i2a,sf,l0e);
 link_model #(.LINK_ID(1),.MAX_FRAMES(LINK_FRAMES)) l1(clk,reset1,t1b,v1b,r2b,i2b,sf,l1e);
 link_model #(.LINK_ID(2),.MAX_FRAMES(LINK_FRAMES)) l2(clk,reset2,t2a,v2a,r1a,i1a,sf,l2e);
 link_model #(.LINK_ID(3),.MAX_FRAMES(LINK_FRAMES)) l3(clk,reset2,t2b,v2b,r1b,i1b,sf,l3e);
 reg [7:0] stimulus[0:31999999];
 reg [16383:0] injected;
 reg [8*40-1:0] command,stage_name;
 reg [31:0] addr,value,sp,dp;
 integer es,vl,n,pen,offset,count,delay,frame,mode,byte_index,mask,link;
 integer i,j,total,w0,w1,w2,w3,w4,w5,rxword,live_n,live_offset,live_count;
 task tick;begin @(posedge clk);#2;end endtask
 task check;input ok;input [8*100-1:0] label;
 begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;
 if(errors<20)$display("[FAIL] SYS cycle=%0d %0s",cycle,label);end end endtask
 always @(posedge clk)begin
  cycle=cycle+1;
  if(v1a||v1b||v2a||v2b||i1a||i1b||i2a||i2b||es1.d_valid||es2.d_valid||
     es1.ev_tx||es2.ev_tx||es1.ev_a||es1.ev_b||es2.ev_a||es2.ev_b||
     es1.ev_rm_drop||es2.ev_rm_drop||es1.ev_deliver||es2.ev_deliver||
     es1.ev_gdrop||es2.ev_gdrop||es1.line_activity||es2.line_activity)quiet=cycle;
  if(cycle>50000000 || errors+e1+e2+l0e+l1e+l2e+l3e>100)begin
   #1;
   $display("[RESULT] %0s FAIL checks=%0d errors=%0d",NAME,checks+c1+c2,errors+e1+e2+l0e+l1e+l2e+l3e+1);$finish;
  end
 end
 task drain;
 begin
  es1.wait_idle;es2.wait_idle;
  // 网络模型的队列也必须清空，不能只看此刻线路是否空闲。
  while(l0.next_regular<=l0.frame_count || l1.next_regular<=l1.frame_count ||
        l2.next_regular<=l2.frame_count || l3.next_regular<=l3.frame_count ||
        l0.next_extra<=l0.extra_count || l1.next_extra<=l1.extra_count ||
        l2.next_extra<=l2.extra_count || l3.next_extra<=l3.extra_count)tick;
  repeat(20001)tick;
  while(cycle-quiet<20001)tick;
 end endtask
 task set_delay;input integer which,cycles;
 begin case(which)0:l0.set_delay(cycles);1:l1.set_delay(cycles);2:l2.set_delay(cycles);3:l3.set_delay(cycles);endcase end endtask
 task action;input integer which,number,kind,byte_no,xor_mask;
 begin case(which)0:l0.set_action(number,kind,byte_no,xor_mask);1:l1.set_action(number,kind,byte_no,xor_mask);2:l2.set_action(number,kind,byte_no,xor_mask);3:l3.set_action(number,kind,byte_no,xor_mask);endcase end endtask
 task replay;input integer which,number;
 begin case(which)0:l0.replay(number);1:l1.replay(number);2:l2.replay(number);3:l3.replay(number);endcase end endtask
 task insert;input integer which,length,off;
 begin
  injected=0;for(j=0;j<length;j=j+1)injected[j*8+:8]=stimulus[off+j];
  case(which)0:l0.inject(length,injected);1:l1.inject(length,injected);2:l2.inject(length,injected);3:l3.inject(length,injected);endcase
 end endtask
 task read_many;input integer who;input [17:0] a;input integer amount;
 integer z;begin for(z=0;z<amount;z=z+1)if(who==1)es1.read_cfg(a);else es2.read_cfg(a);end endtask
 task live_rewrite;
 integer txj,rxj,msgj,previous_message;reg [31:0] words[0:5];
 begin
  words[0]=w0;words[1]=w1;words[2]=w2;words[3]=w3;words[4]=w4;words[5]=w5;
  fork
   begin for(msgj=0;msgj<live_count;msgj=msgj+1)begin
    es1.send_payload(0,live_n,0,16'h1234,16'h4321,live_offset+msgj*live_n);
    repeat(760)tick;
   end end
   begin
    previous_message=es1.last_message;
    for(txj=0;txj<live_count;txj=txj+1)begin
     while(es1.last_message==previous_message)tick;
     previous_message=es1.last_message;
     repeat((txj/6)%80)tick;
     es1.write_cfg(18'h1000+txj%6,words[txj%6],1);
    end
   end
   begin
    for(rxj=0;rxj<live_count;rxj=rxj+1)begin
     while(!es2.slow_rv_a)tick;
     while(es2.slow_rv_a)tick;
     repeat((rxj/2)%40)tick;
     if(rxj%2==0)es2.write_cfg(18'h10000+w2,32'h1000,1);
     else es2.write_cfg(18'h20000,rxword,1);
    end
   end
  join
 end endtask
 // 新值写只在这一专门阶段允许和流量并发；日志仍为W重写0及C。
 task change_live;
 input integer who,which,new_word,probe_n,off;
 integer prior;
 begin
  if(who==1)prior=es1.last_message;else prior=es2.last_message;
  fork
   begin
    if(who==1)es1.send_payload(which,18,0,16'h1234,16'h4321,off);
    else es2.send_payload(which,18,0,16'h1234,16'h4321,off);
   end
   begin
    if(who==1)while(es1.last_message==prior)tick;
    else while(es2.last_message==prior)tick;
    repeat(5)tick;
    if(who==1)begin es1.cfg_live=1;es1.write_cfg(18'h1000+which*8,new_word,0);es1.cfg_live=0;end
    else begin es2.cfg_live=1;es2.write_cfg(18'h1000+which*8,new_word,0);es2.cfg_live=0;end
   end
  join
  drain;
  if(who==1)es1.send_payload(which,probe_n,0,16'h1234,16'h4321,off);
  else es2.send_payload(which,probe_n,0,16'h1234,16'h4321,off);
  drain;
 end endtask
 // 10/77/81 条 VL 均匀错开提交，绝对调度不把应用调用耗时加进 BAG。
 task automatic perf_sender;
 input integer who,rounds,base,period,vls,off;
 integer r,v,target;
 begin
  for(r=0;r<rounds;r=r+1)for(v=0;v<vls;v=v+1)begin
   target=base+r*period+(v*period)/vls;
   while(cycle<target)tick;
   check(cycle==target,"performance submission slot not missed");
   if(who==1)es1.send_payload(v,1471,0,16'h1234,16'h4321,off+(r*vls+v)*1471);
   else es2.send_payload(v,1471,0,16'h1234,16'h4321,off+(r*vls+v)*1471);
  end
 end endtask
 task perf_traffic;
 input integer directions,rounds,period,vls,off1,off2;
 integer base;
 begin
  base=cycle+10;
  fork
   perf_sender(1,rounds,base,period,vls,off1);
   begin if(directions==2)perf_sender(2,rounds,base,period,vls,off2);end
   begin
    while(cycle<base+2*period)tick;
    $fwrite(sf,"F %0d begin %0s\n",cycle,stage_name);
    while(cycle<base+rounds*period)tick;
    $fwrite(sf,"F %0d end %0s\n",cycle,stage_name);
   end
  join
 end endtask
 task automatic light_sender;
 input integer who,length,rounds,period,base,off;
 integer r,target;
 begin
  for(r=0;r<rounds;r=r+1)begin
   target=base+r*period;
   while(cycle<target)tick;
   check(cycle==target,"light-load absolute submission slot");
   if(who==1)es1.send_payload(0,length,0,16'h1234,16'h4321,off+r*length);
   else es2.send_payload(0,length,0,16'h1234,16'h4321,off+r*length);
  end
 end endtask
 task light_traffic;
 input integer length,rounds,period,off1,off2;
 integer base;
 begin
  base=cycle+10;
  fork
   light_sender(1,length,rounds,period,base,off1);
   light_sender(2,length,rounds,period,base,off2);
  join
 end endtask
 task pulse_reads;input integer who;input [17:0] a;input integer amount;
 integer mj;begin
 fork
  read_many(who,a,amount);
  begin for(mj=0;mj<12;mj=mj+1)begin
   if((who==1 && a<18'h48)||(who==2 && a>=18'h48))es1.send_payload(0,18,0,16'h1234,16'h4321,live_offset+mj*18);
   else es2.send_payload(0,18,0,16'h1234,16'h4321,live_offset+mj*18);
   repeat(800)tick;
  end end
 join
 end endtask
 initial begin
  sf=$fopen("sys_events.txt","w");cf=$fopen("vectors/sys_commands.txt","r");
  pf=$fopen("vectors/sys_payload.count","r");rc=$fscanf(pf,"%d",total);$fclose(pf);
  $readmemh("vectors/sys_payload.hex",stimulus,0,total-1);
  $fwrite(sf,"G 0 TX_PAGE_AW %0d\nG 0 TX_OFF_AW %0d\nG 0 LOOKAHEAD %0d\nG 0 RX_RING_AW %0d\nG 0 RX_DQ_AW %0d\n",TX_PAGE_AW,TX_OFF_AW,LOOKAHEAD,RX_RING_AW,RX_DQ_AW);
  $fwrite(sf,"G 0 CLOCK_NS 8\nG 0 GMII_TX_DELAY 0\nG 0 GMII_RX_REPLAY_R 0\n");
  #2;set_delay(0,13001);set_delay(1,13001);set_delay(2,13001);set_delay(3,13001);
  repeat(4)tick;@(negedge clk);reset1=0;
  repeat(13)tick;@(negedge clk);reset2=0;
  while(!ready1||!ready2)tick;repeat(64)tick;
  while(!$feof(cf))begin
   command=0;rc=$fscanf(cf,"%s",command);
   case(command)
    "P":begin rc=$fscanf(cf,"%s",stage_name);drain;es1.stage(stage_name);es2.stage(stage_name);$fwrite(sf,"P %0d %0s\n",cycle,stage_name);$display("[STAGE] %0s cycle=%0d",stage_name,cycle);end
    "C":begin rc=$fscanf(cf,"%d %h %h %d",es,addr,value,mode);if(es==1)es1.write_cfg(addr,value,mode);else es2.write_cfg(addr,value,mode);if(!mode)repeat(17)tick;end
    "Q":begin rc=$fscanf(cf,"%d %h %d",es,addr,count);read_many(es,addr,count);end
    "V":begin rc=$fscanf(cf,"%d %h %d %d",es,addr,count,live_offset);pulse_reads(es,addr,count);end
    "U":begin
     rc=$fscanf(cf,"%d %h",es,value);
     @(negedge clk);
     if(es==1)begin es1.cfg_rewrite=0;es1.cfg_wr=1;es1.cfg_rd=1;es1.cfg_addr=2;es1.cfg_wdata=value;end
     else begin es2.cfg_rewrite=0;es2.cfg_wr=1;es2.cfg_rd=1;es2.cfg_addr=2;es2.cfg_wdata=value;end
     tick;@(negedge clk);if(es==1)begin es1.cfg_wr=0;es1.cfg_rd=0;end else begin es2.cfg_wr=0;es2.cfg_rd=0;end
     repeat(17)tick;
    end
    "M":begin rc=$fscanf(cf,"%d %d %d %d %h %h %d",es,vl,n,pen,sp,dp,offset);if(es==1)es1.send_payload(vl,n,pen,sp,dp,offset);else es2.send_payload(vl,n,pen,sp,dp,offset);end
    "B":begin rc=$fscanf(cf,"%d %d %d %d",vl,n,offset,count);fork es1.send_payload(vl,n,0,16'h1234,16'h4321,offset);es2.send_payload(vl,n,0,16'h1234,16'h4321,count);join end
    "X":begin rc=$fscanf(cf,"%h %h %h %h %h %h %h %d %d %d",w0,w1,w2,w3,w4,w5,rxword,live_n,live_offset,live_count);live_rewrite;end
    "Y":begin rc=$fscanf(cf,"%d %d %h %d %d",es,vl,value,n,offset);change_live(es,vl,value,n,offset);end
    "F":begin rc=$fscanf(cf,"%d %d %d %d %d %d",es,count,delay,vl,offset,live_offset);perf_traffic(es,count,delay,vl,offset,live_offset);end
    "K":begin rc=$fscanf(cf,"%d %d %d %d %d",n,count,delay,offset,live_offset);light_traffic(n,count,delay,offset,live_offset);end
    "L":begin rc=$fscanf(cf,"%d %d",link,delay);set_delay(link,delay);end
    "A":begin rc=$fscanf(cf,"%d %d %d %d %d",link,frame,mode,byte_index,mask);action(link,frame,mode,byte_index,mask);end
    "R":begin rc=$fscanf(cf,"%d %d",link,frame);replay(link,frame);end
    "J":begin rc=$fscanf(cf,"%d %d %d",link,n,offset);insert(link,n,offset);end
    "W":begin rc=$fscanf(cf,"%d",count);repeat(count)tick;end
    "D":drain;
    "H":begin while(!ready1||!ready2)tick;repeat(64)tick;end
    "Z":begin
     rc=$fscanf(cf,"%d",es);
     if(es==1)begin while(!i1a&&!i1b)tick;check(!v1a&&!v1b,"reset own TX idle");@(negedge clk);reset1=1;end
     else begin while(!i2a&&!i2b)tick;check(!v2a&&!v2b,"reset own TX idle");@(negedge clk);reset2=1;end
     repeat(4)tick;@(negedge clk);if(es==1)reset1=0;else reset2=0;
    end
    "T":begin es1.counters;es2.counters;end
    default:if(command!=0)begin check(0,"unknown command");$finish;end
   endcase
  end
  drain;es1.counters;es2.counters;repeat(4)tick;
  check(cycle-quiet>=20000,"final quiet window");
  check(l0e+l1e+l2e+l3e==0,"link model errors");
  check(e1+e2==0,"endpoint errors");
  $fflush(sf);$fflush(es1.tf);$fflush(es1.rf);$fflush(es2.tf);$fflush(es2.rf);
  $display("[COVERAGE] cycles=%0d",cycle);
  $display("[RESULT] %0s %0s checks=%0d errors=%0d",NAME,errors+e1+e2+l0e+l1e+l2e+l3e==0?"PASS":"FAIL",checks+c1+c2,errors+e1+e2+l0e+l1e+l2e+l3e);$finish;
 end
endmodule
