// T1固定规格包装；输入地址/数据/使能先寄存，RAM输出再寄存。
module probe_sdp #(parameter WIDTH=8,DEPTH=2048,AW=11)(
input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [WIDTH-1:0] write_data,
 output wire [WIDTH-1:0] read_data
);
 reg [AW-1:0] wa,ra;reg we,re;
 reg [WIDTH-1:0] wd,q_out;
 wire [WIDTH-1:0] q;
 always @(posedge clk)begin wa<=write_address[AW-1:0];ra<=read_address[AW-1:0];we<=write_enable;re<=read_enable;wd<=write_data;q_out<=q;end
 afdx_ram_sdp #(.WIDTH(WIDTH),.DEPTH(DEPTH)) mem(clk,we,wa,wd,re,ra,q);
 assign read_data=q_out;
endmodule

module probe_p1_2048x8(input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [7:0] write_data,
 output wire [7:0] read_data);
 probe_sdp #(8,2048,11) u(clk,write_enable,read_enable,write_address,read_address,write_data,read_data);
endmodule

module probe_p1_128x32(input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [31:0] write_data,
 output wire [31:0] read_data);
 probe_sdp #(32,128,7) u(clk,write_enable,read_enable,write_address,read_address,write_data,read_data);
endmodule

module probe_p1_4096x44(input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [43:0] write_data,
 output wire [43:0] read_data);
 probe_sdp #(44,4096,12) u(clk,write_enable,read_enable,write_address,read_address,write_data,read_data);
endmodule

module probe_p1_4096x13(input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [12:0] write_data,
 output wire [12:0] read_data);
 probe_sdp #(13,4096,12) u(clk,write_enable,read_enable,write_address,read_address,write_data,read_data);
endmodule

module probe_p2_array(input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,
 input wire [12:0] write_data,
 output wire [12:0] read_data);
 probe_sdp #(13,65536,16) u(clk,write_enable,read_enable,write_address,read_address,write_data,read_data);
endmodule

module probe_p3_banks(
 input wire clk,write_enable,read_enable,
 input wire [15:0] write_address,read_address,input wire [12:0] write_data,
 output reg [12:0] read_data
);
 reg [15:0] wa,ra;reg we,re;reg [12:0] wd;
 reg [3:0] select1,select2;reg enable1,enable2;
 wire [12:0] bank_data[0:15];
 reg [12:0] bank_hold[0:15];
 genvar bank;
 always @(posedge clk)begin
  wa<=write_address;ra<=read_address;we<=write_enable;re<=read_enable;wd<=write_data;
  select1<=ra[15:12];select2<=select1;enable1<=re;enable2<=enable1;
  if(enable2)read_data<=bank_hold[select2];
 end
 generate for(bank=0;bank<16;bank=bank+1)begin:banks
  afdx_ram_sdp #(13,4096) mem(
   .clk(clk),.write_enable(we && wa[15:12]==bank),.write_address(wa[11:0]),.write_data(wd),
   .read_enable(re),.read_address(ra[11:0]),.read_data(bank_data[bank])
  );
  always @(posedge clk)bank_hold[bank]<=bank_data[bank];
 end endgenerate
 // 单级16选1仅是T1指定的比较探测，后续产品遵守ARCH第9节两拍选择。
endmodule

// 两种减法探测共用寄存的地址、数据、使能和减数，避免漏计外部组合选择。
module probe_p4_staged(
 input wire clk,write_enable,read_enable,input wire [6:0] write_address,read_address,
 input wire [31:0] write_data,subtract,output reg [31:0] read_data
);
 reg [6:0] wa,ra;reg we,re,enable1;
 reg [31:0] wd,sub0,sub1;
 wire [31:0] q;
 always @(posedge clk)begin
  wa<=write_address;ra<=read_address;we<=write_enable;re<=read_enable;wd<=write_data;
  sub0<=subtract;sub1<=sub0;enable1<=re;
  if(enable1)read_data<=q-sub1;
 end
 afdx_ram_sdp #(32,128) mem(clk,we,wa,wd,re,ra,q);
endmodule

module probe_p4_direct(
 input wire clk,write_enable,read_enable,input wire [6:0] write_address,read_address,
 input wire [31:0] write_data,subtract,output reg [31:0] read_data
);
 reg [6:0] wa,ra;reg we,re;
 reg [31:0] wd,sub0;
 reg [31:0] memory[0:127];
 always @(posedge clk)begin
  wa<=write_address;ra<=read_address;we<=write_enable;re<=read_enable;wd<=write_data;sub0<=subtract;
 end
 always @(posedge clk)if(we)memory[wa]<=wd;
 always @(posedge clk)if(re)read_data<=memory[ra]-sub0;
endmodule

module probe_p5_zero(
 input wire clk,write_enable,read_enable,input wire [10:0] write_address,read_address,
 input wire [7:0] write_data,output reg [7:0] read_data
);
 reg [7:0] memory[0:2047];
 integer i;
 initial for(i=0;i<2048;i=i+1)memory[i]=0;
 always @(posedge clk)if(write_enable)memory[write_address]<=write_data;
 always @(posedge clk)if(read_enable)read_data<=memory[read_address];
endmodule

module probe_p5_readmemh(
 input wire clk,write_enable,read_enable,input wire [10:0] write_address,read_address,
 input wire [7:0] write_data,output reg [7:0] read_data
);
 reg [7:0] memory[0:2047];
 initial $readmemh("init_probe.hex",memory);
 always @(posedge clk)if(write_enable)memory[write_address]<=write_data;
 always @(posedge clk)if(read_enable)read_data<=memory[read_address];
endmodule
