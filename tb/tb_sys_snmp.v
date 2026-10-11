// 验证 SNMP v1/v2c Get/GetNext、community 和 BER 边界，以及 MIB 快照与配置寄存器一致性。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
// 双端GMII系统；管理端走普通应用口，代理和配置采样只通过顶层公开接口。
module tb_sys_snmp;
    reg clk=0,reset=1;always #4 clk=~clk;
    wire [7:0] a12,b12,a21,b21;wire va12,vb12,va21,vb21,ready1,ready2;
    wire [31:0] checks1,checks2,errors1,errors2;
    snmp_test_endpoint #(.ES(1)) es1(clk,reset,a21,va21,b21,vb21,a12,va12,b12,vb12,ready1,checks1,errors1);
    snmp_test_endpoint #(.ES(2)) es2(clk,reset,a12,va12,b12,vb12,a21,va21,b21,vb21,ready2,checks2,errors2);
    wire [31:0] gmerr1,gmerr2,gmframes1,gmframes2;
    gmii_monitor #(.FILE_NAME("manager_gmii.txt")) mon1(clk,reset,a12,va12,gmerr1,gmframes1);
    gmii_monitor #(.FILE_NAME("agent_gmii.txt")) mon2(clk,reset,a21,va21,gmerr2,gmframes2);
    integer cycle=0,checks=0,errors=0,fd,cf,rc,id,offset,length,sport,address,mode;
    integer timeout,previous_replies,count=0,i;
    reg [31:0] sampled_at,value,bad_before,bad_after,descr0,descr1,descr2,descr3;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>18000000 || errors+errors1+errors2>20)begin
            $display("[RESULT] tb_sys_snmp FAIL checks=%0d errors=%0d",checks+checks1+checks2,errors+errors1+errors2+1);$finish;
        end
    end
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;$display("[SNMP_FAIL] case=%0d cycle=%0d %0s",id,cycle,why);end end
    endtask
    initial begin
        fd=$fopen("snmp_results.txt","w");es1.log_fd=fd;
        repeat(8)@(negedge clk);reset=0;wait(ready1 && ready2);
        es1.configure();es2.configure();
        es2.write_cfg(18'h84,123);es2.write_cfg(18'h85,0);es2.write_cfg(18'h80,4);
        es2.write_cfg(18'h91,2);es2.write_cfg(18'h90,1);
        es2.read_cfg(18'h93,value);check(value==32'h7075626c,"default community public word0");
        es2.read_cfg(18'h94,value);check(value==32'h69630000,"default community public word1");
        es2.read_cfg(18'ha0,descr0);es2.read_cfg(18'ha1,descr1);es2.read_cfg(18'ha2,descr2);es2.read_cfg(18'ha3,descr3);
        $fwrite(fd,"DESC %08x%08x%08x%08x\n",descr0,descr1,descr2,descr3);
        for(i=0;i<7;i=i+1)begin fork es1.user_message();es2.user_message();join repeat(4000)@(negedge clk);end
        // 至少经过10 ms，sysUpTime的非零值由管理报文和配置口同时验证。
        repeat(1250000)@(negedge clk);
        cf=$fopen("vectors/cases.txt","r");
        while(!$feof(cf))begin
            rc=$fscanf(cf,"%d %d %d %d %d %d\n",id,offset,length,sport,address,mode);
            if(rc==6)begin
                fork es1.user_message();es2.user_message();join
                if(mode==3)begin
                    es2.write_cfg(18'h93,32'h63336d61);es2.write_cfg(18'h94,32'h6e616765);es2.write_cfg(18'h92,8);
                end
                if(mode==4)begin
                    es2.write_cfg(18'h93,32'h30313233);es2.write_cfg(18'h94,32'h34353637);
                    es2.write_cfg(18'h95,32'h38396162);es2.write_cfg(18'h96,32'h63646566);es2.write_cfg(18'h92,16);
                end
                if(mode==1)es2.read_cfg(18'h9a,bad_before);
                if(address>=0)begin @(negedge clk);es2.address=mode==5 ? 0 : address;es2.rd=1;end
                es1.current_case=id;previous_replies=es1.replies;
                es1.request_message(offset,length,sport);
                if(mode==5)begin
                    // 主机读取另一对象会推迟代理读取；释放后由代理独立发起总线读。
                    repeat(30000)@(negedge clk);check(es1.replies==previous_replies,"host read priority stalls MIB read");
                    es2.rd=0;
                end
                if(mode==1 || mode==2)begin
                    repeat(50000)@(negedge clk);check(es1.replies==previous_replies,"silent unsupported or bad community");
                end else begin
                    timeout=cycle+100000;
                    while(es1.replies==previous_replies && cycle<timeout)@(negedge clk);
                    check(es1.replies==previous_replies+1,"one response within timeout");
                end
                @(negedge clk);es2.rd=0;
                if(address>=0)begin
                    es2.read_cfg(18'h97,sampled_at);
                    if(mode==5)begin
                        es2.read_cfg(address,value);$fwrite(fd,"S %0d %0d %0d\n",id,sampled_at,value);
                    end else begin
                        check(es2.sample_tags[sampled_at[17:0]]===sampled_at,"configuration and MIB sample have same cycle");
                        value=es2.sample_values[sampled_at[17:0]];
                        $fwrite(fd,"B %0d %0d %0d\n",id,sampled_at,value);
                    end
                end
                if(mode==1)begin
                    es2.read_cfg(18'h9a,bad_after);check(bad_after==bad_before+1,"bad community increments once");
                    $fwrite(fd,"BAD %0d %0d\n",bad_before,bad_after);
                end
                count=count+1;$fflush(fd);
            end
        end
        repeat(50000)@(negedge clk);
        check(count==117,"all reference cases executed");
        check(es1.received==124 && es2.received==124,"user messages exactly once in both directions");
        check(gmerr1==0 && gmerr2==0,"valid GMII framing");
        $fwrite(fd,"U 124 124 %0d %0d\n",es1.received,es2.received);$fclose(fd);$fclose(cf);
        $display("[SNMP_SYSTEM] requests=%0d responses=%0d user=%0d/%0d",count,es1.replies,es1.received,es2.received);
        $display("[RESULT] tb_sys_snmp %0s checks=%0d errors=%0d",errors+errors1+errors2==0 ? "PASS":"FAIL",checks+checks1+checks2,errors+errors1+errors2);
        $finish;
    end
endmodule
