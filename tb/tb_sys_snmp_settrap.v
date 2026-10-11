// 验证 SNMP user_id Set、拒绝非法写、写后读回及冷启动/认证失败 v2c Trap。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_sys_snmp_settrap;
    reg clk=0,reset=1;always #4 clk=~clk;
    wire [7:0] a12,b12,a21,b21;wire va12,vb12,va21,vb21,ready1,ready2;
    wire [31:0] checks1,checks2,errors1,errors2;
    snmp_test_endpoint #(.ES(1)) es1(clk,reset,a21,va21,b21,vb21,a12,va12,b12,vb12,ready1,checks1,errors1);
    snmp_test_endpoint #(.ES(2)) es2(clk,reset,a12,va12,b12,vb12,a21,va21,b21,vb21,ready2,checks2,errors2);
    wire [31:0] gmerr1,gmerr2,gmframes1,gmframes2;
    gmii_monitor #(.FILE_NAME("manager_gmii.txt")) mon1(clk,reset,a12,va12,gmerr1,gmframes1);
    gmii_monitor #(.FILE_NAME("agent_gmii.txt")) mon2(clk,reset,a21,va21,gmerr2,gmframes2);
    integer cycle=0,checks=0,errors=0,fd,cf,rc,id,offset,length,sport,mode,silent,expected_user;
    integer timeout,previous_replies,count=0,i;
    reg [31:0] value,bad_count,trap_count;
    always @(posedge clk)begin
        cycle=cycle+1;
        if(cycle>8000000 || errors+errors1+errors2>20)begin
            $display("[RESULT] tb_sys_snmp_settrap FAIL checks=%0d errors=%0d",checks+checks1+checks2,errors+errors1+errors2+1);$finish;
        end
    end
    task check;
        input ok;input [8*100-1:0] why;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;$display("[SETTRAP_FAIL] case=%0d cycle=%0d %0s",id,cycle,why);end end
    endtask
    initial begin
        fd=$fopen("snmp_results.txt","w");es1.log_fd=fd;
        repeat(8)@(negedge clk);reset=0;wait(ready1 && ready2);es1.configure();es2.configure();
        es2.write_cfg(18'h91,2);es2.read_cfg(18'h9b,value);check(value==0,"Trap disabled by default");
        es2.write_cfg(18'h90,1);
        for(i=0;i<7;i=i+1)begin fork es1.user_message();es2.user_message();join repeat(4000)@(negedge clk);end
        repeat(1250000)@(negedge clk);check(es1.traps==0,"disabled coldStart silent");
        cf=$fopen("vectors/cases.txt","r");
        while(!$feof(cf))begin
            rc=$fscanf(cf,"%d %d %d %d %d %d %d\n",id,offset,length,sport,mode,silent,expected_user);
            if(rc==7)begin
                fork es1.user_message();es2.user_message();join
                if(mode==1)begin
                    es2.write_cfg(18'h90,0);es2.write_cfg(18'h9b,1);es2.write_cfg(18'h90,1);
                    timeout=cycle+100000;
                    while(es1.traps==0 && cycle<timeout)@(negedge clk);
                    check(es1.traps==1,"one enabled coldStart received");
                end
                if(mode==3)begin
                    es2.write_cfg(18'h9b,0);es2.write_cfg(18'h90,0);es2.write_cfg(18'h90,1);
                    repeat(30000)@(negedge clk);check(es1.traps==2,"disabled re-enable does not send coldStart");
                end
                es1.current_case=id;previous_replies=es1.replies;es1.request_message(offset,length,sport);
                if(silent)begin
                    repeat(50000)@(negedge clk);check(es1.replies==previous_replies,"bad community has no GetResponse");
                end else begin
                    timeout=cycle+100000;
                    while(es1.replies==previous_replies && cycle<timeout)@(negedge clk);
                    check(es1.replies==previous_replies+1,"one Set/Get response received");
                end
                es2.read_cfg(2,value);check(value==expected_user,"Set result and failed-Set non-effect read through configuration bus");
                es2.read_cfg(18'h9c,trap_count);es2.read_cfg(18'h9a,bad_count);
                $fwrite(fd,"C %0d %0d %0d %0d %0d\n",id,value,trap_count,es1.traps,bad_count);
                count=count+1;$fflush(fd);
            end
        end
        repeat(100000)@(negedge clk);
        check(count==22,"all Set/Trap reference cases executed");
        check(es1.received==29 && es2.received==29,"user messages exactly once in both directions");
        check(es1.traps==2,"no Trap retransmission or disabled notification");
        check(gmerr1==0 && gmerr2==0,"valid GMII framing");
        $fwrite(fd,"U 29 29 %0d %0d\n",es1.received,es2.received);$fclose(fd);$fclose(cf);
        $display("[SNMP_SETTRAP] requests=%0d responses=%0d traps=%0d user=%0d/%0d",count,es1.replies,es1.traps,es1.received,es2.received);
        $display("[RESULT] tb_sys_snmp_settrap %0s checks=%0d errors=%0d",errors+errors1+errors2==0 ? "PASS":"FAIL",checks+checks1+checks2,errors+errors1+errors2);
        $finish;
    end
endmodule
