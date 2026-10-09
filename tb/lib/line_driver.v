`timescale 1ns/1ps
module line_driver(input wire clk, output reg [7:0] data, output reg valid);
    reg [7:0] bytes [0:4095];
    integer index;
    initial begin data=0;valid=0;end
    task put;
        input integer address;
        input [7:0] value;
        begin bytes[address]=value;end
    endtask
    task play;
        input integer length, idle_cycles;
        input [7:0] idle_data;
        begin
            valid=0;data=idle_data;
            repeat(idle_cycles) @(negedge clk);
            for(index=0;index<length;index=index+1)begin
                valid=1;data=bytes[index];@(negedge clk);
            end
            valid=0;data=idle_data;
        end
    endtask
    task hold;
        input integer cycles;
        input level;
        input [7:0] value;
        begin
            @(negedge clk);valid=level;data=value;
            repeat(cycles)@(negedge clk);
        end
    endtask
endmodule
