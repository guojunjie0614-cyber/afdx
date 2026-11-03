// Two independently controlled eight-row banks. Query latency is nineteen
// clocks; byte streams start only after the explicit prepared acknowledgement.
module afdx_rx_reassembly #(
    parameter CONTEXTS=16, TIMEOUT_CYCLES=250000000, BANK_CTRL_COPIES=0
)(
    input wire clk, reset,
    input wire query, reserve, cancel,
    input wire [(BANK_CTRL_COPIES ? 2 : 1)-1:0] query_bank, reserve_bank, cancel_bank,
    input wire [11:0] r_vl,
    input wire [125:0] r_meta, input wire [10:0] r_length,
    input wire [15:0] r_sport, r_dport, input wire r_net,
    output reg result_valid, output reg reserve_ok,
    (* preserve=1, dont_merge=1 *) output reg [3:0] reserve_slot,
    input wire in_start, in_valid, in_last, in_empty, in_frag,
    input wire [3:0] in_slot, input wire [7:0] in_data,
    input wire [11:0] in_vl, input wire [15:0] in_sport, in_dport,
    input wire in_net, output reg ready, output reg prepared,
    output reg d_valid, d_last, output reg [7:0] d_data,
    output reg [11:0] d_vl, output reg [15:0] d_sport, d_dport,
    output reg d_net, output reg [1:0] reject_events
);
    reg query_active, query_first;
    reg [5:0] query_age;
    (* preserve=1, dont_merge=1 *) reg reject_credit;
    (* preserve=1, dont_merge=1 *) reg [1:0] query_active_bank, reject_credit_bank;
    wire transaction_cancel=cancel || (reserve && reject_credit);
    // result_valid implies query_active, so a rejected reserve cannot inhibit
    // an otherwise idle query. Do not route reserve through the query fanout.
    wire query_fire=query && !query_active && !cancel && !reset;
    (* preserve=1, dont_merge=1 *) reg [1:0] commit_credit;
    wire [1:0] bank_match, bank_free, bank_admit_valid, bank_admit_ok;
    wire [5:0] bank_match_row, bank_free_row;
    reg [1:0] match_summary, free_summary;
    reg [5:0] match_rows, free_rows;
    reg [1:0] select_request;
    reg select_match, select_free;
    (* preserve=1, dont_merge=1 *) reg [2:0] select_row;
    reg [1:0] copy_request, output_request, output_release;
    reg [2:0] copy_row, output_row;
    reg copy_empty;
    wire [1:0] bank_prepared, bank_copy_done, bank_complete, bank_release_done;
    wire [5:0] bank_complete_row;
    wire [1:0] bank_valid, bank_last, bank_net;
    wire [15:0] bank_data;
    wire [23:0] bank_vl;
    wire [31:0] bank_sport, bank_dport;
    wire [3:0] bank_events;

    localparam D_IDLE=0,D_QUIET=1,D_PREP=2,D_COPY=3,D_LEGACY_PREP=4,D_LEGACY=5,D_OUTPUT=6,D_RELEASE=7;
    reg [2:0] stream_state;
    reg stream_bank, output_bank, legacy_empty;
    // A registered idle credit may have launched d_start in deliver on the
    // previous edge. D_QUIET absorbs that outstanding header before output.
    wire accept_header=(stream_state==D_IDLE || stream_state==D_QUIET) && in_start;
    wire output_valid=output_bank ? bank_valid[1] : bank_valid[0];
    wire output_last=output_bank ? bank_last[1] : bank_last[0];

    genvar b;
    generate for(b=0;b<2;b=b+1) begin:banks
        localparam BANK_ROWS=(CONTEXTS>b*8+8) ? 8 : ((CONTEXTS>b*8) ? CONTEXTS-b*8 : 0);
        wire bank_query_in, bank_reserve_in, bank_cancel_in;
        if(BANK_CTRL_COPIES) begin:local_ctrl
            assign bank_query_in=query_bank[b];
            assign bank_reserve_in=reserve_bank[b];
            assign bank_cancel_in=cancel_bank[b];
        end else begin:shared_ctrl
            assign bank_query_in=query;
            assign bank_reserve_in=reserve;
            assign bank_cancel_in=cancel;
        end
        wire bank_query_fire=bank_query_in && !query_active_bank[b] && !bank_cancel_in && !reset;
        wire bank_cancel=bank_cancel_in || (bank_reserve_in && reject_credit_bank[b]);
        wire bank_commit=bank_reserve_in && commit_credit[b] && !bank_cancel_in && !reset;
        afdx_rx_reassembly_bank #(.ROWS(BANK_ROWS),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) u_bank(
            .clk(clk),.reset(reset),.query(bank_query_fire),.cancel(bank_cancel),
            .commit(bank_commit),
            .r_vl(r_vl),.r_meta(r_meta),.r_length(r_length),.r_sport(r_sport),.r_dport(r_dport),.r_net(r_net),
            .match_found(bank_match[b]),.free_found(bank_free[b]),
            .match_row(bank_match_row[b*3+:3]),.free_row(bank_free_row[b*3+:3]),
            .select_valid(select_request[b]),.select_row(select_row),.select_match(select_match),.select_free(select_free),
            .admission_valid(bank_admit_valid[b]),.admission_ok(bank_admit_ok[b]),
            .copy_request(copy_request[b]),.copy_request_row(copy_row),.copy_empty(copy_empty),
            .copy_valid(in_valid && in_frag && stream_bank==b && stream_state==D_COPY),
            .copy_last(in_last),.copy_data(in_data),.copy_prepared(bank_prepared[b]),.copy_done(bank_copy_done[b]),
            .complete_available(bank_complete[b]),.complete_row(bank_complete_row[b*3+:3]),
            .output_request(output_request[b]),.output_request_row(output_row),.output_release(output_release[b]),
            .release_done(bank_release_done[b]),.out_valid(bank_valid[b]),.out_last(bank_last[b]),
            .out_data(bank_data[b*8+:8]),.out_vl(bank_vl[b*12+:12]),.out_sport(bank_sport[b*16+:16]),
            .out_dport(bank_dport[b*16+:16]),.out_net(bank_net[b]),.events(bank_events[b*2+:2]));
    end endgenerate

    always @(posedge clk) begin
        if(reset) begin
            query_active<=0;query_active_bank<=0;query_first<=0;query_age<=0;result_valid<=0;reserve_ok<=0;reserve_slot<=0;
            match_summary<=0;free_summary<=0;match_rows<=0;free_rows<=0;commit_credit<=0;reject_credit<=0;reject_credit_bank<=0;
            select_request<=0;select_match<=0;select_free<=0;select_row<=0;
        end else begin
            select_request<=0;
            if(query_active) begin
                query_age<=query_age+1'b1;
                if(query_age==12) begin
                    match_summary<=bank_match;free_summary<=bank_free;
                    match_rows<=bank_match_row;free_rows<=bank_free_row;
                end
                if(query_age==13) begin
                    select_match<=|match_summary;select_free<=|free_summary;
                    if(query_first) begin
                        if(free_summary[0]) begin reserve_slot<={1'b0,free_rows[2:0]};select_row<=free_rows[2:0];select_request<=2'b01;end
                        else begin reserve_slot<={1'b1,free_rows[5:3]};select_row<=free_rows[5:3];select_request<=2'b10;end
                    end else begin
                        if(match_summary[0]) begin reserve_slot<={1'b0,match_rows[2:0]};select_row<=match_rows[2:0];select_request<=2'b01;end
                        else begin reserve_slot<={1'b1,match_rows[5:3]};select_row<=match_rows[5:3];select_request<=2'b10;end
                    end
                end
                if(query_age==18) begin
                    result_valid<=1;
                    reserve_ok<=reserve_slot[3] ? (bank_admit_valid[1] && bank_admit_ok[1]) : (bank_admit_valid[0] && bank_admit_ok[0]);
                    reject_credit<=reserve_slot[3] ? !(bank_admit_valid[1] && bank_admit_ok[1]) : !(bank_admit_valid[0] && bank_admit_ok[0]);
                    reject_credit_bank<={2{reserve_slot[3] ? !(bank_admit_valid[1] && bank_admit_ok[1]) : !(bank_admit_valid[0] && bank_admit_ok[0])}};
                    commit_credit<=reserve_slot[3] ? {bank_admit_valid[1] && bank_admit_ok[1],1'b0}
                        : {1'b0,bank_admit_valid[0] && bank_admit_ok[0]};
                end
            end
            if(cancel || (reserve && result_valid) || (query_active && query_age==31)) begin
                query_active<=0;query_active_bank<=0;result_valid<=0;reserve_ok<=0;select_request<=0;commit_credit<=0;reject_credit<=0;reject_credit_bank<=0;
            end
            if(query_fire && !cancel) begin
                query_active<=1;query_active_bank<=2'b11;query_first<=r_meta[45:33]==0;query_age<=0;
                // Summaries are overwritten at Q13 before selection; clearing
                // them on Q0 only adds remote cancel to their enable cones.
                result_valid<=0;reserve_ok<=0;commit_credit<=0;reject_credit<=0;reject_credit_bank<=0;
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            stream_state<=D_IDLE;stream_bank<=0;output_bank<=0;legacy_empty<=0;
            copy_request<=0;copy_row<=0;copy_empty<=0;output_request<=0;output_row<=0;output_release<=0;
            ready<=0;prepared<=0;
            d_valid<=0;d_last<=0;d_data<=0;d_vl<=0;d_sport<=0;d_dport<=0;d_net<=0;reject_events<=0;
        end else begin
            copy_request<=0;output_request<=0;output_release<=0;prepared<=0;
            d_valid<=0;d_last<=0;ready<=0;
            reject_events<=bank_events[1:0] | bank_events[3:2];
            case(stream_state)
                D_IDLE: begin
                    ready<=!bank_complete[0] && !bank_complete[1];
                    if(|bank_complete) stream_state<=D_QUIET;
                end
                D_QUIET: if(!in_start) begin
                    if(bank_complete[0]) begin output_bank<=0;output_row<=bank_complete_row[2:0];output_request<=2'b01;stream_state<=D_OUTPUT;end
                    else if(bank_complete[1]) begin output_bank<=1;output_row<=bank_complete_row[5:3];output_request<=2'b10;stream_state<=D_OUTPUT;end
                    else stream_state<=D_IDLE;
                end
                D_PREP: if(stream_bank ? bank_prepared[1] : bank_prepared[0]) begin prepared<=1;stream_state<=D_COPY;end
                D_COPY: if(stream_bank ? bank_copy_done[1] : bank_copy_done[0]) stream_state<=D_IDLE;
                D_LEGACY_PREP: begin prepared<=1;stream_state<=legacy_empty ? D_IDLE : D_LEGACY;end
                D_LEGACY: if(in_valid) begin
                    d_valid<=1;d_last<=in_last;d_data<=in_data;
                    if(in_last) stream_state<=D_IDLE;
                end
                D_OUTPUT: begin
                    // O_LOAD publishes the header; O_ARM/O_SEED prepare the
                    // split terminal comparison before the five-cycle read.
                    // Root metadata leads the first reassembled byte by eight clocks.
                    d_vl<=output_bank ? bank_vl[23:12] : bank_vl[11:0];
                    d_sport<=output_bank ? bank_sport[31:16] : bank_sport[15:0];
                    d_dport<=output_bank ? bank_dport[31:16] : bank_dport[15:0];d_net<=output_bank ? bank_net[1] : bank_net[0];
                    if(output_valid) begin
                        d_valid<=1;d_last<=output_last;
                        d_data<=output_bank ? bank_data[15:8] : bank_data[7:0];
                        if(output_last) begin output_release<=output_bank ? 2'b10 : 2'b01;stream_state<=D_RELEASE;end
                    end
                end
                D_RELEASE: if(output_bank ? bank_release_done[1] : bank_release_done[0]) stream_state<=D_IDLE;
                default: stream_state<=D_IDLE;
            endcase
            if(accept_header) begin
                ready<=0;
                if(in_frag) begin
                    copy_row<=in_slot[2:0];copy_empty<=in_empty;stream_bank<=in_slot[3];
                    copy_request<=in_slot[3] ? 2'b10 : 2'b01;stream_state<=D_PREP;
                end else begin
                    // Idle ownership excludes any previous active message.
                    // Deliver's prepared token and ring pipeline leave seven
                    // clocks between this header and the first legacy byte.
                    legacy_empty<=in_empty;d_vl<=in_vl;d_sport<=in_sport;d_dport<=in_dport;d_net<=in_net;
                    stream_state<=D_LEGACY_PREP;
                end
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!reset) begin
        if(in_start && !accept_header) begin $display("[RX_ASSERT] header without idle credit");$finish_and_return(1);end
        if(in_valid && !(stream_state==D_COPY || stream_state==D_LEGACY)) begin
            $display("[RX_ASSERT] byte before preparation state=%0d",stream_state);$finish_and_return(1);
        end
    end
`endif
endmodule
