// 同步 RAM 的连续预取队列；计入在途读，反压时保留已经发出的读。
module afdx_app_read #(parameter AW=12) (
    input wire clk, reset,
    input wire [AW:0] limit,
    output reg [AW:0] pointer,
    output wire read_enable,
    output wire [AW-1:0] read_address,
    input wire [8:0] read_data,
    output reg valid,
    input wire ready,
    output reg [8:0] data
);
    reg pending;
    reg [3:0] reserved, queued;
    reg [2:0] wr, rd;
    reg [8:0] bytes[0:7];
    assign read_enable = pointer != limit && reserved < 8;
    assign read_address = pointer[AW-1:0];
    // 输出寄存切断小队列 RAM 到下游核心的组合路径，允许每拍替换。
    wire take = valid && ready;
    wire refill = queued != 0 && (!valid || ready);
    always @(posedge clk) begin
        if (reset) begin
            pointer<=0;pending<=0;reserved<=0;queued<=0;wr<=0;rd<=0;valid<=0;data<=0;
        end else begin
            pending<=read_enable;
            if(read_enable) pointer<=pointer+1'b1;
            case({read_enable,take})
                2'b10:reserved<=reserved+1'b1;
                2'b01:reserved<=reserved-1'b1;
            endcase
            case({pending,refill})
                2'b10:queued<=queued+1'b1;
                2'b01:queued<=queued-1'b1;
            endcase
            if(pending)begin bytes[wr]<=read_data;wr<=wr+1'b1;end
            if(!valid || ready)begin
                valid<=refill;
                if(refill)begin data<=bytes[rd];rd<=rd+1'b1;end
            end
        end
    end
endmodule
