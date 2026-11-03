`timescale 1ns/1ps
// Two-slot protocol scoreboard: stalls, bubbles, full occupancy, push/pop and
// reset flush. Unaccepted input words vary to exercise empty-slot pre-capture.
module tb_tx_ingress_elastic;
    reg clk=0;
    always #4 clk=~clk;
    reg reset=1,s_valid=0,m_ready=0;
    reg [48:0] s_word=0;
    wire s_ready,m_valid;
    wire [48:0] m_word;
    afdx_tx_ingress_elastic dut(.clk(clk),.reset(reset),.s_valid(s_valid),
        .s_ready(s_ready),.s_word(s_word),.m_valid(m_valid),.m_ready(m_ready),.m_word(m_word));
    reg [48:0] expected[0:32767];
    reg [31:0] rng=32'h13c5e8a7;
    reg [48:0] saved_skid;
    reg old_skid;
    integer rd=0,wr=0,count=0,checks=0,errors=0,i;
    integer full_cycles=0,simultaneous=0,stalled=0,reset_full=0;
    task verify;
        input condition;
        begin
            checks=checks+1;
            if(condition!==1'b1)begin
                errors=errors+1;
                $display("[FAIL] ingress cycle=%0d occupancy=%0d",i,count);
                if(errors==8)$fatal(1,"ingress scoreboard");
            end
        end
    endtask
    task step;
        begin
            old_skid=dut.skid_valid;
            saved_skid=dut.skid_word;
            @(posedge clk);
            if(reset)begin
                if(count==2)reset_full=reset_full+1;
                rd=0;wr=0;count=0;
            end else begin
                verify(m_valid==(count!=0));
                if(m_valid)verify(m_word===expected[rd]);
                if(m_valid && !m_ready)stalled=stalled+1;
                if(count==2)full_cycles=full_cycles+1;
                if(m_valid && m_ready && s_valid && s_ready)simultaneous=simultaneous+1;
                if(m_valid && m_ready)begin rd=rd+1;count=count-1;end
                if(s_valid && s_ready)begin
                    expected[wr]=s_word;wr=wr+1;count=count+1;
                end
                verify(count>=0 && count<=2);
            end
            #1;
            verify(m_valid==(count!=0));
            if(m_valid)verify(m_word===expected[rd]);
            verify(s_ready===!dut.skid_valid);
            if(!reset && old_skid)verify(dut.skid_word===saved_skid);
            @(negedge clk);
        end
    endtask
    initial begin
        @(negedge clk);step;
        for(i=0;i<24000;i=i+1)begin
            reset=(i==0 || i==102 || i==12002);
            rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            if(i<100 || (i>=12000 && i<12002))begin
                s_valid=1;m_ready=0;
            end else if(i<200)begin
                s_valid=1;m_ready=1;
            end else begin
                // Keep an offered valid word stable until its handshake.
                if(!s_valid || s_ready)begin
                    s_valid=rng[1] | rng[3];
                    s_word={rng[16:0],rng^32'h9e3779b9};
                end
                m_ready=rng[7] | rng[11];
            end
            step;
        end
        reset=0;s_valid=0;m_ready=1;
        repeat(4)step;
        verify(count==0 && full_cycles>100 && simultaneous>100 && stalled>100 && reset_full>0);
        $display("[RESULT] tb_tx_ingress_elastic %s checks=%0d errors=%0d full=%0d simultaneous=%0d stalled=%0d reset_full=%0d",
            errors==0?"PASS":"FAIL",checks,errors,full_cycles,simultaneous,stalled,reset_full);
        if(errors)$fatal(1,"ingress scoreboard");
        $finish;
    end
endmodule
