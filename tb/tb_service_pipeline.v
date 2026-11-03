`timescale 1ns/1ps
// Four pending TX messages with backpressure, then one claimed and one
// application RX message. Checks transactions across the new boundaries.
module tb_service_pipeline;
    reg clk=0,reset=1;
    always #4 clk=~clk;
    integer sent[0:3];
    integer received[0:3];
    integer cycles=0,checks=0,errors=0,tx_messages=0,owner=-1;
    integer rx_messages=0,rx_bytes=0,app_bytes=0;
    integer k,j;
    reg m_ready=0;
    wire app_tx_valid=sent[0]<4;
    wire app_tx_ready;
    wire [7:0] app_tx_data=8'h10+sent[0];
    wire app_tx_last=sent[0]==3;
    wire [2:0] svc_tx_ready;
    reg [2:0] svc_tx_valid,svc_tx_last;
    reg [23:0] svc_tx_data;
    reg [20:0] svc_tx_vl;
    reg [47:0] svc_tx_sport,svc_tx_dport;
    wire m_valid,m_last,m_port_en;
    wire [7:0] m_data;
    wire [6:0] m_vl;
    wire [15:0] m_sport,m_dport;
    reg d_valid=0,d_last=0,d_net=0;
    reg [7:0] d_data=0;
    reg [11:0] d_vl=0;
    reg [15:0] d_sport=0,d_dport=0;
    wire svc_rx_valid,svc_rx_last,svc_rx_net,app_rx_valid,app_rx_last,app_rx_net;
    wire [7:0] svc_rx_data,app_rx_data;
    wire [11:0] svc_rx_vl,app_rx_vl;
    wire [15:0] svc_rx_sport,svc_rx_dport,app_rx_sport,app_rx_dport;
    reg port_stage=0,port_match=0;
    reg [15:0] port_history0=0,port_history1=0,port_history2=0;
    reg rx_was_valid=0;
    afdx_svc dut(
        .clk(clk),.reset(reset),
        .app_tx_valid(app_tx_valid),.app_tx_ready(app_tx_ready),.app_tx_data(app_tx_data),.app_tx_last(app_tx_last),
        .app_tx_vl(7'd1),.app_tx_port_en(1'b1),.app_tx_sport(16'd1000),.app_tx_dport(16'd2000),
        .svc_tx_valid(svc_tx_valid),.svc_tx_ready(svc_tx_ready),.svc_tx_data(svc_tx_data),.svc_tx_last(svc_tx_last),
        .svc_tx_vl(svc_tx_vl),.svc_tx_port_en(3'b111),.svc_tx_sport(svc_tx_sport),.svc_tx_dport(svc_tx_dport),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_last(m_last),.m_vl(m_vl),.m_port_en(m_port_en),.m_sport(m_sport),.m_dport(m_dport),
        .d_valid(d_valid),.d_data(d_data),.d_last(d_last),.d_vl(d_vl),.d_sport(d_sport),.d_dport(d_dport),.d_net(d_net),
        .svc_rx_claim({2'b00,port_match}),.svc_rx_valid(svc_rx_valid),.svc_rx_data(svc_rx_data),.svc_rx_last(svc_rx_last),
        .svc_rx_vl(svc_rx_vl),.svc_rx_sport(svc_rx_sport),.svc_rx_dport(svc_rx_dport),.svc_rx_net(svc_rx_net),
        .app_rx_valid(app_rx_valid),.app_rx_data(app_rx_data),.app_rx_last(app_rx_last),.app_rx_vl(app_rx_vl),
        .app_rx_sport(app_rx_sport),.app_rx_dport(app_rx_dport),.app_rx_net(app_rx_net),
        .snmp_rx_valid(),.snmp_rx_data(),.snmp_rx_last(),.snmp_rx_sport(),.snmp_rx_dport(),
        .load_rx_valid(),.load_rx_data(),.load_rx_last(),.load_rx_sport(),.load_rx_dport());
    always @* begin
        for(j=0;j<3;j=j+1) begin
            svc_tx_valid[j]=sent[j+1]<4;
            svc_tx_last[j]=sent[j+1]==3;
            svc_tx_data[j*8+:8]=(j+2)*16+sent[j+1];
            svc_tx_vl[j*7+:7]=j+2;
            svc_tx_sport[j*16+:16]=1001+j;
            svc_tx_dport[j*16+:16]=2001+j;
        end
    end
    task check;
        input condition;
        input [511:0] message;
        begin checks=checks+1;if(condition!==1'b1) begin errors=errors+1;$display("FAIL %0s",message);end end
    endtask
    always @(negedge clk) if(!reset) m_ready=(cycles%5)!=1;
    always @(posedge clk) begin
        if(reset) begin port_stage<=0;port_match<=0;end
        else begin port_stage<=svc_rx_dport==16'd9000;port_match<=port_stage;end
        if(!reset) begin
            cycles=cycles+1;
            if(app_tx_valid && app_tx_ready) sent[0]<=sent[0]+1;
            for(k=0;k<3;k=k+1) if(svc_tx_valid[k] && svc_tx_ready[k]) sent[k+1]<=sent[k+1]+1;
            if(m_valid && m_ready) begin
                check(m_vl>=1 && m_vl<=4,"TX source VL");
                if(m_vl>=1 && m_vl<=4) begin
                    if(owner<0) begin owner=m_vl-1;check(owner==tx_messages,"round-robin message order");end
                    check(owner==m_vl-1,"TX source changed inside a message");
                    check(m_data==((owner+1)*16+received[owner]),"TX payload sequence");
                    check(m_sport==1000+owner && m_dport==2000+owner && m_port_en,"TX metadata");
                    check(m_last==(received[owner]==3),"TX last byte");
                    received[owner]=received[owner]+1;
                    if(m_last) begin tx_messages=tx_messages+1;owner=-1;end
                end
            end
            if(svc_rx_valid) begin
                if(!rx_was_valid) check(svc_rx_dport==port_history0 && svc_rx_dport==port_history1 && svc_rx_dport==port_history2,"RX metadata lead through service register");
                check(svc_rx_data==((rx_messages==0 ? 8'ha0 : 8'hb0)+rx_bytes),"service RX payload");
                check(svc_rx_vl==5+rx_messages && svc_rx_sport==16'd3000 && svc_rx_dport==(rx_messages==0 ? 16'd9000 : 16'd1234),"service RX metadata");
                check(svc_rx_last==(rx_bytes==3),"service RX last byte");
                if(svc_rx_last) begin rx_messages=rx_messages+1;rx_bytes=0;end
                else rx_bytes=rx_bytes+1;
            end
            if(app_rx_valid) begin
                check(app_rx_data==8'hb0+app_bytes,"application receives only unclaimed payload");
                check(app_rx_vl==6 && app_rx_dport==1234 && app_rx_sport==3000,"application RX metadata");
                check(app_rx_last==(app_bytes==3),"application RX last byte");
                app_bytes=app_bytes+1;
            end
            rx_was_valid=svc_rx_valid;
            port_history2=port_history1;port_history1=port_history0;port_history0=svc_rx_dport;
        end
    end
    task packet;
        input claimed;
        integer n;
        begin
            @(negedge clk);d_vl=claimed ? 5 : 6;d_sport=3000;d_dport=claimed ? 9000 : 1234;
            repeat(3) @(negedge clk);
            for(n=0;n<4;n=n+1) begin
                d_valid=1;d_last=n==3;d_data=(claimed ? 8'ha0 : 8'hb0)+n;
                @(negedge clk);
            end
            d_valid=0;d_last=0;
            repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        for(k=0;k<4;k=k+1) begin sent[k]=0;received[k]=0;end
        repeat(4) @(negedge clk);reset=0;
        packet(1);packet(0);
        repeat(60) @(negedge clk);
        check(tx_messages==4 && rx_messages==2 && app_bytes==4,"all messages completed");
        for(k=0;k<4;k=k+1) check(sent[k]==4 && received[k]==4,"all source bytes accepted once");
        $display("[RESULT] tb_service_pipeline %0s checks=%0d errors=%0d",errors==0 ? "PASS" : "FAIL",checks,errors);
        if(errors) $finish;
        $finish;
    end
endmodule
