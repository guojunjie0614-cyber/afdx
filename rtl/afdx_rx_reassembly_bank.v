// One owner for eight reassembly rows. Wide state lives in four synchronous
// SDP tables; only lifecycle, pending and timeout state is held per row in FFs.
module afdx_rx_reassembly_bank #(
    parameter ROWS=8, TIMEOUT_CYCLES=250000000
)(
    input wire clk, reset,
    input wire query, cancel, commit,
    input wire [11:0] r_vl, input wire [125:0] r_meta,
    input wire [10:0] r_length, input wire [15:0] r_sport, r_dport,
    input wire r_net,
    output reg match_found, free_found, output reg [2:0] match_row, free_row,
    input wire select_valid, input wire [2:0] select_row,
    input wire select_match, select_free,
    output reg admission_valid, admission_ok,
    input wire copy_request, input wire [2:0] copy_request_row,
    input wire copy_empty, copy_valid, copy_last, input wire [7:0] copy_data,
    output reg copy_prepared, copy_done,
    output reg complete_available, output reg [2:0] complete_row,
    input wire output_request, input wire [2:0] output_request_row,
    input wire output_release, output reg release_done,
    output reg out_valid, out_last, output reg [7:0] out_data,
    output reg [11:0] out_vl, output reg [15:0] out_sport, out_dport,
    output reg out_net, output reg [1:0] events
);
    function integer counter_width;
        input integer count; integer n;
        begin counter_width=1; for(n=1;n<32;n=n+1)
            if((count-1)>>n) counter_width=n+1;
        end
    endfunction
    localparam AGE_W=counter_width(TIMEOUT_CYCLES);
    localparam AGE_LOW_W=(AGE_W>14) ? 14 : AGE_W;
    localparam AGE_HIGH_W=(AGE_W>14) ? AGE_W-14 : 1;
    localparam [AGE_W-1:0] AGE_BEFORE_LAST=(TIMEOUT_CYCLES>1) ? TIMEOUT_CYCLES-2 : 0;
    reg [7:0] valid, closed, complete, copy_initialized, context_net;
    reg [5:0] pending[0:7];
    reg [AGE_W-1:0] age[0:7];
    reg [1:0] context_event[0:7];
    reg [7:0] age_due;
    wire [7:0] reclaim_row, commit_rows, retire_rows, check_rows;

    // Q0 samples the request; Q1 stages data and locally distributes the
    // command. Q2 loads fields, still two clocks ahead of key comparison Q4.
    (* preserve=1, dont_merge=1 *) reg [181:0] request_snapshot, request_hold;
    wire [125:0] capture_meta=request_hold[169:44];
    wire [10:0] capture_length=request_hold[43:33];
    wire [15:0] capture_sport=request_hold[32:17], capture_dport=request_hold[16:1];
    wire [11:0] capture_group;
    always @(posedge clk) begin
        request_snapshot<={r_vl,r_meta,r_length,r_sport,r_dport,r_net};
        request_hold<=request_snapshot;
    end
    genvar field_group;
    generate for(field_group=0;field_group<12;field_group=field_group+1) begin:query_capture
        (* preserve=1, dont_merge=1 *) reg command;
        assign capture_group[field_group]=command;
        always @(posedge clk) if(reset) command<=0;else command<=query_start;
    end endgenerate

    (* preserve=1, dont_merge=1 *) reg query_active, query_start;
    (* preserve=1, dont_merge=1 *) reg admission_read_enable;
    (* preserve=1, dont_merge=1 *) reg [2:0] admission_read_address;
    always @(posedge clk) begin
        admission_read_address<=select_row;
        if(reset) begin query_start<=0;admission_read_enable<=0;end
        else begin query_start<=query;admission_read_enable<=select_valid;end
    end
    (* preserve=1, dont_merge=1 *) reg [5:0] query_age;
    (* preserve=1, dont_merge=1 *) reg [91:0] query_key;
    reg q_first, q_mf, q_net;
    reg [15:0] q_udp_length, q_check, q_sport, q_dport;
    reg [16:0] q_start, q_end;
    reg [13:0] q_app_total, selected_total;
    reg [31:0] pair0,pair1,pair2,pair3,pair4,quad0,quad1,tail_sum,oct_sum,last_sum,initial_sum;
    // The Q1 local start owns exactly eight RAM reads at Q2..Q9. The
    // watchdog age remains independent; no wide age decode reaches RAM ENA.
    (* preserve=1, dont_merge=1 *) reg scan_active;
    (* preserve=1, dont_merge=1 *) reg [2:0] scan_row;
    wire key_re=scan_active;
    wire [2:0] key_ra=scan_row;
    always @(posedge clk) begin
        if(reset) begin scan_active<=0;scan_row<=0;end
        else begin
            if(scan_active) begin
                scan_row<=scan_row+1'b1;
                if(scan_row==7) scan_active<=0;
            end
            if(cancel || commit_cmd || (query_active && query_age==31)) scan_active<=0;
            if(query_start && !cancel) begin scan_active<=1;scan_row<=0;end
        end
    end
    wire [91:0] key_q, header_q;
    wire [27:0] admission_q;
    wire [45:0] progress_q;
    reg key_read_valid, key_row_valid, key_row_present;
    reg [2:0] key_read_row, compare_row;
    reg compare_valid, compare_present, compare_occupied;
    // Q2..9 RAM, Q3..10 local return, Q4..11 field comparisons,
    // Q5..12 reduction. E1 local query start uses the old scan preparation
    // slot, so this extra comparison boundary still returns at external Q19.
    (* preserve=1, dont_merge=1 *) reg [91:0] key_return;
    (* preserve=1, dont_merge=1 *) reg [3:0] key_equal;
    reg reduce_valid, reduce_present, reduce_occupied;
    reg [2:0] reduce_row;
    always @(posedge clk) begin
        key_return<=key_q;
        key_equal<={key_return[91:80]==query_key[91:80],
            key_return[79:48]==query_key[79:48],key_return[47:16]==query_key[47:16],
            key_return[15:0]==query_key[15:0]};
    end
    (* preserve=1, dont_merge=1 *) reg locked;
    (* preserve=1, dont_merge=1 *) reg [2:0] locked_row;
    reg selected_valid, selected_closed, selected_match, selected_free;
    reg selected_full;
    (* preserve=1, dont_merge=1 *) reg [7:0] pending_full;
    (* preserve=1, dont_merge=1 *) reg [27:0] admission_return;
    always @(posedge clk) admission_return<=admission_q;
    wire live_ok=q_first ? (!selected_match && selected_free && !selected_valid)
        : (selected_match && selected_valid && !selected_closed && !selected_full);
    wire bounds_ok=q_first
        ? (q_mf && q_udp_length>=9 && q_udp_length<=8200 && q_end<{1'b0,q_udp_length} && q_end[2:0]==0)
        : (q_start=={3'b0,admission_return[27:14]} && q_end<={3'b0,admission_return[13:0]} &&
           (q_mf ? (q_end<{3'b0,admission_return[13:0]} && q_end[2:0]==0) : q_end=={3'b0,admission_return[13:0]}));
    // Only admission_valid grants ownership. The data result is evaluated
    // locally every cycle; remote cancellation clears validity, not this FF.
    always @(posedge clk) begin
        if(reset) admission_ok<=0;
        else admission_ok<=live_ok && bounds_ok;
    end
    reg [1:0] admission_phase;
    // The command is irrevocable after acceptance. A later cancel only ends
    // the query owner; it cannot mask this registered table-write command.
    (* preserve=1, dont_merge=1 *) reg commit_cmd, allocate;
    (* preserve=1, dont_merge=1 *) reg [2:0] commit_row;
    wire [91:0] header_wd={query_key[91:80],q_sport,q_dport,q_app_total,initial_sum,(q_check==0),q_net};
    wire [27:0] admission_wd={q_end[13:0],(q_first ? q_udp_length[13:0] : selected_total)};

    localparam C_IDLE=0,C_LOAD=1,C_RUN=2,C_RETIRE=3,C_FOLD=4,C_CHECK=5,C_FLUSH=6,C_INIT=7,C_DRAIN=8;
    reg [3:0] copy_state;
    (* preserve=1, dont_merge=1 *) reg [2:0] active_copy_row;
    reg was_initialized, empty_copy, copy_check_disabled, copy_net;
    (* maxfan=16 *) reg [13:0] copy_written;
    reg [13:0] retire_written;
    reg [31:0] retire_sum;
    reg [15:0] checksum_low;
    // 4096 payload words plus the pseudo/UDP header fit in 29 sum bits.
    reg [12:0] checksum_high;
    reg checksum_carry, word_half, copy_carry;
    (* preserve=1, dont_merge=1 *) reg checksum_add_q, checksum_load_q;
    (* preserve=1, dont_merge=1 *) reg [15:0] checksum_word_q;
    reg [28:0] checksum_seed;
    reg [13:0] written_seed;
    wire [6:0] written_low_next=copy_written[6:0]+1'b1;
    wire [6:0] written_high_next=copy_written[13:7]+copy_carry;
    wire [13:0] write_address_ahead=payload_we ? {written_high_next,written_low_next} : copy_written;
    (* preserve=1, dont_merge=1 *) reg [7:0] write_slots, read_slots;
    wire [7:0] final_rows;
    reg [7:0] high_byte;
    reg [16:0] folded_sum;
    (* preserve=1, dont_merge=1 *) reg copy_valid_q, copy_last_q;
    (* preserve=1, dont_merge=1 *) reg [7:0] copy_data_q;
    always @(posedge clk) begin
        copy_data_q<=copy_data;copy_last_q<=copy_last;
        if(reset) copy_valid_q<=0;else copy_valid_q<=copy_valid;
    end
    wire [16:0] checksum_next={1'b0,checksum_low}+{1'b0,checksum_word_q};
    wire [12:0] checksum_high_next=checksum_high+checksum_carry;
    wire payload_we=copy_state==C_RUN && copy_valid_q;
    // Byte selection and its valid command cross a register together. The
    // accumulator owns its local load/add recurrence, independent of copy FSM.
    always @(posedge clk) begin
        checksum_word_q<=word_half ? {high_byte,copy_data_q} : {copy_data_q,8'b0};
        if(reset) begin checksum_add_q<=0;checksum_load_q<=0;end
        else begin
            checksum_add_q<=payload_we && (word_half || copy_last_q);
            checksum_load_q<=copy_state==C_LOAD;
        end
    end
    always @(posedge clk) begin
        if(reset) begin checksum_low<=0;checksum_high<=0;checksum_carry<=0;end
        else if(checksum_load_q) begin
            checksum_low<=checksum_seed[15:0];checksum_high<=checksum_seed[28:16];checksum_carry<=0;
        end else begin
            checksum_high<=checksum_high_next;checksum_carry<=0;
            if(checksum_add_q) begin checksum_low<=checksum_next[15:0];checksum_carry<=checksum_next[16];end
        end
    end
    wire retire_issue=(copy_state==C_FLUSH) || (copy_state==C_INIT && empty_copy);
    wire retire=copy_state==C_RETIRE;
    wire [45:0] progress_wd={retire_written,retire_sum};
    wire [15:0] checksum_folded=folded_sum[15:0]+{15'b0,folded_sum[16]};

    localparam O_IDLE=0,O_LOAD=1,O_READ=2,O_RELEASE=3,O_ARM=4,O_SEED=5;
    reg [2:0] output_state;
    (* preserve=1, dont_merge=1 *) reg [2:0] active_output_row;
    reg [13:0] output_total, output_compare_target;
    reg output_first_last, output_second_last, output_nonempty;
    (* preserve=1, dont_merge=1 *) reg [1:0] output_equal;
    always @(posedge clk) begin
        if(reset) output_equal<=0;
        else if(output_state==O_SEED) output_equal<={2{output_second_last}};
        else output_equal<={output_position[13:7]==output_compare_target[13:7],
            output_position[6:0]==output_compare_target[6:0]};
    end
    (* maxfan=16 *) reg [13:0] output_position;
    reg output_carry;
    (* preserve=1, dont_merge=1 *) reg output_read_active, output_last_request;
    wire [6:0] output_low_next=output_position[6:0]+1'b1;
    wire [6:0] output_high_next=output_position[13:7]+output_carry;
    wire [13:0] output_next={output_high_next,output_low_next};
    localparam PAYLOAD_READ_LATENCY=5;
    reg [PAYLOAD_READ_LATENCY-1:0] output_pipe_valid, output_pipe_last;
    wire payload_re=output_read_active;
    wire [7:0] payload_q;
    // Copy and output descriptor ownership is serialized by the parent. Thus
    // their single header read port never has two accepted clients in a cycle.
    wire header_re=copy_request || output_request;
    wire [2:0] header_ra=copy_request ? copy_request_row : output_request_row;

    // Row commands are decoded before the write edge. Each pending/lifecycle
    // slice consumes its own FF, rather than a state+row decode on its feedback.
    genvar row;
    generate for(row=0;row<8;row=row+1) begin:row_control
        (* preserve=1, dont_merge=1 *) reg commit_row_command, retire_row_command, check_row_command;
        reg age_carry;
        (* preserve=1, dont_merge=1 *) reg age_reset, age_running, row_locked;
        (* preserve=1, dont_merge=1 *) reg timer_open, pending_one;
        wire [5:0] pending_next=commit_row_command && !retire_row_command ? pending[row]+1'b1 :
            retire_row_command && !commit_row_command ? pending[row]-1'b1 : pending[row];
        wire [AGE_LOW_W-1:0] low_age=age[row][AGE_LOW_W-1:0];
        wire [AGE_HIGH_W-1:0] high_age=age[row]>>AGE_LOW_W;
        wire [AGE_LOW_W-1:0] next_low=low_age+1'b1;
        wire [AGE_HIGH_W-1:0] next_high=high_age+age_carry;
        // Full describes the same post-edge count as pending_one.
        assign commit_rows[row]=commit_row_command;
        assign retire_rows[row]=retire_row_command;
        assign check_rows[row]=check_row_command;
        // A reservation sampled on the watchdog boundary still owns its
        // irrevocable physical write, even though the query lock just cleared.
        assign reclaim_row[row]=valid[row] && age_running && age_due[row] && !commit_row_command &&
            !(row_locked || (select_valid && select_row==row));
        assign final_rows[row]=retire_row_command && closed[row] && pending_one && !commit_row_command;
        always @(posedge clk) begin
            if(reset) begin
                commit_row_command<=0;retire_row_command<=0;check_row_command<=0;
                age_reset<=0;age_running<=0;row_locked<=0;timer_open<=0;pending_one<=0;pending_full[row]<=0;
            end else begin
                commit_row_command<=commit && row_locked;
                retire_row_command<=retire_issue && active_copy_row==row;
                check_row_command<=copy_state==C_FOLD && active_copy_row==row;
                // Predict post-edge eligibility from the same merged commands
                // as pending. No extra count is gained or lost at copy retirement.
                // Eligibility depends only on local pending/closed state.
                // The registered valid bit gates expiry separately: select-row
                // decoding must not return through reclaim into this feedback.
                // Any commit leaves pending nonzero, including commit+retire.
                // Thus the timer's local open state needs no same-edge mux.
                if(commit_row_command) timer_open<=q_first || q_mf;
                pending_one<=pending_next==1;
                pending_full[row]<=&pending_next;
                age_running<=timer_open && pending_next==0;
                // Reset one clock after lifecycle changes, while the row is
                // invalid or has pending work; it cannot expire in that interval.
                age_reset<=commit_row_command || reclaim_row[row];
                if(select_valid) row_locked<=select_row==row;
                if(cancel || commit_cmd || (query_active && query_age==31) || query_start) row_locked<=0;
            end
        end
        // age_due describes the registered age, so a wide terminal comparison
        // no longer drives the counter enable or the timeout-event path.
        // Predict the next low-part carry when advancing; a paused age retains
        // its carry and due bits. High/low increments are independent adders.
        always @(posedge clk) begin
            if(reset || age_reset) begin
                age[row]<=0;age_carry<=0;age_due[row]<=TIMEOUT_CYCLES<=1;
            end else if(valid[row] && age_running && !age_due[row]) begin
                age[row]<={next_high,next_low};
                age_carry<=low_age==({AGE_LOW_W{1'b1}}-1'b1);
                age_due[row]<=age[row]==AGE_BEFORE_LAST;
            end
        end
    end endgenerate

    afdx_rx_reassembly_ram #(.WIDTH(92),.AW(3),.REGISTER_WRITE_ADDRESS(1)) key_table(
        .clk(clk),.we(allocate && !reset),.wa(locked_row),.wd(query_key),
        .re(key_re && !reset),.ra(key_ra),.q(key_q));
    afdx_rx_reassembly_ram #(.WIDTH(92),.AW(3),.REGISTER_WRITE_ADDRESS(1)) header_table(
        .clk(clk),.we(allocate && !reset),.wa(locked_row),.wd(header_wd),
        .re(header_re && !reset),.ra(header_ra),.q(header_q));
    afdx_rx_reassembly_ram #(.WIDTH(28),.AW(3)) admission_table(
        .clk(clk),.we(commit_cmd && !reset),.wa(commit_row),.wd(admission_wd),
        .re(admission_read_enable && !reset),.ra(admission_read_address),.q(admission_q));
    afdx_rx_reassembly_ram #(.WIDTH(46),.AW(3)) progress_table(
        .clk(clk),.we(retire && !reset),.wa(active_copy_row),.wd(progress_wd),
        .re(copy_request && copy_initialized[copy_request_row] && !reset),
        .ra(copy_request_row),.q(progress_q));
    afdx_rx_reassembly_payload payload(
        .clk(clk),.reset(reset),.we(payload_we),.wa({active_copy_row,write_address_ahead[12:0]}),.wd(copy_data_q),
        .re(payload_re),.ra({active_output_row,output_position[12:0]}),
        .write_slots(write_slots),.read_slots(read_slots),.q(payload_q));

    integer i,k;
    reg complete_any;
    reg [2:0] first_complete;
    reg [1:0] event_comb;
    always @* begin
        complete_any=0; first_complete=0; event_comb=0;
        for(k=0;k<8;k=k+1) begin
            if(complete[k] && !complete_any) begin complete_any=1; first_complete=k; end
            event_comb=event_comb | context_event[k];
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            query_active<=0; query_age<=0; query_key<=0;
            q_first<=0; q_mf<=0; q_net<=0; q_udp_length<=0; q_check<=0; q_sport<=0; q_dport<=0;
            q_start<=0; q_end<=0; q_app_total<=0; selected_total<=0;
            pair0<=0;pair1<=0;pair2<=0;pair3<=0;pair4<=0;quad0<=0;quad1<=0;tail_sum<=0;oct_sum<=0;last_sum<=0;initial_sum<=0;
            key_read_valid<=0;key_row_valid<=0;key_row_present<=0;key_read_row<=0;
            compare_row<=0;compare_valid<=0;compare_present<=0;compare_occupied<=0;
            reduce_valid<=0;reduce_present<=0;reduce_occupied<=0;reduce_row<=0;
            match_found<=0;free_found<=0;match_row<=0;free_row<=0;
            locked<=0;locked_row<=0;selected_valid<=0;selected_closed<=0;selected_full<=0;
            selected_match<=0;selected_free<=0;
            admission_phase<=0;admission_valid<=0;commit_cmd<=0;allocate<=0;commit_row<=0;
        end else begin
            commit_cmd<=commit;allocate<=commit && q_first;
            locked_row<=select_row;commit_row<=locked_row;
            quad0<=pair0+pair1; quad1<=pair2+pair3; tail_sum<=pair4;
            oct_sum<=quad0+quad1; last_sum<=tail_sum; initial_sum<=oct_sum+last_sum;
            key_read_valid<=key_re;
            if(key_re) begin
                key_read_row<=key_ra; key_row_present<=key_ra<ROWS;
                key_row_valid<=valid[key_ra];
            end
            compare_valid<=key_read_valid;
            if(key_read_valid) begin
                compare_row<=key_read_row; compare_present<=key_row_present; compare_occupied<=key_row_valid;
            end
            reduce_valid<=compare_valid;reduce_present<=compare_present;
            reduce_occupied<=compare_occupied;reduce_row<=compare_row;
            if(query_active) begin
                query_age<=query_age+1'b1;
                if(reduce_valid && reduce_present) begin
                    if(reduce_occupied && &key_equal) begin match_found<=1;match_row<=reduce_row;end
                    if(!reduce_occupied && !free_found) begin free_found<=1;free_row<=reduce_row;end
                end
                if(select_valid) begin
                    locked<=1;
                    selected_valid<=valid[select_row];selected_closed<=closed[select_row];selected_full<=pending_full[select_row];
                    selected_match<=select_match;selected_free<=select_free;admission_phase<=1;
                end else if(admission_phase==1) admission_phase<=2;
                else if(admission_phase==2) begin
                    selected_total<=admission_q[13:0];
                    // Q17 captures raw RAM data only. Bounds use the local
                    // return FF at Q18 and are committed with admission_valid.
                    admission_phase<=3;
                end else if(admission_phase==3) begin
                    admission_valid<=1;admission_phase<=0;
                end
            end
            // The deadline is exactly 32 clocks from the request, including
            // scanning. Local expiry is not delayed by a remote cancel pipe.
            if(cancel || commit_cmd || (query_active && query_age==31)) begin
                query_active<=0;locked<=0;admission_phase<=0;admission_valid<=0;
            end
            if(query_start && !cancel) begin
                // E1 local start already consumes one clock of the external
                // Q0 deadline. Expiry stays at external Q32.
                query_active<=1;query_age<=1;locked<=0;admission_phase<=0;admission_valid<=0;
                match_found<=0;free_found<=0;key_read_valid<=0;compare_valid<=0;reduce_valid<=0;
            end
            if(capture_group[0]) begin query_key[91:80]<=request_hold[181:170];query_key[15:0]<=capture_meta[61:46];end
            if(capture_group[1]) query_key[79:48]<=capture_meta[125:94];
            if(capture_group[2]) query_key[47:16]<=capture_meta[93:62];
            if(capture_group[3]) begin
                q_start<={1'b0,capture_meta[45:33],3'b0};
                q_end<=capture_meta[45:33]==0 ? ({6'b0,capture_length}+17'd8) : ({1'b0,capture_meta[45:33],3'b0}+{6'b0,capture_length});
            end
            if(capture_group[4]) begin q_udp_length<=capture_meta[31:16];q_check<=capture_meta[15:0];end
            if(capture_group[5]) begin q_sport<=capture_sport;q_dport<=capture_dport;end
            if(capture_group[6]) begin
                q_first<=capture_meta[45:33]==0;q_mf<=capture_meta[32];q_net<=request_hold[0];
                q_app_total<=capture_meta[31:16]-16'd8;
            end
            if(capture_group[7]) pair0<={16'b0,capture_meta[125:110]}+{16'b0,capture_meta[109:94]};
            if(capture_group[8]) pair1<={16'b0,capture_meta[93:78]}+{16'b0,capture_meta[77:62]};
            if(capture_group[9]) pair2<=32'd17+{16'b0,capture_meta[31:16]};
            if(capture_group[10]) pair3<={16'b0,capture_meta[31:16]}+{16'b0,capture_sport};
            if(capture_group[11]) begin
                pair4<={16'b0,capture_dport}+{16'b0,capture_meta[15:0]};
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            valid<=0;closed<=0;complete<=0;copy_initialized<=0;context_net<=0;
            copy_state<=C_IDLE;active_copy_row<=0;was_initialized<=0;empty_copy<=0;copy_check_disabled<=0;copy_net<=0;
            copy_written<=0;copy_carry<=0;word_half<=0;checksum_seed<=0;written_seed<=0;
            retire_written<=0;retire_sum<=0;high_byte<=0;folded_sum<=0;write_slots<=0;read_slots<=0;
            copy_prepared<=0;copy_done<=0;
            output_state<=O_IDLE;active_output_row<=0;output_total<=0;output_position<=0;output_compare_target<=0;
            output_first_last<=0;output_second_last<=0;output_nonempty<=0;
            output_carry<=0;output_read_active<=0;output_last_request<=0;
            output_pipe_valid<=0;output_pipe_last<=0;
            out_valid<=0;out_last<=0;out_data<=0;out_vl<=0;out_sport<=0;out_dport<=0;out_net<=0;
            release_done<=0;complete_available<=0;complete_row<=0;events<=0;
            for(i=0;i<8;i=i+1) begin pending[i]<=0;context_event[i]<=0;end
        end else begin
            complete_available<=complete_any;complete_row<=first_complete;events<=event_comb;
            copy_prepared<=0;copy_done<=0;release_done<=0;
            for(i=0;i<8;i=i+1) begin
                context_event[i]<=0;
                if(reclaim_row[i]) begin
                    valid[i]<=0;context_event[i]<=context_net[i] ? 2'b10 : 2'b01;
                end
                case({commit_rows[i],retire_rows[i]})
                    2'b10: pending[i]<=pending[i]+1'b1;
                    2'b01: pending[i]<=pending[i]-1'b1;
                    default: ;
                endcase
                if(commit_rows[i]) begin
                    if(q_first) begin
                        valid[i]<=1;closed[i]<=0;complete[i]<=0;copy_initialized[i]<=0;context_net[i]<=q_net;
                    end else if(!q_mf) closed[i]<=1;
                end
                if(retire_rows[i]) copy_initialized[i]<=1;
                if(check_rows[i]) begin
                    if(copy_check_disabled || checksum_folded==16'hffff) complete[i]<=1;
                    else begin valid[i]<=0;context_event[i]<=copy_net ? 2'b10 : 2'b01;end
                end
                if(output_release && active_output_row==i) begin valid[i]<=0;complete[i]<=0;end
            end
            case(copy_state)
                C_IDLE: if(copy_request) begin
                    active_copy_row<=copy_request_row;was_initialized<=copy_initialized[copy_request_row];empty_copy<=copy_empty;
                    write_slots<=8'b1<<copy_request_row;
                    copy_state<=C_LOAD;
                end
                C_LOAD: begin
                    written_seed<=was_initialized ? progress_q[45:32] : 14'd0;
                    checksum_seed<=was_initialized ? progress_q[28:0] : header_q[30:2];
                    copy_check_disabled<=header_q[1];copy_net<=header_q[0];high_byte<=0;
                    copy_state<=C_INIT;
                end
                C_INIT: begin
                    copy_written<=written_seed;copy_carry<=&written_seed[6:0];word_half<=written_seed[0];
                    copy_prepared<=1;
                    if(empty_copy) begin
                        retire_written<=written_seed;retire_sum<={3'b0,checksum_seed};copy_state<=C_RETIRE;
                    end else copy_state<=C_RUN;
                end
                C_RUN: if(copy_valid_q) begin
                    if(!word_half) high_byte<=copy_data_q;
                    word_half<=!word_half;
                    copy_written<={written_high_next,written_low_next};
                    copy_carry<=copy_written[6:0]==7'd126;
                    if(copy_last_q) begin
                        retire_written<={written_high_next,written_low_next};copy_state<=C_DRAIN;
                    end
                end
                // Incoming last E0 -> word/slot command E1 -> add and payload
                // write E2 -> carry/retired sum E3 -> progress/pending E4.
                C_DRAIN: copy_state<=C_FLUSH;
                C_FLUSH: begin
                    retire_sum<={3'b0,checksum_high_next,checksum_low};copy_state<=C_RETIRE;
                end
                C_RETIRE: begin
                    if(|final_rows) copy_state<=C_FOLD;
                    else begin copy_state<=C_IDLE;copy_done<=1;end
                end
                C_FOLD: begin folded_sum<={1'b0,retire_sum[15:0]}+{1'b0,retire_sum[31:16]};copy_state<=C_CHECK;end
                C_CHECK: begin copy_done<=1;copy_state<=C_IDLE;end
                default: copy_state<=C_IDLE;
            endcase

            output_pipe_valid<={output_pipe_valid[PAYLOAD_READ_LATENCY-2:0],payload_re};
            output_pipe_last<={output_pipe_last[PAYLOAD_READ_LATENCY-2:0],(payload_re && output_last_request)};
            out_valid<=output_pipe_valid[PAYLOAD_READ_LATENCY-1];
            out_last<=output_pipe_valid[PAYLOAD_READ_LATENCY-1] && output_pipe_last[PAYLOAD_READ_LATENCY-1];
            if(output_pipe_valid[PAYLOAD_READ_LATENCY-1]) begin
                out_data<=payload_q;
                if(output_pipe_last[PAYLOAD_READ_LATENCY-1]) output_state<=O_RELEASE;
            end
            case(output_state)
                O_IDLE: if(output_request) begin
                    active_output_row<=output_request_row;read_slots<=8'b1<<output_request_row;output_state<=O_LOAD;
                end
                O_LOAD: begin
                    out_vl<=header_q[91:80];out_sport<=header_q[79:64];out_dport<=header_q[63:48];out_net<=header_q[0];
                    output_total<=header_q[47:34];output_position<=0;output_carry<=0;output_state<=O_ARM;
                end
                O_ARM: begin
                    // Two registered half comparisons precede the final AND.
                    // P==N-3 predicts last for P+2; seed N=1 and N=2 explicitly.
                    output_compare_target<=output_total-14'd3;
                    output_nonempty<=output_total!=0;
                    output_first_last<=output_total==1;output_second_last<=output_total==2;
                    output_state<=O_SEED;
                end
                O_SEED: begin
                    output_read_active<=output_nonempty;output_last_request<=output_first_last;
                    output_state<=O_READ;
                end
                O_READ: if(payload_re) begin
                    output_position<=output_next;output_carry<=output_position[6:0]==7'd126;
                    output_read_active<=!output_last_request;
                    output_last_request<=&output_equal;
                end
                O_RELEASE: if(output_release) begin output_state<=O_IDLE;release_done<=1;end
                default: output_state<=O_IDLE;
            endcase
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk) if(!reset) begin
        if(copy_request && output_request) begin $display("[RX_ASSERT] header port double grant %m");$finish_and_return(1);end
        if(copy_request && (!valid[copy_request_row] || pending[copy_request_row]==0 || copy_state!=C_IDLE)) begin
            $display("[RX_ASSERT] copy without committed owner %m row=%0d",copy_request_row);$finish_and_return(1);
        end
        if(retire && pending[active_copy_row]==0) begin $display("[RX_ASSERT] pending underflow %m");$finish_and_return(1);end
        if(output_request && !complete[output_request_row]) begin $display("[RX_ASSERT] output before complete %m");$finish_and_return(1);end
    end
`endif
endmodule
