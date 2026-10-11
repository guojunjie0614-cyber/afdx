// MAC 线路观察器：记录帧字节/时间并检查间隔；外层测试与独立帧检查器共同判定。
// 对应外层用例的赛题功能；本文件不构成独立验收入口，错误必须由调用者汇总。
`timescale 1ns/1ps
module line_monitor #(parameter NET="A", FILE_NAME="dump_a.txt", MIN_GAP=12,
                      SAMPLE_DELAY=1, IGNORE_RESET_TAIL=0)(
    input wire clk, reset,
    input wire [7:0] data,
    input wire valid,
    output integer errors,
    output integer frames
);
    reg [7:0] bytes [0:4095];
    integer fd, cycle, start_cycle, active_cycles, count, last_end, i;
    reg active,wait_idle=0;
    initial begin
        errors=0;frames=0;cycle=0;active=0;last_end=-1;
        fd=$fopen(FILE_NAME,"w");
        if (!fd) begin $display("[MONITOR_FAIL] cannot open %s",FILE_NAME);$finish;end
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        #(SAMPLE_DELAY);
        if (reset) begin active=0;last_end=-1;wait_idle=IGNORE_RESET_TAIL;end
        else if(wait_idle)begin if(!valid)wait_idle=0;end
        else if (valid) begin
            if (!active) begin
                if (last_end>=0 && cycle-last_end<MIN_GAP) begin
                    errors=errors+1;$display("[MONITOR_FAIL] %s gap=%0d",NET,cycle-last_end);
                end
                active=1;start_cycle=cycle;active_cycles=0;count=0;
            end
            if (active_cycles%1==0) begin bytes[count]=data;count=count+1;end
            else if (data!==bytes[count-1]) begin
                errors=errors+1;
                if(errors<10)$display("[MONITOR_FAIL] %s unstable byte at %0d",NET,cycle);
            end
            active_cycles=active_cycles+1;
        end else if (active) begin
            if (active_cycles%1!=0) begin errors=errors+1;$display("[MONITOR_FAIL] fractional byte");end
            $fwrite(fd,"%s %0d %0d ",NET,start_cycle,count);
            for(i=0;i<count;i=i+1)$fwrite(fd,"%02x",bytes[i]);
            $fwrite(fd,"\n");$fflush(fd);
            frames=frames+1;active=0;last_end=cycle;
        end
    end
endmodule
