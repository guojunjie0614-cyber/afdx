// GMII仿真网络：每周期一个字节；普通帧固定延迟，额外段预留空闲区间。
module link_model #(
    parameter LINK_ID = 0,
    parameter MAX_FRAMES = 2048,
    parameter MAX_BYTES = 2048,
    parameter MAX_EXTRA = 256
)(
    input wire clk,
    input wire sender_reset,
    input wire [7:0] data_in,
    input wire valid_in,
    output wire [7:0] data_out,
    output wire valid_out,
    input integer log_fd,
    output integer errors
);
    // 帧号从 1 开始。mode：0=pass，1=drop，2=xor，3=hold。
    integer cycle, delay_cycles, frame_count, input_frame, input_ticks;
    integer next_regular, next_extra, extra_count, last_regular;
    integer source_start [0:MAX_FRAMES];
    integer source_length [0:MAX_FRAMES];
    integer due_start [0:MAX_FRAMES];
    integer delay_at_start [0:MAX_FRAMES];
    integer action_mode [0:MAX_FRAMES];
    integer action_byte [0:MAX_FRAMES];
    integer action_mask [0:MAX_FRAMES];
    integer frame_mode [0:MAX_FRAMES];
    integer frame_byte [0:MAX_FRAMES];
    integer frame_mask [0:MAX_FRAMES];
    reg frame_closed [0:MAX_FRAMES];
    reg frame_aborted [0:MAX_FRAMES];
    reg frame_started [0:MAX_FRAMES];
    reg [7:0] source_bytes [0:MAX_FRAMES*MAX_BYTES-1];
    integer extra_start [0:MAX_EXTRA];
    integer extra_length [0:MAX_EXTRA];
    integer extra_source [0:MAX_EXTRA];
    reg [7:0] extra_bytes [0:MAX_EXTRA*MAX_BYTES-1];
    reg input_active;
    reg buffered_valid;
    reg [7:0] buffered_data;
    reg output_active, have_output;
    integer output_ticks, last_output_end;
    reg [7:0] output_byte;
    integer i, fid, bidx, current_cycle, off, extra_off;
    integer direct_frame, direct_mode, direct_byte, direct_mask, direct_delay;
    reg direct_valid;
    reg [7:0] direct_data;
    reg regular_present, extra_present;

    initial begin
        cycle=0; delay_cycles=1; frame_count=0; input_frame=0; input_ticks=0;
        next_regular=1; next_extra=1; extra_count=0; last_regular=0;
        input_active=0; buffered_valid=0; buffered_data=0; errors=0;
        output_active=0; have_output=0; output_ticks=0; last_output_end=0; output_byte=0;
        for(i=0;i<=MAX_FRAMES;i=i+1) begin
            source_start[i]=0; source_length[i]=0; due_start[i]=0; delay_at_start[i]=0;
            action_mode[i]=0; action_byte[i]=0; action_mask[i]=0;
            frame_mode[i]=0; frame_byte[i]=0; frame_mask[i]=0;
            frame_closed[i]=0; frame_aborted[i]=0; frame_started[i]=0;
        end
        for(i=0;i<=MAX_EXTRA;i=i+1) begin
            extra_start[i]=0; extra_length[i]=0; extra_source[i]=0;
        end
    end

    // 零延迟直接旁路，首拍用即将分配的帧号；状态均在采样后以 NBA 更新。
    always @* begin
        direct_frame=input_active ? input_frame : frame_count+1;
        direct_byte=input_active ? input_ticks : 0;
        direct_mode=0; direct_mask=0; direct_delay=delay_cycles;
        if(direct_frame<=MAX_FRAMES) begin
            if(input_active) begin
                direct_mode=frame_mode[direct_frame];
                direct_mask=(direct_byte==frame_byte[direct_frame]) ? frame_mask[direct_frame] : 0;
                direct_delay=delay_at_start[direct_frame];
            end else begin
                direct_mode=action_mode[direct_frame];
                direct_mask=(direct_byte==action_byte[direct_frame]) ? action_mask[direct_frame] : 0;
            end
        end
        direct_valid=valid_in && !sender_reset && direct_delay==0 &&
                     (direct_mode==0 || direct_mode==2) && direct_frame<=MAX_FRAMES;
        direct_data=data_in;
        if(direct_mode==2) direct_data=data_in ^ direct_mask[7:0];
    end
    assign valid_out=direct_valid || buffered_valid;
    assign data_out=direct_valid ? direct_data : buffered_data;

    task fail;
        input [511:0] reason;
        begin
            errors=errors+1;
            $display("** Error: [LINK] link=%0d cycle=%0d %0s",LINK_ID,cycle+1,reason);
        end
    endtask

    always @(posedge clk) begin
        cycle<=cycle+1;
        if(sender_reset) begin
            if(input_active) begin
                frame_aborted[input_frame]=1;
                frame_closed[input_frame]=1;
            end
            input_active<=0;
            input_ticks<=0;
        end else if(valid_in) begin
            if(!input_active) begin
                fid=frame_count+1;
                if(fid>MAX_FRAMES) fail("source history capacity exceeded");
                else begin
                    frame_count<=fid;
                    input_frame<=fid;
                    input_active<=1;
                    input_ticks<=1;
                    source_start[fid]=cycle+1;
                    source_length[fid]=1;
                    due_start[fid]=cycle+1+delay_cycles;
                    delay_at_start[fid]=delay_cycles;
                    frame_mode[fid]=action_mode[fid];
                    frame_byte[fid]=action_byte[fid];
                    frame_mask[fid]=action_mask[fid];
                    source_bytes[(fid-1)*MAX_BYTES]=data_in;
                    frame_started[fid]=(delay_cycles==0 && (action_mode[fid]==0 || action_mode[fid]==2));
                    if(action_mode[fid]==0 || action_mode[fid]==2) begin
                        if(last_regular!=0 && !frame_aborted[last_regular] &&
                           due_start[fid]<due_start[last_regular]+source_length[last_regular]+12)
                            fail("fixed delay violates preceding normal frame gap");
                        last_regular=fid;
                        for(i=1;i<=extra_count;i=i+1)
                            if(due_start[fid]>=extra_start[i]-11 &&
                               due_start[fid]<extra_start[i]+extra_length[i]+12)
                                fail("new normal frame collides with planned replay or insertion");
                    end
                end
            end else begin
                bidx=input_ticks;
                if(bidx>=MAX_BYTES) fail("source frame exceeds byte capacity");
                else begin
                    source_bytes[(input_frame-1)*MAX_BYTES+bidx]=data_in;
                    source_length[input_frame]=bidx+1;
                end
                input_ticks<=input_ticks+1;
            end
        end else if(input_active) begin
            frame_closed[input_frame]=1;
            if(frame_mode[input_frame]==2 && frame_byte[input_frame]>=source_length[input_frame])
                fail("xor byte index lies outside source frame");
            if(frame_mode[input_frame]==0 || frame_mode[input_frame]==2)
                for(i=1;i<=extra_count;i=i+1)
                    if(due_start[input_frame]<extra_start[i]+extra_length[i]+12 &&
                       due_start[input_frame]+input_ticks+12>extra_start[i])
                        fail("normal frame overlaps planned replay or insertion");
            input_active<=0;
            input_ticks<=0;
        end

        // 独立检查最终线路；12 个空闲周期也适用于额外段和普通帧的交界。
        if(direct_valid && buffered_valid) fail("zero-delay frame collides with buffered output");
        if(valid_out) begin
            if(!output_active) begin
                if(have_output && cycle+1-last_output_end<12) fail("output inter-frame gap below 12 cycles");
                output_active<=1;
                output_ticks<=1;
                output_byte<=data_out;
            end else begin
                output_byte<=data_out;
                output_ticks<=output_ticks+1;
            end
        end else if(output_active) begin
            output_active<=0;
            have_output<=1;
            output_ticks<=0;
            last_output_end<=cycle+1;
        end
    end

    always @(negedge clk) begin
        current_cycle=cycle+1;
        buffered_valid=0;
        buffered_data=0;
        regular_present=0;
        extra_present=0;
        while(next_regular<=frame_count &&
              (frame_aborted[next_regular] || frame_mode[next_regular]==1 || frame_mode[next_regular]==3 ||
               (frame_closed[next_regular] && current_cycle>=due_start[next_regular]+source_length[next_regular])))
            next_regular=next_regular+1;
        if(next_regular<=frame_count && current_cycle>=due_start[next_regular] &&
           delay_at_start[next_regular]!=0) begin
            off=current_cycle-due_start[next_regular];
            if(!frame_started[next_regular] && off!=0) begin
                fail("normal frame missed its fixed start cycle");
                frame_aborted[next_regular]=1;
            end else if(off<source_length[next_regular]) begin
                regular_present=1;
                frame_started[next_regular]=1;
                buffered_data=source_bytes[(next_regular-1)*MAX_BYTES+off];
                if(frame_mode[next_regular]==2 && off==frame_byte[next_regular])
                    buffered_data=buffered_data ^ frame_mask[next_regular][7:0];
            end else if(!frame_closed[next_regular]) fail("streaming delay tried to read an uncaptured byte");
        end
        while(next_extra<=extra_count && current_cycle>=extra_start[next_extra]+extra_length[next_extra])
            next_extra=next_extra+1;
        if(next_extra<=extra_count && current_cycle>=extra_start[next_extra]) begin
            extra_present=1;
            extra_off=current_cycle-extra_start[next_extra];
            if(regular_present) fail("fixed-delay output collides with replay or insertion");
            else if(extra_source[next_extra]!=0)
                buffered_data=source_bytes[(extra_source[next_extra]-1)*MAX_BYTES+extra_off];
            else buffered_data=extra_bytes[(next_extra-1)*MAX_BYTES+extra_off];
        end
        buffered_valid=regular_present || extra_present;
    end

    task set_delay;
        input integer cycles;
        begin
            if(cycles<0) fail("negative delay");
            else begin
                delay_cycles=cycles;
                $fdisplay(log_fd,"L %0d %0d %0d",cycle+1,LINK_ID,cycles);
            end
        end
    endtask

    task set_action;
        input integer frame_no;
        input integer mode;
        input integer byte_index;
        input integer mask;
        begin
            if(frame_no<=frame_count || frame_no>MAX_FRAMES || frame_no<1 ||
               mode<0 || mode>3 || byte_index<0 || byte_index>=MAX_BYTES || mask<0 || mask>255)
                fail("invalid or late frame action");
            else begin
                action_mode[frame_no]=mode;
                action_byte[frame_no]=byte_index;
                action_mask[frame_no]=mask;
                case(mode)
                    0: $fdisplay(log_fd,"A %0d %0d %0d pass %0d %02x",cycle+1,LINK_ID,frame_no,byte_index,mask[7:0]);
                    1: $fdisplay(log_fd,"A %0d %0d %0d drop %0d %02x",cycle+1,LINK_ID,frame_no,byte_index,mask[7:0]);
                    2: $fdisplay(log_fd,"A %0d %0d %0d xor %0d %02x",cycle+1,LINK_ID,frame_no,byte_index,mask[7:0]);
                    3: $fdisplay(log_fd,"A %0d %0d %0d hold %0d %02x",cycle+1,LINK_ID,frame_no,byte_index,mask[7:0]);
                endcase
            end
        end
    endtask

    // 额外段只排在已知普通帧之后；未来发送若闯入这段区间，立即报错。
    task reserve_extra;
        input integer length;
        output integer slot;
        integer p, k, ending;
        begin
            slot=0;
            if(extra_count>=MAX_EXTRA || length<1 || length>MAX_BYTES) fail("invalid extra segment or capacity exceeded");
            else begin
                p=cycle+2;
                if(have_output && p<last_output_end+12) p=last_output_end+12;
                for(k=1;k<=frame_count;k=k+1)
                    if(!frame_aborted[k] && (frame_mode[k]==0 || frame_mode[k]==2)) begin
                        ending=due_start[k]+(frame_closed[k] ? source_length[k] : MAX_BYTES)+12;
                        if(p<ending) p=ending;
                    end
                if(extra_count!=0 && p<extra_start[extra_count]+extra_length[extra_count]+12)
                    p=extra_start[extra_count]+extra_length[extra_count]+12;
                extra_count=extra_count+1;
                slot=extra_count;
                extra_start[slot]=p;
                extra_length[slot]=length;
                extra_source[slot]=0;
            end
        end
    endtask

    task replay;
        input integer frame_no;
        integer slot;
        begin
            if(frame_no<1 || frame_no>frame_count || !frame_closed[frame_no] || frame_aborted[frame_no])
                fail("replay source is not a complete retained frame");
            else begin
                reserve_extra(source_length[frame_no],slot);
                if(slot!=0) begin
                    extra_source[slot]=frame_no;
                    $fdisplay(log_fd,"R %0d %0d %0d %0d",cycle+1,LINK_ID,frame_no,extra_start[slot]);
                end
            end
        end
    endtask

    task inject;
        input integer length;
        input [16383:0] bytes;
        integer slot, k;
        begin
            reserve_extra(length,slot);
            if(slot!=0) begin
                $fwrite(log_fd,"J %0d %0d %0d %0d ",cycle+1,LINK_ID,extra_start[slot],length);
                for(k=0;k<length;k=k+1) begin
                    extra_bytes[(slot-1)*MAX_BYTES+k]=bytes[k*8 +: 8];
                    $fwrite(log_fd,"%02x",bytes[k*8 +: 8]);
                end
                $fwrite(log_fd,"\n");
            end
        end
    endtask
endmodule
