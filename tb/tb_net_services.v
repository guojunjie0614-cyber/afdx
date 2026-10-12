// 本测试通过两个完整端系统的公开端口检查赛题的五项功能。
// 它检查用户收发、网络管理（SNMP）、时钟同步（RTC），以及按 ARINC 615A 加载后再卸载文件。
// 全部检查完成后，只有最后的 [RESULT] 为 PASS 且 errors=0 才通过。
`timescale 1ns/1ps
// 本测试只通过线路、应用、配置和事件端口检查结果。
module tb_net_services;
    reg clk=0,reset=1;always #4 clk=~clk;
    wire [7:0] a12,b12,a21,b21;wire va12,vb12,va21,vb21,ready1,ready2;
    reg inject=0,inject_valid=0;reg [7:0] inject_data=0;
    wire [7:0] rx2a=inject ? inject_data:a12;wire rv2a=inject ? inject_valid:va12;
    wire [31:0] checks1,checks2,errors1,errors2;
    load_test_endpoint #(.ES(1)) es1(clk,reset,a21,va21,b21,vb21,a12,va12,b12,vb12,ready1,checks1,errors1);
    load_test_endpoint #(.ES(2),.ALLOW_A_IC(1)) es2(clk,reset,rx2a,rv2a,b12,vb12,a21,va21,b21,vb21,ready2,checks2,errors2);
    wire [31:0] ge1a,ge1b,ge2a,ge2b,gerx,gf1a,gf1b,gf2a,gf2b,gfrx;
    gmii_monitor #(.FILE_NAME("es1_a.txt")) m1a(clk,reset,a12,va12,ge1a,gf1a);
    gmii_monitor #(.FILE_NAME("es1_b.txt")) m1b(clk,reset,b12,vb12,ge1b,gf1b);
    gmii_monitor #(.FILE_NAME("es2_a.txt")) m2a(clk,reset,a21,va21,ge2a,gf2a);
    gmii_monitor #(.FILE_NAME("es2_b.txt")) m2b(clk,reset,b21,vb21,ge2b,gf2b);
    gmii_monitor #(.FILE_NAME("es2_rx_a.txt")) mrx(clk,reset,rx2a,rv2a,gerx,gfrx);
    reg [7:0] bytes[0:2047],p[0:1023];
    integer fd,cf,rc,cycle=0,checks=0,errors=0,phase=0,start_cycle;
    integer so,sl,lo,ll,ho,hl,doff,dl,fo,fl,i,j,slot,length,sp,dp,op,bn;
    integer lui_port=40000,lur_port=40001,lus_port=41000,lus_target,server_port=0,server_target;
    integer server_offset,server_size,done=0,seen_lus=0,rm1=0,rm2=0,ic2=0;
    reg [31:0] value,status_value,sec1,sec2,ns1,ns2;
    reg signed [63:0] difference;
    `include "download_test_tasks.vh"
    initial $readmemh("vectors/bytes.hex",bytes);
    task check;input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;$display("[NET_FAIL] phase=%0d cycle=%0d %0s",phase,cycle,why);end end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;
        if(!reset)begin
            if(es1.rm_drop)rm1=rm1+1;
            if(es2.rm_drop)rm2=rm2+1;
            if(es2.ev_a[6])ic2=ic2+1;
        end
        if(cycle%32768==0)begin $display("[PROGRESS] phase=%0d cycles=%0d time_ns=%0t",phase,cycle,$time);$fflush(fd);end
        if(cycle>1000000 || errors+errors1+errors2>10)begin
            #1;
            $display("[RESULT] tb_net_services FAIL checks=%0d errors=%0d",checks+checks1+checks2,errors+errors1+errors2+1);$finish;
        end
    end
    task receive;
        begin
            while(es1.head==es1.tail)@(negedge clk);
            slot=es1.head%64;length=es1.lengths[slot];sp=es1.sports[slot];dp=es1.dports[slot];
            for(j=0;j<length;j=j+1)p[j]=es1.queue[slot*1024+j];es1.head=es1.head+1;
            op={p[0],p[1]};bn={p[2],p[3]};
        end
    endtask
    task request;input integer opcode,source;input [7:0] suffix;
        begin
            es1.send_bytes[0]=0;es1.send_bytes[1]=opcode;
            es1.send_bytes[2]="D";es1.send_bytes[3]="E";es1.send_bytes[4]="M";es1.send_bytes[5]="C";es1.send_bytes[6]="3";
            es1.send_bytes[7]="_";es1.send_bytes[8]="1";es1.send_bytes[9]=".";es1.send_bytes[10]="L";es1.send_bytes[11]="U";
            es1.send_bytes[12]=suffix;es1.send_bytes[13]=0;
            es1.send_bytes[14]="o";es1.send_bytes[15]="c";es1.send_bytes[16]="t";es1.send_bytes[17]="e";es1.send_bytes[18]="t";es1.send_bytes[19]=0;
            es1.packet(20,source,59);
        end
    endtask
    task ack;input integer source,dest,block;
        begin es1.send_bytes[0]=0;es1.send_bytes[1]=4;es1.send_bytes[2]=block>>8;es1.send_bytes[3]=block;es1.packet(4,source,dest);end
    endtask
    task data;input integer offset,size,source,dest;
        integer k;
        begin
            es1.send_bytes[0]=0;es1.send_bytes[1]=3;es1.send_bytes[2]=0;es1.send_bytes[3]=1;
            for(k=0;k<size;k=k+1)es1.send_bytes[k+4]=bytes[offset+k];es1.packet(size+4,source,dest);
        end
    endtask
    task finish_phase;input [8*16-1:0] name;
        begin
            $fwrite(fd,"F %0s %0d %0d\n",name,start_cycle,cycle);$fflush(fd);
            $display("[FUNCTION] %0s complete cycles=%0d elapsed_cycles=%0d",name,cycle,cycle-start_cycle);
        end
    endtask
    initial begin
        fd=$fopen("net_services.txt","w");dl_result_fd=$fopen("download_results.txt","w");es1.log_fd=fd;es1.current_case=0;
        cf=$fopen("vectors/offsets.txt","r");rc=$fscanf(cf,"%d %d %d %d %d %d %d %d %d %d",so,sl,lo,ll,ho,hl,doff,dl,fo,fl);$fclose(cf);
        repeat(8)@(negedge clk);reset=0;wait(ready1&&ready2);es1.configure();es2.configure();
        phase=1;start_cycle=cycle;
        fork es1.user_message();es2.user_message();join
        wait(es1.received==1&&es2.received==1&&rm1==1&&rm2==1);
        check(es1.received==1&&es2.received==1,"user data exactly once in both directions");finish_phase("users");
        phase=2;start_cycle=cycle;
        check(!va12&&!vb12,"fault injection while source is idle");
        @(negedge clk);inject=1;
        for(i=0;i<fl;i=i+1)begin inject_valid=1;inject_data=bytes[fo+i];@(negedge clk);end
        inject_valid=0;@(negedge clk);inject=0;
        wait(ic2==1);repeat(64)@(negedge clk);
        check(es2.received==1&&ic2==1&&rm1==1&&rm2==1,"bad SN rejected after normal A/B redundancy removal");
        $fwrite(fd,"I %0d %0d %0d %0d\n",ic2,rm1,rm2,es2.received);finish_phase("integrity");
        phase=3;start_cycle=cycle;
        es2.write_cfg(18'h91,2);es2.write_cfg(18'h90,1);
        for(i=0;i<sl;i=i+1)es1.send_bytes[i]=bytes[so+i];es1.packet(sl,42000,161);
        receive();check(sp==161&&dp==42000&&p[0]==8'h30,"SNMP response arrives at manager application");finish_phase("snmp");
        phase=4;start_cycle=cycle;
        es1.write_cfg(18'h81,1000000);es2.write_cfg(18'h81,1000000);
        es1.write_cfg(18'h82,0);es2.write_cfg(18'h82,2);
        es1.write_cfg(18'h84,1007);es1.write_cfg(18'h85,0);es1.write_cfg(18'h80,4);
        es2.write_cfg(18'h84,1000);es2.write_cfg(18'h85,0);es2.write_cfg(18'h80,7);
        es1.write_cfg(18'h80,1);value=0;
        while(value==0)begin repeat(32)@(negedge clk);es1.read_cfg(18'h88,value);end
        check(value==1,"one SNTP synchronization completes");
        es1.write_cfg(18'h80,0);es2.write_cfg(18'h80,0);
        fork es1.read_cfg(18'h84,sec1);es2.read_cfg(18'h84,sec2);join
        fork es1.read_cfg(18'h85,ns1);es2.read_cfg(18'h85,ns2);join
        difference=({32'b0,sec1}*64'd1000000000+ns1)-({32'b0,sec2}*64'd1000000000+ns2);
        check(difference>=-40&&difference<=40,"idle SNTP clock difference <=40 ns");
        $fwrite(fd,"T %0d %0d\n",value,difference);finish_phase("rtc");
        phase=5;start_cycle=cycle;
        es2.write_cfg(18'hb1,2);es2.write_cfg(18'hb0,1);request(1,lui_port,"I");
        while(!done)begin
            receive();
            if(op==2)begin check(dp==59,"LUS request port");lus_target=sp;lus_port=lus_port+1;ack(lus_port,sp,0);end
            else if(op==3&&dp==lui_port)begin check(length==13&&{p[8],p[9]}==16'h4134&&p[11]==1,"A4 LUI accepted");ack(lui_port,sp,1);end
            else if(op==3&&dp==lus_port)begin
                check(sp==lus_target&&bn==1&&{p[8],p[9]}==16'h4134,"A4 LUS transfer");seen_lus=seen_lus+1;
                ack(lus_port,sp,1);
                if({p[10],p[11]}==1)request(2,lur_port,"R");
                else if({p[10],p[11]}==3)done=1;
                else check({p[10],p[11]}==2,"LUS accepted/in-progress/success only");
            end else if(op==4&&dp==lur_port)begin if(bn==0)data(lo,ll,lur_port,sp);else check(bn==1,"LUR ACK1");end
            else if(op==1)begin
                check(dp==59,"target RRQ port");server_target=sp;
                if(p[12]=="H")begin server_offset=ho;server_size=hl;server_port=43001;end
                else begin check(p[12]=="P","requested data filename");server_offset=doff;server_size=dl;server_port=43002;end
                data(server_offset,server_size,server_port,server_target);
            end else if(op==4&&dp==server_port)check(bn==1&&sp==server_target,"file final ACK1");
            else check(0,"unexpected 615A packet");
        end
        status_value=1;
        while(status_value==1)begin repeat(64)@(negedge clk);es2.read_cfg(18'hb2,status_value);end
        check(status_value==2&&seen_lus==4,"16-byte upload finishes with four status files");
        es2.read_cfg(18'hb3,value);check(value==dl,"loaded byte count");$fwrite(fd,"R ");
        for(i=0;i<dl;i=i+1)begin
            es2.write_cfg(18'hb4,i);repeat(4)@(negedge clk);es2.read_cfg(18'hb5,value);
            check(value==bytes[doff+i],"loaded RAM equals source file");$fwrite(fd,"%02x",value[7:0]);
        end
        $fwrite(fd,"\n");finish_phase("upload");
        phase=6;start_cycle=cycle;
        for(i=0;i<dl;i=i+1)dl_reference[i]=bytes[doff+i];
        run_download(0,dl,16'h4134,59,0,0);finish_phase("download");
        $fclose(dl_result_fd);
        check(es1.received==1&&es2.received==1&&ic2==1,"no extra application deliveries or integrity errors");
        check(ge1a+ge1b+ge2a+ge2b+gerx==0,"GMII frame continuity and gap checks");
        $fwrite(fd,"U %0d %0d\n",es1.received,es2.received);$fclose(fd);
        $display("[COVERAGE] cycles=%0d",cycle);
        // 最后一次配置读回检查也要计入结果。
        #1;
        $display("[RESULT] tb_net_services %0s checks=%0d errors=%0d",errors+errors1+errors2==0?"PASS":"FAIL",checks+checks1+checks2,errors+errors1+errors2);$finish;
    end
endmodule
