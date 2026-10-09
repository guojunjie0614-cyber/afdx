`timescale 1ns/1ps
module mac_tx_suite #(parameter LOOP=0, TEST_NAME="tb_mac_tx");
    reg clk=0,reset=1;
    always #4 clk=~clk;
    reg [2:0] test_phase=0;
    wire byte_en;
    wire [31:0] now;
    wire [15:0] now_c;
    generate if(LOOP)begin:time_source
        afdx_timebase clock_unit(clk,reset,now,byte_en,now_c);
    end else begin:test_source
        always @(posedge clk)if(reset)test_phase<=0;else test_phase<=test_phase+1'b1;
        assign byte_en=(test_phase==7);
        assign now=0;assign now_c=0;
    end endgenerate
    reg s_valid=0,s_last=0,s_en_a=0,s_en_b=0;
    reg [7:0] s_data_a=0,s_data_b=0;
    wire s_ready,tx_sof,tx_eof,tx_underrun,va,vb;
    wire [7:0] da,db;
    afdx_mac_tx dut(clk,reset,byte_en,s_valid,s_ready,s_data_a,s_data_b,s_last,s_en_a,s_en_b,
                    tx_sof,tx_eof,tx_underrun,da,va,db,vb);
    wire ma,mb,fa,fb,ea,eb;
    wire [7:0] qa,qb;
    wire [1:0] erra,errb;
    wire [10:0] lena,lenb;
    generate if(LOOP)begin:receivers
        afdx_mac_rx rx_a(clk,reset,da,va,ma,qa,fa,ea,erra,lena);
        afdx_mac_rx rx_b(clk,reset,db,vb,mb,qb,fb,eb,errb,lenb);
    end else begin:no_receivers
        assign ma=0;assign mb=0;assign fa=0;assign fb=0;assign ea=0;assign eb=0;
        assign qa=0;assign qb=0;assign erra=0;assign errb=0;assign lena=0;assign lenb=0;
    end endgenerate
    wire [31:0] mon_errors_a,mon_errors_b,mon_frames_a,mon_frames_b;
    line_monitor #("A","dump_a.txt") monitor_a(clk,reset,da,va,mon_errors_a,mon_frames_a);
    line_monitor #("B","dump_b.txt") monitor_b(clk,reset,db,vb,mon_errors_b,mon_frames_b);

    reg [7:0] source_a[0:499999],source_b[0:499999],wire_a[0:599999],wire_b[0:599999];
    integer length[0:511],ena[0:511],enb[0:511],delay_cycles[0:511],under[0:511],cut[0:511];
    integer wire_length[0:511],source_base[0:511],wire_base[0:511];
    integer count,source_count,wire_count,fd,rc,i,j,base_s,base_w;
    integer checks=0,errors=0,cycle=0,frame=-1,start_cycle=0,last_eof=-1,last_start=-1,last_reset=0;
    integer offset,sof_count=0,eof_count=0,under_count=0,aborted=0,accepted,source_index;
    integer rx_case_a=0,rx_case_b=0,rx_index_a=0,rx_index_b=0,last_ma=-1,last_mb=-1;
    integer expected_a=0,expected_b=0,expected_eofs=0;
    integer request_phases=0;
    reg active=0,be_before,sr_before,prev_sof=0,prev_eof=0,prev_under=0;
    reg injection_seen,sof_seen,drop_wait,request_seen;
    reg [31:0] prior_now=0;
    task check;
        input ok;
        input [511:0] label;
        begin
            checks=checks+1;
            if(ok!==1'b1)begin errors=errors+1;
                if(errors<20)$display("[FAIL] %s cycle=%0d frame=%0d %s",TEST_NAME,cycle,frame,label);
            end
        end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;be_before=byte_en;sr_before=s_ready;
        #1;
        if(reset)begin
            check(da===0 && db===0 && va===0 && vb===0,"reset lines zero");
            check(!tx_sof && !tx_eof && !tx_underrun,"reset pulses zero");
            if(active)begin check(cut[frame]>0,"only requested reset aborts");aborted=aborted+1;end
            active=0;last_reset=cycle;last_eof=-1;prior_now=0;
        end else begin
            if(LOOP)begin
                check(now===prior_now+1'b1,"timebase increment");
                check(byte_en===(now[2:0]==7),"timebase byte enable");
                check(now_c===now[27:12],"coarse time");prior_now=now;
            end
            check(!(tx_sof && prev_sof) && !(tx_eof && prev_eof) && !(tx_underrun && prev_under),"pulses one cycle");
            if(sr_before && (frame<0 || under[frame]<0 || under_count==0))check(be_before,"normal ready only byte enable");
            if(tx_sof)begin
                check(!active,"no overlapping frames");frame=frame+1;sof_count=sof_count+1;
                check(frame<count,"no extra frame");check(be_before,"SOF on byte boundary");
                check(cycle-last_reset>=96,"reset to SOF at least 96 clocks");
                if(LOOP)check(now[2:0]==0,"SOF aligned to now");
                if(last_eof>=0)begin
                    check(cycle-last_eof>=96,"minimum IFG");
                    if(delay_cycles[frame]==0 && under[frame-1]<0)begin
                        check(cycle-last_eof==96,"queued exact IFG");
                        if(length[frame-1]==60)check(cycle-last_start==672,"minimum frame start spacing");
                    end
                end
                active=1;start_cycle=cycle;last_start=cycle;under_count=0;
            end
            if(tx_underrun)begin check(active && under[frame]>=0,"expected underrun");under_count=under_count+1;end
            if(tx_eof)begin
                check(active,"EOF for active frame");check(cycle-start_cycle==wire_length[frame]*8,"wire frame duration");
                check(under_count==(under[frame]>=0 ? 1:0),"one underrun or none");
                active=0;last_eof=cycle;eof_count=eof_count+1;
            end
            if(active)begin
                offset=(cycle-start_cycle)/8;
                check(offset<wire_length[frame],"no extra wire byte");
                check(va===ena[frame][0] && vb===enb[frame][0],"network enable sampled per frame");
                check(da===(ena[frame] ? wire_a[wire_base[frame]+offset] : 8'b0),"A wire byte");
                check(db===(enb[frame] ? wire_b[wire_base[frame]+offset] : 8'b0),"B wire byte");
                if(ena[frame] && enb[frame])check(va===vb,"dual network synchronization");
            end else check(va===0 && vb===0 && da===0 && db===0,"idle output zero");
            if(LOOP)begin
                while(rx_case_a<count && !ena[rx_case_a])rx_case_a=rx_case_a+1;
                while(rx_case_b<count && !enb[rx_case_b])rx_case_b=rx_case_b+1;
                if(ma)begin
                    check(rx_case_a<count,"A receive enabled only");
                    check(qa===source_a[source_base[rx_case_a]+rx_index_a],"A receive data");
                    check(fa===(rx_index_a==0),"A receive first");rx_index_a=rx_index_a+1;last_ma=cycle;
                end
                if(mb)begin
                    check(rx_case_b<count,"B receive enabled only");
                    check(qb===source_b[source_base[rx_case_b]+rx_index_b],"B receive data");
                    check(fb===(rx_index_b==0),"B receive first");rx_index_b=rx_index_b+1;last_mb=cycle;
                end
                if(ea)begin
                    check(rx_case_a<count && erra===0 && lena===length[rx_case_a]+4,"A frame status");
                    check(rx_index_a==length[rx_case_a] && cycle>last_ma,"A frame complete");rx_case_a=rx_case_a+1;rx_index_a=0;
                end
                if(eb)begin
                    check(rx_case_b<count && errb===0 && lenb===length[rx_case_b]+4,"B frame status");
                    check(rx_index_b==length[rx_case_b] && cycle>last_mb,"B frame complete");rx_case_b=rx_case_b+1;rx_index_b=0;
                end
            end
        end
        prev_sof=tx_sof;prev_eof=tx_eof;prev_under=tx_underrun;
        if(cycle>5000000)begin $display("[RESULT] %s FAIL checks=%0d errors=%0d TIMEOUT",TEST_NAME,checks,errors+1);$finish;end
    end
    initial begin
        fd=$fopen("vectors/tx.meta","r");if(!fd)begin $display("[RESULT] %s FAIL checks=0 errors=1",TEST_NAME);$finish;end
        rc=$fscanf(fd,"%d %d %d\n",count,source_count,wire_count);base_s=0;base_w=0;
        for(i=0;i<count;i=i+1)begin
            rc=$fscanf(fd,"%d %d %d %d %d %d %d\n",length[i],ena[i],enb[i],delay_cycles[i],under[i],cut[i],wire_length[i]);
            source_base[i]=base_s;wire_base[i]=base_w;base_s=base_s+length[i];base_w=base_w+wire_length[i];
            if(cut[i]==0)begin expected_eofs=expected_eofs+1;expected_a=expected_a+ena[i];expected_b=expected_b+enb[i];end
        end
        $fclose(fd);
        $readmemh("vectors/src_a.hex",source_a,0,source_count-1);$readmemh("vectors/src_b.hex",source_b,0,source_count-1);
        $readmemh("vectors/wire_a.hex",wire_a,0,wire_count-1);$readmemh("vectors/wire_b.hex",wire_b,0,wire_count-1);
        repeat(4)@(negedge clk);reset=0;
        for(i=0;i<count;i=i+1)begin
            repeat(delay_cycles[i])@(negedge clk);
            source_index=0;injection_seen=0;sof_seen=0;drop_wait=0;request_seen=0;
            while(source_index<length[i])begin
                @(negedge clk);
                s_en_a=ena[i];s_en_b=enb[i];
                s_data_a=source_a[source_base[i]+source_index];s_data_b=source_b[source_base[i]+source_index];
                s_last=(source_index==length[i]-1);
                drop_wait=(under[i]==source_index && !injection_seen && (source_index!=0 || sof_seen));
                s_valid=!drop_wait;
                if(s_valid && !request_seen)begin
                    request_phases=request_phases | (1 << (LOOP ? now[2:0]:test_phase));request_seen=1;
                end
                @(posedge clk);accepted=s_valid && s_ready;
                #2;
                if(accepted)source_index=source_index+1;
                if(tx_sof)sof_seen=1;
                if(tx_underrun)injection_seen=1;
                if(cut[i]>0 && sof_seen && cycle-start_cycle>=cut[i])begin
                    @(negedge clk);reset=1;s_valid=0;
                    repeat(3)@(negedge clk);reset=0;source_index=length[i];
                end
            end
            @(negedge clk);s_valid=0;s_last=0;
        end
        repeat(300)@(negedge clk);
        check(sof_count==count && eof_count==expected_eofs,"all frame events");
        check(aborted==(LOOP ? 0:1),"reset abort counted");
        check(mon_frames_a==expected_a && mon_frames_b==expected_b,"monitor frame totals");
        check(mon_errors_a==0 && mon_errors_b==0,"monitor stability and IFG");
        check(request_phases==255,"upstream requests cover all eight phases");
        if(LOOP)check(rx_case_a==count && rx_case_b==count && rx_index_a==0 && rx_index_b==0,"all enabled frames delivered");
        $display("[COVERAGE] %s cases=%0d A=%0d B=%0d eof=%0d aborted=%0d phases=%h cycles=%0d",TEST_NAME,count,mon_frames_a,mon_frames_b,eof_count,aborted,request_phases,cycle);
        $display("[RESULT] %s %s checks=%0d errors=%0d",TEST_NAME,errors==0 ? "PASS":"FAIL",checks,errors);$finish;
    end
endmodule
