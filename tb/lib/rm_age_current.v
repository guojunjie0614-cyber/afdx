// Current-interface copy of rm_age_probe; keep the legacy shared helper frozen.
// Advance coarse time while FRAME is busy, then require the old RM record to age.
// This is a child probe: the enclosing test must include its errors in RESULT.
`timescale 1ns/1ps
module rm_age_current(input wire clk,output reg done=0,output reg [31:0] checks=0,output reg [31:0] errors=0);
    localparam RX_RING_AW=12, RX_DQ_AW=5, DESC_WIDTH=RX_RING_AW+209;
    reg reset=1;reg [15:0] now_c=0;reg [DESC_WIDTH-1:0] desc=0;reg valid=0;
    wire init,take,resolve,commit,mre,cre,sre,swe,dwe,rm,deliver,ok;
    wire [15:0] ma;wire [11:0] ca,sa,wa;wire [42:0] wd;
    reg [12:0] mq=0;reg [31:0] cq=0;reg [42:0] sq=0,states[0:4095];
    reg state_read_command=0;reg [11:0] state_read_address=0;reg [42:0] state_ram_q=0;
    wire [RX_DQ_AW-1:0] dwa;wire [RX_RING_AW+60:0] dwd;wire [RX_DQ_AW:0] count;wire [7:0] ea,eb;
    integer cycle=0,origin=0,sent=0,delivered=0,limit,before_d;reg running=0;
    // All 53 ports are named, including the new reassembly transaction ports.
    // Descriptors below are explicitly non-fragmented, so no reassembly result
    // is supplied. Pop each published legacy descriptor to keep load bounded.
    afdx_rx_engine #(.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) dut(
        .clk(clk),.reset(reset),.enable(1'b1),.now_c(now_c),.initialized(init),
        .desc_a_valid(valid),.desc_b_valid(1'b0),.desc_a(desc),.desc_b({DESC_WIDTH{1'b0}}),
        .take_a(take),.take_b(),.resolve_a(resolve),.resolve_b(),.commit_a(commit),.commit_b(),
        .map_re(mre),.map_ra(ma),.map_q(mq),.cfg_re(cre),.cfg_ra(ca),.cfg_q(cq),
        .state_re(sre),.state_we(swe),.state_ra(sa),.state_wa(wa),.state_wd(wd),.state_q(sq),
        .dq_pop(dwe),.dq_we(dwe),.dq_wa(dwa),.dq_wd(dwd),
        .reassembly_result_valid(1'b0),.reassembly_ok(1'b0),.reassembly_slot(4'd0),
        .reassembly_query(),.reassembly_cancel(),.reassembly_reserve(),
        .reassembly_query_bank(),.reassembly_cancel_bank(),.reassembly_reserve_bank(),
        .reassembly_meta(),.reassembly_vl(),.reassembly_length(),
        .reassembly_sport(),.reassembly_dport(),.reassembly_net(),
        .dq_count(count),.ev_a(ea),.ev_b(eb),.ev_rm_drop(rm),.ev_deliver(deliver),
        .cfg_ok(ok),.core_enable_next(1'b1));
    always @(posedge clk)begin
        cycle=cycle+1;
        if(mre)mq<={1'b1,ma[11:0]};
        if(cre)cq<=(17<<17)|(31<<5)|7|(ca==0?16:0);
        // Match the current local read-command, synchronous RAM and return
        // stages. State contents come only from the DUT's public state port.
        state_read_command<=sre;state_read_address<=sa;
        if(state_read_command)state_ram_q<=states[state_read_address];
        sq<=state_ram_q;if(swe)states[wa]<=wd;
        if(deliver)delivered=delivered+1;
    end
    task check;input condition;input [8*100-1:0] why;
        begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;$display("[AGE_FAIL] %0s",why);end end
    endtask
    task send;input [15:0] idx;input [7:0] sn;
        begin @(negedge clk);desc={126'b0,idx,sn,16'd3001,16'd4001,11'd17,{RX_RING_AW{1'b0}},now_c};valid=1;
            while(!take)@(negedge clk);valid=0;while(!resolve)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;wait(init);send(0,55);
        repeat(20)@(negedge clk);check(states[0][24],"initial duplicate record valid");
        check(delivered==1,"initial frame accepted by the actual delivery event");
        origin=cycle;
        while(now_c<16'h9000)begin
            // The background VL has IC/RM disabled. It keeps FRAME busy but
            // cannot refresh VL0's accepted SN55/time0 duplicate record.
            @(negedge clk);desc={126'b0,16'd1,8'd1,16'd3001,16'd4001,11'd17,{RX_RING_AW{1'b0}},now_c};valid=1;
            while(!take)@(negedge clk);valid=0;
            repeat(6)@(negedge clk);check(dut.op==dut.FRAME,"coarse change is under engine load");
            now_c=now_c+1'b1;sent=sent+1;limit=origin+sent*128;
            while(cycle<limit)@(negedge clk);
            if(now_c==16'h5002)check(!states[0][24],"old record aged before signed half-wrap");
        end
        before_d=delivered;send(0,55);repeat(20)@(negedge clk);
        check(delivered==before_d+1,"same SN after long inactivity is accepted");
        $display("[AGE_COVERAGE] busy_ticks=%0d delivered=%0d cycles=%0d",sent,delivered,cycle);
        done=1;
    end
endmodule
