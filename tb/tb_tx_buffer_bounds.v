`timescale 1ns/1ps
// Buffer-level legal/oversize datagrams, first-byte metadata, page allocation,
// rollback and message closure, with real ingress slots and return stalls.
module tb_tx_buffer_bounds;
    reg clk=0;
    always #4 clk=~clk;
    reg reset=1,m_valid=0,m_last=0;
    reg [7:0] m_data=0;
    reg [6:0] m_vl=0;
    reg m_port_en=0;
    reg [15:0] m_sport=0,m_dport=0;
    wire m_ready,pop_req,ret_valid,payload_we,pnext_we,desc_we,enq_valid;
    reg pop_ready=1,pop_ack=0,pop_ok=1,ret_ready=0,enq_ack=0;
    reg [7:0] pop_page=0;
    wire [7:0] ret_page,payload_wd,pnext_wa,pnext_wd,desc_wa,enq_head;
    wire [16:0] payload_wa;
    wire [46:0] desc_wd;
    wire [6:0] enq_vl;
    wire [13:0] enq_len;
    wire ev_accept,ev_drop_dis,ev_drop_full,ev_drop_long,ev_drop_nopage;
    afdx_tx_buf dut(.clk(clk),.reset(reset),.init_done(1'b1),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),.m_vl(m_vl),
        .m_port_en(m_port_en),.m_sport(m_sport),.m_dport(m_dport),
        .pop_req(pop_req),.pop_ready(pop_ready),.pop_ack(pop_ack),.pop_ok(pop_ok),.pop_page(pop_page),
        .ret_valid(ret_valid),.ret_page(ret_page),.ret_ready(ret_ready),
        .payload_we(payload_we),.payload_wa(payload_wa),.payload_wd(payload_wd),
        .pnext_we(pnext_we),.pnext_wa(pnext_wa),.pnext_wd(pnext_wd),
        .desc_we(desc_we),.desc_wa(desc_wa),.desc_wd(desc_wd),
        .enq_valid(enq_valid),.enq_vl(enq_vl),.enq_head(enq_head),.enq_len(enq_len),
        .enq_ack(enq_ack),.enq_result(3'd0),.ev_accept(ev_accept),.ev_drop_dis(ev_drop_dis),
        .ev_drop_full(ev_drop_full),.ev_drop_long(ev_drop_long),.ev_drop_nopage(ev_drop_nopage));
    integer checks=0,errors=0,cycle=0,msg_id=0,writes=0,allocated=0,returned=0,descriptors=0;
    integer accepts=0,longs=0,next_page=0,expected_length=0,i,limit,base_accept,base_long;
    integer page_list[0:31];
    reg closed=0;
    function [7:0] byte_at;
        input integer message_number,position;
        begin byte_at=(position*37) ^ (position>>7) ^ (message_number*83);end
    endfunction
    task verify;
        input condition;
        begin
            checks=checks+1;
            if(condition!==1'b1)begin
                errors=errors+1;
                $display("[FAIL] buffer cycle=%0d msg=%0d writes=%0d allocated=%0d returned=%0d",cycle,msg_id,writes,allocated,returned);
                if(errors==8)$fatal(1,"buffer bounds");
            end
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!reset)begin
            if(ev_accept || ev_drop_long)closed=0;
            if(closed)verify(!m_ready);
            if(m_valid && m_ready && m_last)closed=1;
            if(pop_req && pop_ready)begin
                page_list[allocated]=next_page;
                allocated=allocated+1;
            end
            if(payload_we)begin
                verify(writes<8192 && payload_wd===byte_at(msg_id,writes));
                verify(payload_wa==page_list[writes/512]*512+(writes%512));
                writes=writes+1;
            end
            if(desc_we)begin
                verify(desc_wd=={expected_length[13:0],1'b1,16'h1234,16'habcd});
                verify(desc_wa==page_list[0]);
                descriptors=descriptors+1;
            end
            if(enq_valid)verify(enq_vl==7'd53 && enq_len==expected_length && enq_head==page_list[0]);
            if(ret_valid && ret_ready)begin
                verify(returned<allocated && ret_page==page_list[returned]);
                returned=returned+1;
            end
            if(ev_accept)accepts=accepts+1;
            if(ev_drop_long)longs=longs+1;
            verify(!(ev_drop_dis || ev_drop_full || ev_drop_nopage));
        end
    end
    always @(posedge clk)begin
        if(reset)begin pop_ready<=1;pop_ack<=0;pop_page<=0;enq_ack<=0;end
        else begin
            pop_ack<=0;
            if(pop_req && pop_ready)begin pop_ready<=0;pop_ack<=1;pop_page<=next_page;next_page<=next_page+1;end
            else if(!pop_req)pop_ready<=1;
            enq_ack<=enq_valid;
        end
    end
    always @(negedge clk)ret_ready=(cycle%5)!=0 && (cycle%5)!=1;
    task send_message;
        input integer length;
        begin
            msg_id=msg_id+1;writes=0;allocated=0;returned=0;descriptors=0;
            expected_length=length;
            base_accept=accepts;base_long=longs;
            for(i=0;i<length;i=i+1)begin
                @(negedge clk);
                m_valid=1;m_data=byte_at(msg_id,i);m_last=(i==length-1);
                // Metadata is meaningful only on the first accepted byte.
                m_vl=(i==0)?53:17;m_port_en=(i==0);
                m_sport=(i==0)?16'h1234:16'h8888;m_dport=(i==0)?16'habcd:16'h9999;
                @(posedge clk);while(!m_ready)@(posedge clk);
                // Include bubbles around payload and page boundaries.
                if(i%127==126)begin @(negedge clk);m_valid=0;@(negedge clk);end
            end
            @(negedge clk);m_valid=0;m_last=0;
            limit=cycle+1000;
            while(accepts==base_accept && longs==base_long && cycle<limit)@(negedge clk);
            verify(cycle<limit);
            verify(writes==((length>8192)?8192:length));
            verify(allocated==(length+511)/512 || (length==8193 && allocated==16));
            if(length>8192)begin
                verify(longs==base_long+1 && accepts==base_accept && descriptors==0);
                verify(returned==16);
            end else begin
                verify(accepts==base_accept+1 && longs==base_long && descriptors==1 && returned==0);
            end
            repeat(3)@(negedge clk);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;
        repeat(3)@(negedge clk);
        send_message(1);
        send_message(8192);
        send_message(8193);
        send_message(7);
        $display("[RESULT] tb_tx_buffer_bounds %s checks=%0d errors=%0d accept=%0d long=%0d",errors==0?"PASS":"FAIL",checks,errors,accepts,longs);
        if(errors)$fatal(1,"buffer bounds");
        $finish;
    end
    initial begin #1000000;$fatal(1,"buffer bounds watchdog");end
endmodule
