`timescale 1ns/1ps
// Compares current cfg against the renamed c857aba8361e7f9cea74801d4a4d908f49a76436 baseline.
// tools/run_1030_checks.py materializes that revision in the isolated run folder.
module tb_cfg_local_ready;
    reg clk, reset, tx_ready, cfg_wr, cfg_rd, mib_user_wr, host_read, tx_cfg_ok;
    reg [16:0] rx_ready_by_bank;
    reg [15:0] rx_cfg_ok, mib_user_wdata;
    reg [17:0] cfg_addr, cfg_write_addr, mib_read_addr;
    reg [31:0] cfg_wdata;
    reg [2:0] host_read_addr;
    reg [6:0] ev_tx;
    reg [7:0] ev_a, ev_b;
    reg ev_rm_drop, ev_deliver;
    reg [1:0] ev_gdrop;
    reg [31:0] rtc_rdata, rtc_sync_count, snmp_control_data, snmp_status_data;
    reg [31:0] snmp_descr_data, load_rdata, load_extra_data;
    wire cfg_ready_new, cfg_ready_old;
    wire cfg_rvalid_new, cfg_rvalid_old;
    wire cfg_ready_m_new, cfg_ready_m_old;
    wire [1:0] app_cfg_ready_new;
    wire service_ready_next;
    reg predicted_ready;
    wire [7:0] snmp_wr_sel_new, snmp_wr_sel_old;
    wire [6:0] loader_wr_sel_new, loader_wr_sel_old;
    wire [5:0] rtc_wr_sel_new, rtc_wr_sel_old;
    wire [31:0] cfg_rdata_new, cfg_rdata_old;
    wire [15:0] user_id_new, user_id_old;
    wire tx_cfg_we_new, tx_cfg_we_old;
    wire [9:0] tx_cfg_addr_new, tx_cfg_addr_old;
    wire [31:0] tx_cfg_wdata_new, tx_cfg_wdata_old;
    wire [15:0] rx_map_we_new, rx_map_we_old;
    wire rx_cfg_we_new, rx_cfg_we_old;
    wire [255:0] rx_cfg_addr_new, rx_cfg_addr_old;
    wire [511:0] rx_cfg_wdata_new, rx_cfg_wdata_old;
    afdx_cfg #(.RX_BUS_COPIES(16), .BANKED_READY(1)) new_dut (
        .clk(clk),
        .reset(reset),
        .tx_ready(tx_ready),
        .rx_ready_by_bank(rx_ready_by_bank),
        .cfg_wr(cfg_wr),
        .cfg_rd(cfg_rd),
        .cfg_addr(cfg_addr),
        .cfg_write_addr(cfg_write_addr),
        .cfg_wdata(cfg_wdata),
        .mib_user_wr(mib_user_wr),
        .mib_user_wdata(mib_user_wdata),
        .mib_read_addr(mib_read_addr),
        .host_read_addr(host_read_addr),
        .host_read(host_read),
        .tx_cfg_ok(tx_cfg_ok),
        .rx_cfg_ok(rx_cfg_ok),
        .ev_tx(ev_tx),
        .ev_a(ev_a),
        .ev_b(ev_b),
        .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver),
        .ev_gdrop(ev_gdrop),
        .rtc_rdata(rtc_rdata),
        .rtc_sync_count(rtc_sync_count),
        .snmp_control_data(snmp_control_data),
        .snmp_status_data(snmp_status_data),
        .snmp_descr_data(snmp_descr_data),
        .load_rdata(load_rdata),
        .load_extra_data(load_extra_data),
        .cfg_ready(cfg_ready_new),
        .cfg_rvalid(cfg_rvalid_new),
        .cfg_ready_m(cfg_ready_m_new),
        .app_cfg_ready(app_cfg_ready_new),
        .service_ready_next(service_ready_next),
        .service_ready_rx_term(),.service_ready_base(),
        .snmp_wr_sel(snmp_wr_sel_new),
        .loader_wr_sel(loader_wr_sel_new),
        .rtc_wr_sel(rtc_wr_sel_new),
        .cfg_rdata(cfg_rdata_new),
        .user_id(user_id_new),
        .tx_cfg_we(tx_cfg_we_new),
        .tx_cfg_addr(tx_cfg_addr_new),
        .tx_cfg_wdata(tx_cfg_wdata_new),
        .rx_map_we(rx_map_we_new),
        .rx_cfg_we(rx_cfg_we_new),
        .rx_cfg_addr(rx_cfg_addr_new),
        .rx_cfg_wdata(rx_cfg_wdata_new)
    );
    afdx_cfg_legacy #(.RX_BUS_COPIES(16), .BANKED_READY(1)) old_dut (
        .clk(clk),
        .reset(reset),
        .tx_ready(tx_ready),
        .rx_ready_by_bank(rx_ready_by_bank),
        .cfg_wr(cfg_wr),
        .cfg_rd(cfg_rd),
        .cfg_addr(cfg_addr),
        .cfg_write_addr(cfg_write_addr),
        .cfg_wdata(cfg_wdata),
        .mib_user_wr(mib_user_wr),
        .mib_user_wdata(mib_user_wdata),
        .mib_read_addr(mib_read_addr),
        .host_read_addr(host_read_addr),
        .host_read(host_read),
        .tx_cfg_ok(tx_cfg_ok),
        .rx_cfg_ok(rx_cfg_ok),
        .ev_tx(ev_tx),
        .ev_a(ev_a),
        .ev_b(ev_b),
        .ev_rm_drop(ev_rm_drop),
        .ev_deliver(ev_deliver),
        .ev_gdrop(ev_gdrop),
        .rtc_rdata(rtc_rdata),
        .rtc_sync_count(rtc_sync_count),
        .snmp_control_data(snmp_control_data),
        .snmp_status_data(snmp_status_data),
        .snmp_descr_data(snmp_descr_data),
        .load_rdata(load_rdata),
        .load_extra_data(load_extra_data),
        .cfg_ready(cfg_ready_old),
        .cfg_rvalid(cfg_rvalid_old),
        .cfg_ready_m(cfg_ready_m_old),
        .snmp_wr_sel(snmp_wr_sel_old),
        .loader_wr_sel(loader_wr_sel_old),
        .rtc_wr_sel(rtc_wr_sel_old),
        .cfg_rdata(cfg_rdata_old),
        .user_id(user_id_old),
        .tx_cfg_we(tx_cfg_we_old),
        .tx_cfg_addr(tx_cfg_addr_old),
        .tx_cfg_wdata(tx_cfg_wdata_old),
        .rx_map_we(rx_map_we_old),
        .rx_cfg_we(rx_cfg_we_old),
        .rx_cfg_addr(rx_cfg_addr_old),
        .rx_cfg_wdata(rx_cfg_wdata_old)
    );
    integer cycle, errors, reads, user_beats, tx_beats, rx_beats, map_beats;
    integer mib_beats, conflicts, resets, i;
    reg prev_read, checking;
    reg [31:0] rng;
    always #4 clk = ~clk;
    // Capture request/acceptance before the edge; check outputs after NBA.
    always @(posedge clk) begin
        predicted_ready = service_ready_next;
        cycle = cycle + 1;
        if (reset) begin prev_read = 0; resets = resets + 1; end
        else begin
            if (cfg_wr && cfg_ready_old) begin
                if (cfg_write_addr == 18'h2) user_beats = user_beats + 1;
                if (cfg_write_addr[17:10] == 8'h04) tx_beats = tx_beats + 1;
                if (cfg_write_addr[17:16] == 2'b01) map_beats = map_beats + 1;
                if (cfg_write_addr[17:12] == 6'b100000) rx_beats = rx_beats + 1;
            end
            if (mib_user_wr && cfg_wr) conflicts = conflicts + 1;
            if (mib_user_wr && !cfg_wr && cfg_ready_old) mib_beats = mib_beats + 1;
        end
        #1;
        if (checking) begin
            if (app_cfg_ready_new !== {2{cfg_ready_new}} || predicted_ready !== cfg_ready_new) begin
                $display("FAIL cycle=%0d application/service ready prediction apps=%b predicted=%b public=%b",cycle,app_cfg_ready_new,predicted_ready,cfg_ready_new);errors=errors+1;
            end
            if (cfg_ready_new !== cfg_ready_old) begin
                $display("FAIL cycle=%0d cfg_ready new=%h old=%h wr=%b addr=%h ready=%b", cycle, cfg_ready_new, cfg_ready_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (cfg_rvalid_new !== cfg_rvalid_old) begin
                $display("FAIL cycle=%0d cfg_rvalid new=%h old=%h wr=%b addr=%h ready=%b", cycle, cfg_rvalid_new, cfg_rvalid_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (cfg_ready_m_new !== cfg_ready_m_old) begin
                $display("FAIL cycle=%0d cfg_ready_m new=%h old=%h wr=%b addr=%h ready=%b", cycle, cfg_ready_m_new, cfg_ready_m_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (snmp_wr_sel_new !== snmp_wr_sel_old) begin
                $display("FAIL cycle=%0d snmp_wr_sel new=%h old=%h wr=%b addr=%h ready=%b", cycle, snmp_wr_sel_new, snmp_wr_sel_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (loader_wr_sel_new !== loader_wr_sel_old) begin
                $display("FAIL cycle=%0d loader_wr_sel new=%h old=%h wr=%b addr=%h ready=%b", cycle, loader_wr_sel_new, loader_wr_sel_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (rtc_wr_sel_new !== rtc_wr_sel_old) begin
                $display("FAIL cycle=%0d rtc_wr_sel new=%h old=%h wr=%b addr=%h ready=%b", cycle, rtc_wr_sel_new, rtc_wr_sel_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (cfg_rvalid_old === 1'b1 && cfg_rdata_new !== cfg_rdata_old) begin
                $display("FAIL cycle=%0d cfg_rdata new=%h old=%h", cycle, cfg_rdata_new, cfg_rdata_old); errors=errors+1;
            end
            if (user_id_new !== user_id_old) begin
                $display("FAIL cycle=%0d user_id new=%h old=%h wr=%b addr=%h ready=%b", cycle, user_id_new, user_id_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (tx_cfg_we_new !== tx_cfg_we_old) begin
                $display("FAIL cycle=%0d tx_cfg_we new=%h old=%h wr=%b addr=%h ready=%b", cycle, tx_cfg_we_new, tx_cfg_we_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (tx_cfg_addr_new !== tx_cfg_addr_old) begin
                $display("FAIL cycle=%0d tx_cfg_addr new=%h old=%h wr=%b addr=%h ready=%b", cycle, tx_cfg_addr_new, tx_cfg_addr_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (tx_cfg_wdata_new !== tx_cfg_wdata_old) begin
                $display("FAIL cycle=%0d tx_cfg_wdata new=%h old=%h wr=%b addr=%h ready=%b", cycle, tx_cfg_wdata_new, tx_cfg_wdata_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (rx_map_we_new !== rx_map_we_old) begin
                $display("FAIL cycle=%0d rx_map_we new=%h old=%h wr=%b addr=%h ready=%b", cycle, rx_map_we_new, rx_map_we_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (rx_cfg_we_new !== rx_cfg_we_old) begin
                $display("FAIL cycle=%0d rx_cfg_we new=%h old=%h wr=%b addr=%h ready=%b", cycle, rx_cfg_we_new, rx_cfg_we_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (rx_cfg_addr_new !== rx_cfg_addr_old) begin
                $display("FAIL cycle=%0d rx_cfg_addr new=%h old=%h wr=%b addr=%h ready=%b", cycle, rx_cfg_addr_new, rx_cfg_addr_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (rx_cfg_wdata_new !== rx_cfg_wdata_old) begin
                $display("FAIL cycle=%0d rx_cfg_wdata new=%h old=%h wr=%b addr=%h ready=%b", cycle, rx_cfg_wdata_new, rx_cfg_wdata_old, cfg_wr, cfg_write_addr, cfg_ready_old); errors=errors+1;
            end
            if (cfg_rvalid_old !== (reset ? 1'b0 : prev_read)) begin
                $display("FAIL cycle=%0d read latency actual=%b expected=%b", cycle, cfg_rvalid_old, reset ? 1'b0 : prev_read);
                errors=errors+1;
            end
            if (errors != 0) begin $display("[RESULT] tb_cfg_local_ready FAIL errors=%0d", errors); $finish; end
        end
        if (!reset) begin prev_read = cfg_rd; if (cfg_rd) reads = reads + 1; end
    end
    task idle_cycles;
        input integer count;
        integer n;
        begin for(n=0;n<count;n=n+1) @(negedge clk); end
    endtask
    task write_once;
        input [17:0] address;
        input [31:0] value;
        begin
            @(negedge clk); cfg_wr=1; cfg_write_addr=address; cfg_wdata=value;
            begin : wait_accept
                forever begin @(posedge clk); if (cfg_ready_old === 1'b1) disable wait_accept; end
            end
            @(negedge clk); cfg_wr=0;
        end
    endtask
    initial begin
        clk=0; reset=1; tx_ready=0; rx_ready_by_bank=0;
        cfg_wr=0; cfg_rd=0; cfg_addr=0; cfg_write_addr=0; cfg_wdata=0;
        mib_user_wr=0; mib_user_wdata=0; mib_read_addr=0; host_read_addr=0; host_read=0;
        tx_cfg_ok=0; rx_cfg_ok=0; ev_tx=0; ev_a=0; ev_b=0; ev_rm_drop=0; ev_deliver=0; ev_gdrop=0;
        rtc_rdata=32'h12345678; rtc_sync_count=32'h87654321; snmp_control_data=32'h12345678;
        snmp_status_data=32'hfedcba98; snmp_descr_data=32'habcd1234; load_rdata=32'h01234567; load_extra_data=32'h76543210;
        cycle=0; errors=0; reads=0; user_beats=0; tx_beats=0; rx_beats=0; map_beats=0; mib_beats=0; conflicts=0; resets=0;
        prev_read=0; checking=0; rng=32'h52af19c7;
        idle_cycles(3); checking=1; reset=0;
        idle_cycles(3); tx_ready=1; rx_ready_by_bank=17'h1ffff;
        idle_cycles(6);
        write_once(18'h2,32'h00001234);
        if (user_id_old !== 16'h1234) begin
            $display("[RESULT] FAIL accepted host user write got %h", user_id_old); $finish;
        end
        // Held request while TX pending; then acknowledge and allow rearm.
        write_once(18'h01003,32'h12345678);
        @(negedge clk); cfg_wr=1; cfg_write_addr=18'h10021; cfg_wdata=32'hcafebabe;
        idle_cycles(7); tx_cfg_ok=1; idle_cycles(6); cfg_wr=0; tx_cfg_ok=0;
        idle_cycles(4); rx_cfg_ok=16'hffff; idle_cycles(4); rx_cfg_ok=0;
        write_once(18'h20034,32'hdeadbeef);
        idle_cycles(6); rx_cfg_ok=16'hffff; idle_cycles(4); rx_cfg_ok=0;
        write_once(18'h10078,32'habcdef98);
        idle_cycles(5); rx_cfg_ok=16'hffff; idle_cycles(5); rx_cfg_ok=0;
        @(negedge clk); mib_user_wr=1; mib_user_wdata=16'h3344; idle_cycles(2);
        if (user_id_old !== 16'h3344) begin
            $display("[RESULT] FAIL MIB user write got %h", user_id_old); $finish;
        end
        cfg_wr=1; cfg_write_addr=18'h2; cfg_wdata=32'h5678; mib_user_wdata=16'hcafe;
        idle_cycles(2);
        if (user_id_old !== 16'h5678) begin
            $display("[RESULT] FAIL host/MIB priority got %h", user_id_old); $finish;
        end
        cfg_wr=0; mib_user_wr=0;
        // Host and MIB reads including a user ID snapshot and adjacent reads.
        @(negedge clk); host_read=1; cfg_rd=1; cfg_write_addr=18'h2;
        idle_cycles(1); cfg_write_addr=18'h0;
        idle_cycles(1); host_read=0; mib_read_addr=18'h2;
        idle_cycles(3); cfg_rd=0;
        // Reset while request is active and restore initialization.
        @(negedge clk); cfg_wr=1; cfg_write_addr=18'h20044; cfg_wdata=32'h55aa;
        idle_cycles(1); reset=1; idle_cycles(3); cfg_wr=0; reset=0;
        idle_cycles(6);
        // Deterministic mixed traffic with independent bank acknowledgements.
        for (i=0;i<6000;i=i+1) begin
            @(negedge clk);
            rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
            cfg_wr = rng[2:0] < 4; cfg_rd = rng[5:3] < 3; host_read=rng[6];
            case (rng[9:7])
              0: cfg_write_addr=18'h2;
              1: cfg_write_addr=18'h01000 | {8'b0,rng[19:10]};
              2,3: cfg_write_addr=18'h10000 | {2'b0,rng[25:10]};
              4,5: cfg_write_addr=18'h20000 | {6'b0,rng[21:10]};
              6: cfg_write_addr=18'h90 | {15'b0,rng[12:10]};
              default: cfg_write_addr=18'h0;
            endcase
            cfg_addr=cfg_write_addr; cfg_wdata=rng ^ (i * 32'h01010101);
            mib_user_wr=rng[10] && rng[15]; mib_user_wdata=rng[31:16];
            mib_read_addr={15'b0,rng[15:13]}; host_read_addr=rng[20:18];
            tx_cfg_ok=rng[16] && rng[19];
            rx_cfg_ok={16{rng[17]}} & (16'hffff >> rng[21:18]);
            ev_tx=rng[6:0]; ev_a=rng[15:8]; ev_b=rng[23:16];
            ev_rm_drop=rng[24]; ev_deliver=rng[25]; ev_gdrop=rng[27:26];
            // Each bank and data-ready source can independently drop/recover.
            if (i % 97 == 0) rx_ready_by_bank={rng[16:0]};
            if (i % 97 == 3) rx_ready_by_bank=17'h1ffff;
            if (i % 701 == 0) tx_ready=0;
            if (i % 701 == 3) tx_ready=1;
        end
        @(negedge clk); cfg_wr=0; cfg_rd=0; mib_user_wr=0;
        idle_cycles(5);
        if (user_beats==0 || tx_beats==0 || rx_beats==0 || map_beats==0 || mib_beats==0 || conflicts==0 || reads<100) begin
            $display("[RESULT] tb_cfg_local_ready FAIL insufficient coverage"); $finish;
        end
        $display("[RESULT] tb_cfg_local_ready PASS checks=%0d errors=%0d cycles=%0d user=%0d tx=%0d rx=%0d map=%0d mib=%0d conflicts=%0d reads=%0d reset_cycles=%0d",cycle,errors,cycle,user_beats,tx_beats,rx_beats,map_beats,mib_beats,conflicts,reads,resets);
        $finish;
    end
endmodule
