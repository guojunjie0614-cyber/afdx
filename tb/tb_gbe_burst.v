`timescale 1ns/1ps
// 先在原生收发核心间预装队列，再统一打开 MAC；释放时延与应用提交时延分开记录。
module tb_gbe_burst #(parameter COUNT=77);
    reg clk=0,reset=1,release_mac=0;always #4 clk=~clk;
    integer cycle=0,checks=0,errors=0,accepted=0,received=0,rm_count=0;
    integer v,j,n=0,released=0,first_sof=0,wire_frames=0,max_queue=0,max_raw=0;
    integer message_end[0:127],frame_end[0:127];
    reg [127:0] seen=0;
    integer wire_byte=0;reg [15:0] wire_vlid=0;
    reg previous_valid=0;
    reg m_valid=0,m_last=0,cfg_we=0,map_we=0,rx_cfg_we=0;
    reg [7:0] m_data=0;reg [6:0] m_vl=0;
    reg [9:0] cfg_addr=0;reg [31:0] cfg_data=0,rx_data=0;reg [15:0] rx_addr=0;
    wire m_ready,tx_ready,rx_ready,tx_cfg_ok,rx_cfg_ok;
    wire [7:0] ta,tb,ea,eb,d_data;wire tva,tvb,d_valid,d_last,d_net,rm,deliver;
    wire [11:0] d_vl;wire [15:0] d_sp,d_dp;
    wire ev_accept,dd,df,dl,dn;
    afdx_tx_core tx(.clk(clk),.reset(reset),.now(cycle),.byte_en(release_mac),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),.m_vl(m_vl),
        .m_port_en(1'b0),.m_sport(16'd0),.m_dport(16'd0),.cfg_we(cfg_we),
        .cfg_addr(cfg_addr),.cfg_wdata(cfg_data),.user_id(16'h2344),.init_done(tx_ready),
        .tx_data_a(ta),.tx_valid_a(tva),.tx_data_b(tb),.tx_valid_b(tvb),.ev_tx_a(),.ev_tx_b(),
        .cfg_ok(tx_cfg_ok),.ev_accept(ev_accept),.ev_drop_dis(dd),.ev_drop_full(df),
        .ev_drop_long(dl),.ev_drop_nopage(dn));
    afdx_rx_core rx(.clk(clk),.reset(reset),.now_c(cycle[27:12]),.rx_data_a(ta),.rx_valid_a(tva),
        .rx_data_b(tb),.rx_valid_b(tvb),.cfg_map_we(map_we),.cfg_cfg_we(rx_cfg_we),
        .cfg_addr(rx_addr),.cfg_wdata(rx_data),.init_done(rx_ready),.cfg_ok(rx_cfg_ok),
        .d_valid(d_valid),.d_data(d_data),.d_last(d_last),.d_vl(d_vl),.d_sport(d_sp),.d_dport(d_dp),
        .d_net(d_net),.ev_a(ea),.ev_b(eb),.ev_rm_drop(rm),.ev_deliver(deliver));
    wire [31:0] ma_errors,mb_errors,ma_frames,mb_frames;
    gmii_monitor #(.FILE_NAME("burst_a.txt")) ma(clk,reset,ta,tva,ma_errors,ma_frames);
    gmii_monitor #(.FILE_NAME("burst_b.txt")) mb(clk,reset,tb,tvb,mb_errors,mb_frames);
    task check;input ok;input [8*100-1:0] why;
    begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[BURST_FAIL] %0s",why);end end endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!reset)begin
            if(ev_accept)accepted=accepted+1;
            check(!(dd||df||dl||dn||(|ea[7:1])||(|eb[7:1])),"no allocation, framing or receive error");
            if(m_valid&&m_ready&&m_last)message_end[m_vl]=cycle;
            if(rm)rm_count=rm_count+1;
            if(tva&&!previous_valid&&first_sof==0)first_sof=cycle;
            if(tva)begin
                if(!previous_valid)wire_byte=0;
                if(wire_byte==12)wire_vlid[15:8]=ta;
                if(wire_byte==13)wire_vlid[7:0]=ta;
                wire_byte=wire_byte+1;
            end
            if(!tva&&previous_valid)begin frame_end[wire_vlid-100]=cycle-1;wire_frames=wire_frames+1;end
            previous_valid=tva;
            if(d_valid)begin
                check(d_vl<COUNT&&d_sp==3001&&d_dp==4001,"VL identity and metadata");
                if(n==0)check(!seen[d_vl],"each VL delivered exactly once");
                check(d_data===((n+d_vl)&255),"payload bytes");
                check(d_last===(n==1470),"message boundary");n=n+1;
                if(d_last)begin
                    check(n==1471,"whole message");
                    if(cycle-released>max_queue)max_queue=cycle-released;
                    if(cycle-message_end[d_vl]>max_raw)max_raw=cycle-message_end[d_vl];
                    $display("[BURST_D] vl=%0d queue_cycles=%0d raw_m_to_d=%0d wire_last_to_d=%0d",d_vl,
                        cycle-released,cycle-message_end[d_vl],cycle-frame_end[d_vl]);
                    seen[d_vl]=1;
                    received=received+1;n=0;
                end
            end
        end
        if(cycle>500000||errors>30)begin
            $display("[RESULT] tb_gbe_burst FAIL checks=%0d errors=%0d",checks,errors+1);$finish;
        end
    end
    task write_tx;input integer addr;input [31:0] value;
    begin @(negedge clk);while(!tx_cfg_ok)@(negedge clk);cfg_addr=addr;cfg_data=value;cfg_we=1;
        @(negedge clk);cfg_we=0;repeat(2)@(negedge clk);end endtask
    task write_rx;input integer map,addr;input [31:0] value;
    begin @(negedge clk);while(!rx_cfg_ok)@(negedge clk);rx_addr=addr;rx_data=value;map_we=map;rx_cfg_we=!map;
        @(negedge clk);map_we=0;rx_cfg_we=0;repeat(3)@(negedge clk);end endtask
    initial begin
        repeat(4)@(negedge clk);reset=0;wait(tx_ready&&rx_ready);
        for(v=0;v<COUNT;v=v+1)begin
            write_tx(v*8,1471*512+63*8+7);write_tx(v*8+1,125000);write_tx(v*8+2,100+v);
            write_tx(v*8+3,32'h0a000001);write_tx(v*8+4,32'he0e00064+v);write_tx(v*8+5,32'h0bb90fa1);
            write_rx(1,100+v,4096+v);write_rx(0,v,1471*131072+20*32+31);
        end
        for(v=0;v<COUNT;v=v+1)begin
            m_vl=v;
            for(j=0;j<1471;j=j+1)begin
                @(negedge clk);m_valid=1;m_last=(j==1470);m_data=j+v;
                @(posedge clk);while(!m_ready)@(posedge clk);#1;
            end
            m_valid=0;m_last=0;wait(accepted==v+1);
        end
        @(negedge clk);released=cycle;release_mac=1;
        wait(received==COUNT);repeat(30)@(negedge clk);
        check(accepted==COUNT&&received==COUNT&&rm_count==COUNT,"all queued messages delivered once and duplicates rejected");
        check(ma_errors==0&&mb_errors==0&&ma_frames==COUNT&&mb_frames==COUNT,"both native GMII frame streams");
        $display("[BURST_SUMMARY] count=%0d release=%0d first_sof=%0d max_queue_cycles=%0d max_raw_m_to_d=%0d",COUNT,released,first_sof,max_queue,max_raw);
        $display("[RESULT] tb_gbe_burst %0s checks=%0d errors=%0d",errors==0?"PASS":"FAIL",checks,errors);$finish;
    end
endmodule
