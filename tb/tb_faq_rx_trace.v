`timescale 1ns/1ps
// Observation only. The child retains every original stimulus, assertion,
// deadline, $finish and [RESULT] tb_fragmentation message unchanged.
`define TR_RX suite.rx.es.rx_core
`define TR_PA `TR_RX.parse_a
`define TR_PB `TR_RX.parse_b
`define TR_EN `TR_RX.engine
`define TR_RE `TR_RX.reassembly
module tb_faq_rx_trace;
    tb_fragmentation suite();
    localparam MAX_RECORDS=200000;
    integer trace_fd,trace_cycle=0,records=0,truncated=0;
    wire reject_now=(|`TR_RX.parse_ev_a[7:1]) || (|`TR_RX.parse_ev_b[7:1]) ||
        (|`TR_RX.engine_ev_a) || (|`TR_RX.engine_ev_b) || (|`TR_RX.reassembly_reject);
    wire [12:0] trial_used_a=`TR_PA.trial-`TR_PA.read_ptr;
    wire [12:0] trial_used_b=`TR_PB.trial-`TR_PB.read_ptr;
    wire high_a=(`TR_PA.occupied>=3072 || trial_used_a>=3072);
    wire high_b=(`TR_PB.occupied>=3072 || trial_used_b>=3072);
    wire blocked=(`TR_RX.dq_count!=0 && !`TR_RX.frag_ready);
    reg [31:0] old_control=0;
    reg [11:0] old_water=0;
    reg old_result=0,old_over_a=0,old_over_b=0;
    wire [31:0] control={5'b0,`TR_RX.dq_count,`TR_RE.stream_state,`TR_RX.frag_ready,
        `TR_RX.frag_prepared,`TR_RX.deliver.waiting_prepared,`TR_RX.deliver.issuing,
        blocked,high_a,high_b,suite.rx.ev_app,`TR_RX.d_valid,`TR_RX.d_last,
        suite.rx.rx_valid,suite.rx.application_rx.discard,4'b0};
    wire [11:0] water={`TR_PA.occupied[12:10],trial_used_a[12:10],
        `TR_PB.occupied[12:10],trial_used_b[12:10]};
    function integer room;
        begin
            room=records<MAX_RECORDS;
            if(room)records=records+1;
            else if(!truncated)begin
                truncated=1;
                $fwrite(trace_fd,"T %0d max_records=%0d\n",trace_cycle,MAX_RECORDS);
                $fflush(trace_fd);
            end
        end
    endfunction
    initial begin
        trace_fd=$fopen("rx_internal_trace.txt","w");
        if(!trace_fd)$fatal(1,"Cannot create RX observation trace");
        $fwrite(trace_fd,"H 0 version=1 sampling=post_nba_1ns cycle=original_posedge_count high_water=3072 ring_capacity=4096 max_records=%0d\n",MAX_RECORDS);
        $fflush(trace_fd);
    end
    always @(posedge suite.clk)begin
        trace_cycle=trace_cycle+1;
        #1;
        if(!suite.reset)begin
            if(`TR_RX.parse_ev_a!=0 || (`TR_PA.overflow && !old_over_a))begin
                if(room())$fwrite(trace_fd,"P %0d net=A ev=%h vl=%h sn=%h id=%h frag=%h n=%h iplen=%h udplen=%h committed=%h trial=%h begin=%h finish=%h read=%h occupied=%h trial_used=%h overflow=%b fits=%b limit=%h allowed=%b header_bad=%b end_over=%b\n",
                    trace_cycle,`TR_RX.parse_ev_a,`TR_PA.vlid,`TR_PA.sn,`TR_PA.ip_id,`TR_PA.frag_word,
                    `TR_PA.n,`TR_PA.ip_len,`TR_PA.udp_len,`TR_PA.committed,`TR_PA.trial,`TR_PA.frame_begin,
                    `TR_PA.desc_finish,`TR_PA.read_ptr,`TR_PA.occupied,trial_used_a,`TR_PA.overflow,
                    `TR_PA.fits_q,`TR_PA.space_limit,`TR_PA.allowed,`TR_PA.header_bad,`TR_PA.end_overflow);
            end
            if(`TR_RX.parse_ev_b!=0 || (`TR_PB.overflow && !old_over_b))begin
                if(room())$fwrite(trace_fd,"P %0d net=B ev=%h vl=%h sn=%h id=%h frag=%h n=%h iplen=%h udplen=%h committed=%h trial=%h begin=%h finish=%h read=%h occupied=%h trial_used=%h overflow=%b fits=%b limit=%h allowed=%b header_bad=%b end_over=%b\n",
                    trace_cycle,`TR_RX.parse_ev_b,`TR_PB.vlid,`TR_PB.sn,`TR_PB.ip_id,`TR_PB.frag_word,
                    `TR_PB.n,`TR_PB.ip_len,`TR_PB.udp_len,`TR_PB.committed,`TR_PB.trial,`TR_PB.frame_begin,
                    `TR_PB.desc_finish,`TR_PB.read_ptr,`TR_PB.occupied,trial_used_b,`TR_PB.overflow,
                    `TR_PB.fits_q,`TR_PB.space_limit,`TR_PB.allowed,`TR_PB.header_bad,`TR_PB.end_overflow);
            end
            if(`TR_RX.take_a || `TR_RX.take_b)begin
                if(room())$fwrite(trace_fd,"D %0d take_a=%b take_b=%b desc_a=%h desc_b=%h\n",
                    trace_cycle,`TR_RX.take_a,`TR_RX.take_b,`TR_RX.desc_a,`TR_RX.desc_b);
            end
            if(`TR_RX.resolve_a || `TR_RX.resolve_b || `TR_RX.engine_ev_a!=0 ||
                    `TR_RX.engine_ev_b!=0 || `TR_RX.engine_rm || `TR_RX.engine_deliver)begin
                if(room())$fwrite(trace_fd,"E %0d ev_a=%h ev_b=%h rm=%b deliver=%b resolve_a=%b resolve_b=%b commit_a=%b commit_b=%b op=%h phase=%h result=%h idx=%h net=%b desc=%h cfg=%h state=%h psn=%h psn_valid=%b sequence_reject=%b deliver_allowed=%b admission=%b dq_room=%b fragmented=%b\n",
                    trace_cycle,`TR_RX.engine_ev_a,`TR_RX.engine_ev_b,`TR_RX.engine_rm,`TR_RX.engine_deliver,
                    `TR_RX.resolve_a,`TR_RX.resolve_b,`TR_RX.commit_a,`TR_RX.commit_b,`TR_EN.op,`TR_EN.phase,
                    `TR_EN.result,`TR_EN.op_idx,`TR_EN.op_net,`TR_EN.current_desc,`TR_EN.saved_cfg,
                    `TR_EN.saved_state,`TR_EN.psn,`TR_EN.psn_valid,`TR_EN.sequence_reject,
                    `TR_EN.deliver_allowed,`TR_EN.admission_room,`TR_EN.dq_room,`TR_EN.fragmented);
            end
            if(`TR_RX.query || (`TR_RX.result_valid && !old_result) || `TR_RX.reserve ||
                    (`TR_RX.cancel && `TR_RE.query_active) || `TR_RX.reassembly_reject!=0)begin
                if(room())$fwrite(trace_fd,"Q %0d query=%b cancel=%b reserve=%b active=%b age=%h vl=%h net=%b meta=%h length=%h sport=%h dport=%h result_valid=%b ok=%b slot=%h query_first=%b match=%h free=%h bank_admit_valid=%h bank_admit_ok=%h select_req=%h select_row=%h reject_credit=%b commit_credit=%h reject=%h\n",
                    trace_cycle,`TR_RX.query,`TR_RX.cancel,`TR_RX.reserve,`TR_RE.query_active,`TR_RE.query_age,
                    `TR_RX.reserve_vl,`TR_RX.reservation_net,`TR_RX.reserve_meta,`TR_RX.reserve_length,
                    `TR_RX.reserve_sport,`TR_RX.reserve_dport,`TR_RX.result_valid,`TR_RX.reserve_ok,
                    `TR_RX.reserve_slot,`TR_RE.query_first,`TR_RE.bank_match,`TR_RE.bank_free,
                    `TR_RE.bank_admit_valid,`TR_RE.bank_admit_ok,`TR_RE.select_request,`TR_RE.select_row,
                    `TR_RE.reject_credit,`TR_RE.commit_credit,`TR_RX.reassembly_reject);
            end
            if(reject_now || `TR_RX.query || (`TR_RX.result_valid && !`TR_RX.reserve_ok && !old_result) ||
                    control!==old_control || ((high_a || high_b) && water!==old_water))begin
                if(room())$fwrite(trace_fd,"S %0d parse_a=%h parse_b=%h engine_a=%h engine_b=%h reassembly=%h committed_a=%h trial_a=%h read_a=%h occupied_a=%h trial_used_a=%h overflow_a=%b committed_b=%h trial_b=%h read_b=%h occupied_b=%h trial_used_b=%h overflow_b=%b dq=%h dq_we=%b dq_pop=%b stream=%h ready=%b prepared=%b blocked=%b waiting=%b issuing=%b frag_start=%b frag_valid=%b frag_last=%b frag_slot=%h frag_kind=%b app_ev=%h app_used=%h app_desc=%h app_valid=%b output_valid=%b\n",
                    trace_cycle,`TR_RX.parse_ev_a,`TR_RX.parse_ev_b,`TR_RX.engine_ev_a,`TR_RX.engine_ev_b,
                    `TR_RX.reassembly_reject,`TR_PA.committed,`TR_PA.trial,`TR_PA.read_ptr,`TR_PA.occupied,
                    trial_used_a,`TR_PA.overflow,`TR_PB.committed,`TR_PB.trial,`TR_PB.read_ptr,`TR_PB.occupied,
                    trial_used_b,`TR_PB.overflow,`TR_RX.dq_count,`TR_RX.dq_we,`TR_RX.dq_pop,
                    `TR_RE.stream_state,`TR_RX.frag_ready,`TR_RX.frag_prepared,blocked,
                    `TR_RX.deliver.waiting_prepared,`TR_RX.deliver.issuing,`TR_RX.frag_start,
                    `TR_RX.frag_valid,`TR_RX.frag_last,`TR_RX.frag_slot,`TR_RX.frag_kind,suite.rx.ev_app,
                    suite.rx.application_rx.used,suite.rx.application_rx.descriptors,`TR_RX.d_valid,suite.rx.rx_valid);
            end
            if(reject_now)$fflush(trace_fd);
        end
        old_control=control;old_water=water;old_result=`TR_RX.result_valid;
        old_over_a=`TR_PA.overflow;old_over_b=`TR_PB.overflow;
    end
    genvar bank;
    generate for(bank=0;bank<2;bank=bank+1)begin:observe_bank
        `define TR_BK suite.rx.es.rx_core.reassembly.banks[bank].u_bank
        reg old_admit=0;
        reg [98:0] old_bank=0;
        reg [11:0] old_row[0:7];
        integer row;
        wire [47:0] pending_all={`TR_BK.pending[7],`TR_BK.pending[6],`TR_BK.pending[5],`TR_BK.pending[4],
            `TR_BK.pending[3],`TR_BK.pending[2],`TR_BK.pending[1],`TR_BK.pending[0]};
        wire [98:0] bank_signature={`TR_BK.valid,`TR_BK.closed,`TR_BK.complete,`TR_BK.copy_initialized,
            `TR_BK.context_net,pending_all,`TR_BK.copy_state,`TR_BK.output_state,`TR_BK.locked,`TR_BK.locked_row};
        initial for(row=0;row<8;row=row+1)old_row[row]=0;
        always @(posedge suite.clk)begin
            #1;
            if(!suite.reset)begin
                if(bank_signature!==old_bank || (`TR_BK.admission_valid && !old_admit) ||
                        `TR_BK.commit || `TR_BK.copy_request || `TR_BK.output_request || `TR_BK.output_release ||
                        `TR_BK.events!=0 || reject_now)begin
                    if(room())$fwrite(trace_fd,"B %0d bank=%0d valid=%h closed=%h complete=%h initialized=%h pending=%h age_due=%h locked=%b locked_row=%h query_active=%b query_age=%h key=%h first=%b mf=%b start=%h end=%h udp=%h selected_valid=%b selected_closed=%b selected_full=%b selected_match=%b selected_free=%b live_ok=%b bounds_ok=%b admission_return=%h admit_valid=%b admit_ok=%b commit=%b allocate=%b commit_row=%h copy_state=%h copy_row=%h copy_written=%h check_disabled=%b checksum=%h copy_prepared=%b copy_done=%b output_state=%h output_row=%h output_position=%h release=%b release_done=%b reclaim=%h retire=%h check=%h events=%h\n",
                        trace_cycle,bank,`TR_BK.valid,`TR_BK.closed,`TR_BK.complete,`TR_BK.copy_initialized,
                        pending_all,`TR_BK.age_due,`TR_BK.locked,`TR_BK.locked_row,`TR_BK.query_active,
                        `TR_BK.query_age,`TR_BK.query_key,`TR_BK.q_first,`TR_BK.q_mf,`TR_BK.q_start,
                        `TR_BK.q_end,`TR_BK.q_udp_length,`TR_BK.selected_valid,`TR_BK.selected_closed,
                        `TR_BK.selected_full,`TR_BK.selected_match,`TR_BK.selected_free,`TR_BK.live_ok,
                        `TR_BK.bounds_ok,`TR_BK.admission_return,`TR_BK.admission_valid,`TR_BK.admission_ok,
                        `TR_BK.commit,`TR_BK.allocate,`TR_BK.commit_row,`TR_BK.copy_state,`TR_BK.active_copy_row,
                        `TR_BK.copy_written,`TR_BK.copy_check_disabled,`TR_BK.checksum_folded,
                        `TR_BK.copy_prepared,`TR_BK.copy_done,`TR_BK.output_state,
                        `TR_BK.active_output_row,`TR_BK.output_position,`TR_BK.output_release,`TR_BK.release_done,
                        `TR_BK.reclaim_row,`TR_BK.retire_rows,`TR_BK.check_rows,`TR_BK.events);
                end
                for(row=0;row<8;row=row+1)begin
                    if({`TR_BK.valid[row],`TR_BK.closed[row],`TR_BK.complete[row],`TR_BK.copy_initialized[row],
                            `TR_BK.context_net[row],`TR_BK.pending[row],`TR_BK.age_due[row]}!==old_row[row] ||
                            (reject_now && `TR_BK.valid[row]))begin
                        if(room())$fwrite(trace_fd,"C %0d bank=%0d row=%0d valid=%b closed=%b complete=%b initialized=%b net=%b pending=%h age=%h age_due=%b reclaim=%b commit=%b retire=%b check=%b event=%h\n",
                            trace_cycle,bank,row,`TR_BK.valid[row],`TR_BK.closed[row],`TR_BK.complete[row],
                            `TR_BK.copy_initialized[row],`TR_BK.context_net[row],`TR_BK.pending[row],`TR_BK.age[row],
                            `TR_BK.age_due[row],`TR_BK.reclaim_row[row],`TR_BK.commit_rows[row],`TR_BK.retire_rows[row],
                            `TR_BK.check_rows[row],`TR_BK.context_event[row]);
                    end
                    old_row[row]={`TR_BK.valid[row],`TR_BK.closed[row],`TR_BK.complete[row],`TR_BK.copy_initialized[row],
                        `TR_BK.context_net[row],`TR_BK.pending[row],`TR_BK.age_due[row]};
                end
            end
            old_bank=bank_signature;old_admit=`TR_BK.admission_valid;
        end
        `undef TR_BK
    end endgenerate
    final begin
        $fwrite(trace_fd,"Z %0d records=%0d truncated=%0d\n",trace_cycle,records,truncated);
        $fflush(trace_fd);$fclose(trace_fd);
    end
endmodule
`undef TR_RX
`undef TR_PA
`undef TR_PB
`undef TR_EN
`undef TR_RE
