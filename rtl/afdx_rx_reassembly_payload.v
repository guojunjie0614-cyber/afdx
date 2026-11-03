// Eight 8192-byte slots. Descriptor-time one-hot selects are stable before
// byte commands arrive. Four independent two-bit lanes bound each RAM-port
// command/address net to a quarter slot. WA is the caller's next-cycle
// address, captured per slot one clock ahead of WE/WD; byte write stays E2.
// Read E0 command/E1 RAM/E2 result/E3 pair/E4 OR/E5 bank.
module afdx_rx_reassembly_payload (
    input wire clk, reset,
    input wire we, input wire [15:0] wa, input wire [7:0] wd,
    input wire re, input wire [15:0] ra,
    input wire [7:0] write_slots, read_slots,
    output reg [7:0] q
);
    wire [63:0] slot_results;
    (* preserve=1, dont_merge=1 *) reg [31:0] pair_results;
    genvar slot, pair;
    generate for(slot=0;slot<8;slot=slot+1) begin:slots
        afdx_rx_reassembly_payload_slot storage(
            .clk(clk),.reset(reset),
            .we(we && write_slots[slot]),.wa(wa[12:0]),.wd(wd),
            .re(re && read_slots[slot]),.ra(ra[12:0]),
            .q(slot_results[slot*8+:8]));
    end endgenerate
    generate for(pair=0;pair<4;pair=pair+1) begin:read_pair
        always @(posedge clk) begin
            if(reset) pair_results[pair*8+:8]<=0;
            else pair_results[pair*8+:8]<=slot_results[pair*16+:8] | slot_results[pair*16+8+:8];
        end
    end endgenerate
    always @(posedge clk) begin
        if(reset) q<=0;
        else q<=pair_results[7:0] | pair_results[15:8] | pair_results[23:16] | pair_results[31:24];
    end
endmodule

module afdx_rx_reassembly_payload_slot (
    input wire clk, reset, we,
    input wire [12:0] wa, input wire [7:0] wd,
    input wire re, input wire [12:0] ra, output wire [7:0] q
);
    (* preserve=1, dont_merge=1 *) reg [12:0] write_address;
    always @(posedge clk) write_address<=wa;
    genvar lane;
    generate for(lane=0;lane<4;lane=lane+1) begin:lanes
        afdx_rx_reassembly_payload_lane storage(
            .clk(clk),.reset(reset),.we(we),.wa(write_address),.wd(wd[lane*2+:2]),
            .re(re),.ra(ra),.q(q[lane*2+:2]));
    end endgenerate
endmodule

// Keep each memory declaration and its write-data isolation inside an
// independent module. Inline generated arrays previously lost the isolation
// LUTs. The full mapped design must retain all 128 bit-isolation LUTs.
module afdx_rx_reassembly_payload_lane (
    input wire clk, reset, we,
    input wire [12:0] wa, input wire [1:0] wd,
    input wire re, input wire [12:0] ra, output wire [1:0] q
);
    (* preserve=1, dont_merge=1 *) reg write_command, write_qualifier, read_command;
    (* preserve=1, dont_merge=1 *) reg [12:0] write_address, read_address;
    (* preserve=1, dont_merge=1 *) reg [1:0] write_data;
    reg read_pending;
    (* preserve=1, dont_merge=1 *) reg [1:0] read_result;
    reg [1:0] ram_q;
    (* ramstyle="M4K,no_rw_check" *) reg [1:0] memory[0:8191];
    assign q=read_result;
    always @(posedge clk) begin
        write_address<=wa;write_data<=wd;read_address<=ra;
        if(reset) begin write_command<=0;write_qualifier<=0;read_command<=0;read_pending<=0;end
        else begin
            write_command<=we;write_qualifier<=we;read_command<=re;read_pending<=read_command;
        end
    end
    always @(posedge clk) if(write_command)
        memory[write_address]<=write_qualifier ? write_data : 2'b0;
    always @(posedge clk) if(read_command) ram_q<=memory[read_address];
    always @(posedge clk) begin
        if(reset) read_result<=0;
        else read_result<=read_pending ? ram_q : 2'b0;
    end
endmodule
