// T5 第0步：综合前端应选择直连分支，仿真前端选择反相分支。
module probe_synthesis_define(input wire data,output wire synthesis_defined,output wire result);
`ifdef SYNTHESIS
    assign synthesis_defined=1'b1;
    assign result=data;
`else
    assign synthesis_defined=1'b0;
    assign result=~data;
`endif
endmodule
