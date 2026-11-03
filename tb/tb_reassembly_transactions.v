`timescale 1ns/1ps
module tb_reassembly_transactions;
  localparam TIMEOUT_CYCLES=80;
  reg clk=0; always #4 clk=~clk;
  reg reset=1,query=0,reserve=0,cancel=0,in_start=0,in_valid=0,in_last=0,in_empty=0,in_frag=1;
  reg [11:0] r_vl=0;
  reg [125:0] r_meta=0;
  reg [10:0] r_length=0;
  reg [15:0] r_sport=0,r_dport=0;
  reg r_net=0;
  reg [3:0] in_slot=0;
  reg [7:0] in_data=0;
  wire result_valid,reserve_ok,ready,prepared,d_valid,d_last,d_net;
  wire [3:0] reserve_slot;
  wire [7:0] d_data;
  wire [11:0] d_vl;
  wire [15:0] d_sport,d_dport;
  wire [1:0] reject_events;
  afdx_rx_reassembly #(.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) dut(
    .clk(clk),.reset(reset),.query(query),.reserve(reserve),.cancel(cancel),.result_valid(result_valid),
    .r_vl(r_vl),.r_meta(r_meta),.r_length(r_length),.r_sport(r_sport),.r_dport(r_dport),.r_net(r_net),
    .reserve_ok(reserve_ok),.reserve_slot(reserve_slot),.in_start(in_start),
    .in_valid(in_valid),.in_last(in_last),.in_empty(in_empty),.in_frag(in_frag),.in_slot(in_slot),.in_data(in_data),
    .in_vl(12'd0),.in_sport(16'd0),.in_dport(16'd0),.in_net(1'b0),.ready(ready),.prepared(prepared),
    .d_valid(d_valid),.d_last(d_last),.d_data(d_data),.d_vl(d_vl),.d_sport(d_sport),.d_dport(d_dport),
    .d_net(d_net),.reject_events(reject_events),.query_bank(),.reserve_bank(),.cancel_bank());
  integer cycle=0,errors=0,checks=0,deliveries=0,out_pos=0,event_count=0;
  integer expected_length[0:255],seen[0:255];
  integer event_allowed=0;
  integer i,j,n,prior_events,collision_edges=0;
  reg [3:0] chosen,other;
  function [5:0] context_pending; input [3:0] slot;
    begin context_pending=slot[3] ? dut.banks[1].u_bank.pending[slot[2:0]] : dut.banks[0].u_bank.pending[slot[2:0]];end
  endfunction
  function context_closed; input [3:0] slot;
    begin context_closed=slot[3] ? dut.banks[1].u_bank.closed[slot[2:0]] : dut.banks[0].u_bank.closed[slot[2:0]];end
  endfunction
  function [31:0] context_age; input [3:0] slot;
    begin context_age=slot[3] ? dut.banks[1].u_bank.age[slot[2:0]] : dut.banks[0].u_bank.age[slot[2:0]];end
  endfunction
  function [7:0] pattern; input integer id,pos;
    begin pattern=(id*13+pos*7+3)&255; end
  endfunction
  function [15:0] udp_check; input integer id,len;
    reg [31:0] sum; integer p;
    begin
      sum=16'h0a00+1+16'he000+1+17+2*(len+8)+(16'h1000+id)+(16'h2000+id);
      for(p=0;p<len;p=p+2) sum=sum+{pattern(id,p),8'b0}+(p+1<len ? pattern(id,p+1) : 0);
      sum=(sum&65535)+(sum>>16); sum=(sum&65535)+(sum>>16);
      udp_check=~sum[15:0]; if(udp_check==0)udp_check=16'hffff;
    end
  endfunction
  task fail; input [8*120-1:0] msg;
    begin errors=errors+1;$display("[FAIL] cycle=%0d %0s",cycle,msg);end
  endtask
  always @(posedge clk) begin
    cycle=cycle+1;
    if(!reset && (|(dut.banks[0].u_bank.commit_rows & dut.banks[0].u_bank.retire_rows) ||
                  |(dut.banks[1].u_bank.commit_rows & dut.banks[1].u_bank.retire_rows))) collision_edges=collision_edges+1;
    #1;
    if(!reset) begin
      if(reject_events!=0) begin
        event_count=event_count+1;
        if(!event_allowed)fail("unexpected timeout/checksum event");
      end
      if(d_valid) begin
        if(expected_length[d_vl]==0 || seen[d_vl]!=0)fail("unexpected/duplicate application output");
        if(d_data!==pattern(d_vl,out_pos))fail("payload mismatch");
        if(d_sport!==(16'h1000+d_vl) || d_dport!==(16'h2000+d_vl) || d_net!==(d_vl&1))fail("metadata mismatch");
        if(d_last!==(out_pos==expected_length[d_vl]-1))fail("last mismatch");
        out_pos=out_pos+1;
        if(d_last)begin seen[d_vl]=seen[d_vl]+1;deliveries=deliveries+1;out_pos=0;end
      end else if(out_pos!=0)fail("output throughput below one byte per clock");
    end
  end
  genvar check_bank,check_row;
  generate for(check_bank=0;check_bank<2;check_bank=check_bank+1)begin:bank_invariants
    always @(posedge clk) if(!reset && dut.banks[check_bank].u_bank.payload_re)
      if(dut.banks[check_bank].u_bank.output_last_request !==
         (dut.banks[check_bank].u_bank.output_position==dut.banks[check_bank].u_bank.output_total-1))
        fail("split terminal flag disagrees with the physical read position");
    for(check_row=0;check_row<8;check_row=check_row+1)begin:row_invariants
      always @(posedge clk) begin
        #1;
        if(!reset && (dut.banks[check_bank].u_bank.pending_full[check_row] !==
                     (&dut.banks[check_bank].u_bank.pending[check_row])))
          fail("registered pending-full flag is not aligned with pending");
      end
    end
  end endgenerate
  task set_request; input integer id,offset,len,mf,total,bad;
    begin
      r_vl=id;r_length=len;r_sport=16'h1000+id;r_dport=16'h2000+id;r_net=id&1;
      r_meta={32'h0a000001,32'he0000001,16'd0,13'd0,1'b0,16'd0,16'd0};
      r_meta[61:46]=id;r_meta[45:33]=offset;r_meta[32]=mf;r_meta[31:16]=total+8;
      r_meta[15:0]=udp_check(id,total)^(bad ? 16'd1 : 16'd0);
    end
  endtask
  task request; input integer id,offset,len,mf,total,bad,permit,action; output [3:0] slot;
    integer elapsed;
    begin
      @(negedge clk);set_request(id,offset,len,mf,total,bad);query=1;
      @(negedge clk);query=0;
      // The request fields may change immediately after the request edge.
      r_meta=0;r_vl=12'hfff;r_length=0;
      elapsed=0;
      while(!result_valid && elapsed<24)begin @(negedge clk);elapsed=elapsed+1;end
      checks=checks+1;
      if(!result_valid || elapsed!=19)fail("query latency is not nineteen clocks");
      if(reserve_ok!==permit)begin $display("id=%0d off=%0d permit=%0d actual=%b",id,offset,permit,reserve_ok);fail("admission mismatch");end
      slot=reserve_slot;
      if(action!=2)begin reserve=(action==1);cancel=(action==0);@(negedge clk);reserve=0;cancel=0;end
    end
  endtask
  task copy; input integer id,slot,start_pos,len,commit_last;
    integer p;
    begin
      // Preprepare before query. Last byte is Q27; reserve at Q30 produces
      // the physical pending increment at Q31, exactly with last-byte E4.
      if(!commit_last)begin
        while(!ready)@(negedge clk);
        @(negedge clk);in_start=1;in_slot=slot;in_empty=(len==0);
        @(negedge clk);in_start=0;in_empty=0;
        while(!prepared)@(negedge clk);
      end
      for(p=0;p<len;p=p+1)begin
        in_valid=1;in_last=(p==len-1);in_data=pattern(id,start_pos+p);
        @(negedge clk);
      end
      in_valid=0;in_last=0;reserve=0;
      if(commit_last)begin
        repeat(2)@(negedge clk);reserve=1;
        @(negedge clk);reserve=0;
      end
      while(!ready)@(negedge clk);
    end
  endtask
  task wait_output; input integer id; integer deadline;
    begin
      deadline=cycle+expected_length[id]+50;
      while(seen[id]==0 && cycle<deadline)@(negedge clk);
      checks=checks+1;if(seen[id]!=1)fail("complete output missing");
      repeat(3)@(negedge clk);
    end
  endtask
  task reset_contexts;
    begin
      @(negedge clk);reset=1;query=0;reserve=0;cancel=0;in_start=0;in_valid=0;in_empty=0;
      repeat(3)@(negedge clk);reset=0;repeat(2)@(negedge clk);
    end
  endtask
  initial begin
    for(i=0;i<256;i=i+1)begin expected_length[i]=0;seen[i]=0;end
    reset_contexts;
    // Cancel before/after every lookup stage: no allocation or stale result.
    for(j=0;j<=19;j=j+1)begin
      @(negedge clk);set_request(10,0,8,1,16,0);query=1;
      @(negedge clk);query=0;repeat(j)@(negedge clk);
      cancel=1;@(negedge clk);cancel=0;
      if(result_valid)fail("cancel did not clear response");
      request(10,0,8,1,16,0,1,0,chosen);
    end
    // Reserve is atomic with end-copy, so pending must remain one.
    request(20,0,8,1,16,0,1,1,chosen);
    while(!ready)@(negedge clk);
    @(negedge clk);in_start=1;in_slot=chosen;in_empty=0;
    @(negedge clk);in_start=0;
    while(!prepared)@(negedge clk);
    request(20,2,8,0,16,0,1,2,other);
    if(chosen!=other)fail("context identity changed");
    copy(20,chosen,0,8,1);
    if(context_pending(chosen)!=1 || !context_closed(chosen) || collision_edges!=1)fail("physical commit/retire collision lost pending state");
    expected_length[20]=16;copy(20,chosen,8,8,0);wait_output(20);
    // Pending accepted data must survive arbitrarily longer than timeout.
    request(21,0,8,1,17,0,1,1,chosen);
    prior_events=event_count;repeat(TIMEOUT_CYCLES+20)@(negedge clk);
    if(event_count!=prior_events)fail("pending fragment timed out");
    copy(21,chosen,0,8,0);
    request(21,2,9,0,17,0,1,1,other);
    expected_length[21]=17;copy(21,chosen,8,9,0);wait_output(21);
    // A corrupted nonzero UDP checksum never exposes partial application data.
    request(22,0,8,1,16,1,1,1,chosen);copy(22,chosen,0,8,0);
    request(22,2,8,0,16,1,1,1,other);
    event_allowed=1;prior_events=event_count;copy(22,chosen,8,8,0);repeat(10)@(negedge clk);
    checks=checks+1;if(event_count!=prior_events+1 || seen[22]!=0)fail("checksum reject missing or leaked output");event_allowed=0;
    // Header-only first fragments use the empty/start boundary without data.
    request(23,0,0,1,9,0,1,1,chosen);copy(23,chosen,0,0,0);
    request(23,1,9,0,9,0,1,1,other);
    expected_length[23]=9;copy(23,chosen,0,9,0);wait_output(23);
    // Expiry after row snapshot must be caught by selected-state revalidation.
    request(24,0,8,1,16,0,1,1,chosen);copy(24,chosen,0,8,0);
    while(context_age(chosen)<76)@(negedge clk);
    event_allowed=1;prior_events=event_count;
    request(24,2,8,0,16,0,0,0,other);repeat(3)@(negedge clk);
    checks=checks+1;if(event_count!=prior_events+1)fail("expiry during query missing");event_allowed=0;
    // A lost owner cannot lock a row forever: watchdog releases the result.
    request(25,0,8,1,16,0,1,1,chosen);copy(25,chosen,0,8,0);
    while(context_age(chosen)<TIMEOUT_CYCLES-18)@(negedge clk);
    request(25,2,8,0,16,0,1,2,other);
    event_allowed=1;prior_events=event_count;
    repeat(12)@(negedge clk);
    if(!result_valid)fail("watchdog released owner before query+32");
    @(negedge clk);if(result_valid)fail("watchdog retained owner beyond query+32");
    repeat(24)@(negedge clk);
    checks=checks+1;if(result_valid || event_count!=prior_events+1)fail("bounded lock failed to release/expire");event_allowed=0;
    // Once accepted, the registered allocation write must survive a cancel
    // arriving on its physical write edge.
    request(26,0,8,1,16,0,1,1,chosen);
    cancel=1;@(negedge clk);cancel=0;
    if(context_pending(chosen)!=1)fail("cancel revoked accepted allocation");
    copy(26,chosen,0,8,0);
    while(context_age(chosen)<TIMEOUT_CYCLES-18)@(negedge clk);
    request(26,2,8,0,16,0,1,2,other);
    repeat(12)@(negedge clk); // Q31 remains valid; next edge accepts at Q32.
    if(!result_valid || !reserve_ok)fail("deadline reservation lost its valid owner");
    reserve=1;@(negedge clk);reserve=0;cancel=1;
    @(negedge clk);cancel=0;
    if(context_pending(chosen)!=1)fail("watchdog/cancel revoked physical commit");
    expected_length[26]=16;copy(26,chosen,8,8,0);wait_output(26);
    // 8192-byte application, six frames, real checksum and continuous output.
    request(30,0,1464,1,8192,0,1,1,chosen);copy(30,chosen,0,1464,0);
    for(n=1464;n<7352;n=n+1472)begin
      request(30,(n+8)/8,1472,1,8192,0,1,1,other);copy(30,chosen,n,1472,0);
    end
    request(30,920,840,0,8192,0,1,1,other);
    expected_length[30]=8192;copy(30,chosen,7352,840,0);wait_output(30);
    // Comparator pipeline startup and its first seven-bit carry boundary.
    for(j=0;j<4;j=j+1)begin
      n=j==3 ? 129 : j+1;i=40+j;
      request(i,0,0,1,n,0,1,1,chosen);copy(i,chosen,0,0,0);
      request(i,1,n,0,n,0,1,1,other);
      expected_length[i]=n;copy(i,chosen,0,n,0);wait_output(i);
    end
    // Exercise 62->63/full rejection, then retirement and renewed admission.
    // These are short accepted fragments; pending work prevents the 80-clock timeout.
    request(50,0,8,1,512,0,1,1,chosen);
    for(j=1;j<63;j=j+1) request(50,j+1,8,1,512,0,1,1,other);
    repeat(2)@(negedge clk);
    if(context_pending(chosen)!=63)fail("pending saturation fixture did not reach 63");
    request(50,64,8,0,512,0,0,0,other);
    copy(50,chosen,0,8,0);
    if(context_pending(chosen)!=62)fail("retirement did not release a pending credit");
    request(50,64,8,0,512,0,1,1,other);
    repeat(2)@(negedge clk);
    if(context_pending(chosen)!=63 || !context_closed(chosen))fail("full prediction blocked the released credit");
    checks=checks+1;if(deliveries!=9 || out_pos!=0)fail("wrong number of complete datagrams");
    if(errors)begin $display("[RESULT] tb_reassembly_transactions FAIL checks=%0d errors=%0d",checks,errors);$finish;end
    $display("[RESULT] tb_reassembly_transactions PASS checks=%0d errors=0 deliveries=%0d",checks,deliveries);$finish;
  end
  initial begin #2000000;$display("[RESULT] tb_reassembly_transactions FAIL watchdog");$finish;end
endmodule
