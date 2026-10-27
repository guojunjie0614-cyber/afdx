// 连续交付流直通输出，先插入 VLID。消息开始预留最大载荷，保证不输出半条。
// 每帧 GMII 开销至少 66 拍，应用封装增加 2 字节和 1 拍间隔，平均服务速率有余量。
module afdx_app_rx (
    input wire clk,reset,
    input wire cfg_write,
    input wire [11:0] cfg_index,
    input wire [15:0] cfg_vlid,
    input wire app_valid,
    input wire [7:0] app_data,
    input wire app_last,
    input wire [11:0] app_index,
    output reg valid,
    output reg [7:0] data,
    output reg drop
);
    reg active,discard;
    reg [12:0] write_ptr;
    wire [12:0] read_ptr;
    wire [12:0] used=write_ptr-read_ptr;
    reg [5:0] dw,dr;
    wire [5:0] descriptors=dw-dr;
    wire first=app_valid && !active;
    reg reject;
    always @(posedge clk)begin
        if(reset)reject<=1'b1;
        else reject<=used>2624 || descriptors>=30;
    end
    wire store=app_valid && (active?!discard:!reject);
    wire [15:0] map_q;
    wire map_collision=cfg_write && cfg_index==app_index;
    reg map_bypass;
    reg [15:0] map_write_value;
    afdx_app_map reverse_map(
        .clk(clk),.write_enable(cfg_write),.write_address(cfg_index),.write_data(cfg_vlid),
        .read_enable(1'b1),.read_address(app_index),.read_data(map_q));
    reg map_pending;
    reg [2:0] state;
    wire q_valid,q_ready;
    wire [15:0] descriptor_id;
    afdx_ram_sdp #(.WIDTH(16),.DEPTH(32)) descriptor_ids(
        .clk(clk),.write_enable(map_pending),.write_address(dw[4:0]),.write_data(map_bypass?map_write_value:map_q),
        .read_enable(state==0 && descriptors!=0 && q_valid),.read_address(dr[4:0]),.read_data(descriptor_id));
    wire read_en;
    wire [11:0] read_addr;
    wire [8:0] memory_q;
    afdx_app_map #(.WIDTH(9)) payload(
        .clk(clk),.write_enable(store),.write_address(write_ptr[11:0]),.write_data({app_last,app_data}),
        .read_enable(read_en),.read_address(read_addr),.read_data(memory_q));
    wire [8:0] q_data;
    afdx_app_read reader(clk,reset,write_ptr,read_ptr,read_en,read_addr,memory_q,q_valid,q_ready,q_data);
    always @(posedge clk)begin
        if(reset)begin active<=0;discard<=0;write_ptr<=0;dw<=0;map_pending<=0;drop<=0;map_bypass<=0;map_write_value<=0;end
        else begin
            drop<=first && reject;
            map_pending<=first && !reject;
            map_bypass<=map_collision;map_write_value<=cfg_vlid;
            if(map_pending)dw<=dw+1'b1;
            if(app_valid)begin
                active<=!app_last;
                if(first)discard<=reject;
            end
            if(store)write_ptr<=write_ptr+1'b1;
        end
    end
    reg [15:0] id;
    assign q_ready=state==3;
    always @(posedge clk)begin
        if(reset)begin state<=0;id<=0;dr<=0;valid<=0;data<=0;end
        else begin
            valid<=0;data<=0;
            case(state)
                0:if(descriptors!=0 && q_valid)state<=5;
                5:begin id<=descriptor_id;state<=1;end
                1:begin valid<=1;data<=id[15:8];state<=2;end
                2:begin valid<=1;data<=id[7:0];state<=3;end
                3:if(q_valid)begin
                    valid<=1;data<=q_data[7:0];
                    if(q_data[8])begin dr<=dr+1'b1;state<=4;end
                end
                4:state<=0;
                default:state<=0;
            endcase
        end
    end
endmodule
