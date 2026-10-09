`timescale 1ns/1ps
module tb_probe_ram;
`ifdef PROBE_P2
    localparam WIDTH=13,DEPTH=65536;
`else
    localparam WIDTH=8,DEPTH=2048;
`endif
 reg clk=0;always #4 clk=~clk;
    reg we=0,re=0;
    reg [15:0] wa=0,ra=0;
    reg [WIDTH-1:0] wd=0;
    wire [WIDTH-1:0] rd;
`ifdef PROBE_P2
    probe_p2_array dut(clk,we,re,wa,ra,wd,rd);
`else
    probe_p1_2048x8 dut(clk,we,re,wa,ra,wd,rd);
`endif
    reg [WIDTH-1:0] first[0:DEPTH-1],final_data[0:DEPTH-1];
    integer i,round,checks=0,errors=0;
    initial begin
        $readmemh("vectors/ram_first.hex",first,0,DEPTH-1);
        $readmemh("vectors/ram_final.hex",final_data,0,DEPTH-1);
        repeat(4)@(negedge clk);
        for(round=0;round<2;round=round+1)begin
            for(i=0;i<DEPTH;i=i+1)begin
                @(negedge clk);we=(round==0 || i%2==0);wa=i;wd=(round==0 ? first[i]:final_data[i]);
            end
            @(negedge clk);we=0;repeat(3)@(negedge clk);
            for(i=0;i<DEPTH+2;i=i+1)begin
                @(negedge clk);re=(i<DEPTH);ra=(i<DEPTH ? i:0);
                @(posedge clk);#1;
                if(i>=2)begin
                    checks=checks+1;
                    if(rd!==(round==0 ? first[i-2]:final_data[i-2]))begin
                        errors=errors+1;
                        if(errors<12)$display("[FAIL] RAM round=%0d address=%0d got=%h",round,i-2,rd);
                    end
                end
            end
            @(negedge clk);re=0;
        end
        $display("[RESULT] tb_probe_ram %s checks=%0d errors=%0d",errors==0 ? "PASS":"FAIL",checks,errors);$finish;
    end
endmodule
