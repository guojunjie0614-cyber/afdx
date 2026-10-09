// 公开端口上的615A加载端模型；正常/丢ACK/无此文件，不访问目标内部状态。
reg [7:0] dl_reference[0:8191], dl_received[0:8191], dl_packet[0:1023];
integer dl_result_fd, dl_length, dl_sp, dl_dp, dl_op, dl_bn;
integer unsupported_result_fd;
task dl_request;
    input integer opcode,source,port; input [7:0] group,suffix;
    begin
        es1.send_bytes[0]=0;es1.send_bytes[1]=opcode;
        es1.send_bytes[2]="D";es1.send_bytes[3]="E";es1.send_bytes[4]="M";es1.send_bytes[5]="C";es1.send_bytes[6]="3";
        es1.send_bytes[7]="_";es1.send_bytes[8]="1";es1.send_bytes[9]=".";es1.send_bytes[10]="L";es1.send_bytes[11]=group;
        es1.send_bytes[12]=suffix;es1.send_bytes[13]=0;
        es1.send_bytes[14]="o";es1.send_bytes[15]="c";es1.send_bytes[16]="t";es1.send_bytes[17]="e";es1.send_bytes[18]="t";es1.send_bytes[19]=0;
        es1.packet(20,source,port);
    end
endtask
task unsupported_probe;
    input integer case_id,version,port;input [7:0] group,suffix;
    integer oldlog,oldcase,source;
    reg [31:0] before_status,after_status,before_loaded,after_loaded;
    begin
        oldlog=es1.log_fd;oldcase=es1.current_case;source=58000+case_id;
        es1.log_fd=unsupported_result_fd;es1.current_case=case_id;
        es2.write_cfg(18'hbb,version);es2.read_cfg(18'hb2,before_status);es2.read_cfg(18'hb3,before_loaded);
        $fwrite(unsupported_result_fd,"B %0d %0d %0d %0d %0d %0d\n",case_id,cycle,version,port,group,suffix);
        dl_request(1,source,port,group,suffix);dl_pop();
        check(dl_dp==source && dl_sp!=port && dl_op==3 && dl_bn==1 && dl_length==13,"unsupported operation returns initialization DATA1 from new TID");
        check({dl_packet[4],dl_packet[5],dl_packet[6],dl_packet[7]}==9 && {dl_packet[8],dl_packet[9]}==version,"unsupported initialization length and configured version");
        check({dl_packet[10],dl_packet[11]}==16'h1002 && dl_packet[12]==0,"unsupported operation status1002 with empty description");
        ack(source,dl_sp,1);repeat(40000)@(negedge clk);
        es2.read_cfg(18'hb2,after_status);es2.read_cfg(18'hb3,after_loaded);
        check(after_status==before_status && after_loaded==before_loaded && es1.head==es1.tail,"unsupported operation does not start a transfer or change load state");
        $fwrite(unsupported_result_fd,"C %0d %0d %0d %0d %0d\n",case_id,before_status,after_status,before_loaded,after_loaded);
        $fwrite(unsupported_result_fd,"E %0d %0d\n",case_id,cycle);$fflush(unsupported_result_fd);
        es1.log_fd=oldlog;es1.current_case=oldcase;
    end
endtask
task dl_pop;
    integer s,k;
    begin
        while(es1.head==es1.tail)@(negedge clk);
        s=es1.head%64;dl_length=es1.lengths[s];dl_sp=es1.sports[s];dl_dp=es1.dports[s];
        for(k=0;k<dl_length;k=k+1)dl_packet[k]=es1.queue[s*1024+k];
        es1.head=es1.head+1;dl_op={dl_packet[0],dl_packet[1]};dl_bn={dl_packet[2],dl_packet[3]};
    end
endtask
task dl_busy_probe;
    input integer port,source;input [7:0] group,suffix;
    integer oldlog,begin_cycle;
    begin
        oldlog=es1.log_fd;es1.log_fd=dl_result_fd;begin_cycle=cycle;
        dl_request(1,source,port,group,suffix);dl_pop();
        check(dl_dp==source && dl_op==3 && dl_bn==1 && dl_length==21,"busy initialization response uses DATA1");
        check({dl_packet[10],dl_packet[11]}==16'h1000 && dl_packet[12]==8 && dl_packet[13]=="B","busy denied 1000 with description");
        ack(source,dl_sp,1);
        $fwrite(dl_result_fd,"Q %0d %0d %0d %0d\n",es1.current_case,begin_cycle,cycle,group);
        es1.log_fd=oldlog;
    end
endtask
task run_download;
    // mode 0正常、1丢一次ACK2、2持续丢ACK2、3不存在的文件。
    input integer case_id,size,version,port,mode,busy_probe;
    integer oldlog,oldcase,initial_port,list_port,status_port,data_port,status_tid;
    integer stop_cycle,finished,wire_status,expected_block,received_size,lost,status_count,k,initial_tid;
    reg [31:0] before_retry,after_retry,result_status;
    begin
        oldlog=es1.log_fd;oldcase=es1.current_case;es1.log_fd=dl_result_fd;es1.current_case=case_id;
        initial_port=48000+case_id*4;list_port=initial_port+1;status_port=50000+case_id*32;data_port=52000+case_id;
        finished=0;expected_block=1;received_size=0;lost=0;status_count=0;stop_cycle=cycle+1800000;
        es2.read_cfg(18'hb7,before_retry);
        $fwrite(dl_result_fd,"B %0d %0d %0d %0d %0d %0d\n",case_id,cycle,size,version,port,mode);
        dl_request(1,initial_port,port,"N","D");
        while(!finished && cycle<stop_cycle)begin
            dl_pop();
            if(dl_op==3 && dl_dp==initial_port)begin
                check(dl_length==13 && dl_bn==1 && {dl_packet[8],dl_packet[9]}==version && dl_packet[11]==1,"LND accepted with configured version");
                initial_tid=dl_sp;
                if(busy_probe!=0)dl_busy_probe(port,57000+case_id,"U","I");
                ack(initial_port,initial_tid,1);
            end
            else if(dl_op==2)begin
                check(dl_dp==port,"download WRQ uses configured request port");
                if(dl_packet[2]=="D")begin
                    check(dl_length==20 && dl_packet[11]=="N" && dl_packet[12]=="S","status filename is LNS");
                    status_tid=dl_sp;status_port=status_port+1;ack(status_port,dl_sp,0);
                end
                else begin
                    check(mode!=3 && dl_length==19 && dl_packet[2]=="M" && dl_packet[11]=="N","requested RAM data filename");
                    ack(data_port,dl_sp,0);
                end
            end
            else if(dl_op==3 && dl_dp==status_port)begin
                check(dl_sp==status_tid && dl_bn==1 && {dl_packet[8],dl_packet[9]}==version,"LNS version/TID/block");
                wire_status={dl_packet[10],dl_packet[11]};status_count=status_count+1;
                check({dl_packet[21],dl_packet[22]}==status_count,"LNS counter increments for new status files");
                ack(status_port,dl_sp,1);
                if(wire_status==1)dl_request(2,list_port,port,"N","R");
                else if(wire_status==3 || wire_status==16'h1003)finished=1;
                else check(wire_status==2,"LNS intermediate status is 0002");
            end
            else if(dl_op==4 && dl_dp==list_port)begin
                if(dl_bn==0)begin
                    es1.send_bytes[0]=0;es1.send_bytes[1]=3;es1.send_bytes[2]=0;es1.send_bytes[3]=1;
                    es1.send_bytes[4]=0;es1.send_bytes[5]=0;es1.send_bytes[6]=0;es1.send_bytes[7]=21;
                    es1.send_bytes[8]=version>>8;es1.send_bytes[9]=version;es1.send_bytes[10]=0;es1.send_bytes[11]=1;
                    es1.send_bytes[12]=11;
                    es1.send_bytes[13]=mode==3 ? "A":"M";es1.send_bytes[14]=mode==3 ? "B":"E";
                    es1.send_bytes[15]=mode==3 ? "S":"M";es1.send_bytes[16]=mode==3 ? "E":"O";
                    es1.send_bytes[17]=mode==3 ? "N":"R";es1.send_bytes[18]=mode==3 ? "T":"Y";
                    es1.send_bytes[19]=".";es1.send_bytes[20]="B";es1.send_bytes[21]="I";es1.send_bytes[22]="N";
                    es1.send_bytes[23]=0;es1.send_bytes[24]=0;es1.packet(25,list_port,dl_sp);
                end
                else check(dl_bn==1,"LNR final ACK1");
            end
            else if(dl_op==3 && dl_dp==data_port)begin
                check(dl_bn==expected_block || dl_bn==expected_block-1,"consecutive or retransmitted data block");
                if(dl_bn==expected_block)begin
                    for(k=4;k<dl_length;k=k+1)begin
                        check(received_size<size && dl_packet[k]==dl_reference[received_size],"downloaded RAM byte equals original upload");
                        dl_received[received_size]=dl_packet[k];received_size=received_size+1;
                    end
                    expected_block=expected_block+1;
                    if(dl_length<516)check(received_size==size,"short or empty last DATA ends at exact file length");
                end
                else for(k=4;k<dl_length;k=k+1)check(dl_packet[k]==dl_reference[(dl_bn-1)*512+k-4],"retransmission preserves every byte");
                if(dl_bn==2 && (mode==2 || (mode==1 && lost==0)))lost=lost+1;
                else ack(data_port,dl_sp,dl_bn);
            end
            else if(dl_op==5)check(mode==2 || mode==3,"TFTP ERROR only in requested failure cases");
            else check(0,"unexpected download packet");
        end
        check(finished,"download reaches terminal LNS");
        repeat(40000)@(negedge clk);
        es2.read_cfg(18'hb2,result_status);es2.read_cfg(18'hb7,after_retry);
        check(result_status==(mode==2 ? 16'h0503:mode==3 ? 16'h0103:2),"download completion status and reason");
        check(wire_status==(mode>=2 ? 16'h1003:3),"download final LNS success/failure");
        if(mode<2)check(received_size==size,"download exact byte count");
        else check(received_size==(mode==2 ? 1024:0),"failure has only preceding received data");
        check(after_retry-before_retry==(mode==1 ? 1:mode==2 ? 2:0),"download retry count matches injected ACK loss");
        $fwrite(dl_result_fd,"C %0d %0d %0d %0d %0d %0d\n",case_id,result_status,received_size,after_retry-before_retry,lost,status_count);
        $fwrite(dl_result_fd,"R %0d ",case_id);for(k=0;k<received_size;k=k+1)$fwrite(dl_result_fd,"%02x",dl_received[k]);$fwrite(dl_result_fd,"\n");
        $fwrite(dl_result_fd,"E %0d %0d\n",case_id,cycle);$fflush(dl_result_fd);
        $display("[615A_DOWNLOAD] case=%0d status=%0h bytes=%0d retries=%0d status_files=%0d",case_id,result_status,received_size,after_retry-before_retry,status_count);
        es1.log_fd=oldlog;es1.current_case=oldcase;
    end
endtask
