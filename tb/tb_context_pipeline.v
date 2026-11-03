`timescale 1ns/1ps
// Scheduler protocol test: interleaved long messages, live configuration
// changes, descriptor-selected ports, page boundaries and same-VL reuse.
module tb_context_pipeline;
    reg clk=0; always #4 clk=~clk;
    reg reset=1; reg [31:0] now=0;
    wire enable=1'b1;
    wire initialized, cfg_re, state_we, state_re, mnext_we, mnext_re, desc_re;
    wire [9:0] cfg_ra; wire [6:0] state_wa,state_ra;
    wire [62:0] state_wd; reg [62:0] state_q;
    wire [7:0] mnext_wa,mnext_ra,mnext_wd,desc_ra;
    reg [31:0] cfg_q; reg [7:0] mnext_q; reg [46:0] desc_q;
    reg enq_valid=0; reg [6:0] enq_vl=0; reg [7:0] enq_head=0;
    reg [13:0] enq_len=0; wire enq_ack; wire [2:0] enq_result;
    reg start_valid=0, fragment_done=0,completion_now=0;
    reg [6:0] completion_vl=0;
    reg [31:0] t_start=0;
    reg [6:0] fragment_done_vl=0;
    reg [7:0] fragment_done_page=0; reg [8:0] fragment_done_offset=0;
    reg grant_ready=0; wire grant_valid,grant_a,grant_b,grant_timed,grant_first,grant_more;
    wire [31:0] grant_time,grant_src,grant_dst;
    wire [15:0] grant_vlid,grant_sport,grant_dport,grant_ident;
    wire [10:0] grant_len; wire [7:0] grant_sn,grant_page,grant_head;
    wire [8:0] grant_offset; wire [12:0] grant_ip_offset;
    wire [13:0] grant_message_len; wire [6:0] grant_vl_index;
    wire cfg_ok;
    reg [31:0] config_mem[0:1023]; reg [62:0] state_mem[0:127];
    reg [46:0] desc_mem[0:255]; reg [7:0] next_mem[0:255];
    afdx_tx_engine #(.LOOKAHEAD(0),.COMPLETION_LOOKAHEAD(1)) dut(.*);
    integer cycle=0,checks=0,errors=0,i,frames=0,builder_wait=0;
    integer pos[0:127],serial[0:127],messages[0:127],ids[0:127];
    integer last_launch[0:127];
    integer v,length,cap,total,part,app,head_page,next_position;
    integer active_vl,active_page,active_offset;
    reg mutate=0;
    always @(posedge clk) begin
        cycle=cycle+1;
        now<=now+1;
        // Match builder: real completion at F0, registered pointer/valid after
        // F0, engine busy clear at F1. DUT checks local/legacy clear every cycle.
        if(reset)fragment_done<=0;
        else fragment_done<=completion_now;
        fragment_done_vl<=completion_vl;
        fragment_done_page<=active_page;
        fragment_done_offset<=active_offset;
        if(cfg_re) cfg_q<=config_mem[cfg_ra];
        if(state_re) state_q<=state_mem[state_ra];
        if(state_we) state_mem[state_wa]<=state_wd;
        if(mnext_re) mnext_q<=next_mem[mnext_ra];
        if(mnext_we) next_mem[mnext_wa]<=mnext_wd;
        if(desc_re) desc_q<=desc_mem[desc_ra];
        if(cycle>20000) begin $display("[RESULT] tb_context_pipeline FAIL checks=%0d errors=1 timeout",checks);$finish;end
    end
    task check;
        input condition; input [8*100-1:0] label;
        begin
            checks=checks+1;
            if(condition!==1'b1)begin errors=errors+1;$display("[FAIL] cycle=%0d VL=%0d %0s",cycle,v,label);end
        end
    endtask
    // Deliberately variable builder latency; start feedback and pointer return
    // are separate events and other VLs remain eligible between fragments.
    always @(negedge clk) begin
        start_valid=0;completion_now=0;
        if(!reset) begin
            if(builder_wait>0)begin
                builder_wait=builder_wait-1;
                if(builder_wait==5)begin
                    start_valid=1;t_start=now;
                    check(now-last_launch[active_vl]>=100,"BAG uses actual start feedback");
                    last_launch[active_vl]=now;
                end
                if(builder_wait==0)begin
                    completion_now=1;completion_vl=active_vl;
                    grant_ready=1;
                end
            end
            // grant_valid becomes visible after the preceding posedge. Keep
            // ready asserted through the following posedge to accept it.
        end
    end
    always @(posedge clk) if(!reset && grant_valid && grant_ready)begin
        v=grant_vl_index;
        check(v==1 || v==65,"known scheduled VL");
        length=v==65 ? 1472 : (messages[v]==0 ? 8192 : 17);
        cap=v==65 ? 511 : 1479;
        total=length-pos[v]+(pos[v]==0 ? 8 : 0);
        part=total<=cap ? total : ((cap/8)*8);
        app=part-(pos[v]==0 ? 8 : 0);
        head_page=v==65 ? 80 : (messages[v]==0 ? 8 : 40);
        check(grant_len==app && grant_message_len==length,"fragment and complete lengths");
        check(grant_first==(pos[v]==0) && grant_more==(total>part),"first and MF flags");
        check(grant_ip_offset==(pos[v]==0 ? 0 : (pos[v]+8)/8),"IP offset counts UDP header");
        check(grant_page==head_page+pos[v]/512 && grant_offset==pos[v]%512,"returned partial-page pointer");
        check(grant_head==head_page,"retained message head");
        check(grant_sn==serial[v],"SN increments once per grant");
        if(pos[v]==0)ids[v]=grant_ident;
        check(grant_ident==ids[v],"shared datagram identification");
        check(grant_a && grant_b,"both networks retained");
        check(grant_src==(v==1 && messages[v]!=0 ? 32'h0a000199 : 32'h0a000101+v),"source persists across configuration mutation");
        check(grant_sport==(v==65 ? 16'h1234 : (messages[v]==0 ? 16'd1000 : 16'd3000)),"descriptor/configured ports persist");
        check(grant_dport==(v==65 ? 16'h5678 : (messages[v]==0 ? 16'd2000 : 16'd4000)),"destination port");
        next_position=pos[v]+app;
        active_vl=v;active_page=head_page+next_position/512;active_offset=next_position%512;
        pos[v]=next_position;serial[v]=serial[v]+1;frames=frames+1;
        if(!grant_more)begin messages[v]=messages[v]+1;pos[v]=0;end
        if(v==1 && !mutate)begin
            mutate=1;
            config_mem[11]=32'h0a000199;
            config_mem[13]={16'd3000,16'd4000};
        end
        #1;grant_ready=0;builder_wait=8+(frames%3);
    end
    task enqueue;
        input [6:0] vl; input [7:0] page; input [13:0] count;
        begin
            @(negedge clk);enq_valid=1;enq_vl=vl;enq_head=page;enq_len=count;
            while(!enq_ack)begin @(posedge clk);#2;end
            check(enq_result==0,"enqueue accepted");
            @(negedge clk);enq_valid=0;
            repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        for(i=0;i<1024;i=i+1)config_mem[i]=0;
        for(i=0;i<256;i=i+1)begin desc_mem[i]=0;next_mem[i]=0;end
        for(i=0;i<128;i=i+1)begin
            pos[i]=0;serial[i]=0;messages[i]=0;ids[i]=-1;last_launch[i]=-1000;
        end
        config_mem[8]=1471*512+63*8+7;config_mem[9]=100;config_mem[10]=16'h100;
        config_mem[11]=32'h0a000102;config_mem[12]=32'he0e00100;config_mem[13]={16'd1000,16'd2000};
        config_mem[520]=503*512+63*8+7;config_mem[521]=100;config_mem[522]=16'h200;
        config_mem[523]=32'h0a000142;config_mem[524]=32'he0e00200;config_mem[525]={16'd1111,16'd2222};
        desc_mem[8]={14'd8192,1'b0,32'b0};desc_mem[40]={14'd17,1'b0,32'b0};
        desc_mem[80]={14'd1472,1'b1,16'h1234,16'h5678};
        repeat(4)@(negedge clk);reset=0;
        wait(initialized);
        enqueue(1,8,8192);enqueue(65,80,1472);enqueue(1,40,17);
        @(negedge clk);grant_ready=1;
        wait(messages[1]==2 && messages[65]==1);
        repeat(200)@(negedge clk);
        check(frames==10,"six plus three plus one frames, no duplicate grant");
        $display("[RESULT] tb_context_pipeline %0s checks=%0d errors=%0d",errors==0 ? "PASS" : "FAIL",checks,errors);
        if(errors)$finish;else $finish;
    end
endmodule
