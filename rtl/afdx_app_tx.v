// 应用输入的 valid 下降沿结束消息。完整消息才提交，缓存不足时回退整个消息。
// VLID 比较在描述符取出后流水执行，128 项并行比较，重复取最小索引。
module afdx_app_tx (
    input wire clk,reset,initialized,
    input wire [7:0] data,
    input wire valid,
    output reg ready,
    input wire cfg_write,
    input wire [6:0] cfg_index,
    input wire [15:0] cfg_vlid,
    output wire app_valid,
    input wire app_ready,
    output wire [7:0] app_data,
    output wire app_last,
    output reg [6:0] app_vl,
    output reg [1:0] drop
);
    reg [15:0] vlids[0:127];
    reg [127:0] enabled;
    // One complete command capture terminates the remote configuration bus.
    // E0 ingress -> E1 bank -> E2 four-entry group -> E3 table retirement.
    // Writes may arrive on every clock, including repeated writes to one row.
    (* preserve=1,dont_merge=1 *) reg configuration_write;
    (* preserve=1,dont_merge=1 *) reg [6:0] configuration_index;
    (* preserve=1,dont_merge=1 *) reg [15:0] configuration_vlid;
    (* preserve=1,dont_merge=1 *) reg [1:0] configuration_retiring;
    wire configuration_busy=configuration_write || |configuration_retiring;
    always @(posedge clk)begin
        if(reset)begin configuration_write<=0;configuration_retiring<=0;end
        else begin
            configuration_write<=cfg_write;
            configuration_retiring<={configuration_retiring[0],configuration_write};
        end
        configuration_index<=cfg_index;configuration_vlid<=cfg_vlid;
    end
    genvar cb,cg,cv;
    generate for(cb=0;cb<8;cb=cb+1)begin:configuration_bank
        (* preserve=1,dont_merge=1 *) reg [15:0] data_q;
        (* preserve=1,dont_merge=1 *) reg [3:0] index_q;
        (* preserve=1,dont_merge=1 *) reg write_q;
        always @(posedge clk)begin
            if(reset)write_q<=0;
            else write_q<=configuration_write && configuration_index[6:4]==cb;
            data_q<=configuration_vlid;index_q<=configuration_index[3:0];
        end
        for(cg=0;cg<4;cg=cg+1)begin:group
            (* preserve=1,dont_merge=1 *) reg [15:0] local_data;
            (* preserve=1,dont_merge=1 *) reg [3:0] write_select;
            always @(posedge clk)begin
                local_data<=data_q;
                if(reset)write_select<=0;
                else begin
                    write_select[0]<=write_q && index_q==cg*4;
                    write_select[1]<=write_q && index_q==cg*4+1;
                    write_select[2]<=write_q && index_q==cg*4+2;
                    write_select[3]<=write_q && index_q==cg*4+3;
                end
            end
            // Each registered select enables only the sixteen bits of one VLID.
            for(cv=0;cv<4;cv=cv+1)begin:entry
                always @(posedge clk)begin
                    if(reset)enabled[cb*16+cg*4+cv]<=0;
                    else if(write_select[cv])begin
                        vlids[cb*16+cg*4+cv]<=local_data;
                        enabled[cb*16+cg*4+cv]<=1'b1;
                    end
                end
            end
        end
    end endgenerate
    reg vq,active,bad;
    reg [7:0] dq,hi;
    reg [15:0] message_id;
    localparam MAX_MESSAGE_BYTES = 8192;
    localparam RING_BYTES = 32768;
    reg [13:0] count;
    // Exact predecoded count boundaries. These describe the byte processed on
    // this clock, so wide count comparisons do not feed ID capture or store.
    (* preserve=1,dont_merge=1 *) reg header_second,payload_phase,too_long;
    reg [15:0] write_ptr,start_ptr,committed;
    wire [15:0] read_ptr;
    wire [15:0] used=write_ptr-read_ptr;
    reg [5:0] desc_wr,desc_rd;
    (* preserve=1,dont_merge=1 *) reg descriptor_retire;
    wire [5:0] descriptor_head=desc_rd+{5'd0,descriptor_retire};
    wire descriptors_waiting=desc_wr!=descriptor_head;
    wire [5:0] descriptors=desc_wr-descriptor_head;
    reg [3:0] state;
    wire [15:0] descriptor_id;
    reg space_available;
    wire commit_request=vq && !valid && payload_phase && !too_long && !bad && space_available;
    reg descriptor_write;
    reg [15:0] commit_pointer,commit_id;
    // Payload command E0 -> physical bank write E1. Publish the descriptor
    // and limit at E1, after the final byte has reached its RAM bank.
    always @(posedge clk)begin
        if(reset)begin descriptor_write<=0;commit_pointer<=0;commit_id<=0;end
        else begin
            descriptor_write<=commit_request;
            if(commit_request)begin commit_pointer<=write_ptr+1'b1;commit_id<=message_id;end
        end
    end
    // Continuously sample an occupied head; only the FSM tag consumes it.
    // Empty suppression also prevents reading the just-written empty address.
    // Configuration busy therefore never drives this RAM's read enables.
    afdx_ram_sdp #(.WIDTH(16),.DEPTH(32)) descriptor_ids(
        .clk(clk),.write_enable(descriptor_write),.write_address(desc_wr[4:0]),.write_data(commit_id),
        .read_enable(descriptors_waiting),.read_address(descriptor_head[4:0]),.read_data(descriptor_id));
    wire store=vq && payload_phase && !too_long && !bad && space_available;
    wire rollback=vq && !valid && payload_phase && (bad || too_long || !space_available);
    wire [15:0] write_next=write_ptr+16'd1;
    wire rollback_full=start_ptr==(read_ptr^16'h8000);
    // Exact full-state lookahead for this 2^15-byte ring: pointers separated
    // by 0x8000 mean full. The subtraction/comparison no longer feeds all
    // eight bank write commands. Account for both in-flight read issue and
    // rollback, rather than registering a stale occupancy decision.
    always @(posedge clk)begin
        if(reset)space_available<=1;
        // Rollback cannot put the read pointer beyond start_ptr: the reader
        // sees only committed messages. A read can therefore only clear full,
        // avoiding a read_enable-controlled pointer increment before compare.
        else if(rollback)space_available<=!rollback_full || read_en;
        else if(store && !read_en)space_available<=write_next!=(read_ptr^16'h8000);
        else if(read_en && !store)space_available<=1;
    end
    // The pointer has just two local actions. Header-only failure cannot have
    // allocated any payload, so it needs no physical pointer rollback/mux.
    always @(posedge clk)begin
        if(reset)write_ptr<=0;
        else if(rollback)write_ptr<=start_ptr;
        else if(store)write_ptr<=write_ptr+1'b1;
    end
    wire [8:0] memory_q;
    wire read_en;
    wire [14:0] read_addr;
    afdx_app_payload #(.SPLIT_RETURN(1)) payload(
        .clk(clk),.reset(reset),.write_enable(store),.write_address(write_ptr[14:0]),
        .write_data({!valid,dq}),.read_enable(read_en),.read_address(read_addr),.read_data(memory_q));
    wire q_valid,q_ready;
    wire [8:0] q_data;
    wire [15:0] next_committed=descriptor_write?commit_pointer:committed;
    afdx_app_read #(.AW(15),.READ_LATENCY(4),.PREDICT_LIMIT(1)) reader(
        .clk(clk),.reset(reset),.limit(committed),.pointer(read_ptr),
        .read_enable(read_en),.read_address(read_addr),.read_data(memory_q),
        .valid(q_valid),.ready(q_ready),.data(q_data),.next_limit(next_committed));
    always @(posedge clk)begin
        if(reset)begin
            vq<=0;dq<=0;active<=0;bad<=0;hi<=0;message_id<=0;
            count<=0;header_second<=0;payload_phase<=0;too_long<=0;
            start_ptr<=0;committed<=0;desc_wr<=0;ready<=0;drop[1]<=0;
        end else begin
            vq<=valid;dq<=data;drop[1]<=0;
            ready<=initialized && used<=RING_BYTES-MAX_MESSAGE_BYTES && descriptors<31;
            if(descriptor_write)begin desc_wr<=desc_wr+1'b1;committed<=commit_pointer;end
            if(vq)begin
                if(!active)begin
                    active<=1;start_ptr<=write_ptr;count<=1;hi<=dq;
                    header_second<=1;payload_phase<=0;too_long<=0;
                    bad<=!initialized || descriptors==32;
                end else begin
                    if(!too_long)count<=count+1'b1;
                    if(header_second)begin
                        message_id<={hi,dq};header_second<=0;payload_phase<=1;
                    end
                    // count=8193 processes payload byte 8192. Mark the next
                    // byte as oversized without rejecting this final legal byte.
                    if(count==MAX_MESSAGE_BYTES+1)too_long<=1;
                    if(payload_phase && (!space_available || too_long))bad<=1;
                end
                if(!valid)begin
                    active<=0;count<=0;header_second<=0;payload_phase<=0;too_long<=0;
                    if(active && payload_phase)begin
                        if(rollback)drop[1]<=1;
                        // Successful commit is published by descriptor_write
                        // on the next clock, together with the physical write.
                    end else if(bad || (!active && (!initialized || descriptors==32)))begin
                        drop[1]<=1;
                    end
                end
            end
        end
    end
    // 只有 VLID、没有载荷的消息也只报告一次未命中。
    wire empty_message=vq && !valid && (!active || !payload_phase) && !bad;
    // Terminate the descriptor RAM return at one sixteen-bit capture rather
    // than eight dispersed copies. The following FF-to-FF stage still feeds
    // the same 32 four-entry groups on the same comparison clock.
    (* preserve=1,dont_merge=1 *) reg [15:0] descriptor_capture;
    always @(posedge clk)begin
        if(reset)descriptor_capture<=0;
        else descriptor_capture<=descriptor_id;
    end
    (* preserve=1,dont_merge=1 *) reg [15:0] query_local[0:31];
    integer query_group;
    always @(posedge clk)begin
        for(query_group=0;query_group<32;query_group=query_group+1)
            query_local[query_group]<=descriptor_capture;
    end
    reg [127:0] hit,hit_low,hit_high,nibble0,nibble1,nibble2,nibble3;
    reg [7:0] bank_hit;
    reg [3:0] bank_index[0:7];
    reg [3:0] pair_hit;
    (* preserve=1,dont_merge=1 *) reg [6:0] pair_index[0:3];
    reg [1:0] half_hit;
    reg [6:0] half_index[0:1];
    reg found,discard;
    integer compare_bank,compare_item;
    // 比较流水每拍运行，FSM 只等待结果，消除 512 个比较寄存器的共享使能。
    always @(posedge clk)begin
        if(reset)begin hit<=0;hit_low<=0;hit_high<=0;nibble0<=0;nibble1<=0;nibble2<=0;nibble3<=0;end
        else begin
            for(compare_bank=0;compare_bank<8;compare_bank=compare_bank+1)
                for(compare_item=0;compare_item<16;compare_item=compare_item+1)begin
                    nibble0[compare_bank*16+compare_item]<=enabled[compare_bank*16+compare_item] && vlids[compare_bank*16+compare_item][3:0]==query_local[compare_bank*4+compare_item/4][3:0];
                    nibble1[compare_bank*16+compare_item]<=vlids[compare_bank*16+compare_item][7:4]==query_local[compare_bank*4+compare_item/4][7:4];
                    nibble2[compare_bank*16+compare_item]<=vlids[compare_bank*16+compare_item][11:8]==query_local[compare_bank*4+compare_item/4][11:8];
                    nibble3[compare_bank*16+compare_item]<=vlids[compare_bank*16+compare_item][15:12]==query_local[compare_bank*4+compare_item/4][15:12];
                end
            hit_low<=nibble0 & nibble1;hit_high<=nibble2 & nibble3;
            hit<=hit_low & hit_high;
        end
    end
    integer bank,item;
    // Data flows continuously. Busy/retry affects only transaction tags, not
    // the enable of hundreds of query/priority registers spread across banks.
    always @(posedge clk)begin
        if(reset)begin
            bank_hit<=0;pair_hit<=0;half_hit<=0;found<=0;
            for(bank=0;bank<4;bank=bank+1)pair_index[bank]<=0;
            for(bank=0;bank<2;bank=bank+1)half_index[bank]<=0;
            for(bank=0;bank<8;bank=bank+1)bank_index[bank]<=0;
        end else begin
            for(bank=0;bank<8;bank=bank+1)begin
                bank_hit[bank]<=|hit[bank*16+:16];bank_index[bank]<=0;
                for(item=15;item>=0;item=item-1)
                    if(hit[bank*16+item])bank_index[bank]<=item[3:0];
            end
            for(bank=0;bank<4;bank=bank+1)begin
                pair_hit[bank]<=|bank_hit[bank*2+:2];
                pair_index[bank]<=bank_hit[bank*2] ?
                    {bank[1:0],1'b0,bank_index[bank*2]} :
                    {bank[1:0],1'b1,bank_index[bank*2+1]};
            end
            for(bank=0;bank<2;bank=bank+1)begin
                half_hit[bank]<=|pair_hit[bank*2+:2];
                half_index[bank]<=pair_hit[bank*2]?pair_index[bank*2]:pair_index[bank*2+1];
            end
            found<=|half_hit;
        end
    end
    // The held public index is consumed only at the local result tag. It is
    // never enabled directly by configuration_busy and stays fixed in state 5.
    always @(posedge clk)begin
        if(reset)app_vl<=0;
        else if(state==8)app_vl<=half_hit[0]?half_index[0]:half_index[1];
    end
    // Capture a remote last-byte handshake before the six-bit retirement
    // arithmetic. Forward the pending increment into the next head fetch so
    // this local boundary adds no inter-message lookup wait.
    always @(posedge clk)begin
        if(reset)begin descriptor_retire<=0;desc_rd<=0;end
        else begin
            descriptor_retire<=state==5 && q_valid && q_ready && q_data[8];
            if(descriptor_retire)desc_rd<=desc_rd+1'b1;
        end
    end
    always @(posedge clk)begin
        if(reset)begin state<=0;discard<=0;drop[0]<=0;end
        else begin
            drop[0]<=empty_message;
            // Retry tags while accepted configuration commands retire. The
            // continuously sampled descriptor head remains the same message.
            if(configuration_busy && state!=0 && state!=5)state<=6;
            else case(state)
                0:if(descriptors_waiting && !configuration_busy)state<=6;
                6:state<=1;
                1:state<=11;
                11:state<=9;
                9:state<=10;
                10:state<=2;
                2:state<=3;
                3:state<=7;
                7:state<=8;
                8:state<=4;
                4:begin discard<=!found;drop[0]<=!found || empty_message;state<=5;end
                // After last-take the local retirement token masks the public
                // stream for exactly the old state-0 quiet cycle. Consume the
                // token on the next edge and start state 6 under precisely the
                // old idle conditions, preserving the next head's fetch clock.
                5:if(descriptor_retire)begin
                    if(descriptors_waiting && !configuration_busy)state<=6;
                    else state<=0;
                end
                default:state<=0;
            endcase
        end
    end
    // The reader's two local output slots share its eight total credits.
    // q_ready may depend on remote ready; it only pops a registered slot and
    // no longer enables reader data capture. The final external take retires
    // this descriptor before the next lookup may change app_vl.
    assign app_valid=state==5 && !descriptor_retire && !discard && q_valid;
    assign app_data=q_data[7:0];
    assign app_last=q_data[8] && app_valid;
    assign q_ready=state==5 && !descriptor_retire && (discard || app_ready);
endmodule
