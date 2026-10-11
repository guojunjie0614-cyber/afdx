// 本模块读取配置和消息指令，驱动发送核心并记录两网输出。
// 它检查握手和事件，参考检查器另行核对帧内容和发送时间。
// 本文件不是单独测试，外层必须把这里的错误计入最终结果。
`timescale 1ns/1ps
// events 文件记录实际发生的握手和事件脉冲。
module tx_core_suite #(parameter NAME="tb_tx_basic",TX_PAGE_AW=8,TX_OFF_AW=9,LOOKAHEAD=512);
    reg clk=0;always #4 clk=~clk;
    reg reset=1;reg [31:0] now=0;
    wire byte_en=1'b1;
    reg m_valid=0,m_last=0,m_port_en=0,cfg_we=0;
    reg [7:0] m_data=0;reg [6:0] m_vl=0;reg [15:0] m_sport=0,m_dport=0,user_id=16'h1234;
    reg [9:0] cfg_addr=0;reg [31:0] cfg_wdata=0;
    wire m_ready,init_done,tx_valid_a,tx_valid_b,ev_accept,ev_drop_dis,ev_drop_full,ev_drop_long,ev_drop_nopage,ev_tx_a,ev_tx_b;
    wire [7:0] tx_data_a,tx_data_b;
    wire cfg_ok;
`ifdef CORE_NETLIST
    afdx_tx_core dut(
`else
    afdx_tx_core #(.TX_PAGE_AW(TX_PAGE_AW),.TX_OFF_AW(TX_OFF_AW),.LOOKAHEAD(LOOKAHEAD)) dut(
`endif
        clk,reset,now,byte_en,m_valid,m_ready,m_data,m_last,m_vl,m_port_en,m_sport,m_dport,
        cfg_we,cfg_addr,cfg_wdata,user_id,tx_data_a,tx_valid_a,tx_data_b,tx_valid_b,init_done,
        ev_accept,ev_drop_dis,ev_drop_full,ev_drop_long,ev_drop_nopage,ev_tx_a,ev_tx_b,cfg_ok);
    wire [31:0] err_a,err_b,frames_a,frames_b;
    line_monitor #(.NET("A"),.FILE_NAME("dump_a.txt")) mon_a(clk,reset,tx_data_a,tx_valid_a,err_a,frames_a);
    line_monitor #(.NET("B"),.FILE_NAME("dump_b.txt")) mon_b(clk,reset,tx_data_b,tx_valid_b,err_b,frames_b);
    reg [7:0] stimulus[0:3999999];
    reg [7:0] message_bytes[0:4095];
    reg [31:0] cfg_shadow[0:1023];
    integer cycle=0,checks=0,errors=0,ef,fd,rc,i,j,k,low_run=0,release_cycle=0;
    integer message_len=0,message_vl=0,message_port=0,message_sport=0,message_dport=0;
    integer messages=0,outcomes=0,outstanding=0,last_message=0,last_outcome=-1;
    integer want_a=0,want_b=0,got_a=0,got_b=0,last_start=-20001,anchor=-1;
    integer op_vl,op_n,op_pen,op_sp,op_dp,op_pause,op_mutate,op_cut,op_offset,wait_count,limit;
    integer pulses,old_errors,accepts=0,discards=0;
    reg [31:0] arg_hex,arg_data;
    reg [8*32-1:0] command,stage;
    reg previous_reset=0,previous_line=0,record_now=0;
    task check;
        input condition;input [8*100-1:0] label;
        begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;if(errors<30)$display("[FAIL] cycle=%0d %0s",cycle,label);end end
    endtask
    always @(posedge clk) begin
        cycle=cycle+1;
        if (!reset) now<=now+1'b1;
        if (reset && !previous_reset) begin
            $fwrite(ef,"Z %0d\n",cycle);outstanding=0;message_len=0;want_a=got_a;want_b=got_b;anchor=-1;
            for(k=0;k<1024;k=k+1)cfg_shadow[k]=0;
        end
        record_now=!reset && previous_reset;
        if (record_now) begin $fwrite(ef,"R %0d\n",cycle);release_cycle=cycle;end
        previous_reset=reset;
        if (!reset && cfg_we && init_done) begin
            check(cfg_ok,"configuration write accepted by engine");
            $fwrite(ef,"C %0d tx %0x %0x\n",cycle,cfg_addr,cfg_wdata);cfg_shadow[cfg_addr]=cfg_wdata;
        end
        if (!reset && m_valid && m_ready) begin
            if(message_len==0)begin message_vl=m_vl;message_port=m_port_en;message_sport=m_sport;message_dport=m_dport;end
            message_bytes[message_len]=m_data;message_len=message_len+1;
            if(m_last)begin
                check(outstanding==0,"one outcome before next message end");check(cycle>last_outcome,"outcome strictly before next end");
                $fwrite(ef,"M %0d %0d %0d %0d %04x %04x ",cycle,message_vl,message_len,message_port,message_sport[15:0],message_dport[15:0]);
                for(k=0;k<message_len;k=k+1)$fwrite(ef,"%02x",message_bytes[k]);$fwrite(ef,"\n");
                message_len=0;messages=messages+1;last_message=cycle;outstanding=1;
            end
        end
        #1;
        if(record_now)$fwrite(ef,"N %0d %08x\n",cycle,now);
        if(reset || !init_done)begin
            check(!m_ready && !tx_valid_a && !tx_valid_b && tx_data_a==0 && tx_data_b==0,"initialization keeps interfaces idle");low_run=0;
            if(!reset)check(cycle-release_cycle<2048,"initialization deadline");
        end else begin
            if(m_ready)low_run=0;else low_run=low_run+1;
            check(low_run<=96,"ready low run <=96");
        end
        pulses=(ev_accept?1:0)+(ev_drop_dis?1:0)+(ev_drop_full?1:0)+(ev_drop_long?1:0)+(ev_drop_nopage?1:0);
        check(pulses<=1,"exclusive outcome pulses");
        if(pulses!=0)begin
            check(outstanding==1 && cycle>last_message && cycle-last_message<=96,"outcome bound and order");
            outstanding=0;outcomes=outcomes+1;last_outcome=cycle;
            if(ev_accept)begin
                $fwrite(ef,"E %0d accept\n",cycle);accepts=accepts+1;
                if(cfg_shadow[message_vl*8][1])want_a=want_a+1;
                if(cfg_shadow[message_vl*8][2])want_b=want_b+1;
            end else begin
                discards=discards+1;
                if(ev_drop_dis)$fwrite(ef,"E %0d drop_dis\n",cycle);
                if(ev_drop_full)$fwrite(ef,"E %0d drop_full\n",cycle);
                if(ev_drop_long)$fwrite(ef,"E %0d drop_long\n",cycle);
                if(ev_drop_nopage)$fwrite(ef,"E %0d drop_nopage\n",cycle);
            end
        end
        if(outstanding)check(cycle-last_message<=96,"missing outcome deadline");
        if(ev_tx_a)begin $fwrite(ef,"E %0d tx_a\n",cycle);got_a=got_a+1;end
        if(ev_tx_b)begin $fwrite(ef,"E %0d tx_b\n",cycle);got_b=got_b+1;end
        if((tx_valid_a || tx_valid_b) && !previous_line)begin last_start=cycle;if(anchor<0)anchor=cycle;end
        previous_line=tx_valid_a || tx_valid_b;
        if(cycle>100000000 || errors>100)begin $display("[RESULT] %0s FAIL checks=%0d errors=%0d",NAME,checks,errors+1);$finish;end
    end
    task tick;begin @(posedge clk);#2;end endtask
    task drain;
        begin
            limit=cycle+50000000;
            while(outstanding || got_a!=want_a || got_b!=want_b || tx_valid_a || tx_valid_b || !m_ready)begin
                tick;if(cycle>limit)begin check(0,"drain timeout");$display("[RESULT] %0s FAIL checks=%0d errors=%0d",NAME,checks,errors);$finish;end
            end
            repeat(20)tick;
        end
    endtask
    task send_message;
        begin
            for(i=0;i<op_n && (op_cut==0 || i<op_cut);i=i+1)begin
                if(i>0 && op_pause>0)begin
                    @(negedge clk);m_valid=0;
                    repeat((stimulus[op_offset+i] % (op_pause+1)))tick;
                end
                @(negedge clk);m_valid=1;m_data=stimulus[op_offset+i];m_last=i==op_n-1;
                if(i==0 || op_mutate==0)begin m_vl=op_vl;m_port_en=op_pen;m_sport=op_sp;m_dport=op_dp;end
                else begin m_vl=(op_vl+i+19)%128;m_port_en=!op_pen;m_sport=op_sp^i;m_dport=op_dp+i;end
                @(posedge clk);while(!m_ready)@(posedge clk);#2;
            end
            // 当前握手后的 #2 撤去 valid；下条消息在紧接着的负沿给出，无额外空拍。
            m_valid=0;m_last=0;
        end
    endtask
    initial begin
        ef=$fopen("events.txt","w");fd=$fopen("vectors/tx_core.txt","r");
        if(!ef || !fd)begin $display("[RESULT] %0s FAIL checks=0 errors=1",NAME);$finish;end
        j=$fopen("vectors/tx_payload.count","r");rc=$fscanf(j,"%d",wait_count);$fclose(j);
        $readmemh("vectors/tx_payload.hex",stimulus,0,wait_count-1);
        $fwrite(ef,"G 0 TX_PAGE_AW %0d\nG 0 TX_OFF_AW %0d\nG 0 LOOKAHEAD %0d\nN 0 00000000\nU 0 %04x\n",TX_PAGE_AW,TX_OFF_AW,LOOKAHEAD,user_id);
        repeat(4)tick;@(negedge clk);reset=0;
        while(!init_done)tick;
        while(!$feof(fd))begin
            command=0;rc=$fscanf(fd,"%s",command);
            case(command)
                "P":begin rc=$fscanf(fd,"%s",stage);drain;anchor=-1;$fwrite(ef,"P %0d %0s\n",cycle,stage);$display("[STAGE] %0s cycle=%0d",stage,cycle);end
                "C":begin rc=$fscanf(fd,"%h %h",arg_hex,arg_data);@(negedge clk);cfg_we=1;cfg_addr=arg_hex;cfg_wdata=arg_data;tick;@(negedge clk);cfg_we=0;repeat(2)tick;end
                "U":begin rc=$fscanf(fd,"%h",arg_hex);drain;@(negedge clk);user_id=arg_hex;$fwrite(ef,"U %0d %04x\n",cycle+1,user_id);end
                "M":begin rc=$fscanf(fd,"%d %d %d %h %h %d %d %d %d",op_vl,op_n,op_pen,op_sp,op_dp,op_pause,op_mutate,op_cut,op_offset);send_message;end
                "W":begin rc=$fscanf(fd,"%d",wait_count);repeat(wait_count)tick;end
                "D":drain;
                "S":begin while(anchor<0)tick;end
                "B":begin
                    rc=$fscanf(fd,"%d %d",op_n,op_cut);
                    check(tx_valid_a || tx_valid_b,"reset prerequisite: frame is on wire");
                    check(want_a-got_a>=op_n,"reset prerequisite: active plus queued frames");
                    if(op_cut!=0)check(message_len>0,"reset prerequisite: partial input message");
                end
                "T":begin rc=$fscanf(fd,"%d",wait_count);while(cycle<anchor+wait_count-1)tick;end
                "J":begin rc=$fscanf(fd,"%h",arg_hex);drain;@(negedge clk);now=now+arg_hex;$fwrite(ef,"N %0d %08x\n",cycle,now);end
                "Z":begin
                    rc=$fscanf(fd,"%h",arg_hex);@(negedge clk);reset=1;m_valid=0;cfg_we=0;now=arg_hex;
                    $fwrite(ef,"N %0d %08x\n",cycle+1,now);repeat(4)tick;@(negedge clk);reset=0;
                    while(!init_done)tick;
                end
                default: if(command!=0)begin check(0,"unknown stimulus command");$finish;end
            endcase
        end
        drain;repeat(20001)tick;
        check(!tx_valid_a && !tx_valid_b && cycle-last_start>=20000,"final quiet window");
        check(err_a==0 && err_b==0,"line monitor errors");check(outstanding==0,"final outcome complete");
        $fflush(ef);$fclose(ef);$fclose(fd);
        $display("[COVERAGE] cycles=%0d messages=%0d outcomes=%0d accept=%0d drop=%0d frames_a=%0d frames_b=%0d",cycle,messages,outcomes,accepts,discards,frames_a,frames_b);
        $display("[RESULT] %0s %0s checks=%0d errors=%0d",NAME,errors==0 ? "PASS" : "FAIL",checks,errors);$finish;
    end
endmodule
