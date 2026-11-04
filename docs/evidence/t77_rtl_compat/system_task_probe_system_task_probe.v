module system_task_probe;
reg fail=0;
initial begin
if(fail) $finish_and_return(1);
$display("SYSTEM_TASK_PROBE_PASS");
$finish;
end
endmodule
