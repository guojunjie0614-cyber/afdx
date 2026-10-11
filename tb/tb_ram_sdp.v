// 验证四种 RAM 宽度/深度的写入、同步读延迟和禁读保持；对应载荷及 VL 表的基础存储契约。
// 通过条件：全部自检完成且最终 [RESULT] 为 PASS、errors=0；超时或任一不一致均失败。
`timescale 1ns/1ps
module ram_sdp_case #(parameter WIDTH=8,DEPTH=2048,AW=11)(
 input wire clk,output reg done,output reg [31:0] checks,errors
);
 reg write_enable=0,read_enable=0;
 reg [AW-1:0] write_address=0,read_address=0;
 reg [WIDTH-1:0] write_data=0;
 wire [WIDTH-1:0] read_data;
 reg [WIDTH-1:0] previous;
 reg previous_valid=0;
 integer i,k;
 afdx_ram_sdp #(.WIDTH(WIDTH),.DEPTH(DEPTH)) dut(
  .clk(clk),.write_enable(write_enable),.write_address(write_address),.write_data(write_data),
  .read_enable(read_enable),.read_address(read_address),.read_data(read_data)
 );
 function [WIDTH-1:0] pattern;
  input integer address;
  begin pattern=64'hc35a96e74d21b80f ^ (address*64'h9e3779b97f4a7c15);end
 endfunction
 task check_value;
  input [WIDTH-1:0] actual,expected;
  begin
   checks=checks+1;
   if(actual!==expected)begin
    errors=errors+1;$display("RAM mismatch width=%0d depth=%0d address=%0d got=%h expected=%h",WIDTH,DEPTH,i,actual,expected);
   end
  end
 endtask
 task read_one;
  input integer address;
  begin
   @(negedge clk);read_enable=1;read_address=address;
   #1;if(previous_valid)check_value(read_data,previous); // 边沿前不能提前变化。
   @(posedge clk);#1;check_value(read_data,pattern(address)); // 恰好一拍同步读。
   previous=pattern(address);previous_valid=1;
  end
 endtask
 initial begin
  done=0;checks=0;errors=0;
  for(i=0;i<DEPTH;i=i+1)begin
   @(negedge clk);write_enable=1;write_address=i;write_data=pattern(i);
   @(posedge clk);#1;
  end
  @(negedge clk);write_enable=0;
  for(i=0;i<DEPTH;i=i+1)read_one(i);
  @(negedge clk);read_enable=0;
  for(k=0;k<4;k=k+1)begin
   read_address=k;@(posedge clk);#1;check_value(read_data,previous);
   @(negedge clk);
  end
  // 禁写时给出不同数据，最低/最高地址原内容都必须保持。
  write_address=0;write_data=~pattern(0);write_enable=0;
  @(posedge clk);#1;@(negedge clk);write_address=DEPTH-1;write_data=~pattern(DEPTH-1);
  @(posedge clk);#1;read_one(0);read_one(DEPTH-1);
  @(negedge clk);read_enable=0;done=1;
 end
endmodule

module tb_ram_sdp;
 reg clk=0;always #4 clk=~clk;
 wire [3:0] done;
 wire [31:0] c0,c1,c2,c3,e0,e1,e2,e3;
 ram_sdp_case #(8,2048,11) a(clk,done[0],c0,e0);
 ram_sdp_case #(32,128,7) b(clk,done[1],c1,e1);
 ram_sdp_case #(44,4096,12) c(clk,done[2],c2,e2);
 ram_sdp_case #(13,4096,12) d(clk,done[3],c3,e3);
 initial begin
  wait(&done);
  if(e0+e1+e2+e3==0)$display("[RESULT] tb_ram_sdp PASS checks=%0d errors=0",c0+c1+c2+c3);
  else $display("[RESULT] tb_ram_sdp FAIL checks=%0d errors=%0d",c0+c1+c2+c3,e0+e1+e2+e3);
  $finish;
 end
 initial begin
  #2000000;$display("[RESULT] tb_ram_sdp FAIL checks=0 errors=1 timeout");$finish;
 end
endmodule
