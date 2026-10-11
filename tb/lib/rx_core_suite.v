// 接收核心共用主体：按绝对周期播放双网向量，记录完整 D 行和分类事件；Verilog 与独立参考器共同判定。
// 对应外层用例的赛题功能；本文件不构成独立验收入口，错误必须由调用者汇总。
`timescale 1ns/1ps
// 绝对周期激励，两网独立播放；只观察外壳端口，D 行在整条交付完成后写出。
module rx_core_suite #(parameter NAME="tb_rx_basic",RX_RING_AW=12,RX_DQ_AW=5);
    reg clk=0;always #4 clk=~clk;
    reg reset=1;reg [15:0] now_c=0;
    reg [7:0] rx_data_a=0,rx_data_b=0;reg rx_valid_a=0,rx_valid_b=0;
    reg cfg_map_we=0,cfg_cfg_we=0;reg [15:0] cfg_addr=0;reg [31:0] cfg_wdata=0;
    wire d_valid,d_last,d_net,init_done,ev_rm_drop,ev_deliver;wire [7:0] d_data,ev_a,ev_b;
    wire [11:0] d_vl;wire [15:0] d_sport,d_dport;
    wire cfg_ok;
`ifdef RX_CORE_NETLIST
    afdx_rx_core dut(
`else
    afdx_rx_core #(.RX_RING_AW(RX_RING_AW),.RX_DQ_AW(RX_DQ_AW)) dut(
`endif
        clk,reset,now_c,rx_data_a,rx_valid_a,rx_data_b,rx_valid_b,cfg_map_we,cfg_cfg_we,cfg_addr,cfg_wdata,
        d_valid,d_data,d_last,d_vl,d_sport,d_dport,d_net,init_done,ev_a,ev_b,ev_rm_drop,ev_deliver,cfg_ok);
    wire [31:0] errors_a,errors_b,frames_a,frames_b;
    line_monitor #(.NET("A"),.FILE_NAME("dump_a.txt"),.MIN_GAP(8)) mon_a(clk,reset,rx_data_a,rx_valid_a,errors_a,frames_a);
    line_monitor #(.NET("B"),.FILE_NAME("dump_b.txt"),.MIN_GAP(8)) mon_b(clk,reset,rx_data_b,rx_valid_b,errors_b,frames_b);
    reg [7:0] wire_bytes[0:3999999],delivered[0:4095];
    integer starts_a[0:24999],starts_b[0:24999],offsets_a[0:24999],offsets_b[0:24999],lengths_a[0:24999],lengths_b[0:24999];
    integer count_a,count_b,ia=0,ib=0,cycle=0,checks=0,errors=0,ef,cf,fd,rc,j,k,total_bytes,end_cycle;
    integer next_cycle,command_cycle,release_cycle=5,reset_release=5,base_cycle=5,base_now=0,step=4096;
    integer arg_step,quiet_since=0,last_wire_end=-100000,deliver_start,deliver_len=0,deliver_count=0;
    reg [31:0] arg_addr,arg_value;reg [8*32-1:0] command,word;
    reg was_reset=0,was_init=0,was_line=0,delivery_active=0,meta_net;
    reg [11:0] meta_vl;reg [15:0] meta_sport,meta_dport;
    task check;
        input condition;input [8*100-1:0] label;
        begin checks=checks+1;if(condition!==1'b1)begin errors=errors+1;if(errors<30)$display("[FAIL] cycle=%0d %0s",cycle,label);end end
    endtask
    task read_command;
        begin
            command=0;command_cycle=200000000;
            if(!$feof(cf))begin
                rc=$fscanf(cf,"%s %d",command,command_cycle);
                case(command)
                    "P":rc=$fscanf(cf,"%s",word);
                    "C":rc=$fscanf(cf,"%s %h %h",word,arg_addr,arg_value);
                    "Z":rc=$fscanf(cf,"%h %d",arg_value,arg_step);
                    "K":rc=$fscanf(cf,"%d",arg_step);
                    "B":rc=$fscanf(cf,"%d",arg_step);
                    default:;
                endcase
            end
        end
    endtask
    task pulse;
        input [8*16-1:0] name;
        begin $fwrite(ef,"E %0d %0s\n",cycle,name);quiet_since=cycle;end
    endtask
    always @(negedge clk)begin
        next_cycle=cycle+1;cfg_map_we=0;cfg_cfg_we=0;
        if(next_cycle==reset_release)begin reset=0;base_cycle=next_cycle;end
        now_c=base_now+(next_cycle-base_cycle)/step;
        while(command_cycle==next_cycle)begin
            case(command)
                "P":begin $fwrite(ef,"P %0d %0s\n",next_cycle,word);$display("[STAGE] %0s cycle=%0d",word,next_cycle);end
                "C":begin
                    check(!rx_valid_a && !rx_valid_b && next_cycle-last_wire_end>200,"configuration quiescence");
                    cfg_map_we=word=="map";cfg_cfg_we=word=="cfg";cfg_addr=arg_addr;cfg_wdata=arg_value;
                    check(init_done,"configuration only after initialization");
                    check(cfg_ok,"configuration write accepted by engine");
                    $fwrite(ef,"C %0d %0s %0x %0x\n",next_cycle,word,cfg_addr,cfg_wdata);
                end
                "Z":begin
                    reset=1;reset_release=next_cycle+4;base_now=arg_value;base_cycle=reset_release;step=arg_step;now_c=base_now;
                    if(ia<count_a && starts_a[ia]<next_cycle && starts_a[ia]+lengths_a[ia]>next_cycle)ia=ia+1;
                    if(ib<count_b && starts_b[ib]<next_cycle && starts_b[ib]+lengths_b[ib]>next_cycle)ib=ib+1;
                end
                "K":begin base_now=now_c;base_cycle=next_cycle;step=arg_step;$fwrite(ef,"K %0d %04x %0d\n",next_cycle,now_c,step);end
                "B":begin check(d_valid && delivery_active,"reset while delivery active");check(rx_valid_b,"reset while B frame active");end
                default:;
            endcase
            read_command;
        end
        rx_valid_a=0;rx_valid_b=0;rx_data_a=(cycle*17)&255;rx_data_b=(cycle*29)&255;
        while(ia<count_a && next_cycle>=starts_a[ia]+lengths_a[ia])ia=ia+1;
        while(ib<count_b && next_cycle>=starts_b[ib]+lengths_b[ib])ib=ib+1;
        if(!reset)begin
            if(ia<count_a && next_cycle>=starts_a[ia])begin rx_valid_a=1;rx_data_a=wire_bytes[offsets_a[ia]+(next_cycle-starts_a[ia])];end
            if(ib<count_b && next_cycle>=starts_b[ib])begin rx_valid_b=1;rx_data_b=wire_bytes[offsets_b[ib]+(next_cycle-starts_b[ib])];end
        end
    end
    always @(posedge clk)begin
        cycle=cycle+1;
        if(reset && !was_reset)$fwrite(ef,"Z %0d\n",cycle);
        if(!reset && was_reset)begin $fwrite(ef,"R %0d\nK %0d %04x %0d\n",cycle,cycle,now_c,step);release_cycle=cycle;end
        was_reset=reset;
        #1;
        if(init_done && !was_init)$fwrite(ef,"I %0d\n",cycle);
        was_init=init_done;
        if(reset || !init_done)begin
            check(!d_valid && ev_a==0 && ev_b==0 && !ev_rm_drop && !ev_deliver,"initialization output suppression");
            if(!reset)check(cycle-release_cycle<65600,"initialization deadline");
        end
        check((ev_a[0]?1:0)+(ev_a[1]?1:0)+(ev_a[2]?1:0)+(ev_a[3]?1:0)<=1,"A class exclusivity");
        check((ev_b[0]?1:0)+(ev_b[1]?1:0)+(ev_b[2]?1:0)+(ev_b[3]?1:0)<=1,"B class exclusivity");
        check(!d_last || d_valid,"last requires valid");
        if(reset)begin delivery_active=0;deliver_len=0;end
        else begin
            if(delivery_active)check(d_valid,"delivery continuous");
            if(d_valid)begin
                quiet_since=cycle;
                if(!delivery_active)begin delivery_active=1;deliver_start=cycle;deliver_len=0;meta_vl=d_vl;meta_sport=d_sport;meta_dport=d_dport;meta_net=d_net;end
                check({d_vl,d_sport,d_dport,d_net}=={meta_vl,meta_sport,meta_dport,meta_net},"delivery metadata stable");
                delivered[deliver_len]=d_data;deliver_len=deliver_len+1;
                if(d_last)begin
                    $fwrite(ef,"D %0d %s %0d %04x %04x %0d ",deliver_start,meta_net ? "B" : "A",meta_vl,meta_sport,meta_dport,deliver_len);
                    for(k=0;k<deliver_len;k=k+1)$fwrite(ef,"%02x",delivered[k]);$fwrite(ef,"\n");delivery_active=0;deliver_count=deliver_count+1;
                end
            end
        end
        if(ev_a[0])pulse("a_good");if(ev_a[1])pulse("a_fcs");if(ev_a[2])pulse("a_len");if(ev_a[3])pulse("a_hdr");
        if(ev_a[4])pulse("a_unk");if(ev_a[5])pulse("a_cfg");if(ev_a[6])pulse("a_ic");if(ev_a[7])pulse("a_ovf");
        if(ev_b[0])pulse("b_good");if(ev_b[1])pulse("b_fcs");if(ev_b[2])pulse("b_len");if(ev_b[3])pulse("b_hdr");
        if(ev_b[4])pulse("b_unk");if(ev_b[5])pulse("b_cfg");if(ev_b[6])pulse("b_ic");if(ev_b[7])pulse("b_ovf");
        if(ev_rm_drop)pulse("rm_drop");if(ev_deliver)pulse("deliver");
        if(rx_valid_a || rx_valid_b)quiet_since=cycle;
        if(was_line && !rx_valid_a && !rx_valid_b)last_wire_end=cycle;
        was_line=rx_valid_a || rx_valid_b;
        if(errors>100 || cycle>=end_cycle)begin
            check(cycle-quiet_since>=2000 && !delivery_active,"final quiet 2000 cycles");
            check(errors_a==0 && errors_b==0,"line monitor errors");
            $fflush(ef);$fclose(ef);
            $display("[COVERAGE] cycles=%0d segments_a=%0d segments_b=%0d deliveries=%0d",cycle,frames_a,frames_b,deliver_count);
            $display("[RESULT] %0s %0s checks=%0d errors=%0d",NAME,errors==0 ? "PASS" : "FAIL",checks,errors);$finish;
        end
    end
    initial begin
        ef=$fopen("events.txt","w");cf=$fopen("vectors/rx_control.txt","r");
        fd=$fopen("vectors/rx_core.meta","r");rc=$fscanf(fd,"%d %d %d %d",count_a,count_b,total_bytes,end_cycle);
        for(j=0;j<count_a;j=j+1)rc=$fscanf(fd,"%d %d %d",starts_a[j],offsets_a[j],lengths_a[j]);
        for(j=0;j<count_b;j=j+1)rc=$fscanf(fd,"%d %d %d",starts_b[j],offsets_b[j],lengths_b[j]);$fclose(fd);
        $readmemh("vectors/rx_wire.hex",wire_bytes,0,total_bytes-1);
        $fwrite(ef,"G 0 RX_RING_AW %0d\nG 0 RX_DQ_AW %0d\nK 0 0000 4096\n",RX_RING_AW,RX_DQ_AW);
        read_command;
    end
endmodule
