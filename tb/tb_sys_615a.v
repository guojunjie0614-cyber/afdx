// 验证双端完整 615A 加卸载流程、文件 CRC/元数据错误、TFTP 丢包重试和公开口 RAM 读回。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_sys_615a;
    reg clk=0,reset=1;always #4 clk=~clk;
    wire [7:0] a12,b12,a21,b21;wire va12,vb12,va21,vb21,ready1,ready2;
    wire [31:0] checks1,checks2,errors1,errors2;
    load_test_endpoint #(.ES(1)) es1(clk,reset,a21,va21,b21,vb21,a12,va12,b12,vb12,ready1,checks1,errors1);
    load_test_endpoint #(.ES(2)) es2(clk,reset,a12,va12,b12,vb12,a21,va21,b21,vb21,ready2,checks2,errors2);
    wire [31:0] gmerr1,gmerr2,gmframes1,gmframes2;
    gmii_monitor #(.FILE_NAME("loader_gmii.txt")) mon1(clk,reset,a12,va12,gmerr1,gmframes1);
    gmii_monitor #(.FILE_NAME("target_gmii.txt")) mon2(clk,reset,a21,va21,gmerr2,gmframes2);
    integer cycle=0,checks=0,errors=0,fd,cf,rc,id,lo,ll,ho,hl,doff,dl,i,j;
    integer request_port,timeout,slot,length,sp,dp,op,bn,lui_port,lur_port,lus_port,lus_target,server_port,server_target;
    integer server_offset,server_size,server_kind,done,dropped,seen_lus,wire_status,final_status,packet_count=0;
    integer protocol_version,lur_version,option_flags;
    reg [7:0] file_bytes[0:65535],p[0:1023];
    reg [31:0] value,status_value,loaded_value,retry_value;
    `include "download_test_tasks.vh"
    initial $readmemh("vectors/bytes.hex",file_bytes);
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>10000000 || errors+errors1+errors2>20)begin
            $display("[RESULT] tb_sys_615a FAIL checks=%0d errors=%0d",checks+checks1+checks2,errors+errors1+errors2+1);$finish;
        end
    end
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;$display("[615A_FAIL] case=%0d cycle=%0d %0s",id,cycle,why);end end
    endtask
    task request;
        input integer opcode,source;input [7:0] suffix;
        begin
            es1.send_bytes[0]=0;es1.send_bytes[1]=opcode;
            es1.send_bytes[2]="D";es1.send_bytes[3]="E";es1.send_bytes[4]="M";es1.send_bytes[5]="C";es1.send_bytes[6]="3";
            es1.send_bytes[7]="_";es1.send_bytes[8]="1";es1.send_bytes[9]=".";es1.send_bytes[10]="L";es1.send_bytes[11]="U";
            es1.send_bytes[12]=suffix;es1.send_bytes[13]=0;
            es1.send_bytes[14]="o";es1.send_bytes[15]="c";es1.send_bytes[16]="t";es1.send_bytes[17]="e";es1.send_bytes[18]="t";es1.send_bytes[19]=0;
            if(option_flags!=0)begin
                // RRQ 和 WRQ 都带 blksize=1024、port=5555；目标必须忽略并仍用512字节块和配置端口。
                es1.send_bytes[20]="b";es1.send_bytes[21]="l";es1.send_bytes[22]="k";es1.send_bytes[23]="s";
                es1.send_bytes[24]="i";es1.send_bytes[25]="z";es1.send_bytes[26]="e";es1.send_bytes[27]=0;
                es1.send_bytes[28]="1";es1.send_bytes[29]="0";es1.send_bytes[30]="2";es1.send_bytes[31]="4";es1.send_bytes[32]=0;
                es1.send_bytes[33]="p";es1.send_bytes[34]="o";es1.send_bytes[35]="r";es1.send_bytes[36]="t";es1.send_bytes[37]=0;
                es1.send_bytes[38]="5";es1.send_bytes[39]="5";es1.send_bytes[40]="5";es1.send_bytes[41]="5";es1.send_bytes[42]=0;
                es1.packet(43,source,request_port);
            end else es1.packet(20,source,request_port);
        end
    endtask
    task ack;
        input integer source,dest,block;
        begin es1.send_bytes[0]=0;es1.send_bytes[1]=4;es1.send_bytes[2]=block>>8;es1.send_bytes[3]=block;es1.packet(4,source,dest);end
    endtask
    task data_block;
        input integer offset,size,block,source,dest,kind;
        integer n,start,amount;
        begin
            start=(block-1)*512;amount=size-start;if(amount>512)amount=512;
            if(start<=size)begin
                if(kind==2 && block==2 && (id==4 || (id==2 && dropped==0)))begin dropped=dropped+1;$display("[615A_DROP] case=%0d block=%0d attempt=%0d",id,block,dropped);end
                else begin
                    es1.send_bytes[0]=0;es1.send_bytes[1]=3;es1.send_bytes[2]=block>>8;es1.send_bytes[3]=block;
                    for(n=0;n<amount;n=n+1)es1.send_bytes[n+4]=file_bytes[offset+start+n];
                    if(kind==2 && id==3 && block==2)es1.send_bytes[17]=es1.send_bytes[17]^8'h80;
                    es1.packet(amount+4,source,dest);
                end
            end
        end
    endtask
    initial begin
        fd=$fopen("load_results.txt","w");es1.log_fd=fd;dl_result_fd=$fopen("download_results.txt","w");unsupported_result_fd=$fopen("unsupported_results.txt","w");
        repeat(8)@(negedge clk);reset=0;wait(ready1 && ready2);es1.configure();es2.configure();
        es2.read_cfg(18'hb8,value);check(value==59,"615A default request port is 59");$fwrite(fd,"V port %0d\n",value);
        es2.read_cfg(18'hb9,value);check(value==250000000,"615A default timeout is 2 seconds at 125 MHz");$fwrite(fd,"V timeout %0d\n",value);
        es2.read_cfg(18'hba,value);check(value==1,"615A default retry number is 1");$fwrite(fd,"V retries %0d\n",value);
        es2.read_cfg(18'hbb,value);check(value==16'h4134,"protocol version defaults to A4");$fwrite(fd,"V version %0d\n",value);
        es2.write_cfg(18'hbb,16'h4135);es2.read_cfg(18'hbb,value);check(value==16'h4134,"unsupported configuration write ignored");
        es2.write_cfg(18'hb8,1059);es2.read_cfg(18'hb8,value);check(value==1059,"request port configurable");es2.write_cfg(18'hb8,59);
        es2.write_cfg(18'hb9,250000);es2.write_cfg(18'hba,2);
        es2.read_cfg(18'hb9,value);check(value==250000,"simulation timeout configured to 2 ms");
        es2.read_cfg(18'hba,value);check(value==2,"simulation retry number configured to 2");
        es2.write_cfg(18'hb1,2);es2.write_cfg(18'hb0,1);
        unsupported_probe(0,16'h4134,59,"C","I");unsupported_probe(1,16'h4134,59,"N","O");
        unsupported_probe(2,16'h4133,59,"C","I");unsupported_probe(3,16'h4133,59,"N","O");
        es2.write_cfg(18'hbb,16'h4134);
        cf=$fopen("vectors/cases.txt","r");
        while(!$feof(cf))begin
            rc=$fscanf(cf,"%d %d %d %d %d %d %d %d %d %d %d\n",id,lo,ll,ho,hl,doff,dl,request_port,protocol_version,lur_version,option_flags);
            if(rc==11)begin
                es2.write_cfg(18'hb8,request_port);es2.read_cfg(18'hb8,value);check(value==request_port,"configured request port readback");
                if(id!=0)es2.write_cfg(18'hbb,protocol_version);
                es2.read_cfg(18'hbb,value);check(value==protocol_version,"configured protocol version readback");
                es1.current_case=id;done=0;dropped=0;seen_lus=0;final_status=0;server_port=0;server_target=0;
                lui_port=40000+id*16;lur_port=lui_port+1;lus_port=41000+id*100;
                request(1,lui_port,"I");timeout=cycle+1800000;
                while(!done && cycle<timeout)begin
                    while(es1.head==es1.tail && cycle<timeout)@(negedge clk);
                    if(es1.head<es1.tail)begin
                        slot=es1.head%64;length=es1.lengths[slot];sp=es1.sports[slot];dp=es1.dports[slot];
                        for(j=0;j<length;j=j+1)p[j]=es1.queue[slot*1024+j];es1.head=es1.head+1;
                        op={p[0],p[1]};bn={p[2],p[3]};packet_count=packet_count+1;
                        if(op==2)begin
                            check(dp==request_port,"LUS WRQ sent to TFTP well-known port");lus_target=sp;lus_port=lus_port+1;ack(lus_port,sp,0);
                        end else if(op==3 && dp==lui_port)begin
                            check(length==13 && bn==1 && p[11]==1,"LUI accepted with one TFTP block");
                            if(id==0)dl_busy_probe(request_port,56999,"N","D");
                            ack(lui_port,sp,1);
                            check({p[8],p[9]}==protocol_version,"LUI uses configured A3/A4");
                            es2.write_cfg(18'hbb,protocol_version==16'h4134 ? 16'h4133 : 16'h4134);
                            es2.read_cfg(18'hbb,value);check(value==protocol_version,"busy protocol version write ignored");
                        end else if(op==3 && dp==lus_port)begin
                            check(sp==lus_target && bn==1,"LUS TID and block number");wire_status={p[10],p[11]};seen_lus=seen_lus+1;
                            check({p[8],p[9]}==protocol_version,"LUS uses configured A3/A4");
                            ack(lus_port,sp,1);
                            if(wire_status==1)request(2,lur_port,"R");
                            else if(wire_status==3 || wire_status==16'h1003)begin done=1;final_status=wire_status;end
                        end else if(op==4 && dp==lur_port)begin
                            if(bn==0)data_block(lo,ll,1,lur_port,sp,0);else check(bn==1,"LUR final ACK");
                        end else if(op==1)begin
                            check(id!=8,"unsupported A5 LUR never starts file downloads");
                            check(dp==request_port,"target RRQ uses configured port despite ignored port option");server_target=sp;
                            if(p[12]=="H")begin server_kind=1;server_offset=ho;server_size=hl;end
                            else begin
                                check(p[12]=="P","data filename from 665 header");server_kind=2;server_offset=doff;server_size=dl;
                                // 每次上传在数据阶段并行发双向用户消息。
                                fork es1.user_message();es2.user_message();join
                            end
                            server_port=43000+id*16+server_kind;data_block(server_offset,server_size,1,server_port,server_target,server_kind);
                        end else if(op==4 && dp==server_port)begin
                            check(sp==server_target,"download DATA transfer TID");data_block(server_offset,server_size,bn+1,server_port,sp,server_kind);
                        end else if(op==5)begin check(id>=3,"TFTP ERROR only in failure scenarios");end
                        else check(0,"unexpected TFTP packet");
                    end
                end
                check(done,"upload reaches final status within deadline");repeat(40000)@(negedge clk);
                es2.read_cfg(18'hb2,status_value);es2.read_cfg(18'hb3,loaded_value);es2.read_cfg(18'hb7,retry_value);
                $fwrite(fd,"C %0d %0d %0d %0d\n",id,status_value,loaded_value,retry_value);
                if(id!=3 && id!=4 && id!=8)begin
                    check(final_status==3 && status_value==2 && loaded_value==dl,"successful final file/status register");
                    $fwrite(fd,"R %0d ",id);
                    for(i=0;i<dl;i=i+1)begin
                        es2.write_cfg(18'hb4,i);repeat(4)@(negedge clk);es2.read_cfg(18'hb5,value);
                        check(value==file_bytes[doff+i],"loaded RAM byte matches independent source");$fwrite(fd,"%02x",value[7:0]);
                    end
                    $fwrite(fd,"\n");
                end else if(id==8)check(final_status==16'h1003 && status_value==16'h0103 && loaded_value==0,"unsupported A5 fails as metadata without loading");
                else check(final_status==16'h1003 && status_value[1:0]==3,"corruption/retry exhaustion reports failure");
                check(seen_lus==(id==8 ? 2 : 5),"expected status-file sequence");
                if(id!=3 && id!=4 && id!=8)begin
                    for(i=0;i<dl;i=i+1)dl_reference[i]=file_bytes[doff+i];
                    run_download(id,dl,protocol_version,request_port,id==2 ? 1:id==6 ? 2:id==5 ? 3:0,id==0);
                end
                $display("[615A_CASE] id=%0d state=%0h bytes=%0d retries=%0d status_files=%0d",id,status_value,loaded_value,retry_value,seen_lus);
            end
        end
        repeat(50000)@(negedge clk);check(es1.received==8 && es2.received==8,"all concurrent user messages exactly once");
        check(gmerr1==0 && gmerr2==0,"continuous GMII frames and gaps");
        $fwrite(fd,"U 8 8 %0d %0d\n",es1.received,es2.received);$fclose(fd);$fclose(cf);$fclose(dl_result_fd);$fclose(unsupported_result_fd);
        errors=errors+errors1+errors2;checks=checks+checks1+checks2;
        if(errors==0)$display("[RESULT] tb_sys_615a PASS checks=%0d errors=0",checks);
        else $display("[RESULT] tb_sys_615a FAIL checks=%0d errors=%0d",checks,errors);
        $finish;
    end
endmodule
