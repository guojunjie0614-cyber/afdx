// RX-owned synchronous SDP. The shallow context tables must use M4K storage,
// not a resettable FF array. Callers exclude read/write collisions explicitly.
module afdx_rx_reassembly_ram #(parameter WIDTH=8, AW=3, REGISTER_WRITE_ADDRESS=0) (
    input wire clk,
    input wire we, input wire [AW-1:0] wa, input wire [WIDTH-1:0] wd,
    input wire re, input wire [AW-1:0] ra, output reg [WIDTH-1:0] q
);
    wire [AW-1:0] write_address;
    generate if(REGISTER_WRITE_ADDRESS) begin:local_write
        // Caller supplies the already selected row one clock before WE.
        // Each table owns this address FF; the physical write edge is unchanged.
        (* preserve=1, dont_merge=1 *) reg [AW-1:0] address;
        always @(posedge clk) address<=wa;
        assign write_address=address;
    end else begin:direct_write
        assign write_address=wa;
    end endgenerate
    (* ramstyle = "M4K,no_rw_check" *) reg [WIDTH-1:0] memory[0:(1<<AW)-1];
    // Keep the mapped write-data isolation used by the common RAM wrapper.
    always @(posedge clk) if(we) memory[write_address] <= we ? wd : {WIDTH{1'b0}};
    always @(posedge clk) if(re) q <= memory[ra];
`ifndef SYNTHESIS
    always @(posedge clk) if(we && re && write_address==ra) begin
        $display("** Error: [RAMCOLL] %m time=%0t address=%0d",$time,write_address);
        $finish_and_return(1);
    end
`endif
endmodule
