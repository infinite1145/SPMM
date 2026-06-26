`timescale 1ns/1ps
`default_nettype none

module PE_Load_A #(
    parameter int PE_LANES = 64,
    parameter int DATA_W   = 16,
    parameter int IDX_W    = 16,
    parameter int A_ADDR_W = 16
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    output logic done,
    output logic busy,

    input  wire [31:0] csv_vector_count,
    input  wire        csv_has_row_idx,

    // A vector ROM, synchronous read, 1-cycle latency
    // 64PE fixed CSV format:
    // word0              = {row_base[15:0], k[15:0]}
    // word1              = valid_mask[31:0]
    // word2              = valid_mask[63:32]
    // word3              = eor_mask[31:0]
    // word4              = eor_mask[63:32]
    // word5 ~ word68     = lane_word[0] ~ lane_word[63]
    output logic                         a_rom_ena,
    output logic [A_ADDR_W-1:0]          a_rom_addra,
    input  wire [32*69-1:0]              a_rom_douta,

    // QA channel to PE array / QA FIFO
    output logic [PE_LANES-1:0]                 qa_valid,
    input  wire  [PE_LANES-1:0]                 qa_ready,
    output logic [PE_LANES-1:0][IDX_W-1:0]      qa_row_idx,
    output logic [PE_LANES-1:0][DATA_W-1:0]     qa_val,
    output logic [PE_LANES-1:0]                 qa_eor,

    // Request to Load_B
    output logic                     b_req_valid,
    input  wire                      b_req_ready,
    output logic [IDX_W-1:0]         b_req_k,
    output logic [PE_LANES-1:0]      b_req_active_mask,

    // Response from Load_B
    input  wire b_done,

    // PE round done feedback.
    // One pulse means the corresponding PE has finished one QA/QB round.
    input  wire [PE_LANES-1:0] pe_round_done
);

    localparam int A_VEC_W              = 32 * 69;
    localparam int VALID_MASK_LO_WORD   = 1;
    localparam int VALID_MASK_HI_WORD   = 2;
    localparam int EOR_MASK_LO_WORD     = 3;
    localparam int EOR_MASK_HI_WORD     = 4;
    localparam int LANE_WORD_BASE       = 5;

    typedef enum logic [3:0] {
        LA_S_IDLE,
        LA_S_REQ_A,
        LA_S_WAIT_A,
        LA_S_DECODE_A,
        LA_S_SEND_QA,
        LA_S_SEND_B_REQ,
        LA_S_WAIT_B_DONE,

        // Old pending vector has not finished yet.
        // Current vector has already sent QA/B, so wait here before issuing more.
        LA_S_WAIT_OLD_PE_DONE,

        // All vectors have been issued.
        // Wait for the last pending vector to really finish.
        LA_S_WAIT_LAST_PE_DONE,

        LA_S_NEXT,
        LA_S_DONE
    } la_state_e;

    la_state_e state, state_n;

    logic [31:0] vector_idx;
    logic [A_VEC_W-1:0] a_vec_reg;

    logic [IDX_W-1:0] row_base_reg;
    logic [IDX_W-1:0] k_reg;
    logic [PE_LANES-1:0] valid_mask_reg;
    logic [PE_LANES-1:0] eor_mask_reg;
    logic [PE_LANES-1:0][DATA_W-1:0] a_val_reg;
    logic [PE_LANES-1:0][IDX_W-1:0]  row_idx_reg;

    logic [PE_LANES-1:0] qa_accepted;
    logic [PE_LANES-1:0] qa_fire;

    logic [31:0] dec_word0;
    logic [31:0] dec_valid_mask_lo;
    logic [31:0] dec_valid_mask_hi;
    logic [31:0] dec_eor_mask_lo;
    logic [31:0] dec_eor_mask_hi;

    logic [PE_LANES-1:0] dec_valid_mask;
    logic [PE_LANES-1:0] dec_eor_mask;

    // ============================================================
    // One-vector-lookahead bookkeeping
    //
    // pending_* records the older outstanding vector.
    // current_done_seen records current lookahead vector done pulses before
    // it is promoted to pending.
    // ============================================================

    logic pending_valid;
    logic [PE_LANES-1:0] pending_mask_reg;
    logic [PE_LANES-1:0] pending_done_seen;

    logic [PE_LANES-1:0] pending_remaining;
    logic [PE_LANES-1:0] pending_done_fire;
    logic pending_done_now;

    logic [PE_LANES-1:0] current_done_seen;
    logic [PE_LANES-1:0] current_done_fire;

    logic current_is_last;

    integer p;

    function automatic logic [31:0] get_word(
        input logic [A_VEC_W-1:0] vec,
        input int idx
    );
        begin
            get_word = vec[32*idx +: 32];
        end
    endfunction

    assign qa_fire = qa_valid & qa_ready;

    // ============================================================
    // 64PE fixed CSV decode
    // ============================================================

    assign dec_word0 = get_word(a_vec_reg, 0);

    assign dec_valid_mask_lo = get_word(a_vec_reg, VALID_MASK_LO_WORD);
    assign dec_valid_mask_hi = get_word(a_vec_reg, VALID_MASK_HI_WORD);

    assign dec_eor_mask_lo   = get_word(a_vec_reg, EOR_MASK_LO_WORD);
    assign dec_eor_mask_hi   = get_word(a_vec_reg, EOR_MASK_HI_WORD);

    assign dec_valid_mask = {dec_valid_mask_hi, dec_valid_mask_lo};
    assign dec_eor_mask   = {dec_eor_mask_hi, dec_eor_mask_lo};

    assign current_is_last = ((vector_idx + 1) >= csv_vector_count);

    // Old pending lanes that have not finished yet.
    assign pending_remaining =
        pending_valid ? (pending_mask_reg & ~pending_done_seen) : '0;

    // A pe_round_done pulse first belongs to old pending if that lane is still waiting.
    assign pending_done_fire = pe_round_done & pending_remaining;

    // Only pulses not belonging to old pending are allowed to count as current done.
    // This prevents overlapping-lane done pulses from being mis-attributed.
    assign current_done_fire =
        pe_round_done & valid_mask_reg & ~pending_remaining;

    assign pending_done_now =
        (!pending_valid) ||
        ((((pending_done_seen | pending_done_fire) & pending_mask_reg) == pending_mask_reg));

    // ============================================================
    // Combinational control
    // ============================================================

    always_comb begin
        a_rom_ena         = 1'b0;
        a_rom_addra       = vector_idx[A_ADDR_W-1:0];

        qa_valid          = '0;
        qa_row_idx        = row_idx_reg;
        qa_val            = a_val_reg;
        qa_eor            = eor_mask_reg;

        b_req_valid       = 1'b0;
        b_req_k           = k_reg;
        b_req_active_mask = valid_mask_reg;

        done              = 1'b0;
        busy              = (state != LA_S_IDLE) && (state != LA_S_DONE);

        state_n           = state;

        unique case (state)
            LA_S_IDLE: begin
                if (start) begin
                    if (csv_vector_count == 0) begin
                        state_n = LA_S_DONE;
                    end else begin
                        state_n = LA_S_REQ_A;
                    end
                end
            end

            LA_S_REQ_A: begin
                a_rom_ena   = 1'b1;
                a_rom_addra = vector_idx[A_ADDR_W-1:0];
                state_n     = LA_S_WAIT_A;
            end

            LA_S_WAIT_A: begin
                state_n = LA_S_DECODE_A;
            end

            LA_S_DECODE_A: begin
                // Use decoded current vector mask, not previous valid_mask_reg.
                if (dec_valid_mask == '0) begin
                    state_n = LA_S_NEXT;
                end else begin
                    state_n = LA_S_SEND_QA;
                end
            end

            LA_S_SEND_QA: begin
                qa_valid = valid_mask_reg & ~qa_accepted;

                if (((qa_accepted | qa_fire) & valid_mask_reg) == valid_mask_reg) begin
                    state_n = LA_S_SEND_B_REQ;
                end
            end

            LA_S_SEND_B_REQ: begin
                b_req_valid = 1'b1;

                if (b_req_ready) begin
                    state_n = LA_S_WAIT_B_DONE;
                end
            end

            LA_S_WAIT_B_DONE: begin
                if (b_done) begin
                    // Current vector's B row has been pushed into downstream FIFO.
                    // If old pending still has unfinished PE lanes, do not issue more.
                    if (pending_valid && !pending_done_now) begin
                        state_n = LA_S_WAIT_OLD_PE_DONE;
                    end else begin
                        if (current_is_last) begin
                            state_n = LA_S_WAIT_LAST_PE_DONE;
                        end else begin
                            state_n = LA_S_NEXT;
                        end
                    end
                end
            end

            LA_S_WAIT_OLD_PE_DONE: begin
                // Wait until old pending vector really finishes.
                // Then promote current vector to pending in sequential logic.
                if (pending_done_now) begin
                    if (current_is_last) begin
                        state_n = LA_S_WAIT_LAST_PE_DONE;
                    end else begin
                        state_n = LA_S_NEXT;
                    end
                end
            end

            LA_S_WAIT_LAST_PE_DONE: begin
                if (pending_done_now) begin
                    state_n = LA_S_DONE;
                end
            end

            LA_S_NEXT: begin
                if ((vector_idx + 1) >= csv_vector_count) begin
                    // This path mainly handles zero-valid final vectors.
                    if (pending_valid && !pending_done_now) begin
                        state_n = LA_S_WAIT_LAST_PE_DONE;
                    end else begin
                        state_n = LA_S_DONE;
                    end
                end else begin
                    state_n = LA_S_REQ_A;
                end
            end

            LA_S_DONE: begin
                done = 1'b1;

                if (!start) begin
                    state_n = LA_S_IDLE;
                end
            end

            default: begin
                state_n = LA_S_IDLE;
            end
        endcase
    end

    // ============================================================
    // Sequential logic
    // ============================================================

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= LA_S_IDLE;
            vector_idx         <= '0;
            a_vec_reg          <= '0;
            row_base_reg       <= '0;
            k_reg              <= '0;
            valid_mask_reg     <= '0;
            eor_mask_reg       <= '0;
            a_val_reg          <= '0;
            row_idx_reg        <= '0;
            qa_accepted        <= '0;

            pending_valid      <= 1'b0;
            pending_mask_reg   <= '0;
            pending_done_seen  <= '0;

            current_done_seen  <= '0;
        end else begin
            state <= state_n;

            // Capture done pulses for old pending vector.
            if (pending_valid) begin
                pending_done_seen <= pending_done_seen | pending_done_fire;
            end

            // Capture done pulses for current lookahead vector.
            // These pulses may happen before current is promoted to pending.
            if ((state == LA_S_SEND_B_REQ)       ||
                (state == LA_S_WAIT_B_DONE)      ||
                (state == LA_S_WAIT_OLD_PE_DONE) ||
                (state == LA_S_WAIT_LAST_PE_DONE)) begin
                current_done_seen <= current_done_seen | current_done_fire;
            end

            if (state == LA_S_IDLE && start) begin
                vector_idx         <= '0;
                qa_accepted        <= '0;

                pending_valid      <= 1'b0;
                pending_mask_reg   <= '0;
                pending_done_seen  <= '0;

                current_done_seen  <= '0;
            end

            // A ROM is synchronous-read:
            // LA_S_REQ_A gives address and ena.
            // In the next cycle, ROM douta is valid.
            // LA_S_WAIT_A latches douta into a_vec_reg.
            if (state == LA_S_WAIT_A) begin
                a_vec_reg <= a_rom_douta;
            end

            if (state == LA_S_DECODE_A) begin
                logic [31:0] lane_word;

                row_base_reg   <= dec_word0[31:16];
                k_reg          <= dec_word0[15:0];
                eor_mask_reg   <= dec_eor_mask;
                valid_mask_reg <= dec_valid_mask;

                for (p = 0; p < PE_LANES; p = p + 1) begin
                    lane_word = get_word(a_vec_reg, LANE_WORD_BASE + p);

                    a_val_reg[p] <= lane_word[DATA_W-1:0];

                    if (csv_has_row_idx) begin
                        row_idx_reg[p] <= lane_word[31:16];
                    end else begin
                        row_idx_reg[p] <= dec_word0[31:16] + p;
                    end
                end

                qa_accepted       <= '0;
                current_done_seen <= '0;
            end

            if (state == LA_S_SEND_QA) begin
                qa_accepted <= qa_accepted | qa_fire;
            end

            // Promote current vector to pending.
            //
            // This happens when:
            //   1. current B row is done and there is no unfinished old pending; or
            //   2. we were waiting for old pending, and old pending just finished.
            //
            // Important:
            // pending_done_seen must inherit current_done_seen.
            if ((state == LA_S_WAIT_B_DONE && b_done && (!pending_valid || pending_done_now)) ||
                (state == LA_S_WAIT_OLD_PE_DONE && pending_done_now)) begin

                pending_valid     <= 1'b1;
                pending_mask_reg  <= valid_mask_reg;
                pending_done_seen <= current_done_seen | current_done_fire;

                current_done_seen <= '0;
            end

            // Final pending vector has really completed.
            if (state == LA_S_WAIT_LAST_PE_DONE && pending_done_now) begin
                pending_valid      <= 1'b0;
                pending_mask_reg   <= '0;
                pending_done_seen  <= '0;
                current_done_seen  <= '0;
            end

            if (state == LA_S_NEXT) begin
                if ((vector_idx + 1) < csv_vector_count) begin
                    vector_idx <= vector_idx + 1'b1;
                end

                qa_accepted <= '0;
            end

            if (state == LA_S_DONE && !start) begin
                vector_idx         <= '0;

                pending_valid      <= 1'b0;
                pending_mask_reg   <= '0;
                pending_done_seen  <= '0;

                current_done_seen  <= '0;
            end
        end
    end

endmodule

`default_nettype wire