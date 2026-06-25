`include "pe_defines.svh"

module PE_Core #(
    parameter int PE_DATA_W_P      = `PE_DATA_W,
    parameter int PE_IDX_W_P       = `PE_IDX_W,
    parameter int PE_ENTRY_W_P     = `PE_ENTRY_W,
    parameter int PE_RESULT_W_P    = `PE_RESULT_W,
    parameter int PE_BUF_DEPTH_P   = `PE_BUF_DEPTH
)(
    input  logic                         clk,
    input  logic                         rst_n,

    // QA stream from loader: one A scalar task for this PE.
    //handshake
    input  logic                         qa_valid,
    output logic                         qa_ready,
    //
    input  logic [PE_IDX_W_P-1:0]        qa_row_idx,
    input  logic [PE_DATA_W_P-1:0]       qa_val,
    input  logic                         qa_eor,

    // QB stream from loader: B[k,*] entry stream broadcast to this PE.
    // Empty B row convention: qb_valid=1, qb_empty=1, qb_last=1.
    //handshake
    input  logic                         qb_valid,
    output logic                         qb_ready,
    //
    input  logic [PE_IDX_W_P-1:0]        qb_col_idx,
    input  logic [PE_DATA_W_P-1:0]       qb_val,
    input  logic                         qb_last,
    input  logic                         qb_empty,

    // Final result stream to external Result_FIFO.
    output logic                         result_wr_en,
    output logic [PE_RESULT_W_P-1:0]     result_wr_data,
    input  logic                         result_full,
    // status
    output logic                         pe_busy,
    output logic                         pe_round_done,
    output logic                         pe_error
);
    localparam int PE_COUNT_W = $clog2(PE_BUF_DEPTH_P + 1);

    typedef enum logic [3:0] {
        PE_S_IDLE,
        PE_S_FETCH_B,
        PE_S_DECIDE,
        PE_S_START_MUL,
        PE_S_WAIT_MUL,
        PE_S_START_ADD,
        PE_S_WAIT_ADD,
        PE_S_EMIT,
        PE_S_FINISH
    } pe_state_e;

    pe_state_e state_q, state_d;

    // Latched QA task information.
    logic [PE_IDX_W_P-1:0]  row_q;
    logic [PE_DATA_W_P-1:0] a_val_q;
    logic                   final_merge_q;

    // Held QB entry. The PE consumes QB only when merge logic needs a new B entry.
    logic                   b_hold_valid_q;
    logic [PE_IDX_W_P-1:0]  b_col_q;
    logic [PE_DATA_W_P-1:0] b_val_q;
    logic                   b_last_q;
    logic                   b_done_q;

    // Buffer selector: 0 => read buffer0/write buffer1; 1 => read buffer1/write buffer0.
    logic buf_sel_q;

    // Buffer wires.
    logic                       buf0_clear		,buf1_clear;   //clear buffer
    logic                       buf0_wr_en		,buf1_wr_en;   //write enable
    logic [PE_ENTRY_W_P-1:0]    buf0_wr_data	,buf1_wr_data;    //write data to buffer
    logic                       buf0_full		,buf1_full;     // full signals
    logic                       buf0_rd_en		,buf1_rd_en;   //
    logic [PE_ENTRY_W_P-1:0] 	buf0_rd_data	,buf1_rd_data;
    logic 						buf0_empty		,buf1_empty;
    logic [PE_COUNT_W-1:0] 		buf0_count		,buf1_count;
    logic 						buf0_ovf		,buf0_udf, 
								buf1_ovf		,buf1_udf;

    PE_Row_Buffer #(
        .PE_BUF_DEPTH_P (PE_BUF_DEPTH_P),
        .PE_ENTRY_W_P   (PE_ENTRY_W_P)
    ) u_buf0 (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (buf0_clear),
        .wr_en     (buf0_wr_en),
        .wr_data   (buf0_wr_data),
        .full      (buf0_full),
        .rd_en     (buf0_rd_en),
        .rd_data   (buf0_rd_data),
        .empty     (buf0_empty),
        .count     (buf0_count),
        .overflow  (buf0_ovf),
        .underflow (buf0_udf)
    );

    PE_Row_Buffer #(
        .PE_BUF_DEPTH_P (PE_BUF_DEPTH_P),
        .PE_ENTRY_W_P   (PE_ENTRY_W_P)
    ) u_buf1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear     (buf1_clear),
        .wr_en     (buf1_wr_en),
        .wr_data   (buf1_wr_data),
        .full      (buf1_full),
        .rd_en     (buf1_rd_en),
        .rd_data   (buf1_rd_data),
        .empty     (buf1_empty),
        .count     (buf1_count),
        .overflow  (buf1_ovf),
        .underflow (buf1_udf)
    );

    wire [PE_ENTRY_W_P-1:0] rbuf_data  = (buf_sel_q == 1'b0) ? buf0_rd_data : buf1_rd_data;
    wire                   	rbuf_empty = (buf_sel_q == 1'b0) ? buf0_empty   : buf1_empty;
    wire                   	wbuf_full  = (buf_sel_q == 1'b0) ? buf1_full    : buf0_full;

    wire [PE_IDX_W_P-1:0]  rbuf_col = rbuf_data[PE_ENTRY_W_P-1 -: PE_IDX_W_P];
    wire [PE_DATA_W_P-1:0] rbuf_val = rbuf_data[PE_DATA_W_P-1:0];

    // Pending output from merge decision.
    typedef enum logic [1:0] {
        PE_OUT_OLD,
        PE_OUT_NEW,
        PE_OUT_SUM
    } pe_out_kind_e;

    pe_out_kind_e out_kind_q;
    logic [PE_IDX_W_P-1:0]  out_col_q;
    logic [PE_DATA_W_P-1:0] out_val_q;
    logic                   out_pop_old_q;
    logic                   out_pop_b_q;
    logic [PE_DATA_W_P-1:0] mul_result_q;

    // Floating-point multiplier wrapper.
    logic [PE_DATA_W_P-1:0] mul_a_tdata, mul_b_tdata;
    logic                   mul_a_tvalid, mul_a_tready;
    logic                   mul_b_tvalid, mul_b_tready;
    logic [PE_DATA_W_P-1:0] mul_res_tdata;
    logic                   mul_res_tvalid, mul_res_tready;

    PE_FP_Mul #(
        .PE_DATA_W_P (PE_DATA_W_P)
    ) u_fp_mul (
        .aclk                 (clk),
        .aresetn              (rst_n),
        .s_axis_a_tdata       (mul_a_tdata),
        .s_axis_a_tvalid      (mul_a_tvalid),
        .s_axis_a_tready      (mul_a_tready),
        .s_axis_b_tdata       (mul_b_tdata),
        .s_axis_b_tvalid      (mul_b_tvalid),
        .s_axis_b_tready      (mul_b_tready),
        .m_axis_result_tdata  (mul_res_tdata),
        .m_axis_result_tvalid (mul_res_tvalid),
        .m_axis_result_tready (mul_res_tready)
    );

    // Floating-point add wrapper.
    logic [PE_DATA_W_P-1:0] add_a_tdata, add_b_tdata;
    logic                   add_a_tvalid, add_a_tready, add_a_tlast;
    logic                   add_b_tvalid, add_b_tready;
    logic [PE_DATA_W_P-1:0] add_res_tdata;
    logic                   add_res_tvalid, add_res_tready, add_res_tlast;

    PE_FP_Add #(
        .PE_DATA_W_P (PE_DATA_W_P)
    ) u_fp_add (
        .aclk                 (clk),
        .aresetn              (rst_n),
        .s_axis_a_tdata       (add_a_tdata),
        .s_axis_a_tvalid      (add_a_tvalid),
        .s_axis_a_tready      (add_a_tready),
        .s_axis_a_tlast       (add_a_tlast),
        .s_axis_b_tdata       (add_b_tdata),
        .s_axis_b_tvalid      (add_b_tvalid),
        .s_axis_b_tready      (add_b_tready),
        .m_axis_result_tdata  (add_res_tdata),
        .m_axis_result_tvalid (add_res_tvalid),
        .m_axis_result_tready (add_res_tready),
        .m_axis_result_tlast  (add_res_tlast)
    );

    // Default assignments.
    always_comb begin
        qa_ready       = (state_q == PE_S_IDLE);
        qb_ready       = (state_q == PE_S_FETCH_B) && !b_hold_valid_q && !b_done_q;
        pe_busy        = (state_q != PE_S_IDLE);
        pe_round_done  = 1'b0;

        result_wr_en   = 1'b0;
        result_wr_data = '0;

        buf0_clear   = 1'b0;
        buf1_clear   = 1'b0;
        buf0_wr_en   = 1'b0;
        buf1_wr_en   = 1'b0;
        buf0_wr_data = '0;
        buf1_wr_data = '0;
        buf0_rd_en   = 1'b0;
        buf1_rd_en   = 1'b0;

        mul_a_tdata   = a_val_q;
        mul_b_tdata   = b_val_q;
        mul_a_tvalid  = 1'b0;
        mul_b_tvalid  = 1'b0;
        mul_res_tready = 1'b0;

        add_a_tdata   = rbuf_val;
        add_b_tdata   = mul_result_q;
        add_a_tvalid  = 1'b0;
        add_b_tvalid  = 1'b0;
        add_a_tlast   = 1'b0;
        add_res_tready = 1'b0;

        state_d = state_q;

        unique case (state_q)
            PE_S_IDLE: begin
                if (qa_valid) begin
                    state_d = PE_S_FETCH_B;
                    // Clear the next write buffer before this round starts.
                    if (buf_sel_q == 1'b0) begin
                        buf1_clear = 1'b1;
                    end else begin
                        buf0_clear = 1'b1;
                    end
                end
            end

            PE_S_FETCH_B: begin
                if (qb_valid && qb_ready) begin
                    state_d = PE_S_DECIDE;
                end
            end

            PE_S_DECIDE: begin
                if (!rbuf_empty && !b_hold_valid_q && !b_done_q) begin
                    state_d = PE_S_FETCH_B;
                end else if (rbuf_empty && !b_hold_valid_q && !b_done_q) begin
                    state_d = PE_S_FETCH_B;
                end else if (rbuf_empty && !b_hold_valid_q && b_done_q) begin
                    state_d = PE_S_FINISH;
                end else if (!rbuf_empty && (!b_hold_valid_q && b_done_q)) begin
                    state_d = PE_S_EMIT; // old-only
                end else if (rbuf_empty && b_hold_valid_q) begin
                    state_d = PE_S_START_MUL; // new-only
                end else if (!rbuf_empty && b_hold_valid_q) begin
                    if (rbuf_col < b_col_q) begin
                        state_d = PE_S_EMIT; // old-only
                    end else begin
                        state_d = PE_S_START_MUL; // new-only or equal
                    end
                end else begin
                    state_d = PE_S_FINISH;
                end
            end

            PE_S_START_MUL: begin
                mul_a_tvalid = 1'b1;
                mul_b_tvalid = 1'b1;
                if (mul_a_tready && mul_b_tready) begin
                    state_d = PE_S_WAIT_MUL;
                end
            end

            PE_S_WAIT_MUL: begin
                mul_res_tready = 1'b1;
                if (mul_res_tvalid) begin
                    if (!rbuf_empty && b_hold_valid_q && (rbuf_col == b_col_q)) begin
                        state_d = PE_S_START_ADD;
                    end else begin
                        state_d = PE_S_EMIT;
                    end
                end
            end

            PE_S_START_ADD: begin
                add_a_tvalid = 1'b1;
                add_b_tvalid = 1'b1;
                add_a_tlast  = 1'b0;
                if (add_a_tready && add_b_tready) begin
                    state_d = PE_S_WAIT_ADD;
                end
            end

            PE_S_WAIT_ADD: begin
                add_res_tready = 1'b1;
                if (add_res_tvalid) begin
                    state_d = PE_S_EMIT;
                end
            end

            PE_S_EMIT: begin
                if (final_merge_q) begin
                    if (!result_full) begin
                        result_wr_en   = 1'b1;
                        result_wr_data = {row_q, out_col_q, out_val_q};
                        if (out_pop_old_q) begin
                            if (buf_sel_q == 1'b0) buf0_rd_en = 1'b1;
                            else                   buf1_rd_en = 1'b1;
                        end
                        state_d = PE_S_DECIDE;
                    end
                end else begin
                    if (!wbuf_full) begin
                        if (buf_sel_q == 1'b0) begin
                            buf1_wr_en   = 1'b1;
                            buf1_wr_data = {out_col_q, out_val_q};
                        end else begin
                            buf0_wr_en   = 1'b1;
                            buf0_wr_data = {out_col_q, out_val_q};
                        end
                        if (out_pop_old_q) begin
                            if (buf_sel_q == 1'b0) buf0_rd_en = 1'b1;
                            else                   buf1_rd_en = 1'b1;
                        end
                        state_d = PE_S_DECIDE;
                    end
                end
            end

            PE_S_FINISH: begin
                pe_round_done = 1'b1;
                if (final_merge_q) begin
                    buf0_clear = 1'b1;
                    buf1_clear = 1'b1;
                end
                state_d = PE_S_IDLE;
            end

            default: begin
                state_d = PE_S_IDLE;
            end
        endcase
    end

    // Sequential state and datapath registers.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q        <= PE_S_IDLE;
            row_q          <= '0;
            a_val_q        <= '0;
            final_merge_q  <= 1'b0;
            b_hold_valid_q <= 1'b0;
            b_col_q        <= '0;
            b_val_q        <= '0;
            b_last_q       <= 1'b0;
            b_done_q       <= 1'b0;
            buf_sel_q      <= 1'b0;
            out_kind_q     <= PE_OUT_OLD;
            out_col_q      <= '0;
            out_val_q      <= '0;
            out_pop_old_q  <= 1'b0;
            out_pop_b_q    <= 1'b0;
            mul_result_q   <= '0;
            pe_error       <= 1'b0;
        end else begin
            state_q <= state_d;
            pe_error <= pe_error | buf0_ovf | buf0_udf | buf1_ovf | buf1_udf;

            if ((state_q == PE_S_IDLE) && qa_valid && qa_ready) begin
                row_q          <= qa_row_idx;
                a_val_q        <= qa_val;
                final_merge_q  <= qa_eor;
                b_hold_valid_q <= 1'b0;
                b_done_q       <= 1'b0;
            end

            if ((state_q == PE_S_FETCH_B) && qb_valid && qb_ready) begin
                if (qb_empty) begin
                    b_hold_valid_q <= 1'b0;
                    b_done_q       <= 1'b1;
                    b_last_q       <= 1'b1;
                end else begin
                    b_hold_valid_q <= 1'b1;
                    b_col_q        <= qb_col_idx;
                    b_val_q        <= qb_val;
                    b_last_q       <= qb_last;
                    b_done_q       <= 1'b0;
                end
            end

            if (state_q == PE_S_DECIDE) begin
                out_pop_old_q <= 1'b0;
                out_pop_b_q   <= 1'b0;
                out_kind_q    <= PE_OUT_OLD;

                if (!rbuf_empty && (!b_hold_valid_q && b_done_q)) begin
                    out_kind_q    <= PE_OUT_OLD;
                    out_col_q     <= rbuf_col;
                    out_val_q     <= rbuf_val;
                    out_pop_old_q <= 1'b1;
                    out_pop_b_q   <= 1'b0;
                end else if (!rbuf_empty && b_hold_valid_q && (rbuf_col < b_col_q)) begin
                    out_kind_q    <= PE_OUT_OLD;
                    out_col_q     <= rbuf_col;
                    out_val_q     <= rbuf_val;
                    out_pop_old_q <= 1'b1;
                    out_pop_b_q   <= 1'b0;
                end else if (rbuf_empty && b_hold_valid_q) begin
                    out_kind_q    <= PE_OUT_NEW;
                    out_col_q     <= b_col_q;
                    out_pop_old_q <= 1'b0;
                    out_pop_b_q   <= 1'b1;
                end else if (!rbuf_empty && b_hold_valid_q && (rbuf_col > b_col_q)) begin
                    out_kind_q    <= PE_OUT_NEW;
                    out_col_q     <= b_col_q;
                    out_pop_old_q <= 1'b0;
                    out_pop_b_q   <= 1'b1;
                end else if (!rbuf_empty && b_hold_valid_q && (rbuf_col == b_col_q)) begin
                    out_kind_q    <= PE_OUT_SUM;
                    out_col_q     <= rbuf_col;
                    out_pop_old_q <= 1'b1;
                    out_pop_b_q   <= 1'b1;
                end
            end

            if ((state_q == PE_S_WAIT_MUL) && mul_res_tvalid && mul_res_tready) begin
                mul_result_q <= mul_res_tdata;
                if (out_kind_q == PE_OUT_NEW) begin
                    out_val_q <= mul_res_tdata;
                end
            end

            if ((state_q == PE_S_WAIT_ADD) && add_res_tvalid && add_res_tready) begin
                out_val_q <= add_res_tdata;
            end

            if (state_q == PE_S_EMIT) begin
                if ((final_merge_q && !result_full) || (!final_merge_q && !wbuf_full)) begin
                    if (out_pop_b_q) begin
                        b_hold_valid_q <= 1'b0;
                        if (b_last_q) begin
                            b_done_q <= 1'b1;
                        end
                    end
                end
            end

            if (state_q == PE_S_FINISH) begin
                if (final_merge_q) begin
                    buf_sel_q <= 1'b0;
                end else begin
                    buf_sel_q <= ~buf_sel_q;
                end
                b_hold_valid_q <= 1'b0;
                b_done_q       <= 1'b0;
            end
        end
    end
endmodule
