`timescale 1ns/1ps
// Engine + reassembly transaction integration, driven at CE_DIV2 start cadence.
module tb_reassembly_engine;
  reg clk=0;always #4 clk=~clk;
  reg reset=1,enable=0;
  wire initialized;
  // Core prediction is valid only after engine initialization, then exercise
  // the stricter CE_DIV2 enable boundary on every existing frame trajectory.
  always @(posedge clk)if(reset || !initialized)enable<=0;else enable<=!enable;
  reg av=0,bv=0;
  reg [15:0] coarse_now=0;
  reg coarse_tick=0;
  reg [15:0] reference_previous=0;
  reg reference_age_pending=0;
  reg [220:0] ad=0,bd=0;
  wire take_a,take_b,resolve_a,resolve_b,commit_a,commit_b;
  wire map_re,cfg_re,state_re,state_we,dq_we;
  wire [15:0] map_ra;
  wire [11:0] cfg_ra,state_ra,state_wa;
  wire [42:0] state_wd;
  reg [42:0] state_q=0,state_ram_q=0,state_memory[0:4095];
  reg state_read_command=0;
  reg [11:0] state_read_address=0;
  wire [0:0] dq_wa;
  wire [72:0] dq_wd;
  wire [1:0] dq_count;
  reg auto_pop=1,manual_pop=0;
  wire dq_pop=auto_pop ? dq_we : manual_pop;
  wire query,cancel,reserve,result_valid,reserve_ok,r_net;
  wire [3:0] reserve_slot;
  wire [125:0] r_meta;
  wire [11:0] r_vl;
  wire [10:0] r_length;
  wire [15:0] r_sport,r_dport;
  wire [7:0] ev_a,ev_b;
  wire ev_rm,ev_deliver,cfg_ok;
  reg [31:0] cfg_q=(1500<<17)|(100<<5)|31;
  wire in_start,in_valid,in_last,in_empty,in_frag,in_net;
  wire [3:0] in_slot;
  wire [7:0] in_data;
  wire [11:0] in_vl;
  wire [15:0] in_sport,in_dport;
  wire ready,prepared,d_valid,d_last,d_net;
  reg [1:0] fixture_count=0;
  reg [72:0] fixture_descriptor=0;
  reg [7:0] fixture_ring_q=0,fixture_ring_b_q=0;
  reg fixture_grant=1;
  wire fixture_pop,fixture_re,fixture_b_re;
  wire [11:0] fixture_ra,fixture_b_ra;
  wire [12:0] fixture_read_a,fixture_read_b;
  always @(posedge clk) begin
    if(fixture_pop)fixture_count<=fixture_count-1'b1;
    if(fixture_re)fixture_ring_q<=fixture_ra[7:0];
    if(fixture_b_re)fixture_ring_b_q<=fixture_b_ra[7:0];
  end
  // Use the real delivery pipeline: a synchronous ring read and the new
  // descriptor-prepared acknowledgement must align before any byte is sent.
  afdx_rx_deliver #(.RX_DQ_AW(1)) fixture_deliver(
    .clk(clk),.reset(reset),.dq_count(fixture_count),.dq_ra(),.dq_q(fixture_descriptor),.dq_pop(fixture_pop),
    .ring_a_re(fixture_re),.ring_b_re(fixture_b_re),.ring_a_ra(fixture_ra),.ring_b_ra(fixture_b_ra),
    .ring_a_q(fixture_ring_q),.ring_b_q(fixture_ring_b_q),.read_ptr_a(fixture_read_a),.read_ptr_b(fixture_read_b),
    .d_valid(in_valid),.d_data(in_data),.d_last(in_last),.d_vl(in_vl),.d_sport(in_sport),.d_dport(in_dport),.d_net(in_net),
    .downstream_ready(ready && fixture_grant),.downstream_prepared(prepared),.d_frag(in_frag),.d_slot(in_slot),.d_start(in_start),.d_empty(in_empty));
  wire [7:0] d_data;
  wire [11:0] d_vl;
  wire [15:0] d_sport,d_dport;
  wire [1:0] reject_events;
  afdx_rx_engine #(.RX_DQ_AW(1),.CORE_ENABLE_PREDICT(1),.REGISTERED_TIME_TICK(1)) engine(
    .clk(clk),.reset(reset),.enable(enable),.core_enable_next(initialized && !enable),.now_c({coarse_tick,coarse_now}),.initialized(initialized),
    .desc_a_valid(av),.desc_b_valid(bv),.desc_a(ad),.desc_b(bd),
    .take_a(take_a),.take_b(take_b),.resolve_a(resolve_a),.resolve_b(resolve_b),.commit_a(commit_a),.commit_b(commit_b),
    .map_re(map_re),.map_ra(map_ra),.map_q(13'h1003),.cfg_re(cfg_re),.cfg_ra(cfg_ra),.cfg_q(cfg_q),
    .state_re(state_re),.state_we(state_we),.state_ra(state_ra),.state_wa(state_wa),.state_wd(state_wd),.state_q(state_q),
    .dq_pop(dq_pop),.dq_we(dq_we),.dq_wa(dq_wa),.dq_wd(dq_wd),.dq_count(dq_count),
    .reassembly_result_valid(result_valid),.reassembly_ok(reserve_ok),.reassembly_slot(reserve_slot),
    .reassembly_query(query),.reassembly_cancel(cancel),.reassembly_reserve(reserve),.reassembly_meta(r_meta),
    .reassembly_vl(r_vl),.reassembly_length(r_length),.reassembly_sport(r_sport),.reassembly_dport(r_dport),.reassembly_net(r_net),
    .ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm),.ev_deliver(ev_deliver),.cfg_ok(cfg_ok),
    .reassembly_query_bank(),.reassembly_reserve_bank(),.reassembly_cancel_bank());
  afdx_rx_reassembly reassembly(
    .clk(clk),.reset(reset),.query(query),.cancel(cancel),.reserve(reserve),.result_valid(result_valid),
    .reserve_ok(reserve_ok),.reserve_slot(reserve_slot),.r_meta(r_meta),.r_vl(r_vl),.r_length(r_length),.r_sport(r_sport),.r_dport(r_dport),.r_net(r_net),
    .in_start(in_start),.in_valid(in_valid),.in_last(in_last),.in_empty(in_empty),.in_frag(in_frag),.in_slot(in_slot),.in_data(in_data),
    .in_vl(in_vl),.in_sport(in_sport),.in_dport(in_dport),.in_net(in_net),.ready(ready),.prepared(prepared),
    .d_valid(d_valid),.d_last(d_last),.d_data(d_data),.d_vl(d_vl),.d_sport(d_sport),.d_dport(d_dport),.d_net(d_net),.reject_events(reject_events),
    .query_bank(),.reserve_bank(),.cancel_bank());
  integer cycle=0,checks=0,errors=0,accepted=0,duplicates=0,rejected_sequence=0,rejected_full=0;
  integer started=-1,last_take=-1,max_service=0,min_spacing=9999,max_spacing=0,paired_frames=0;
  reg pair_waiting=0;
  reg reference_quiet=1;
  integer resolved=0,output_bytes=0,datagrams=0,query_cycle=0,legacy_bytes=0,legacy_seen=0;
  reg output_active=0;
  reg [31:0] ports_history0=0,ports_history1=0,ports_history2=0;
  reg [3:0] first_slot=0;
  function [5:0] context_pending;input [3:0] slot;
    begin context_pending=slot[3] ? reassembly.banks[1].u_bank.pending[slot[2:0]] : reassembly.banks[0].u_bank.pending[slot[2:0]];end
  endfunction
  task fail;input [8*120-1:0]msg;begin errors=errors+1;$display("[FAIL] cycle=%0d %0s",cycle,msg);end endtask
  always @(posedge clk)begin
    if(reset)begin reference_quiet<=1;reference_previous=0;reference_age_pending=0;end
    else begin
      reference_quiet<=!(av || bv);
      if(coarse_tick !== (coarse_now!=reference_previous))fail("registered coarse tick changed its sampling edge");
      if(coarse_tick)reference_age_pending=1;
      if(engine.op==engine.AGE && !(av || bv) && engine.phase==5)
        reference_age_pending=coarse_now!=reference_previous;
      reference_previous=coarse_now;
    end
    if(state_we)state_memory[state_wa]<=state_wd;
    state_read_command<=state_re;state_read_address<=state_ra;
    if(state_read_command)state_ram_q<=state_memory[state_read_address];
    state_q<=state_ram_q;
    if(take_a)av<=0;
    if(take_b)bv<=0;
    cycle=cycle+1;
    if(query)query_cycle=cycle;
    if(reserve && (!result_valid || !reserve_ok))fail("commit without successful result");
    #1;
    if(!reset)begin
      if(engine.age_pending !== reference_age_pending)fail("AGE retirement changed the original sampled-time predicate");
      // Original combinational ready predicate, evaluated after this edge's
      // mode/enable updates. Exercise it throughout the existing frame cases.
      if(cfg_ok !== (enable && (engine.op==engine.IDLE || engine.op==engine.AGE) && reference_quiet))
        fail("predicted cfg ack changed the same-cycle acceptance predicate");
      if(take_a || take_b)begin
        started=cycle;
        if(take_b && pair_waiting)begin
          paired_frames=paired_frames+1;pair_waiting=0;
          if(cycle-last_take<min_spacing)min_spacing=cycle-last_take;
          if(cycle-last_take>max_spacing)max_spacing=cycle-last_take;
        end
        if(take_a && bv)pair_waiting=1;
        last_take=cycle;
      end
      if(resolve_a || resolve_b)begin
        if(cycle-started>max_service)max_service=cycle-started;
        checks=checks+1;if(cycle-started>32)fail("control service exceeded 32 clocks");
        resolved=resolved+1;
      end
      if(ev_deliver)begin accepted=accepted+1;if(accepted==1)first_slot=dq_wd[71:68];end
      if(ev_rm)duplicates=duplicates+1;
      if(ev_a==8'h40 || ev_b==8'h40)rejected_sequence=rejected_sequence+1;
      if(ev_a==8'h80 || ev_b==8'h80)rejected_full=rejected_full+1;
      if(reject_events)fail("unexpected reassembly reject");
      if(d_valid)begin
        if(!output_active)begin
          checks=checks+1;
          if({d_sport,d_dport}!==ports_history0 || {d_sport,d_dport}!==ports_history1 || {d_sport,d_dport}!==ports_history2)
            fail("service ports were not stable three clocks before first valid");
        end
        output_active=!d_last;
        if(d_vl==12'd9)begin
          if(d_data!==(8'h40+legacy_bytes) || d_sport!=16'h1234 || d_dport!=16'h5678)fail("legacy payload/metadata mismatch");
          if(d_last!==(legacy_bytes==16))fail("legacy last mismatch");
          legacy_bytes=legacy_bytes+1;if(d_last)legacy_seen=legacy_seen+1;
        end else begin
          if(d_data!==output_bytes[7:0])fail("integration payload mismatch");
          if(d_last!==(output_bytes==15))fail("integration last mismatch");
          output_bytes=output_bytes+1;
          if(d_last)datagrams=datagrams+1;
        end
      end else if(output_active)fail("bubble in application message");
    end
    ports_history2=ports_history1;ports_history1=ports_history0;ports_history0={d_sport,d_dport};
  end
  function [220:0] descriptor;input integer id,sn,final_fragment;
    reg [125:0] meta;
    begin
      meta={32'h0a000001,32'he0000001,16'd0,13'd0,1'b0,16'd24,16'd0};
      meta[61:46]=id;meta[45:33]=final_fragment ? 2 : 0;meta[32]=!final_fragment;
      descriptor={meta,16'h1234,sn[7:0],16'h1000,16'h2000,11'd8,12'd0,16'd100};
    end
  endfunction
  task send_frame;input integer id,sn,final_fragment,both;
    integer target,deadline;
    begin
      target=resolved+(both ? 2 : 1);deadline=cycle+80;
      @(negedge clk);ad=descriptor(id,sn,final_fragment);bd=ad;av=1;bv=both;
      while(resolved<target && cycle<deadline)@(negedge clk);
      if(resolved!=target)fail("frame resolution timeout");
      repeat(2)@(negedge clk);
      checks=checks+1;if(result_valid)fail("completed frame left a locked query");
    end
  endtask
  task copy_fragment;input integer start_pos;
    integer deadline;
    begin
      while(!ready)@(negedge clk);
      @(negedge clk);
      fixture_descriptor={1'b1,first_slot,1'b0,start_pos[11:0],11'd8,12'd3,16'h1000,16'h2000};
      fixture_count=1;deadline=cycle+100;
      while(!in_last && cycle<deadline)@(negedge clk);
      if(!in_last)fail("deliver preparation/ring pipeline timeout");
      @(negedge clk);
      if(start_pos==8)begin
        // Queue a legacy packet while the completed datagram is still being
        // finalized. The two streams must never interleave or lose a byte.
        fixture_descriptor={1'b0,4'd0,1'b1,12'h040,11'd17,12'd9,16'h1234,16'h5678};
        fixture_count=1;deadline=cycle+160;
        while(legacy_seen==0 && cycle<deadline)@(negedge clk);
        if(legacy_seen!=1)fail("legacy packet blocked or lost after reassembly");
      end
      while(!ready && cycle<deadline)@(negedge clk);
      if(!ready)fail("copy/output retirement timeout");
    end
  endtask
  task send_frame_with_pop;input integer id,sn,pop_phase;
    integer pop_deadline;
    begin
      fork
        send_frame(id,sn,0,0);
        begin
          pop_deadline=cycle+70;
          while(!(engine.op==engine.FRAME && engine.phase==pop_phase) && cycle<pop_deadline)@(negedge clk);
          if(cycle>=pop_deadline)fail("queue-room boundary phase was not reached");
          else begin manual_pop=1;@(negedge clk);manual_pop=0;end
        end
      join
    end
  endtask
  task empty_credit_boundary;
    integer deadline;
    begin
      while(!ready)@(negedge clk);
      @(negedge clk);fixture_descriptor={1'b0,4'd0,1'b1,12'habc,11'd0,12'd9,16'h1234,16'h5678};fixture_count=1;
      deadline=cycle+40;
      while(!fixture_deliver.fetch_command && cycle<deadline)@(negedge clk);
      fixture_grant=0;repeat(3)@(negedge clk);
      checks=checks+1;
      if(!fixture_deliver.dq_valid || in_start || fixture_read_a!=16 || fixture_read_b!=17)
        fail("withdrawn ready spent a header credit or changed a ring pointer");
      // Inject only a one-clock completion notification at the idle-credit
      // boundary. Header priority must absorb it in D_QUIET; no payload/context
      // state is forced, and no output request may be launched for this token.
      force reassembly.bank_complete=2'b01;fixture_grant=1;
      @(negedge clk);checks=checks+1;
      if(!in_start || !in_empty || reassembly.stream_state!=reassembly.D_QUIET)
        fail("current ready did not launch start for the one-clock quiet credit");
      @(negedge clk);release reassembly.bank_complete;
      while(!fixture_deliver.dq_req && cycle<deadline)@(negedge clk);
      checks=checks+1;
      if(!fixture_deliver.dq_req || fixture_read_a!=16 || fixture_read_b!=17 || in_valid || fixture_re || fixture_b_re)
        fail("empty delivery emitted bytes or advanced a ring pointer");
    end
  endtask
  integer boundary_deadline,saved_age_ptr;
  initial begin
    repeat(4)@(negedge clk);reset=0;
    while(!initialized)@(negedge clk);
    send_frame(1,1,0,1);
    checks=checks+1;if(accepted!=1 || duplicates!=1 || context_pending(first_slot)!=1)fail("simultaneous A/B first fragment not deduplicated");
    send_frame(1,2,1,1);
    checks=checks+1;if(accepted!=2 || duplicates!=2 || context_pending(first_slot)!=2)fail("simultaneous A/B final fragment not deduplicated");
    copy_fragment(0);copy_fragment(8);repeat(30)@(negedge clk);
    checks=checks+1;if(datagrams!=1 || output_bytes!=16)fail("complete datagram not delivered exactly once");
    empty_credit_boundary;
    send_frame(2,10,0,0);
    checks=checks+1;if(rejected_sequence!=1 || accepted!=2)fail("IC rejection changed admission");
    send_frame(2,11,0,0);
    checks=checks+1;if(accepted!=3)fail("IC cancellation leaked a reservation");
    // A newer SN passes IC/RM but the same open datagram key cannot allocate.
    send_frame(2,12,0,0);
    checks=checks+1;if(rejected_full!=1 || accepted!=3 || state_memory[3][23:16]!=11)fail("reassembly rejection committed RM");
    auto_pop=0;
    send_frame(3,13,0,0);send_frame(4,14,0,0);
    checks=checks+1;if(dq_count!=2 || accepted!=5)fail("delivery queue did not fill");
    send_frame(5,15,0,0);
    checks=checks+1;if(rejected_full!=2 || accepted!=5 || state_memory[3][23:16]!=14)fail("queue-full rejection committed RM");
    // A phase26 pop must be reflected in phase27 admission, restoring full
    // occupancy after the accepted write. A phase27 pop is one edge too late.
    send_frame_with_pop(5,16,26);
    checks=checks+1;if(accepted!=6 || state_memory[3][23:16]!=16 || dq_count!=2)fail("phase26 pop was not accepted atomically");
    send_frame_with_pop(6,17,27);
    checks=checks+1;if(accepted!=6 || rejected_full!=3 || state_memory[3][23:16]!=16 || dq_count!=1)fail("phase27 pop changed the original admission edge");
    checks=checks+1;if(paired_frames!=2 || max_spacing>32)fail("paired A/B service budget not observed");
    // Enter AGE with one sampled time, then change coarse time on its phase5
    // retirement edge. The old comparison must leave the next age request set.
    @(negedge clk);coarse_now=100;coarse_tick=1;
    @(negedge clk);coarse_tick=0;boundary_deadline=cycle+30;
    while(!(engine.op==engine.AGE && engine.phase==5) && cycle<boundary_deadline)@(negedge clk);
    saved_age_ptr=engine.age_ptr;coarse_now=101;coarse_tick=1;
    @(negedge clk);coarse_tick=0;checks=checks+1;
    if(engine.op!=engine.IDLE || !engine.age_pending || engine.age_ptr!=saved_age_ptr+1 || engine.age_time!=100)
      fail("AGE completion lost its simultaneous tick or changed sampled time");
    if(errors)begin $display("[RESULT] tb_reassembly_engine FAIL checks=%0d errors=%0d",checks,errors);$finish;end
    $display("[RESULT] tb_reassembly_engine PASS checks=%0d errors=0 accepted=%0d duplicates=%0d max_service_cycles=%0d paired_take_spacing=%0d..%0d CE_DIV=2",checks,accepted,duplicates,max_service,min_spacing,max_spacing);$finish;
  end
  initial begin #200000;$display("[RESULT] tb_reassembly_engine FAIL watchdog");$finish;end
endmodule
