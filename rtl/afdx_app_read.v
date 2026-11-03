// 同步 RAM 的连续预取队列；计入在途读，反压时保留已经发出的读。
module afdx_app_read #(parameter AW=12, parameter READ_LATENCY=1,
    parameter PREDICT_LIMIT=0) (
    input wire clk, reset,
    input wire [AW:0] limit,
    output reg [AW:0] pointer,
    output wire read_enable,
    output wire [AW-1:0] read_address,
    input wire [8:0] read_data,
    output wire valid,
    input wire ready,
    output wire [8:0] data,
    // Used only with PREDICT_LIMIT=1: caller supplies the limit value that
    // its producer will publish on this same edge. Default mode ignores it.
    input wire [AW:0] next_limit
);
    // Exactly eight credits cover pending reads, queued bytes, BOTH output
    // slots and one accepted take awaiting local retirement. At every edge:
    // reserved = popcount(pending) + queued + output_count + take_q.
    // A remote take is captured first and returns its credit one clock later;
    // moving bytes between the local stages never returns a credit.
    reg [READ_LATENCY-1:0] pending;
    integer stage;
    wire response = pending[READ_LATENCY-1];
    reg [3:0] reserved, queued;
    reg [2:0] wr, rd;
    reg [8:0] bytes[0:7];
    wire available;
    wire issue = available && reserved < 8;
    wire [AW:0] pointer_step=pointer+{{AW{1'b0}},1'b1};
    generate if(PREDICT_LIMIT)begin:predict_limit
        (* preserve=1,dont_merge=1 *) reg available_q;
        // Compare both possible local pointers before selecting by issue.
        // After this edge available_q == (new pointer != new real limit).
        wire current_available=pointer!=next_limit;
        wire step_available=pointer_step!=next_limit;
        always @(posedge clk)begin
            if(reset)available_q<=0;
            else available_q<=issue?step_available:current_available;
        end
        assign available=available_q;
    end else begin:current_limit
        assign available=pointer!=limit;
    end endgenerate
    assign read_enable = issue;
    assign read_address = pointer[AW-1:0];
    // Explicit FF slots preserve the RAM-to-output register boundary. Only
    // local occupancy enables their data FFs: remote ready terminates at the
    // small output count/read selector rather than feeding data/queue enables.
    reg [8:0] output0,output1;
    reg output_wr,output_rd;
    reg [1:0] output_count;
    assign valid=output_count!=0;
    assign data=output_rd?output1:output0;
    wire take = valid && ready;
    (* preserve=1,dont_merge=1 *) reg take_q;
    wire refill = queued != 0 && output_count < 2;
    always @(posedge clk) begin
        if (reset) begin
            pointer<=0;pending<=0;reserved<=0;queued<=0;wr<=0;rd<=0;
            output0<=0;output1<=0;output_wr<=0;output_rd<=0;output_count<=0;take_q<=0;
        end else begin
            take_q<=take;
            pending[0]<=issue;
            for(stage=1;stage<READ_LATENCY;stage=stage+1)pending[stage]<=pending[stage-1];
            if(issue) pointer<=pointer_step;
            case({issue,take_q})
                2'b10:reserved<=reserved+1'b1;
                2'b01:reserved<=reserved-1'b1;
            endcase
            case({response,refill})
                2'b10:queued<=queued+1'b1;
                2'b01:queued<=queued-1'b1;
            endcase
            // Preserve the input-LUT isolation at this inferred queue RAM.
            if(response)begin bytes[wr]<=response ? read_data : 9'b0;wr<=wr+1'b1;end
            case({refill,take})
                2'b10:output_count<=output_count+1'b1;
                2'b01:output_count<=output_count-1'b1;
            endcase
            if(refill)begin
                if(output_wr)output1<=bytes[rd];else output0<=bytes[rd];
                output_wr<=!output_wr;rd<=rd+1'b1;
            end
            if(take)output_rd<=!output_rd;
        end
    end
endmodule
