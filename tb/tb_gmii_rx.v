`timescale 1ns/1ps
// 只看端口的字节环参考模型：先释放本拍慢线首字节，再接收本拍GMII字节。
module tb_gmii_rx #(parameter GMII_RX_AW=12);
    localparam CAPACITY=1<<GMII_RX_AW;
    localparam R=16;
    reg clk=0;
    always #4 clk=~clk;
    reg reset=1,enable=0,rx_valid=0;
    reg [7:0] rx_data=0;
    wire [7:0] slow_data;
    wire slow_valid,gdrop;
    afdx_gmii_rx #(.GMII_RX_AW(GMII_RX_AW)) dut(
        .clk(clk),.reset(reset),.enable(enable),.rx_data(rx_data),.rx_valid(rx_valid),
        .slow_data(slow_data),.slow_valid(slow_valid),.gdrop(gdrop)
    );
    reg [7:0] frame_bytes[0:1024*8192-1];
    integer frame_lengths[0:1023],queue_frame[0:1023],queue_start[0:1023],queue_end[0:1023];
    integer cycle=0,checks=0,errors=0,frames=0,deliveries=0,drops=0;
    integer qin=0,qout=0,occupied=0,peak_occupied=0,peak_self=0;
    integer active_frame=0,active_length=0,previous_end=0;
    integer next_start,offset,expected_frame,expected_byte,drop_mid=0;
    integer self_prev_len=0,self_prev_d=0,self_max_d=0,self_frames=0;
    integer gap1=0,gap12=0,gap96=0,last_input_end=0;
    reg input_active=0,input_skip=0,waiting_low=1,expected_drop=0,was_reset=0;
    reg expected_valid,self_stream=0;
    integer j,k,n,gap,mark_drops,mark_mid,mark_frames;
    reg [31:0] random_state=32'h6c37a105;

    task check;
        input ok;
        input [8*100-1:0] label;
        begin
            checks=checks+1;
            if(ok!==1'b1)begin
                errors=errors+1;
                if(errors<30)$display("[FAIL] tb_gmii_rx cycle=%0d %0s",cycle,label);
            end
        end
    endtask

    always @(posedge clk) begin
        cycle=cycle+1;
        if(reset) begin
            if(was_reset)check(!slow_valid && !gdrop,"reset outputs zero");
            qin=0;qout=0;occupied=0;previous_end=0;
            input_active=0;input_skip=0;waiting_low=1;expected_drop=0;
            self_prev_len=0;self_prev_d=0;
        end else begin
            check(gdrop===expected_drop,"one gdrop on first rejected byte plus one cycle");
            if(gdrop)drops=drops+1;
            expected_drop=0;
            if(qout<qin && cycle==queue_end[qout])begin qout=qout+1;deliveries=deliveries+1;end
            expected_valid=(qout<qin && cycle>=queue_start[qout] && cycle<queue_end[qout]);
            check(slow_valid===expected_valid,"exact frame start/end and continuous replay valid");
            if(expected_valid)begin
                offset=cycle-queue_start[qout];expected_frame=queue_frame[qout];
                expected_byte=frame_bytes[expected_frame*8192+offset/8];
                check(slow_data===expected_byte[7:0],"replay bytes and eight-cycle hold");
                if(offset%8==0)occupied=occupied-1;
            end
            if(waiting_low)begin
                if(!rx_valid)waiting_low=0;
            end else if(rx_valid)begin
                if(!input_active)begin
                    input_active=1;input_skip=!enable;active_length=0;active_frame=frames;frames=frames+1;
                    check(frames<1024,"reference frame capacity");
                    if(last_input_end!=0)begin
                        if(cycle-last_input_end==1)gap1=gap1+1;
                        if(cycle-last_input_end==12)gap12=gap12+1;
                        if(cycle-last_input_end==96)gap96=gap96+1;
                    end
                end
                if(!input_skip)begin
                    if(occupied==CAPACITY)begin
                        if(active_length!=0)drop_mid=drop_mid+1;
                        occupied=occupied-active_length;
                        input_skip=1;expected_drop=1;
                    end else begin
                        frame_bytes[active_frame*8192+active_length]=rx_data;
                        active_length=active_length+1;
                        occupied=occupied+1;
                    end
                end
            end else if(input_active)begin
                input_active=0;last_input_end=cycle;
                if(!input_skip)begin
                    next_start=cycle+R;
                    if(next_start<previous_end+16)next_start=previous_end+16;
                    queue_frame[qin]=active_frame;
                    queue_start[qin]=next_start;
                    queue_end[qin]=next_start+8*active_length;
                    frame_lengths[active_frame]=active_length;
                    previous_end=queue_end[qin];qin=qin+1;
                    if(self_stream)begin
                        offset=next_start-cycle-R;
                        if(self_prev_len!=0)begin
                            expected_byte=self_prev_d+self_prev_len-active_length-80;
                            if(expected_byte<0)expected_byte=0;
                            check(offset==expected_byte,"self-source waiting recurrence");
                        end else check(offset==0,"self-source first frame has no queue wait");
                        self_prev_len=active_length;self_prev_d=offset;self_frames=self_frames+1;
                        if(offset>self_max_d)self_max_d=offset;
                    end
                end
            end
            check(occupied>=0 && occupied<=CAPACITY,"reference byte occupancy range");
            if(occupied>peak_occupied)peak_occupied=occupied;
            if(self_stream && occupied>peak_self)peak_self=occupied;
        end
        was_reset=reset;
        if(cycle>3000000)begin $display("[RESULT] tb_gmii_rx FAIL checks=%0d errors=%0d",checks,errors+1);$finish;end
    end

    task send_frame;
        input integer length,idle,tag;
        integer b;
        begin
            for(b=0;b<length;b=b+1)begin
                @(negedge clk);rx_valid=1;rx_data=(tag*37+b*19+(b>>3))&255;
            end
            @(negedge clk);rx_valid=0;rx_data=0;
            repeat(idle-1)@(negedge clk);
        end
    endtask

    task drain;
        integer timeout_cycle;
        begin
            timeout_cycle=cycle+500000;
            @(posedge clk);#1;
            while(qout<qin || slow_valid || gdrop || input_active)begin
                @(posedge clk);#1;
                if(cycle>timeout_cycle)begin check(0,"unit drain timeout");$finish;end
            end
            repeat(24)begin @(posedge clk);#1;end
            check(occupied==0,"all accepted bytes released");
        end
    endtask

    task reset_idle;
        begin
            @(negedge clk);reset=1;rx_valid=0;
            repeat(4)@(negedge clk);
            reset=0;enable=1;
            repeat(3)@(negedge clk);
        end
    endtask

    initial begin
        repeat(4)@(negedge clk);reset=0;enable=1;repeat(3)@(negedge clk);
        send_frame(72,1,1);send_frame(73,12,2);send_frame(1526,96,3);send_frame(1527,29,4);
        drain;
        // 最短恶意段足以考验描述队列；不是只测完整以太网帧。
        for(j=0;j<700;j=j+1)send_frame(1,1,j);
        drain;
        for(j=0;j<48;j=j+1)begin
            random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            n=1+random_state%1527;
            case(j%4)0:gap=1;1:gap=12;2:gap=96;default:gap=1+(random_state>>12)%131;endcase
            send_frame(n,gap,j+1000);
        end
        drain;
        send_frame(CAPACITY,12,2000);drain;
        mark_drops=drops;mark_mid=drop_mid;
        send_frame(CAPACITY+37,1,2001);send_frame(73,12,2002);drain;
        check(drops==mark_drops+1,"frame longer than byte capacity dropped once");
        check(drop_mid==mark_mid+1,"oversized frame exhausted buffer mid-frame");
        mark_drops=drops;mark_mid=drop_mid;
        for(j=0;j<12;j=j+1)send_frame(1526,1,j+2100);
        drain;
        check(drops>mark_drops && drop_mid>mark_mid,"back-to-back long frames cause whole-frame rollback");
        send_frame(72,12,2200);drain;
        // 未就绪时开始，即使帧中途就绪，也整帧忽略。
        mark_drops=drops;enable=0;
        fork
            send_frame(73,12,2300);
            begin repeat(20)@(negedge clk);enable=1;end
        join
        drain;check(drops==mark_drops,"enable-ignored frame is not gdrop");
        send_frame(72,12,2301);drain;
        // 接收半帧复位，复位后仍为高的尾段不得认作新帧。
        fork
            send_frame(1526,12,2400);
            begin repeat(99)@(negedge clk);reset=1;repeat(4)@(negedge clk);reset=0;end
        join
        drain;send_frame(73,12,2401);drain;
        // 已开始的慢线重放被复位切断，后续新帧恢复。
        send_frame(1526,1,2500);
        while(!slow_valid)begin @(posedge clk);#1;end
        repeat(100)@(negedge clk);reset_idle;
        send_frame(72,12,2501);drain;
        // 自身发送器的GMII起点间距为8*L+96，长短交替达到排队边界。
        reset_idle;self_stream=1;mark_drops=drops;self_prev_len=0;self_prev_d=0;
        for(j=0;j<64;j=j+1)begin
            if(j%3==0)n=1526;
            else if(j%3==1)n=72;
            else begin
                random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
                n=72+random_state%1455;
            end
            send_frame(n,7*n+96,j+3000);
        end
        drain;self_stream=0;
        check(drops==mark_drops,"self-source traffic zero gdrop");
        check(self_frames==64 && self_max_d<=1374,"self-source delay bound");
        check(peak_self<=3054,"self-source safe occupancy bound");
        check(gap1>0 && gap12>0 && gap96>0,"GMII gap coverage 1/12/96");
        check(drop_mid>0 && deliveries>64,"overflow and delivered coverage");
        $display("[COVERAGE] gmii_rx R=%0d capacity=%0d frames=%0d delivered=%0d gdrop=%0d mid_drop=%0d peak_occupancy=%0d self_frames=%0d self_max_d=%0d self_peak_occupancy=%0d",R,CAPACITY,frames,deliveries,drops,drop_mid,peak_occupied,self_frames,self_max_d,peak_self);
        $display("[RESULT] tb_gmii_rx %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);
        $finish;
    end
endmodule
