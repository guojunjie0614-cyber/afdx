// Reconstructed RM-04 experiment; the historical source was not available.
// New deterministic vectors and an independent checker live in
// tools/gbe_rm_psn_ref.py. This does not reproduce the report's old counts.
`timescale 1ns/1ps
module tb_gbe_rm_psn;
    rx_core_suite #(.NAME("tb_gbe_rm_psn")) suite();
    integer probe;
    reg old_a=0,old_b=0;
    initial probe=$fopen("rm_psn_probe.txt","w");
    // Internal observations establish arbitration coverage only. They never
    // determine expected delivery, IC or RM outcomes in the reference model.
    always @(posedge suite.clk)begin
        #2;
        if(suite.reset)begin old_a=0;old_b=0;end
        else if(suite.init_done)begin
            if(suite.dut.take_a || suite.dut.take_b)
                $fwrite(probe,"T %0d %s\n",suite.cycle,suite.dut.take_b?"B":"A");
            if((suite.dut.da_valid[0] && !old_a) || (suite.dut.db_valid[0] && !old_b))
                $fwrite(probe,"B %0d %0d\n",suite.cycle,suite.dut.engine.op!=4'b0010);
            if(suite.dut.take_a || suite.dut.take_b ||
                (suite.dut.da_valid[0] && !old_a) || (suite.dut.db_valid[0] && !old_b))$fflush(probe);
            old_a=suite.dut.da_valid[0];old_b=suite.dut.db_valid[0];
        end
    end
endmodule
