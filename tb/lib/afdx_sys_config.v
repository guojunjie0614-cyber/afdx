// 系统配置激励；只驱动公开 cfg_*，父测试台只负责应用流。
// 保持本分支 sys_endpoint.write_cfg 的三参数接口和配置次序。
`timescale 1ns/1ps
module afdx_sys_config #(parameter CONFIG_FILE="vectors/vl_config.txt") (
    input wire clk,reset1,reset2,ready1,ready2,
    output reg cfg_done=0, output integer cfg_count=0
);
    integer cf,rc,vlid,bag,lmax,sport,dport,vi=0;
    reg [8*1024-1:0] command;
    task tick;begin @(posedge clk);#2;end endtask
    initial begin
        cf=$fopen(CONFIG_FILE,"r");
        if(!cf)$fatal(1,"[SYS_CONFIG_FAIL] cannot open configuration file");
        wait(!reset1 && !reset2);
        while(!ready1||!ready2)tick;repeat(64)tick;
        es1.stage("app");es2.stage("app");
        while(!$feof(cf))begin
            rc=$fscanf(cf,"%h %d %d %d %d",vlid,bag,lmax,sport,dport);
            if(rc==5)begin
                es1.write_cfg(18'h1000+vi*8,lmax*512+63*8+7,0);
                es1.write_cfg(18'h1001+vi*8,bag*125,0);
                es1.write_cfg(18'h1002+vi*8,vlid,0);
                es1.write_cfg(18'h1003+vi*8,32'h0a000101+vi,0);
                es1.write_cfg(18'h1004+vi*8,32'he0e00000|vlid,0);
                es1.write_cfg(18'h1005+vi*8,(sport<<16)|dport,0);
                es2.write_cfg(18'h10000+vlid,4096+vi,0);
                es2.write_cfg(18'h20000+vi,lmax*131072+20*32+31,0);
                es2.write_cfg(18'h1000+vi*8,lmax*512+63*8+7,0);
                es2.write_cfg(18'h1001+vi*8,bag*125,0);
                es2.write_cfg(18'h1002+vi*8,vlid,0);
                es2.write_cfg(18'h1003+vi*8,32'h0a000201+vi,0);
                es2.write_cfg(18'h1004+vi*8,32'he0e00000|vlid,0);
                es2.write_cfg(18'h1005+vi*8,(sport<<16)|dport,0);
                es1.write_cfg(18'h10000+vlid,4096+vi,0);
                es1.write_cfg(18'h20000+vi,lmax*131072+20*32+31,0);
                vi=vi+1;cfg_count=cfg_count+16;
            end else rc=$fgets(command,cf);
        end
        $fclose(cf);
        if(vi<1 || vi>128)$fatal(1,"[SYS_CONFIG_FAIL] invalid VL count");
        cfg_done=1;
    end
endmodule
