// All public output bits are checked, including idle data, after initialization.
// Sampling after the falling edge avoids NBA/delta-cycle transients.
`timescale 1ns/1ps
module afdx_x_monitor #(parameter WIDTH=1, parameter LABEL="public_outputs") (
    input wire clk,reset,armed,input wire [WIDTH-1:0] outputs,
    output integer checked_cycles=0
);
    always @(negedge clk) begin
        #1;
        if(!reset && armed) begin
            checked_cycles=checked_cycles+1;
            if((^outputs)===1'bx)
                $fatal(1,"[XZ_FAIL] %0s outputs=%h time=%0t",LABEL,outputs,$time);
        end
    end
endmodule
