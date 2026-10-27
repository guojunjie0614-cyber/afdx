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
    wire reject=used>2625 || descriptors>=31;
    wire store=app_valid && (active?!discard:!reject);
    wire [15:0] map_q;
    afdx_ram_sdp #(.WIDTH(16),.DEPTH(4096)) reverse_map(
        .clk(clk),.write_enable(cfg_write),.write_address(cfg_index),.write_data(cfg_vlid),
        .read_enable(first && !reject),.read_address(app_index),.read_data(map_q));
    reg map_pending;
    reg [15:0] ids[0:31];
    wire read_en;
    wire [11:0] read_addr;
    wire [8:0] memory_q;
    afdx_ram_sdp #(.WIDTH(9),.DEPTH(4096)) payload(
        .clk(clk),.write_enable(store),.write_address(write_ptr[11:0]),.write_data({app_last,app_data}),
        .read_enable(read_en),.read_address(read_addr),.read_data(memory_q));
    wire q_valid,q_ready;
    wire [8:0] q_data;
    afdx_app_read reader(clk,reset,write_ptr,read_ptr,read_en,read_addr,memory_q,q_valid,q_ready,q_data);
    always @(posedge clk)begin
        if(reset)begin active<=0;discard<=0;write_ptr<=0;dw<=0;map_pending<=0;drop<=0;end
        else begin
            drop<=first && reject;
            map_pending<=first && !reject;
            if(map_pending)begin ids[dw[4:0]]<=map_q;dw<=dw+1'b1;end
            if(app_valid)begin
                active<=!app_last;
                if(first)discard<=reject;
            end
            if(store)write_ptr<=write_ptr+1'b1;
        end
    end
    reg [2:0] state;
    reg [15:0] id;
    assign q_ready=state==3;
    always @(posedge clk)begin
        if(reset)begin state<=0;id<=0;dr<=0;valid<=0;data<=0;end
        else begin
            valid<=0;data<=0;
            case(state)
                0:if(descriptors!=0 && q_valid)begin id<=ids[dr[4:0]];state<=1;end
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
