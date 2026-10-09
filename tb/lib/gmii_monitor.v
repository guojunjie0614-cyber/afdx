`timescale 1ns/1ps
// 每周期记录一个GMII字节。段是否被错误拆开，由X1/X3逐帧比对共同检查。
module gmii_monitor #(
    parameter NET="A",
    parameter FILE_NAME="dump_a.txt",
    parameter MIN_GAP=12,
    parameter SAMPLE_DELAY=0,
    parameter IGNORE_RESET_TAIL=1
)(
    input wire clk,reset,
    input wire [7:0] data,
    input wire valid,
    output integer errors,
    output integer frames
);
    reg [7:0] bytes[0:8191];
    integer fd,cycle,start_cycle,count,last_end,i;
    reg active,wait_idle,overflow;
    initial begin
        errors=0;frames=0;cycle=0;active=0;last_end=-1;
        count=0;wait_idle=0;overflow=0;
        fd=$fopen(FILE_NAME,"w");
        if(!fd)begin $display("[GMII_MONITOR_FAIL] cannot open %s",FILE_NAME);$finish;end
    end
    always @(posedge clk)begin
        cycle=cycle+1;
        #(SAMPLE_DELAY);
        if(reset)begin
            active=0;last_end=-1;count=0;overflow=0;wait_idle=IGNORE_RESET_TAIL;
        end else if(wait_idle)begin
            if(!valid)wait_idle=0;
        end else if(valid)begin
            if(!active)begin
                if(last_end>=0 && cycle-last_end<MIN_GAP)begin
                    errors=errors+1;
                    $display("[GMII_MONITOR_FAIL] %s cycle=%0d gap=%0d",NET,cycle,cycle-last_end);
                end
                active=1;start_cycle=cycle;count=0;overflow=0;
            end
            if(count<8192)bytes[count]=data;
            else if(!overflow)begin
                overflow=1;errors=errors+1;
                $display("[GMII_MONITOR_FAIL] %s capture capacity exceeded at %0d",NET,cycle);
            end
            count=count+1;
        end else if(active)begin
            if(!overflow)begin
                $fwrite(fd,"%s %0d %0d ",NET,start_cycle,count);
                for(i=0;i<count;i=i+1)$fwrite(fd,"%02x",bytes[i]);
                $fwrite(fd,"\n");$fflush(fd);
            end
            frames=frames+1;active=0;last_end=cycle;
        end
    end
endmodule
