// 本模块通过 AFDX_top 的公开端口执行配置、发送消息和复位。
// 它记录每次消息提交和交付，把错误数交给系统测试。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
// 所有端口值在时钟上升沿、非阻塞赋值更新前采样。
module sys_endpoint #(
    parameter ES=1,TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512,RX_RING_AW=12,RX_DQ_AW=5,DIRECT_CORE=0
)(
    input wire clk,reset,
    input wire [7:0] rd_a,
    input wire rv_a,
    input wire [7:0] rd_b,
    input wire rv_b,
    input wire [31:0] sys_fd,
    output wire [7:0] td_a,
    output wire tv_a,
    output wire [7:0] td_b,
    output wire tv_b,tx_ready,
    output integer checks,errors
);
`ifdef SYS_TOP_NETLIST
    localparam CAPTURE_CORE=0;
`else
    localparam CAPTURE_CORE=1;
`endif
    reg raw_mode=0;reg [15:0] raw_vlid=0;wire initialized;
    reg m_valid=0,m_last=0,m_port_en=0;
    reg [7:0] m_data=0;
    reg [6:0] m_vl=0;
    reg [15:0] m_sport=0,m_dport=0;
    wire m_ready,d_valid,d_last,d_net;
    wire [7:0] d_data,ev_a,ev_b;
    wire [6:0] ev_tx;
    wire [11:0] d_vl;
    wire [15:0] d_sport,d_dport;
    wire ev_rm_drop,ev_deliver;
    wire [1:0] ev_gdrop=2'b00;
    reg cfg_wr=0,cfg_rd=0,cfg_rewrite=0,cfg_live=0;
    reg [17:0] cfg_addr=0;
    reg [31:0] cfg_wdata=0;
    wire [31:0] cfg_rdata;
    wire cfg_ready,cfg_rvalid;
    wire [31:0] shadow_now;
    wire [15:0] shadow_now_c;
    wire shadow_byte_en;
`ifdef SYS_TOP_NETLIST
    top_stream_endpoint dut(
`else
    top_stream_endpoint #(.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD),
        .RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW),.DIRECT_CORE(DIRECT_CORE)) dut(
`endif
        .raw_mode(raw_mode),.raw_vlid(raw_vlid),.initialized(initialized),
        .clk(clk),.reset(reset),.tx_data(td_a),.tx_valid(tv_a),.rx_data(rd_a),.rx_valid(rv_a),
        .tx_ready(tx_ready),.rx_ready(1'b0),.tx_data_b(td_b),.tx_valid_b(tv_b),.rx_data_b(rd_b),.rx_valid_b(rv_b),
        .app_tx_valid(m_valid),.app_tx_ready(m_ready),.app_tx_data(m_data),.app_tx_last(m_last),.app_tx_vl(m_vl),
        .app_tx_port_en(m_port_en),.app_tx_sport(m_sport),.app_tx_dport(m_dport),
        .app_rx_valid(d_valid),.app_rx_data(d_data),.app_rx_last(d_last),.app_rx_vl(d_vl),
        .app_rx_sport(d_sport),.app_rx_port(d_dport),.app_rx_net(d_net),
        .cfg_wr(cfg_wr),.cfg_rd(cfg_rd),.cfg_addr(cfg_addr),.cfg_wdata(cfg_wdata),
        .cfg_rdata(cfg_rdata),.cfg_rvalid(cfg_rvalid),.cfg_ready(cfg_ready),
        .ev_tx(ev_tx),.ev_a(ev_a),.ev_b(ev_b),.ev_rm_drop(ev_rm_drop),.ev_deliver(ev_deliver)
    );
    afdx_timebase shadow_timebase(clk,reset,shadow_now,shadow_byte_en,shadow_now_c);
    wire [7:0] slow_td_a,slow_td_b,slow_rd_a,slow_rd_b;
    wire slow_tv_a,slow_tv_b,slow_rv_a,slow_rv_b;
    wire [31:0] mon_ta_errors,mon_tb_errors,mon_ra_errors,mon_rb_errors;
    wire [31:0] mon_ta_frames,mon_tb_frames,mon_ra_frames,mon_rb_frames;
`ifdef SYS_TOP_NETLIST
    assign slow_td_a=0;assign slow_td_b=0;assign slow_rd_a=0;assign slow_rd_b=0;
    assign slow_tv_a=0;assign slow_tv_b=0;assign slow_rv_a=0;assign slow_rv_b=0;
    assign mon_ta_errors=0;assign mon_tb_errors=0;assign mon_ra_errors=0;assign mon_rb_errors=0;
`else
    // 唯一的内部观测例外：四条核心边界慢线。
    assign slow_td_a=td_a;assign slow_tv_a=tv_a;
    assign slow_td_b=td_b;assign slow_tv_b=tv_b;
    assign slow_rd_a=rd_a;assign slow_rv_a=rv_a;
    assign slow_rd_b=rd_b;assign slow_rv_b=rv_b;
    line_monitor #(.NET("A"),.FILE_NAME(ES==1 ? "es1_tx/dump_a.txt" : "es2_tx/dump_a.txt"),
        .MIN_GAP(12),.SAMPLE_DELAY(0),.IGNORE_RESET_TAIL(1))
        mon_ta(clk,reset,slow_td_a,slow_tv_a,mon_ta_errors,mon_ta_frames);
    line_monitor #(.NET("B"),.FILE_NAME(ES==1 ? "es1_tx/dump_b.txt" : "es2_tx/dump_b.txt"),
        .MIN_GAP(12),.SAMPLE_DELAY(0),.IGNORE_RESET_TAIL(1))
        mon_tb(clk,reset,slow_td_b,slow_tv_b,mon_tb_errors,mon_tb_frames);
    line_monitor #(.NET("A"),.FILE_NAME(ES==1 ? "es1_rx/dump_a.txt" : "es2_rx/dump_a.txt"),
        .MIN_GAP(12),.SAMPLE_DELAY(0),.IGNORE_RESET_TAIL(1))
        mon_ra(clk,reset,slow_rd_a,slow_rv_a,mon_ra_errors,mon_ra_frames);
    line_monitor #(.NET("B"),.FILE_NAME(ES==1 ? "es1_rx/dump_b.txt" : "es2_rx/dump_b.txt"),
        .MIN_GAP(12),.SAMPLE_DELAY(0),.IGNORE_RESET_TAIL(1))
        mon_rb(clk,reset,slow_rd_b,slow_rv_b,mon_rb_errors,mon_rb_frames);
