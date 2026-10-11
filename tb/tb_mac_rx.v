// 验证 Ethernet MAC 对正常帧、FCS/长度/前导异常的识别，以及去 FCS 后的字节和边界。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
// 完整回归还要求 sim 运行器的独立参考检查通过；所需 vectors 由该运行器准备。
`timescale 1ns/1ps
module tb_mac_rx;
    reg clk=0,reset=1;
    always #4 clk=~clk;
    wire [7:0] rx_data,m_data;
    wire rx_valid,m_valid,m_first,f_end;
    wire [1:0] f_err;
    wire [10:0] f_len;
    line_driver driver(clk,rx_data,rx_valid);
    afdx_mac_rx dut(clk,reset,rx_data,rx_valid,m_valid,m_data,m_first,f_end,f_err,f_len);
    reg [7:0] wire_bytes[0:199999],body_bytes[0:199999];
    integer wire_len[0:255],body_len[0:255],exp_len[0:255],exp_err[0:255],idle[0:255],noise[0:255];
    integer wire_base[0:255],body_base[0:255];
    integer count,wire_count,body_count,fd,rc,i,j,wb,bb;
    integer checks=0,errors=0,frame=0,index=0,cycle=0,last_output=-1;
    reg started=0,prev_end=0;
    task check;
        input ok;input [511:0] label;
        begin checks=checks+1;if(ok!==1'b1)begin errors=errors+1;
            if(errors<20)$display("[FAIL] tb_mac_rx cycle=%0d frame=%0d %s",cycle,frame,label);end end
    endtask
    always @(posedge clk)begin
        cycle=cycle+1;#1;
        if(reset || !started)check(!m_valid && !m_first && !f_end,"reset/half frame ignored");
        else begin
            check(!m_first || m_valid,"first only on valid byte");
            check(!(f_end && prev_end),"end one cycle");
            if(m_valid)begin
                check(frame<count && index<body_len[frame],"output bounds");
                check(m_data===body_bytes[body_base[frame]+index],"reference byte");
                check(m_first===(index==0),"first marker");index=index+1;last_output=cycle;
            end
            if(f_end)begin
                check(frame<count,"no extra end");
                check(f_err===exp_err[frame][1:0],"error priority");
                check(f_len===exp_len[frame][10:0],"frame length or saturation");
                check(index==body_len[frame],"output byte count");
                check(!m_valid && cycle>last_output,"end follows last output");
                frame=frame+1;index=0;
            end
        end
        prev_end=f_end;
        if(cycle>2000000)begin $display("[RESULT] tb_mac_rx FAIL checks=%0d errors=%0d TIMEOUT",checks,errors+1);$finish;end
    end
    initial begin
        fd=$fopen("vectors/rx.meta","r");if(!fd)begin $display("[RESULT] tb_mac_rx FAIL checks=0 errors=1");$finish;end
        rc=$fscanf(fd,"%d %d %d\n",count,wire_count,body_count);wb=0;bb=0;
        for(i=0;i<count;i=i+1)begin
            rc=$fscanf(fd,"%d %d %d %d %d %d\n",wire_len[i],body_len[i],exp_len[i],exp_err[i],idle[i],noise[i]);
            wire_base[i]=wb;body_base[i]=bb;wb=wb+wire_len[i];bb=bb+body_len[i];
        end
        $fclose(fd);$readmemh("vectors/rx_wire.hex",wire_bytes,0,wire_count-1);
        $readmemh("vectors/rx_body.hex",body_bytes,0,body_count-1);
        // 复位跨越高电平半帧，随后低电平噪声不得触发输出。
        driver.hold(8,1,8'hd5);reset=0;driver.hold(32,1,8'h55);driver.hold(16,0,8'hd5);
        started=1;
        for(i=0;i<count;i=i+1)begin
            for(j=0;j<wire_len[i];j=j+1)driver.put(j,wire_bytes[wire_base[i]+j]);
            driver.play(wire_len[i],idle[i],noise[i][7:0]);
        end
        driver.hold(32,0,8'hd5);
        check(frame==count && index==0,"all frames end exactly once");
        $display("[COVERAGE] tb_mac_rx cases=%0d cycles=%0d",count,cycle);
        $display("[RESULT] tb_mac_rx %s checks=%0d errors=%0d",errors==0 ? "PASS":"FAIL",checks,errors);$finish;
    end
endmodule
