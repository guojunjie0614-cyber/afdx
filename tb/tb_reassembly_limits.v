`timescale 1ns/1ps
// Standalone test of the public reserve/copy interface, not parser or IC/RM.
module tb_reassembly_limits;
  // Sixteen contexts are drained serially, including the four-cycle payload
  // read pipeline. Leave time for that capacity test before intentional expiry.
  parameter integer TIMEOUT_CYCLES=1200;
  reg clk=0; always #4 clk=~clk;
  reg reset=1, query=0, reserve=0, cancel=0, in_start=0, in_valid=0, in_last=0, in_empty=0, in_frag=1;
  reg [11:0] r_vl=0, in_vl=0;
  reg [125:0] r_meta=0;
  reg [10:0] r_length=8;
  reg [15:0] r_sport=0,r_dport=0,in_sport=0,in_dport=0;
  reg r_net=0,in_net=0;
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
    .in_start(in_start),.r_vl(r_vl),.r_meta(r_meta),.r_length(r_length),
    .r_sport(r_sport),.r_dport(r_dport),.r_net(r_net),.reserve_ok(reserve_ok),.reserve_slot(reserve_slot),
    .in_valid(in_valid),.in_last(in_last),.in_empty(in_empty),.in_frag(in_frag),.in_slot(in_slot),.in_data(in_data),
    .in_vl(in_vl),.in_sport(in_sport),.in_dport(in_dport),.in_net(in_net),.ready(ready),.prepared(prepared),
    .d_valid(d_valid),.d_last(d_last),.d_data(d_data),.d_vl(d_vl),.d_sport(d_sport),.d_dport(d_dport),
    .d_net(d_net),.reject_events(reject_events),.query_bank(),.reserve_bank(),.cancel_bank());
  integer cycle=0, errors=0, deliveries=0, byte_pos=0, byte_vl=-1;
  integer timeout_a=0,timeout_b=0,timeout_phase=0,checks=0;
  integer expected[0:4095], seen[0:4095];
  reg [3:0] slots[0:15];
  integer i;
  function [7:0] pattern; input integer id; input integer pos;
    begin pattern=(id*13+pos*7+3)&255; end
  endfunction
  task fail; input [8*120-1:0] message;
    begin errors=errors+1; $display("[FAIL] cycle=%0d %0s",cycle,message); end
  endtask
  always @(posedge clk) begin
    cycle=cycle+1;
    #1;
    if (!reset) begin
      if(reject_events!=0) begin
        if(!timeout_phase) fail("unexpected reject_events");
        if(reject_events[0]) timeout_a=timeout_a+1;
        if(reject_events[1]) timeout_b=timeout_b+1;
      end
      if(d_valid) begin
        if(byte_pos==0) begin
          byte_vl=d_vl;
          if(expected[d_vl]!=1 || seen[d_vl]!=0) fail("unexpected or duplicate delivery");
        end
        if(d_vl!==byte_vl || d_sport!==(16'h1000+byte_vl) || d_dport!==(16'h2000+byte_vl) || d_net!==(byte_vl&1))
          fail("delivery metadata mismatch");
        if(d_data!==pattern(byte_vl,byte_pos)) begin
          $display("[DETAIL] vl=%0d byte=%0d got=%02x expected=%02x",byte_vl,byte_pos,d_data,pattern(byte_vl,byte_pos));
          fail("delivery payload mismatch");
        end
        if(d_last !== (byte_pos==15)) fail("d_last early or late");
        byte_pos=byte_pos+1;
        if(d_last)begin
          if(byte_pos!=16)fail("truncated delivery");
          seen[byte_vl]=seen[byte_vl]+1; deliveries=deliveries+1;byte_pos=0;byte_vl=-1;
        end
      end else if(byte_pos!=0) fail("bubble inside output delivery");
    end else if(d_valid) fail("output asserted during reset");
  end
  task wait_ready; integer deadline;
    begin deadline=cycle+200;
      while(!ready && cycle<deadline) @(negedge clk);
      if(!ready)begin fail("ready timeout");$finish;end
    end
  endtask
  // First fragment has 8 application bytes after the UDP header; final offset=2 means IP byte 16.
  task frame; input integer id; input integer final_fragment; input integer permit;
    output [3:0] chosen; integer p;
    begin
      wait_ready;
      @(negedge clk);
      r_vl=id;r_length=8;r_sport=16'h1000+id;r_dport=16'h2000+id;r_net=id&1;
      r_meta=0;r_meta[125:94]=32'h0a000001;r_meta[93:62]=32'he0000001;
      r_meta[61:46]=id;r_meta[45:33]=final_fragment ? 13'd2 : 13'd0;
      r_meta[32]=!final_fragment;r_meta[31:16]=16'd24;r_meta[15:0]=0;
      query=1; @(negedge clk); query=0;
      p=0;
      while(!result_valid && p<24) begin @(negedge clk); p=p+1; end
      if(!result_valid || p!=19) fail("query result latency must be nineteen clocks");
      checks=checks+1;
      if(reserve_ok!==permit)begin
        $display("[DETAIL] id=%0d final=%0d reserve_ok=%b expected=%b",id,final_fragment,reserve_ok,permit);
        fail("reservation result mismatch");
      end
      chosen=reserve_slot;
      reserve=permit; cancel=!permit;
      @(negedge clk);reserve=0;cancel=0;
      if(permit)begin
        in_start=1;in_slot=chosen;@(negedge clk);in_start=0;
        while(!prepared)@(negedge clk);
        for(p=0;p<8;p=p+1)begin
          in_valid=1;in_last=(p==7);in_frag=1;in_slot=chosen;in_data=pattern(id,p+(final_fragment?8:0));
          @(negedge clk);
        end
        in_valid=0;in_last=0;
      end
      wait_ready;
    end
  endtask
  task wait_deliveries;input integer count;integer deadline;
    begin deadline=cycle+300;
      while(deliveries<count && cycle<deadline)@(negedge clk);
      if(deliveries!=count)begin $display("[DETAIL] deliveries=%0d expected=%0d",deliveries,count);fail("delivery count timeout");end
      wait_ready;repeat(3)@(negedge clk);
    end
  endtask
  reg [3:0] chosen;
  initial begin
    for(i=0;i<4096;i=i+1)begin expected[i]=0;seen[i]=0;end
    repeat(4)@(negedge clk);reset=0;repeat(3)@(negedge clk);
    // Reserve all contexts first; a 17th new datagram cannot evict one.
    for(i=0;i<16;i=i+1)frame(i,0,1,slots[i]);
    frame(16,0,0,chosen);
    expected[0]=1;frame(0,1,1,chosen);if(chosen!==slots[0])fail("final fragment changed slot");
    wait_deliveries(1);
    frame(16,0,1,chosen);
    for(i=1;i<16;i=i+1)begin expected[i]=1;frame(i,1,1,chosen);if(chosen!==slots[i])fail("context corrupted after overflow");end
    expected[16]=1;frame(16,1,1,chosen);
    wait_deliveries(17);
    repeat(10)@(negedge clk);if(deliveries!=17 || byte_pos!=0)fail("extra or partial output");
    // Reserve all again and allow their independent timers to expire.
    for(i=32;i<48;i=i+1)frame(i,0,1,chosen);
    frame(48,0,0,chosen);
    timeout_phase=1;repeat(TIMEOUT_CYCLES+40)@(negedge clk);timeout_phase=0;
    if(timeout_a==0 || timeout_b==0)fail("timeout reject events missing per network");
    if(deliveries!=17 || byte_pos!=0)fail("incomplete timeout produced output");
    // Reallocate all 16, confirm full capacity, then reset with every context pending.
    for(i=64;i<80;i=i+1)frame(i,0,1,chosen);
    frame(80,0,0,chosen);
    @(negedge clk);reset=1;repeat(4)@(negedge clk);reset=0;repeat(25)@(negedge clk);
    if(deliveries!=17 || byte_pos!=0)fail("reset caused spurious output");
    frame(80,0,1,chosen);expected[80]=1;frame(80,1,1,chosen);wait_deliveries(18);
    repeat(20)@(negedge clk);
    if(deliveries!=18 || byte_pos!=0)fail("final unexpected output");
    for(i=0;i<17;i=i+1)if(seen[i]!=1)fail("first-phase output missing");
    if(seen[80]!=1)fail("post-reset recovery missing");
    if(errors)begin $display("[RESULT] tb_reassembly_limits FAIL checks=%0d errors=%0d deliveries=%0d timeout_a=%0d timeout_b=%0d",checks,errors,deliveries,timeout_a,timeout_b);$finish;end
    $display("[RESULT] tb_reassembly_limits PASS checks=%0d errors=0 deliveries=%0d timeout_a=%0d timeout_b=%0d",checks,deliveries,timeout_a,timeout_b);$finish;
  end
  initial begin #2000000; $display("[RESULT] tb_reassembly_limits FAIL watchdog");$finish;end
endmodule