`endif
    wire [31:0] gm_ta_errors,gm_tb_errors,gm_ra_errors,gm_rb_errors;
    wire [31:0] gm_ta_frames,gm_tb_frames,gm_ra_frames,gm_rb_frames;
    gmii_monitor #(.NET("A"),.FILE_NAME(ES==1 ? "es1_gmii_tx/dump_a.txt" : "es2_gmii_tx/dump_a.txt"))
        gm_ta(clk,reset,td_a,tv_a,gm_ta_errors,gm_ta_frames);
    gmii_monitor #(.NET("B"),.FILE_NAME(ES==1 ? "es1_gmii_tx/dump_b.txt" : "es2_gmii_tx/dump_b.txt"))
        gm_tb(clk,reset,td_b,tv_b,gm_tb_errors,gm_tb_frames);
    gmii_monitor #(.NET("A"),.FILE_NAME(ES==1 ? "es1_gmii_rx/dump_a.txt" : "es2_gmii_rx/dump_a.txt"))
        gm_ra(clk,reset,rd_a,rv_a,gm_ra_errors,gm_ra_frames);
    gmii_monitor #(.NET("B"),.FILE_NAME(ES==1 ? "es1_gmii_rx/dump_b.txt" : "es2_gmii_rx/dump_b.txt"))
        gm_rb(clk,reset,rd_b,rv_b,gm_rb_errors,gm_rb_frames);
    wire line_activity=tv_a||tv_b||rv_a||rv_b||slow_tv_a||slow_tv_b||slow_rv_a||slow_rv_b;

    reg [7:0] stimulus[0:31999999],message_bytes[0:8191],delivered_bytes[0:4095];
    reg [31:0] expected_count[0:26],cfg_shadow[0:1023];
    // 0–24 号计数器的事件在设计内经两级寄存才加一，期望值同样晚两拍累加。
    reg count_lag1[0:24],count_lag2[0:24];
    reg [15:0] user_shadow=0;
    integer tf,rf,cycle=0,release_cycle=0,quiet_since=0,last_wire_end=-100000;
    integer pending_tx=0,outstanding=0,last_message=0,last_outcome=-1,low_run=0;
    integer message_len=0,message_vl=0,message_pen=0,message_sp=0,message_dp=0,outcome_vl=0;
    // R119：应用发送口首次 valid 为高的拍与消息内最长反压连拍，随 M 行附在最后。
    integer message_start=0,stall_run=0,stall_max=0;
    reg m_seen=0;
    integer delivery_len=0,delivery_start=0;
    reg [11:0] delivery_vl;
    reg [15:0] delivery_sp,delivery_dp;
    reg delivery_net,delivery_active=0;
    reg was_reset=0,was_ready=0;
    reg [7:0] previous_lines=0;
    reg read_pending0=0,read_pending1=0;
    reg [31:0] read_expected0=0,read_expected1=0;
    reg [17:0] read_address0=0,read_address1=0;
    integer read_cycle0=0,read_cycle1=0;
    reg bus_pending=0,bus_rewrite=0,ready_check=0,ready_expected=0;
    reg [17:0] bus_address=0;
    reg [31:0] bus_data=0;
    integer bus_accept=0,cfg_max_wait=0,cfg_tx_waited=0,cfg_map_waited=0,cfg_rx_waited=0;
    integer k,pulses,waited,payload_fd,payload_total,payload_rc;

    task check;
        input condition;
        input [8*100-1:0] label;
        begin
            checks=checks+1;
            if(condition!==1'b1)begin
                errors=errors+1;
                if(errors<40)$display("[SYS_FAIL] ES%0d cycle=%0d %0s",ES,cycle,label);
            end
        end
    endtask

    function [31:0] expected_read;
        input [17:0] address;
        begin
            case(address)
                18'h00000:expected_read=32'hc3110000;
                18'h00001:expected_read={31'b0,initialized};
                18'h00002:expected_read={16'b0,user_shadow};
                18'h00040:expected_read=expected_count[0];
                18'h00041:expected_read=expected_count[1];
                18'h00042:expected_read=expected_count[2];
                18'h00043:expected_read=expected_count[3];
                18'h00044:expected_read=expected_count[4];
                18'h00045:expected_read=expected_count[5];
                18'h00046:expected_read=expected_count[6];
                18'h00048:expected_read=expected_count[7];
                18'h00049:expected_read=expected_count[8];
                18'h0004a:expected_read=expected_count[9];
                18'h0004b:expected_read=expected_count[10];
                18'h0004c:expected_read=expected_count[11];
                18'h0004d:expected_read=expected_count[12];
                18'h0004e:expected_read=expected_count[13];
                18'h0004f:expected_read=expected_count[14];
                18'h00050:expected_read=expected_count[15];
                18'h00051:expected_read=expected_count[16];
                18'h00052:expected_read=expected_count[17];
                18'h00053:expected_read=expected_count[18];
                18'h00054:expected_read=expected_count[19];
                18'h00055:expected_read=expected_count[20];
                18'h00056:expected_read=expected_count[21];
                18'h00057:expected_read=expected_count[22];
                18'h00058:expected_read=expected_count[23];
                18'h00059:expected_read=expected_count[24];
                18'h0005a:expected_read=expected_count[25];
                18'h0005b:expected_read=expected_count[26];
                default:expected_read=0;
            endcase
        end
    endfunction

    task record_pulse;
        input integer index;
        input [8*16-1:0] label;
        begin
            if(index>=25)$fwrite(sys_fd,"E %0d %0d %0s\n",cycle,ES,label);
            else if(CAPTURE_CORE)begin
                if(index<7)$fwrite(tf,"E %0d %0s\n",cycle,label);
                else $fwrite(rf,"E %0d %0s\n",cycle,label);
            end
            if(index<25)count_lag1[index]=1;
            else expected_count[index]=expected_count[index]+32'd1;
            quiet_since=cycle;
        end
    endtask

    initial begin
        checks=0;errors=0;
        tf=$fopen(ES==1 ? "es1_tx/events.txt" : "es2_tx/events.txt","w");
        rf=$fopen(ES==1 ? "es1_rx/events.txt" : "es2_rx/events.txt","w");
        if(!tf || !rf)begin $display("[SYS_FAIL] cannot open endpoint events");$finish;end
        if(CAPTURE_CORE)$fwrite(tf,"G 0 TX_PAGE_AW %0d\nG 0 TX_OFF_AW %0d\nG 0 LOOKAHEAD %0d\n",TX_PAGE_AW,TX_OFF_AW,LOOKAHEAD);
        if(CAPTURE_CORE)$fwrite(rf,"G 0 RX_RING_AW %0d\nG 0 RX_DQ_AW %0d\n",RX_RING_AW,RX_DQ_AW);
        for(k=0;k<27;k=k+1)expected_count[k]=0;
            for(k=0;k<25;k=k+1)begin count_lag1[k]=0;count_lag2[k]=0;end
        for(k=0;k<1024;k=k+1)cfg_shadow[k]=0;
        payload_fd=$fopen("vectors/sys_payload.count","r");
        if(!payload_fd)begin $display("[SYS_FAIL] cannot open payload count");$finish;end
        payload_rc=$fscanf(payload_fd,"%d",payload_total);$fclose(payload_fd);
        $readmemh("vectors/sys_payload.hex",stimulus,0,payload_total-1);
    end

    always @(posedge clk)begin
        cycle=cycle+1;
        if(reset)begin
            if(!was_reset)begin
                if(CAPTURE_CORE)$fwrite(tf,"Z %0d\n",cycle);
                if(CAPTURE_CORE)$fwrite(rf,"Z %0d\n",cycle);
            end
            outstanding=0;pending_tx=0;message_len=0;outcome_vl=0;delivery_len=0;delivery_active=0;
            message_start=0;stall_run=0;stall_max=0;m_seen=0;
            read_pending0=0;read_pending1=0;bus_pending=0;ready_check=0;
            user_shadow=0;low_run=0;
            for(k=0;k<27;k=k+1)expected_count[k]=0;
            for(k=0;k<25;k=k+1)begin count_lag1[k]=0;count_lag2[k]=0;end
            for(k=0;k<1024;k=k+1)cfg_shadow[k]=0;
        end else begin
            if(was_reset)begin
                release_cycle=cycle;
                if(CAPTURE_CORE)$fwrite(tf,"R %0d\nN %0d %08x\nU %0d 0000\n",cycle,cycle,shadow_now,cycle);
                if(CAPTURE_CORE)$fwrite(rf,"R %0d\nK %0d %04x 4096\n",cycle,cycle,shadow_now_c);
            end
            if(initialized && !was_ready)begin
                if(CAPTURE_CORE)$fwrite(rf,"I %0d\n",cycle);
                check(cycle-release_cycle>=65536 && cycle-release_cycle<65600,"combined initialization deadline");
            end
            if(!initialized)begin
                check(!cfg_ready,"cfg_ready low until tx_ready");
                check(!d_valid && ev_a==0 && ev_b==0 && !ev_rm_drop && !ev_deliver && ev_gdrop==0,"receive initialization output suppression");
                check(!tv_a && !tv_b && td_a==0 && td_b==0,"transmit initialization line idle");
                check(cycle-release_cycle<65600,"initialization completes");
                low_run=0;
            end else begin
                if(m_ready)low_run=0;else low_run=low_run+1;
                if(DIRECT_CORE)check(low_run<=96,"application ready low run <=96");
            end

            // 先核读响应，再取本拍读快照，最后才累计本拍的 E。
            check(cfg_rvalid===read_pending1,"read response exactly t+2");
            if(cfg_rvalid)begin
                check(cfg_rdata===read_expected1,"read data including E(t-1), excluding E(t)");
                $fwrite(sys_fd,"V %0d %0d %05x %08x %0d\n",cycle,ES,read_address1,cfg_rdata,read_cycle1);
            end
            read_pending1=read_pending0;read_expected1=read_expected0;
            read_address1=read_address0;read_cycle1=read_cycle0;
            read_pending0=cfg_rd;read_expected0=expected_read(cfg_addr);
            read_address0=cfg_addr;read_cycle0=cycle;
            if(cfg_rd)$fwrite(sys_fd,"Q %0d %0d %05x\n",cycle,ES,cfg_addr);

            if(ready_check)check(cfg_ready===ready_expected,"configuration ready after acceptance");
            ready_check=0;
            if(bus_pending)begin
                check(cycle-bus_accept<=65,"table write wait deadline");
                if(cfg_ready)begin
                    waited=cycle-bus_accept-1;
                    check(waited>=1 && waited<=64,"table write waits one to 64 cycles");
                    if(waited>cfg_max_wait)cfg_max_wait=waited;
                    $fwrite(sys_fd,"W %0d %0d %05x %08x %0d %0d\n",bus_accept,ES,bus_address,bus_data,cycle-1,bus_rewrite);
                    if(bus_address[17:10]==8'b00000100)begin
                        if(waited>=2)cfg_tx_waited=cfg_tx_waited+1;
                        if(!bus_rewrite)begin
                            if(CAPTURE_CORE)$fwrite(tf,"C %0d tx %0x %0x\n",cycle-1,bus_address[9:0],bus_data);
                            cfg_shadow[bus_address[9:0]]=bus_data;
                        end
                    end else if(bus_address[17:16]==2'b01)begin
                        if(waited>=2)cfg_map_waited=cfg_map_waited+1;
                        if(!bus_rewrite)if(CAPTURE_CORE)$fwrite(rf,"C %0d map %0x %0x\n",cycle-1,bus_address[15:0],bus_data&32'h1fff);
                    end else begin
                        if(waited>=2)cfg_rx_waited=cfg_rx_waited+1;
                        if(!bus_rewrite)if(CAPTURE_CORE)$fwrite(rf,"C %0d cfg %0x %0x\n",cycle-1,bus_address[11:0],bus_data);
                    end
                    bus_pending=0;
                end
            end
            if(cfg_wr && cfg_ready)begin
                if(!cfg_rewrite && !cfg_live && (cfg_addr==18'h2 || cfg_addr[17:10]==8'b00000100 ||
                    cfg_addr[17:16]==2'b01 || cfg_addr[17:12]==6'b100000))begin
                    check(!line_activity && cycle-last_wire_end>200,
                          "ordinary configuration only on four quiet lines");
                    check(pending_tx==0 && !outstanding,"ordinary configuration after transmit drain");
                end
                if(cfg_addr[17:10]==8'b00000100 || cfg_addr[17:16]==2'b01 || cfg_addr[17:12]==6'b100000)begin
                    check(!bus_pending,"one pending table write");
                    bus_pending=1;bus_accept=cycle;bus_address=cfg_addr;bus_data=cfg_wdata;bus_rewrite=cfg_rewrite;
                    ready_check=1;ready_expected=0;
                end else begin
                    $fwrite(sys_fd,"W %0d %0d %05x %08x %0d %0d\n",cycle,ES,cfg_addr,cfg_wdata,cycle,cfg_rewrite);
                    ready_check=1;ready_expected=1;
                    if(cfg_addr==18'h00002)begin
                        user_shadow=cfg_wdata[15:0];
                        if(CAPTURE_CORE)$fwrite(tf,"U %0d %04x\n",cycle+1,cfg_wdata[15:0]);
                    end
                end
            end

            // R119 起点：消息首字节第一次出现 valid 的拍；反压连拍只用于报告。
            if(dut.core_valid && !m_seen)begin message_start=DIRECT_CORE?cycle:dut.current_source_first;stall_run=0;stall_max=0;end
            if(dut.core_valid && !dut.core_ready)begin
                stall_run=stall_run+1;if(stall_run>stall_max)stall_max=stall_run;
            end else stall_run=0;
            m_seen=dut.core_valid;
            if(dut.core_valid && dut.core_ready)begin
                quiet_since=cycle;
                if(message_len==0)begin
                    message_vl=dut.core_vl;message_pen=m_port_en;message_sp=m_sport;message_dp=m_dport;
                end
                check(message_len<8192,"message capture capacity");
                if(message_len<8192)message_bytes[message_len]=dut.core_data;
                message_len=message_len+1;
                if(dut.core_last)begin
                    check(!outstanding && cycle>last_outcome,"one result before next message end");
                    if(CAPTURE_CORE)$fwrite(tf,"M %0d %0d %0d %0d %04x %04x ",cycle,message_vl,message_len,message_pen,message_sp[15:0],message_dp[15:0]);
                    for(k=0;k<message_len && k<8192;k=k+1)if(CAPTURE_CORE)$fwrite(tf,"%02x",message_bytes[k]);
                    if(CAPTURE_CORE)$fwrite(tf," %0d %0d\n",message_start,stall_max);
                    outcome_vl=message_vl;
                    message_len=0;outstanding=1;last_message=cycle;
                end
            end
            pulses=(ev_tx[0]?1:0)+(ev_tx[1]?1:0)+(ev_tx[2]?1:0)+(ev_tx[3]?1:0)+(ev_tx[4]?1:0);
            check(pulses<=1,"exclusive transmit outcome");
            if(pulses)begin
                check(outstanding && cycle>last_message && cycle-last_message<=96,"transmit outcome deadline");
                outstanding=0;last_outcome=cycle;
                if(ev_tx[0])pending_tx=pending_tx+(cfg_shadow[outcome_vl*8][1]?1:0)+(cfg_shadow[outcome_vl*8][2]?1:0);
            end
            if(outstanding)check(cycle-last_message<=96,"missing transmit outcome");
            if(ev_tx[5])pending_tx=pending_tx-1;
            if(ev_tx[6])pending_tx=pending_tx-1;
            check(pending_tx>=0,"transmit pulses correspond to accepted messages");
            check((ev_a[0]?1:0)+(ev_a[1]?1:0)+(ev_a[2]?1:0)+(ev_a[3]?1:0)<=1,"A category exclusivity");
            check((ev_b[0]?1:0)+(ev_b[1]?1:0)+(ev_b[2]?1:0)+(ev_b[3]?1:0)<=1,"B category exclusivity");
            check(!d_last || d_valid,"delivery last requires valid");
            if(delivery_active)check(d_valid,"delivery has no bubble");
            if(d_valid)begin
                quiet_since=cycle;
                if(!delivery_active)begin
                    delivery_active=1;delivery_start=cycle;delivery_len=0;
                    delivery_vl=d_vl;delivery_sp=d_sport;delivery_dp=d_dport;delivery_net=d_net;
                end
                check({d_vl,d_sport,d_dport,d_net}=={delivery_vl,delivery_sp,delivery_dp,delivery_net},"delivery metadata stable");
                check(delivery_len<4096,"delivery capture capacity");
                if(delivery_len<4096)delivered_bytes[delivery_len]=d_data;
                delivery_len=delivery_len+1;
                if(d_last)begin
                    $fwrite(rf,"D %0d %s %0d %04x %04x %0d ",delivery_start,delivery_net ? "B" : "A",delivery_vl,delivery_sp,delivery_dp,delivery_len);
                    for(k=0;k<delivery_len && k<4096;k=k+1)$fwrite(rf,"%02x",delivered_bytes[k]);
                    $fwrite(rf,"\n");
                    delivery_active=0;delivery_len=0;
                end
            end
            for(k=0;k<25;k=k+1)begin
                if(count_lag2[k])expected_count[k]=expected_count[k]+32'd1;
                count_lag2[k]=count_lag1[k];count_lag1[k]=0;
            end
            if(ev_tx[0])record_pulse(0,"accept");
            if(ev_tx[1])record_pulse(1,"drop_dis");
            if(ev_tx[2])record_pulse(2,"drop_full");
            if(ev_tx[3])record_pulse(3,"drop_long");
            if(ev_tx[4])record_pulse(4,"drop_nopage");
            if(ev_tx[5])record_pulse(5,"tx_a");
            if(ev_tx[6])record_pulse(6,"tx_b");
            if(ev_a[0])record_pulse(7,"a_good");
            if(ev_a[1])record_pulse(8,"a_fcs");
            if(ev_a[2])record_pulse(9,"a_len");
            if(ev_a[3])record_pulse(10,"a_hdr");
            if(ev_a[4])record_pulse(11,"a_unk");
            if(ev_a[5])record_pulse(12,"a_cfg");
            if(ev_a[6])record_pulse(13,"a_ic");
            if(ev_a[7])record_pulse(14,"a_ovf");
            if(ev_b[0])record_pulse(15,"b_good");
            if(ev_b[1])record_pulse(16,"b_fcs");
            if(ev_b[2])record_pulse(17,"b_len");
            if(ev_b[3])record_pulse(18,"b_hdr");
            if(ev_b[4])record_pulse(19,"b_unk");
            if(ev_b[5])record_pulse(20,"b_cfg");
            if(ev_b[6])record_pulse(21,"b_ic");
            if(ev_b[7])record_pulse(22,"b_ovf");
            if(ev_rm_drop)record_pulse(23,"rm_drop");
            if(ev_deliver)record_pulse(24,"deliver");
            if(ev_gdrop[0])record_pulse(25,"a_gdrop");
            if(ev_gdrop[1])record_pulse(26,"b_gdrop");
        end
        if(line_activity)quiet_since=cycle;
        if((previous_lines & ~{tv_a,tv_b,rv_a,rv_b,slow_tv_a,slow_tv_b,slow_rv_a,slow_rv_b})!=0)last_wire_end=cycle;
        previous_lines={tv_a,tv_b,rv_a,rv_b,slow_tv_a,slow_tv_b,slow_rv_a,slow_rv_b};
        was_reset=reset;was_ready=initialized;
        check(gm_ta_errors==0 && gm_tb_errors==0 && gm_ra_errors==0 && gm_rb_errors==0,"GMII monitors clean");
        check(mon_ta_errors==0 && mon_tb_errors==0 && mon_ra_errors==0 && mon_rb_errors==0,"line monitors clean");
    end

    task write_cfg;
        input [17:0] address;
        input [31:0] value;
        input rewrite;
        integer deadline;
        begin:write_operation
            deadline=cycle+100000;
            @(negedge clk);
            while(!cfg_ready || reset)begin
                if(cycle>deadline)begin check(0,"host write ready timeout");disable write_operation;end
                @(negedge clk);
            end
            cfg_addr=address;cfg_wdata=value;cfg_rewrite=rewrite;cfg_wr=1;
            @(posedge clk);#2;cfg_wr=0;
            while(!cfg_ready && !reset)begin
                @(posedge clk);#2;
                if(cycle>deadline)begin check(0,"host table completion timeout");disable write_operation;end
            end
        end
    endtask

    task read_cfg;
        input [17:0] address;
        begin
            @(negedge clk);cfg_addr=address;cfg_rd=1;
            @(posedge clk);#2;cfg_rd=0;
        end
    endtask

    task send_payload;
        input integer vl,n,pen,sp,dp,offset;
        integer j,deadline;
        reg accepted;
        begin:send_operation
            deadline=cycle+10000000;
            // 上一条结果与新消息首字节可同拍；先等结果，避免一字节消息的 M/E 歧义。
            while(DIRECT_CORE && outstanding)begin
                @(posedge clk);#2;
                if(cycle>deadline)begin check(0,"host prior outcome timeout");disable send_operation;end
            end
            for(j=0;j<n;j=j+1)begin
                @(negedge clk);
                m_valid=1;m_data=stimulus[offset+j];m_last=(j==n-1);m_vl=vl;
                m_port_en=pen;m_sport=sp;m_dport=dp;
                accepted=0;
                while(!accepted)begin
                    @(posedge clk);accepted=m_ready && !reset;#2;
                    if(cycle>deadline)begin
                        check(0,"host application timeout");m_valid=0;m_last=0;disable send_operation;
                    end
                end
            end
            m_valid=0;m_last=0;
        end
    endtask

    // 应用激励入口：按绝对拍注入，首字节 valid 在 due 拍为高；相同时刻按调用顺序串行排队。
    task send_at;
        input integer due,vl,n,offset;
        integer j,deadline;
        reg accepted;
        begin:send_at_operation
            deadline=cycle+10000000;
            while(DIRECT_CORE && outstanding)begin
                @(posedge clk);#2;
                if(cycle>deadline)begin check(0,"host prior outcome timeout");disable send_at_operation;end
            end
            while(cycle<due-1)begin
                @(posedge clk);#2;
                if(cycle>deadline)begin check(0,"host schedule timeout");disable send_at_operation;end
            end
            @(negedge clk);
            m_valid=1;m_vl=vl;m_port_en=0;m_sport=0;m_dport=0;
            m_data=stimulus[offset];m_last=(n==1);
            for(j=0;j<n;j=j+1)begin
                accepted=0;
                while(!accepted)begin
                    @(posedge clk);accepted=m_ready && !reset;#2;
                    if(cycle>deadline)begin check(0,"host application timeout");m_valid=0;m_last=0;disable send_at_operation;end
                end
                if(j<n-1)begin @(negedge clk);m_data=stimulus[offset+j+1];m_last=(j+2==n);end
            end
            m_valid=0;m_last=0;
        end
    endtask

    task stage;
        input [8*40-1:0] label;
        begin
            if(CAPTURE_CORE)$fwrite(tf,"P %0d %0s\n",cycle,label);
            if(CAPTURE_CORE)$fwrite(rf,"P %0d %0s\n",cycle,label);
        end
    endtask

    task counters;
        integer index;
        begin
            for(index=0;index<7;index=index+1)read_cfg(18'h00040+index);
            for(index=0;index<20;index=index+1)read_cfg(18'h00048+index);
            repeat(3)begin @(posedge clk);#2;end
        end
    endtask

    task wait_idle;
        integer deadline;
        begin:idle_operation
            deadline=cycle+50000000;
            while(outstanding || pending_tx!=0 || m_valid || (!DIRECT_CORE && !dut.input_empty) || tv_a || tv_b || slow_tv_a || slow_tv_b)begin
                @(posedge clk);#2;
                if(cycle>deadline)begin check(0,"endpoint drain timeout");disable idle_operation;end
            end
        end
    endtask

    task flush;
        begin $fflush(tf);$fflush(rf);$fflush(sys_fd);end
    endtask
endmodule
