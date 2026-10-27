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
    // 配置先复制到各 16 项局部银行，避免全表写数据和译码扇出。
    genvar cb,cv;
    generate for(cb=0;cb<8;cb=cb+1)begin:configuration_bank
        (* preserve=1,dont_merge=1 *) reg [15:0] data_q;
        (* preserve=1,dont_merge=1 *) reg [3:0] index_q;
        (* preserve=1,dont_merge=1 *) reg write_q;
        always @(posedge clk)begin
            if(reset)begin data_q<=0;index_q<=0;write_q<=0;end
            else begin
                data_q<=cfg_vlid;index_q<=cfg_index[3:0];
                write_q<=cfg_write && cfg_index[6:4]==cb;
            end
        end
        for(cv=0;cv<16;cv=cv+1)begin:entry
            always @(posedge clk)begin
                if(reset)enabled[cb*16+cv]<=0;
                else if(write_q && index_q==cv)begin
                    vlids[cb*16+cv]<=data_q;enabled[cb*16+cv]<=1'b1;
                end
            end
        end
    end endgenerate
    reg vq,active,bad;
    reg [7:0] dq,hi;
    reg [15:0] message_id;
    reg [12:0] count,write_ptr,start_ptr,committed;
    wire [12:0] read_ptr;
    wire [12:0] used=write_ptr-read_ptr;
    reg [5:0] desc_wr,desc_rd;
    wire [5:0] descriptors=desc_wr-desc_rd;
    reg [3:0] state;
    wire [15:0] descriptor_id;
    wire descriptor_write=vq && !valid && active && count>=2 && !bad && used<4096;
    wire descriptor_read=state==0 && descriptors!=0;
    afdx_ram_sdp #(.WIDTH(16),.DEPTH(32)) descriptor_ids(
        .clk(clk),.write_enable(descriptor_write),.write_address(desc_wr[4:0]),.write_data(message_id),
        .read_enable(descriptor_read),.read_address(desc_rd[4:0]),.read_data(descriptor_id));
    wire store=vq && active && count>=2 && !bad && used<4096;
    wire [8:0] memory_q;
    wire read_en;
    wire [11:0] read_addr;
    afdx_ram_sdp #(.WIDTH(9),.DEPTH(4096)) payload(
        .clk(clk),.write_enable(store),.write_address(write_ptr[11:0]),
        .write_data({!valid,dq}),.read_enable(read_en),.read_address(read_addr),.read_data(memory_q));
    wire q_valid,q_ready;
    wire [8:0] q_data;
    afdx_app_read reader(clk,reset,committed,read_ptr,read_en,read_addr,memory_q,q_valid,q_ready,q_data);
    always @(posedge clk)begin
        if(reset)begin
            vq<=0;dq<=0;active<=0;bad<=0;hi<=0;message_id<=0;
            count<=0;write_ptr<=0;start_ptr<=0;committed<=0;desc_wr<=0;ready<=0;drop[1]<=0;
        end else begin
            vq<=valid;dq<=data;drop[1]<=0;
            ready<=initialized && used<=2616 && descriptors<31;
            if(vq)begin
                if(!active)begin
                    active<=1;start_ptr<=write_ptr;count<=1;hi<=dq;
                    bad<=!initialized || descriptors==32;
                end else begin
                    if(count<8191)count<=count+1'b1;
                    if(count==1)message_id<={hi,dq};
                    if(store)write_ptr<=write_ptr+1'b1;
                    if(count>=2 && used>=4096)bad<=1;
                end
                if(!valid)begin
                    active<=0;count<=0;
                    if(bad || (count>=2 && used>=4096) || (!active && (!initialized || descriptors==32)))begin
                        write_ptr<=active?start_ptr:write_ptr;drop[1]<=1;
                    end else if(active && count>=2)begin
                        desc_wr<=desc_wr+1'b1;
                        committed<=write_ptr+1'b1;
                    end
                end
            end
        end
    end
    // 只有 VLID、没有载荷的消息也只报告一次未命中。
    wire empty_message=vq && !valid && (!active || count<2) && !bad;
    (* preserve=1,dont_merge=1 *) reg [15:0] query[0:31];
    reg [127:0] hit,hit_low,hit_high,nibble0,nibble1,nibble2,nibble3;
    reg [7:0] bank_hit;
    reg [3:0] bank_index[0:7];
    reg [3:0] pair_hit;
    reg [6:0] pair_index[0:3];
    reg [1:0] half_hit;
    reg [6:0] half_index[0:1];
    reg found,discard;
    integer bank,item;
    always @(posedge clk)begin
        if(reset)begin
            desc_rd<=0;state<=0;hit<=0;hit_low<=0;hit_high<=0;nibble0<=0;nibble1<=0;nibble2<=0;nibble3<=0;bank_hit<=0;app_vl<=0;found<=0;discard<=0;drop[0]<=0;
            pair_hit<=0;half_hit<=0;
            for(bank=0;bank<4;bank=bank+1)pair_index[bank]<=0;
            for(bank=0;bank<2;bank=bank+1)half_index[bank]<=0;
            for(bank=0;bank<32;bank=bank+1)query[bank]<=0;
            for(bank=0;bank<8;bank=bank+1)bank_index[bank]<=0;
        end else begin
            drop[0]<=empty_message;
            case(state)
                0:if(descriptors!=0)state<=6;
                6:begin
                    for(bank=0;bank<32;bank=bank+1)query[bank]<=descriptor_id;
                    state<=1;
                end
                1:begin
                    for(bank=0;bank<8;bank=bank+1)
                        for(item=0;item<16;item=item+1)begin
                            nibble0[bank*16+item]<=enabled[bank*16+item] && vlids[bank*16+item][3:0]==query[bank*4+item/4][3:0];
                            nibble1[bank*16+item]<=vlids[bank*16+item][7:4]==query[bank*4+item/4][7:4];
                            nibble2[bank*16+item]<=vlids[bank*16+item][11:8]==query[bank*4+item/4][11:8];
                            nibble3[bank*16+item]<=vlids[bank*16+item][15:12]==query[bank*4+item/4][15:12];
                        end
                    state<=9;
                end
                9:begin hit_low<=nibble0 & nibble1;hit_high<=nibble2 & nibble3;state<=10;end
                10:begin hit<=hit_low & hit_high;state<=2;end
                2:begin
                    for(bank=0;bank<8;bank=bank+1)begin
                        bank_hit[bank]<=|hit[bank*16+:16];bank_index[bank]<=0;
                        for(item=15;item>=0;item=item-1)if(hit[bank*16+item])bank_index[bank]<=item[3:0];
                    end
                    state<=3;
                end
                // 每级只选择两个候选，保持重复 VLID 的最小索引优先。
                3:begin
                    for(bank=0;bank<4;bank=bank+1)begin
                        pair_hit[bank]<=|bank_hit[bank*2+:2];
                        pair_index[bank]<=bank_hit[bank*2] ?
                            {bank[1:0],1'b0,bank_index[bank*2]} :
                            {bank[1:0],1'b1,bank_index[bank*2+1]};
                    end
                    state<=7;
                end
                7:begin
                    for(bank=0;bank<2;bank=bank+1)begin
                        half_hit[bank]<=|pair_hit[bank*2+:2];
                        half_index[bank]<=pair_hit[bank*2]?pair_index[bank*2]:pair_index[bank*2+1];
                    end
                    state<=8;
                end
                8:begin
                    found<=|half_hit;app_vl<=half_hit[0]?half_index[0]:half_index[1];
                    state<=4;
                end
                4:begin discard<=!found;drop[0]<=!found || empty_message;state<=5;end
                5:if(q_valid && q_ready && q_data[8])begin desc_rd<=desc_rd+1'b1;state<=0;end
                default:state<=0;
            endcase
        end
    end
    assign app_valid=state==5 && !discard && q_valid;
    assign app_data=q_data[7:0];
    assign app_last=q_data[8] && app_valid;
    assign q_ready=state==5 && (discard || app_ready);
endmodule
