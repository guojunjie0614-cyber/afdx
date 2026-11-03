// Eight logical 4 KiB x 9 banks, each with four local 1 KiB RAM slices.
// Command E0 -> physical write E1. Reads: E0 command, E1 RAM, E2 slice
// result, E3 bank return, E4 reader response. Both optional modes retain it.
module afdx_app_payload #(parameter EARLY_DATA=0,parameter SPLIT_RETURN=0) (
    input wire clk,reset,
    input wire write_enable,
    input wire [14:0] write_address,
    input wire [8:0] write_data,
    input wire read_enable,
    input wire [14:0] read_address,
    output wire [8:0] read_data,
    // EARLY_DATA only: full byte+last from the clock BEFORE the command.
    // Default/TX mode never reads this optional input.
    input wire [8:0] raw_write_data
);
    (* keep=1 *) wire [8:0] bank_data[0:7];
    (* preserve=1,dont_merge=1 *) reg [7:0] read_bank_command,read_bank_ram,read_bank_result;
    wire [8:0] local_write_data[0:3];
    genvar p,b;
    generate for(p=0;p<4;p=p+1)begin:write_pair
        if(EARLY_DATA)begin:early
            // This replaces RX's central E0 byte capture, not an added stage.
            // Each complete E0 byte/last copy drives only two E1 bank captures;
            // the caller's aligned E1 admission tag alone may consume it.
            (* preserve=1,dont_merge=1 *) reg [8:0] data_q;
            always @(posedge clk)data_q<=raw_write_data;
            assign local_write_data[p]=data_q;
        end else begin:command
            assign local_write_data[p]=write_data;
        end
    end
    for(b=0;b<8;b=b+1)begin:bank
        afdx_app_payload_bank storage(
            .clk(clk),.reset(reset),
            .write_enable(write_enable && write_address[14:12]==b),
            .write_address(write_address[11:0]),.write_data(local_write_data[b/2]),
            .read_enable(read_enable),.read_select(read_address[14:12]==b),
            .read_address(read_address[11:0]),.read_data(bank_data[b]));
    end endgenerate
    always @(posedge clk)begin
        read_bank_command<=8'b00000001<<read_address[14:12];
        read_bank_ram<=read_bank_command;
        read_bank_result<=read_bank_ram;
    end
    wire [8:0] read_first=({9{read_bank_result[0]}} & bank_data[0]) |
                          ({9{read_bank_result[1]}} & bank_data[1]) |
                          ({9{read_bank_result[2]}} & bank_data[2]) |
                          ({9{read_bank_result[3]}} & bank_data[3]);
    wire [8:0] read_second=({9{read_bank_result[4]}} & bank_data[4]) |
                           ({9{read_bank_result[5]}} & bank_data[5]) |
                           ({9{read_bank_result[6]}} & bank_data[6]) |
                           ({9{read_bank_result[7]}} & bank_data[7]);
    generate if(SPLIT_RETURN)begin:split_return
        // Both E3 gathers are already onehot-masked; the inactive half is zero.
        // The final two-input OR uses the existing E3-to-E4 response window.
        (* preserve=1,dont_merge=1 *) reg [8:0] first_half,second_half;
        always @(posedge clk)begin first_half<=read_first;second_half<=read_second;end
        assign read_data=first_half | second_half;
    end else begin:single_return
        reg [8:0] result;
        always @(posedge clk)result<=read_first | read_second;
        assign read_data=result;
    end endgenerate
endmodule

module afdx_app_payload_bank (
    input wire clk,reset,write_enable,
    input wire [11:0] write_address,
    input wire [8:0] write_data,
    input wire read_enable,read_select,
    input wire [11:0] read_address,
    output wire [8:0] read_data
);
    (* preserve=1,dont_merge=1 *) reg write_q;
    (* preserve=1,dont_merge=1 *) reg [11:0] address_q;
    (* preserve=1,dont_merge=1 *) reg [8:0] data_q;
    (* preserve=1,dont_merge=1 *) reg read_command_q,read_select_q;
    (* preserve=1,dont_merge=1 *) reg [11:0] read_address_q;
    (* preserve=1,dont_merge=1 *) reg [3:0] read_slice_ram,read_slice_result;
    always @(posedge clk)begin
        if(reset)begin write_q<=0;read_command_q<=0;read_select_q<=0;end
        else begin
            write_q<=write_enable;read_command_q<=read_enable;read_select_q<=read_select;
        end
        address_q<=write_address;data_q<=write_data;
        read_address_q<=read_address;
        read_slice_ram<=4'b0001<<read_address_q[11:10];
        read_slice_result<=read_slice_ram;
    end
    wire [8:0] slice_data[0:3];
    genvar s;
    generate for(s=0;s<4;s=s+1)begin:slice
        afdx_app_payload_slice storage(
            .clk(clk),
            .write_enable(write_q && address_q[11:10]==s),
            .write_address(address_q[9:0]),.write_data(data_q),
            .read_enable(read_command_q && read_select_q && read_address_q[11:10]==s),
            .read_address(read_address_q[9:0]),.read_data(slice_data[s]));
    end endgenerate
    assign read_data=({9{read_slice_result[0]}} & slice_data[0]) |
                     ({9{read_slice_result[1]}} & slice_data[1]) |
                     ({9{read_slice_result[2]}} & slice_data[2]) |
                     ({9{read_slice_result[3]}} & slice_data[3]);
endmodule

module afdx_app_payload_slice (
    input wire clk,write_enable,
    input wire [9:0] write_address,
    input wire [8:0] write_data,
    input wire read_enable,
    input wire [9:0] read_address,
    output wire [8:0] read_data
);
    (* ramstyle = "no_rw_check" *) reg [8:0] memory[0:1023];
    reg [8:0] ram_q;
    // Keep write-data isolation inside each independent RAM module.
    always @(posedge clk)if(write_enable)
        memory[write_address]<=write_enable ? write_data : 9'b0;
    always @(posedge clk)if(read_enable)ram_q<=memory[read_address];
    (* preserve=1,dont_merge=1 *) reg [8:0] result_q;
    always @(posedge clk)result_q<=ram_q;
    assign read_data=result_q;
endmodule
