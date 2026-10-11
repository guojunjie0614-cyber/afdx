// 验证两个真实端系统的 RTC 无负载和负载同步误差、秒边界与用户交付；RTC_SYNC/RTC_LOAD/RTC_GBE 输出误差。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
`timescale 1ns/1ps
// 两个真实GMII端系统；只经公开配置口读时钟，经应用口核对用户交付。
module tb_sys_rtc;
    reg clk=0,reset=1;
    always #4 clk=~clk;
    wire [7:0] a12,b12,a21,b21;
    wire va12,vb12,va21,vb21,ready1,ready2;
    wire [31:0] checks1,checks2,errors1,errors2;
    rtc_test_endpoint #(.ES(1)) es1(clk,reset,a21,va21,b21,vb21,a12,va12,b12,vb12,ready1,checks1,errors1);
    rtc_test_endpoint #(.ES(2)) es2(clk,reset,a12,va12,b12,vb12,a21,va21,b21,vb21,ready2,checks2,errors2);
    wire [31:0] gmerr1,gmerr2,gmframes1,gmframes2;
    gmii_monitor #(.FILE_NAME("rtc_es1_gmii.txt")) mon1(clk,reset,a12,va12,gmerr1,gmframes1);
    gmii_monitor #(.FILE_NAME("rtc_es2_gmii.txt")) mon2(clk,reset,a21,va21,gmerr2,gmframes2);
    reg fraction_start=0,fraction_inverse=0,fraction_finished=0;reg [31:0] fraction_input=0;
    wire fraction_done;wire [31:0] fraction_result;
    afdx_ntp_fraction fraction_probe(clk,reset,fraction_start,fraction_inverse,fraction_input,fraction_done,fraction_result);
    integer fraction_fd,fraction_rc,fraction_cases=0;reg [31:0] expected_ns,expected_fraction;
    integer cycle=0,checks=0,errors=0,fd,phase,loaded_max=0,gbe_max=0,gbe_base;
    reg [63:0] time1,time2,previous_time;
    reg signed [63:0] difference;
    integer previous_cycle;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>7000000 || errors+errors1+errors2>30)begin
            $display("[RESULT] tb_sys_rtc FAIL checks=%0d errors=%0d",checks+checks1+checks2,errors+errors1+errors2+1);$finish;
        end
    end
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;$display("[RTC_FAIL] phase=%0d cycle=%0d %0s",phase,cycle,why);end end
    endtask
    task measure;
        reg [31:0] s1,s2,n1,n2;
        begin
            fork es1.read_cfg(18'h84,s1);es2.read_cfg(18'h84,s2);join
            fork es1.read_cfg(18'h85,n1);es2.read_cfg(18'h85,n2);join
            check(n1<1000000000 && n2<1000000000,"nanoseconds normalized");
            time1={32'b0,s1}*64'd1000000000+n1;
            time2={32'b0,s2}*64'd1000000000+n2;
            difference=time2-time1;
        end
    endtask
    task observe;
        input integer slave,count,loaded;
        reg [31:0] current,last_count,os,on;
        integer i,timeout,absolute;
        begin
            if(slave==1)es1.read_cfg(18'h88,last_count);else es2.read_cfg(18'h88,last_count);
            for(i=0;i<count;i=i+1)begin
                timeout=cycle+500000;current=last_count;
                while(current==last_count && cycle<timeout)begin
                    repeat(250)@(negedge clk);
                    if(slave==1)es1.read_cfg(18'h88,current);else es2.read_cfg(18'h88,current);
                end
                check(current==last_count+1,"one completed synchronization");last_count=current;
                measure();absolute=difference<0 ? -difference : difference;
                if(!loaded)check(absolute<=40,"idle clock error <= 40 ns");
                if(loaded==1 && absolute>loaded_max)loaded_max=absolute;
                if(loaded==2 && absolute>gbe_max)gbe_max=absolute;
                if(slave==1)begin es1.read_cfg(18'h86,os);es1.read_cfg(18'h87,on);end
                else begin es2.read_cfg(18'h86,os);es2.read_cfg(18'h87,on);end
                check(on<1000000000,"reported offset normalized");
                $display("[RTC_SYNC] phase=%0d slave=%0d count=%0d difference_ns=%0d offset_sec=%0d offset_ns=%0d",phase,slave,current,difference,$signed(os),on);
                $fwrite(fd,"S %0d %0d %0d %0d %0d %0d\n",phase,slave,current,difference,$signed(os),on);
            end
        end
    endtask
    task idle_case;
        input integer number,slave,fast;
        begin
            phase=number;
            es1.write_cfg(18'h80,0);es2.write_cfg(18'h80,0);
            if(slave==2)begin
                es1.set_time(1000,999980000);
                if(fast)es2.set_time(1007,200000000);else es2.set_time(991,700000000);
                es1.write_cfg(18'h80,3);es2.write_cfg(18'h80,1);
            end else begin
                es2.set_time(1000,999980000);
                if(fast)es1.set_time(1007,200000000);else es1.set_time(991,700000000);
                es2.write_cfg(18'h80,3);es1.write_cfg(18'h80,1);
            end
            measure();$fwrite(fd,"I %0d %0d\n",phase,difference);
            check((difference>64'sd6000000000 || difference< -64'sd6000000000),"initial clocks differ by several seconds");
            observe(slave,5,0);
            es1.write_cfg(18'h80,0);es2.write_cfg(18'h80,0);
            measure();previous_time=time1;previous_cycle=cycle;
            repeat(250000)@(negedge clk);
            measure();check((difference>=-40 && difference<=40),"idle error stays bounded after sync stops");
            check(time1-previous_time==8*(cycle-previous_cycle),"RTC keeps ticking 8 ns including second rollover");
            $fwrite(fd,"H %0d %0d\n",phase,difference);
        end
    endtask
    initial begin
        wait(!reset);fraction_fd=$fopen("vectors/fractions.txt","r");
        while(!$feof(fraction_fd))begin
            fraction_rc=$fscanf(fraction_fd,"%d %h\n",expected_ns,expected_fraction);
            if(fraction_rc==2)begin
                @(negedge clk);fraction_input=expected_ns;fraction_inverse=0;fraction_start=1;
                @(negedge clk);fraction_start=0;wait(fraction_done);#1;
                check(fraction_result==expected_fraction,"exact nanosecond to NTP fraction conversion");
                @(negedge clk);fraction_input=expected_fraction;fraction_inverse=1;fraction_start=1;
                @(negedge clk);fraction_start=0;wait(fraction_done);#1;
                check(fraction_result==expected_ns,"fraction to rounded nanoseconds round trip");fraction_cases=fraction_cases+1;
            end
        end
        $fclose(fraction_fd);fraction_finished=1;
    end
    initial begin
        phase=0;fd=$fopen("rtc_results.txt","w");
        repeat(8)@(negedge clk);reset=0;
        wait(ready1 && ready2);
        es1.configure();es2.configure();
        es1.set_time(30,999999000);es2.set_time(30,999999000);
        measure();previous_time=time1;previous_cycle=cycle;
        repeat(250)@(negedge clk);
        measure();
        check(time1>=64'd31000000000 && time1<64'd32000000000,"seconds increment at nanosecond rollover");
        check(time1-previous_time==8*(cycle-previous_cycle),"RTC configuration snapshot and 8 ns tick across rollover");
        idle_case(1,2,1);
        idle_case(2,2,0);
        // 两端大载荷用户消息和RTC同时争用提交口、线路与交付口。
        phase=3;es1.write_cfg(18'h80,3);es2.write_cfg(18'h80,1);
        fork
            begin es1.traffic(40);end
            begin es2.traffic(40);end
            begin observe(2,8,1);es2.write_cfg(18'h80,0);es1.write_cfg(18'h80,0);end
        join
        repeat(100000)@(negedge clk);
        es1.write_cfg(18'h80,0);es2.write_cfg(18'h80,0);
        check(es1.received==40 && es2.received==40,"all application messages delivered exactly once");
        $fwrite(fd,"U 40 40 %0d %0d %0d\n",es1.received,es2.received,loaded_max);
        idle_case(4,1,1);
        idle_case(5,1,0);
        // 77 条用户 VL 每条 BAG 1 ms，并在两个方向实测 RTC 与用户数据共存。
        phase=6;es1.configure_gbe();es2.configure_gbe();
        es1.write_cfg(18'h80,3);es2.write_cfg(18'h80,1);gbe_base=cycle+100;
        fork
            es1.gbe_traffic(gbe_base);
            es2.gbe_traffic(gbe_base);
            observe(2,40,2);
        join
        es1.write_cfg(18'h80,0);es2.write_cfg(18'h80,0);
        repeat(100000)@(negedge clk);
        check(es1.received==40+23*77 && es2.received==40+23*77,"all full-load user messages delivered once");
        check(gbe_max<=39364,"900 Mbps RTC error no worse than T14");
        $fwrite(fd,"G %0d %0d %0d %0d %0d\n",gbe_base+250000,gbe_base+23*125000,es1.received,es2.received,gbe_max);
        $fwrite(fd,"A 1 %0d %0d\nA 2 %0d %0d\n",es1.max_source_lateness,es1.max_source_duration,es2.max_source_lateness,es2.max_source_duration);
        $display("[RTC_GBE] delivered=%0d/%0d max_difference_ns=%0d",es1.received-40,es2.received-40,gbe_max);
        check(fraction_finished && fraction_cases==72,"all independent conversion vectors checked");
        check(gmerr1==0 && gmerr2==0,"SNTP GMII framing");
        $fwrite(fd,"F %0d\n",fraction_cases);$fclose(fd);
        $display("[RTC_LOAD] delivered=%0d/%0d max_difference_ns=%0d",es1.received,es2.received,loaded_max);
        $display("[RESULT] tb_sys_rtc %0s checks=%0d errors=%0d",(errors+errors1+errors2)==0 ? "PASS":"FAIL",checks+checks1+checks2,errors+errors1+errors2);
        $finish;
    end
endmodule

module rtc_test_endpoint #(parameter ES=1)(
    input wire clk,reset,input wire [7:0] ra,input wire rva,input wire [7:0] rb,input wire rvb,
    output wire [7:0] ta,output wire tva,output wire [7:0] tb,output wire tvb,output wire ready,
    output reg [31:0] checks=0,errors=0
);
    reg m_valid=0,m_last=0;reg [7:0] m_data=0;reg [6:0] m_vl=1;wire m_ready;
    wire d_valid,d_last,d_net;wire [7:0] d_data;wire [11:0] d_vl;wire [15:0] d_sp,d_dp;
    reg wr=0,rd=0;reg [17:0] address=0;reg [31:0] wdata=0;
    wire [31:0] rdata;wire rvalid,bready;
    wire [6:0] ev_tx;wire [7:0] ev_a,ev_b;wire [1:0] gdrop;wire rm_drop,deliver;
    integer received=0,byte_index=0,gbe_mode=0,max_source_lateness=0,max_source_duration=0;
    reg [7:0] expected_byte;
    AFDX_top dut(
        .clk(clk),.reset(reset),.tx_data(ta),.tx_valid(tva),.rx_data(ra),.rx_valid(rva),.tx_ready(ready),.rx_ready(1'b0),
        .tx_data_b(tb),.tx_valid_b(tvb),.rx_data_b(rb),.rx_valid_b(rvb),
        .app_tx_valid(m_valid),.app_tx_ready(m_ready),.app_tx_data(m_data),.app_tx_last(m_last),.app_tx_vl(m_vl),
        .app_tx_port_en(1'b0),.app_tx_sport(16'd0),.app_tx_dport(16'd0),
        .app_rx_valid(d_valid),.app_rx_data(d_data),.app_rx_last(d_last),.app_rx_vl(d_vl),
        .app_rx_sport(d_sp),.app_rx_port(d_dp),.app_rx_net(d_net),
        .cfg_wr(wr),.cfg_rd(rd),.cfg_addr(address),.cfg_wdata(wdata),.cfg_rdata(rdata),.cfg_rvalid(rvalid),.cfg_ready(bready),
        .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(rm_drop),.ev_deliver(deliver),.ev_gdrop(gdrop)
    );
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;if(errors<20)$display("[RTC_ENDPOINT_FAIL] ES%0d %0s",ES,why);end end
    endtask
    always @(posedge clk)if(!reset)begin
        if(|ev_tx[4:1] || |ev_a[7:1] || |ev_b[7:1] || |gdrop)check(0,"unexpected drop/error pulse");
        if(d_valid)begin
            expected_byte=byte_index+received*19+(3-ES)*37;
            check(d_dp==4001 && d_sp==3001 && d_vl==(gbe_mode ? 1+(received-40)%77 : 1),"RTC hidden from application and user metadata intact");
            check(d_data==expected_byte,"application bytes and ordering intact");
            byte_index=byte_index+1;
            if(d_last)begin check(byte_index==1471,"complete application message");received=received+1;byte_index=0;end
        end
    end
    task write_cfg;
        input [17:0] a;input [31:0] v;
        begin
            @(negedge clk);while(!bready)@(negedge clk);
            address=a;wdata=v;wr=1;
            @(posedge clk);#1;wr=0;
            while(!bready)begin @(posedge clk);#1;end
        end
    endtask
    task read_cfg;
        input [17:0] a;output [31:0] value;
        begin
            @(negedge clk);address=a;rd=1;
            @(posedge clk);#1;rd=0;
            @(posedge clk);#1;check(rvalid,"configuration read valid");value=rdata;
        end
    endtask
    task set_time;
        input [31:0] sec,ns;
        begin write_cfg(18'h84,sec);write_cfg(18'h85,ns);write_cfg(18'h80,4);end
    endtask
    task configure;
        integer v,maximum,vlid,peer_vlid;
        begin
            write_cfg(2,ES);
            for(v=0;v<2;v=v+1)begin
                maximum=v==0 ? 48 : 1471;vlid=ES*100+v;peer_vlid=(3-ES)*100+v;
                write_cfg(18'h1000+v*8,maximum*512+63*8+7);
                write_cfg(18'h1001+v*8,v==0 ? 800 : 12304);
                write_cfg(18'h1002+v*8,vlid);
                write_cfg(18'h1003+v*8,32'h0a000001+ES);
                write_cfg(18'h1004+v*8,32'he0e00000+vlid);
                write_cfg(18'h1005+v*8,v==0 ? 32'h007b007b : 32'h0bb90fa1);
                write_cfg(18'h10000+peer_vlid,4096+v);
                write_cfg(18'h20000+v,maximum*131072+20*32+31);
            end
            write_cfg(18'h81,62500);write_cfg(18'h82,0);write_cfg(18'h83,123);
        end
    endtask
    task configure_gbe;
        integer v,vlid,peer_vlid;
        begin
            for(v=1;v<=77;v=v+1)begin
                vlid=ES*100+v;peer_vlid=(3-ES)*100+v;
                write_cfg(18'h1000+v*8,1471*512+63*8+7);write_cfg(18'h1001+v*8,125000);
                write_cfg(18'h1002+v*8,vlid);write_cfg(18'h1003+v*8,32'h0a000001+ES);
                write_cfg(18'h1004+v*8,32'he0e00000+vlid);write_cfg(18'h1005+v*8,32'h0bb90fa1);
                write_cfg(18'h10000+peer_vlid,4096+v);write_cfg(18'h20000+v,1471*131072+20*32+31);
            end
            gbe_mode=1;
        end
    endtask
    task gbe_traffic;
        input integer base;
        integer r,v,j,target,timeout;
        reg taken;
        begin
            for(r=0;r<23;r=r+1)for(v=0;v<77;v=v+1)begin
                target=base+r*125000+(v*125000)/77;
                while(tb_sys_rtc.cycle<target)@(negedge clk);
                // 服务正在提交时应用必须遵守 ready；用实际吞吐判定负载，记录提交等待。
                if(tb_sys_rtc.cycle-target>max_source_lateness)max_source_lateness=tb_sys_rtc.cycle-target;
                m_vl=v+1;timeout=tb_sys_rtc.cycle;
                for(j=0;j<1471;j=j+1)begin
                    @(negedge clk);m_valid=1;m_last=(j==1470);m_data=j+(40+r*77+v)*19+ES*37;taken=0;
                    while(!taken)begin @(posedge clk);taken=m_ready;#1;end
                end
                m_valid=0;m_last=0;
                if(tb_sys_rtc.cycle-timeout>max_source_duration)max_source_duration=tb_sys_rtc.cycle-timeout;
            end
        end
    endtask
    task traffic;
        input integer count;
        integer m,j;reg accepted;
        begin
            for(m=0;m<count;m=m+1)begin
                for(j=0;j<1471;j=j+1)begin
                    @(negedge clk);m_valid=1;m_last=(j==1470);m_data=j+m*19+ES*37;accepted=0;
                    while(!accepted)begin @(posedge clk);accepted=m_ready;#1;end
                end
                m_valid=0;m_last=0;
                repeat(11000)@(negedge clk);
            end
        end
    endtask
endmodule
