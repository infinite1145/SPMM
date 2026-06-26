`timescale 1ns/1ps
`default_nettype none

module PE_SpMM_Top #(
    parameter int PE_LANES        = 64,
    parameter int DATA_W          = 16,
    parameter int IDX_W           = 16,

    parameter int A_ADDR_W        = 16,
    parameter int A_DEPTH         = 65536,

    parameter int B_PTR_ADDR_W    = 16,
    parameter int B_PTR_DEPTH     = 65536,

    parameter int B_ENT_ADDR_W    = 16,
    parameter int B_ENT_DEPTH     = 65536,

    parameter int C_ADDR_W        = 18,
    parameter int C_DEPTH         = 512 * 512,

    parameter int FIFO_DEPTH      = 512,

    parameter string A_INIT_FILE      = "",
    parameter string B_PTR_INIT_FILE  = "",
    parameter string B_ENT_INIT_FILE  = "",
    parameter string C_INIT_FILE      = ""
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,

    input  wire [IDX_W-1:0] cfg_m,
    input  wire [IDX_W-1:0] cfg_n,
    input  wire [31:0]      cfg_csv_vector_count,
    input  wire             cfg_csv_has_row_idx,

    output logic done,
    output logic busy,

    output logic [31:0] cycle_count,
    output logic [31:0] compute_cycle_count,

    // Debug read port for dense C RAM.
    // This port maps to C_BRAM port B.
    input  wire                  dbg_c_en,
    input  wire [C_ADDR_W-1:0]   dbg_c_addr,
    output wire [DATA_W-1:0]     dbg_c_dout
);

    localparam int RESULT_W  = IDX_W + IDX_W + DATA_W;

    // 64PE fixed CSV vector format:
    // word0              = {row_base[15:0], k[15:0]}
    // word1              = valid_mask[31:0]
    // word2              = valid_mask[63:32]
    // word3              = eor_mask[31:0]
    // word4              = eor_mask[63:32]
    // word5 ~ word68     = lane_word[0] ~ lane_word[63]
    localparam int A_VEC_W   = 32 * 69;

    // QA FIFO payload:
    // {qa_eor, qa_row_idx, qa_val}
    localparam int QA_FIFO_W = 1 + IDX_W + DATA_W;

    // QB FIFO payload:
    // {qb_empty, qb_last, qb_col_idx, qb_val}
    localparam int QB_FIFO_W = 2 + IDX_W + DATA_W;

    typedef enum logic [2:0] {
        TOP_S_IDLE,
        TOP_S_CLEAR_C,
        TOP_S_RUN,
        TOP_S_DONE
    } top_state_e;

    top_state_e state, state_n;

    logic [IDX_W-1:0] m_reg;
    logic [IDX_W-1:0] n_reg;
    logic [31:0]      csv_vector_count_reg;
    logic             csv_has_row_idx_reg;

    logic [31:0] c_total_elems;
    logic [31:0] c_clear_addr;

    // ============================================================
    // A vector ROM interface
    // ============================================================

    logic                  a_rom_ena;
    logic [A_ADDR_W-1:0]   a_rom_addra;
    logic [A_VEC_W-1:0]    a_rom_douta;

    // ============================================================
    // B row_ptr ROM interface
    // ============================================================

    logic                     b_ptr_ena;
    logic [B_PTR_ADDR_W-1:0]  b_ptr_addra;
    logic [31:0]              b_ptr_douta;

    logic                     b_ptr_enb;
    logic [B_PTR_ADDR_W-1:0]  b_ptr_addrb;
    logic [31:0]              b_ptr_doutb;

    // ============================================================
    // B entry ROM interface
    // ============================================================

    logic                     b_ent_ena;
    logic [B_ENT_ADDR_W-1:0]  b_ent_addra;
    logic [31:0]              b_ent_douta;

    // ============================================================
    // C RAM write/debug interface
    // ============================================================

    logic                  c_ena_store;
    logic [0:0]            c_wea_store;
    logic [C_ADDR_W-1:0]   c_addra_store;
    logic [DATA_W-1:0]     c_dina_store;

    logic                  c_ena_mux;
    logic [0:0]            c_wea_mux;
    logic [C_ADDR_W-1:0]   c_addra_mux;
    logic [DATA_W-1:0]     c_dina_mux;
    logic [DATA_W-1:0]     c_douta_unused;

    // ============================================================
    // Load / Store / PE control
    // ============================================================

    logic core_start;

    logic load_a_done;
    logic load_a_busy;

    logic load_b_done;
    logic load_b_busy;

    logic store_done;
    logic store_busy;

    logic store_finish_condition;

    // ============================================================
    // Load_A raw QA channel
    // Load_A -> QA_FIFO
    // ============================================================

    logic [PE_LANES-1:0]                 la_qa_valid;
    logic [PE_LANES-1:0]                 la_qa_ready;
    logic [PE_LANES-1:0][IDX_W-1:0]      la_qa_row_idx;
    logic [PE_LANES-1:0][DATA_W-1:0]     la_qa_val;
    logic [PE_LANES-1:0]                 la_qa_eor;

    // ============================================================
    // PE QA channel
    // QA_FIFO -> PE
    // ============================================================

    logic [PE_LANES-1:0]                 qa_valid;
    logic [PE_LANES-1:0]                 qa_ready;
    logic [PE_LANES-1:0][IDX_W-1:0]      qa_row_idx;
    logic [PE_LANES-1:0][DATA_W-1:0]     qa_val;
    logic [PE_LANES-1:0]                 qa_eor;

    logic [PE_LANES-1:0][QA_FIFO_W-1:0]  qa_fifo_in_data;
    logic [PE_LANES-1:0][QA_FIFO_W-1:0]  qa_fifo_out_data;
    logic [PE_LANES-1:0]                 qa_fifo_full;
    logic [PE_LANES-1:0]                 qa_fifo_empty;

    // ============================================================
    // Load_B raw QB channel
    // Load_B -> QB_FIFO
    // ============================================================

    logic [PE_LANES-1:0]                 lb_qb_valid;
    logic [PE_LANES-1:0]                 lb_qb_ready;
    logic [PE_LANES-1:0][IDX_W-1:0]      lb_qb_col_idx;
    logic [PE_LANES-1:0][DATA_W-1:0]     lb_qb_val;
    logic [PE_LANES-1:0]                 lb_qb_last;
    logic [PE_LANES-1:0]                 lb_qb_empty;

    // ============================================================
    // PE QB channel
    // QB_FIFO -> PE
    // ============================================================

    logic [PE_LANES-1:0]                 qb_valid;
    logic [PE_LANES-1:0]                 qb_ready;
    logic [PE_LANES-1:0][IDX_W-1:0]      qb_col_idx;
    logic [PE_LANES-1:0][DATA_W-1:0]     qb_val;
    logic [PE_LANES-1:0]                 qb_last;
    logic [PE_LANES-1:0]                 qb_empty;

    logic [PE_LANES-1:0][QB_FIFO_W-1:0]  qb_fifo_in_data;
    logic [PE_LANES-1:0][QB_FIFO_W-1:0]  qb_fifo_out_data;
    logic [PE_LANES-1:0]                 qb_fifo_full;
    logic [PE_LANES-1:0]                 qb_fifo_empty;

    // ============================================================
    // Load_A -> Load_B request
    // ============================================================

    logic                    b_req_valid;
    logic                    b_req_ready;
    logic [IDX_W-1:0]        b_req_k;
    logic [PE_LANES-1:0]     b_req_active_mask;

    // ============================================================
    // PE result channel
    // ============================================================

    logic [PE_LANES-1:0]                  result_wr_en;
    logic [PE_LANES-1:0][RESULT_W-1:0]    result_wr_data;
    logic [PE_LANES-1:0]                  result_full;

    logic [PE_LANES-1:0] pe_busy;
    logic [PE_LANES-1:0] pe_round_done;
    logic [PE_LANES-1:0] pe_error;

    wire all_pe_idle;
    wire any_pe_error;
    wire qa_fifos_empty;
    wire qb_fifos_empty;

    assign all_pe_idle    = (pe_busy == '0);
    assign any_pe_error   = |pe_error;
    assign qa_fifos_empty = &qa_fifo_empty;
    assign qb_fifos_empty = &qb_fifo_empty;

    // Store should finish only after:
    // 1. Load_A has no more vectors;
    // 2. Load_B is not busy;
    // 3. QA/QB FIFOs are empty;
    // 4. all PE instances are idle;
    // 5. Store internal result FIFOs have drained.
    assign store_finish_condition =
        load_a_done &&
        !load_b_busy &&
        qa_fifos_empty &&
        qb_fifos_empty &&
        all_pe_idle;

    assign core_start = (state == TOP_S_RUN);

    assign c_total_elems = cfg_m * cfg_n;

    // ============================================================
    // Top FSM
    // ============================================================

    always_comb begin
        state_n = state;

        done = 1'b0;
        busy = 1'b0;

        unique case (state)
            TOP_S_IDLE: begin
                done = 1'b0;
                busy = 1'b0;

                if (start) begin
                    if (c_total_elems == 0) begin
                        state_n = TOP_S_RUN;
                    end else begin
                        state_n = TOP_S_CLEAR_C;
                    end
                end
            end

            TOP_S_CLEAR_C: begin
                busy = 1'b1;

                if (c_clear_addr == (c_total_elems - 1)) begin
                    state_n = TOP_S_RUN;
                end
            end

            TOP_S_RUN: begin
                busy = 1'b1;

                if (store_done) begin
                    state_n = TOP_S_DONE;
                end
            end

            TOP_S_DONE: begin
                done = 1'b1;
                busy = 1'b0;

                if (!start) begin
                    state_n = TOP_S_IDLE;
                end
            end

            default: begin
                state_n = TOP_S_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= TOP_S_IDLE;
            m_reg                <= '0;
            n_reg                <= '0;
            csv_vector_count_reg <= '0;
            csv_has_row_idx_reg  <= 1'b0;
            c_clear_addr         <= '0;
            cycle_count          <= '0;
            compute_cycle_count  <= '0;
        end else begin
            state <= state_n;

            if (state == TOP_S_IDLE && start) begin
                m_reg                <= cfg_m;
                n_reg                <= cfg_n;
                csv_vector_count_reg <= cfg_csv_vector_count;
                csv_has_row_idx_reg  <= cfg_csv_has_row_idx;
                c_clear_addr         <= '0;
                cycle_count          <= '0;
                compute_cycle_count  <= '0;
            end else begin
                if (state != TOP_S_IDLE && state != TOP_S_DONE) begin
                    cycle_count <= cycle_count + 1'b1;
                end

                if (state == TOP_S_RUN) begin
                    compute_cycle_count <= compute_cycle_count + 1'b1;
                end
            end

            if (state == TOP_S_CLEAR_C) begin
                if (c_clear_addr < (c_total_elems - 1)) begin
                    c_clear_addr <= c_clear_addr + 1'b1;
                end
            end

            if (any_pe_error) begin
                // 后续可以扩展 error 输出。
            end
        end
    end

    // ============================================================
    // C RAM port A mux:
    //   CLEAR_C has priority before compute starts.
    //   RUN state uses Store module.
    // ============================================================

    always_comb begin
        if (state == TOP_S_CLEAR_C) begin
            c_ena_mux   = 1'b1;
            c_wea_mux   = 1'b1;
            c_addra_mux = c_clear_addr[C_ADDR_W-1:0];
            c_dina_mux  = '0;
        end else begin
            c_ena_mux   = c_ena_store;
            c_wea_mux   = c_wea_store;
            c_addra_mux = c_addra_store;
            c_dina_mux  = c_dina_store;
        end
    end

    // ============================================================
    // Memories
    // ============================================================

    PE_A_Vector_ROM #(
        .ADDR_W    (A_ADDR_W),
        .DEPTH     (A_DEPTH),
        .INIT_FILE (A_INIT_FILE)
    ) u_a_vector_rom (
        .clka   (clk),
        .ena    (a_rom_ena),
        .addra  (a_rom_addra),
        .douta  (a_rom_douta)
    );

    PE_B_RowPtr_ROM_2P #(
        .ADDR_W    (B_PTR_ADDR_W),
        .DEPTH     (B_PTR_DEPTH),
        .INIT_FILE (B_PTR_INIT_FILE)
    ) u_b_rowptr_rom (
        .clka   (clk),
        .ena    (b_ptr_ena),
        .addra  (b_ptr_addra),
        .douta  (b_ptr_douta),

        .clkb   (clk),
        .enb    (b_ptr_enb),
        .addrb  (b_ptr_addrb),
        .doutb  (b_ptr_doutb)
    );

    PE_B_Entry_ROM #(
        .ADDR_W    (B_ENT_ADDR_W),
        .DEPTH     (B_ENT_DEPTH),
        .INIT_FILE (B_ENT_INIT_FILE)
    ) u_b_entry_rom (
        .clka   (clk),
        .ena    (b_ent_ena),
        .addra  (b_ent_addra),
        .douta  (b_ent_douta)
    );

    PE_C_Dense_RAM_TDP #(
        .DATA_W    (DATA_W),
        .ADDR_W    (C_ADDR_W),
        .DEPTH     (C_DEPTH),
        .INIT_FILE (C_INIT_FILE)
    ) u_c_dense_ram (
        // Port A: clear / store write
        .clka   (clk),
        .ena    (c_ena_mux),
        .wea    (c_wea_mux),
        .addra  (c_addra_mux),
        .dina   (c_dina_mux),
        .douta  (c_douta_unused),

        // Port B: debug read
        .clkb   (clk),
        .enb    (dbg_c_en),
        .web    (1'b0),
        .addrb  (dbg_c_addr),
        .dinb   ('0),
        .doutb  (dbg_c_dout)
    );

    // ============================================================
    // Load_A
    // ============================================================

    PE_Load_A #(
        .PE_LANES (PE_LANES),
        .DATA_W   (DATA_W),
        .IDX_W    (IDX_W),
        .A_ADDR_W (A_ADDR_W)
    ) u_load_a (
        .clk                  (clk),
        .rst_n                (rst_n),

        .start                (core_start),
        .done                 (load_a_done),
        .busy                 (load_a_busy),

        .csv_vector_count      (csv_vector_count_reg),
        .csv_has_row_idx       (csv_has_row_idx_reg),

        .a_rom_ena             (a_rom_ena),
        .a_rom_addra           (a_rom_addra),
        .a_rom_douta           (a_rom_douta),

        .qa_valid              (la_qa_valid),
        .qa_ready              (la_qa_ready),
        .qa_row_idx            (la_qa_row_idx),
        .qa_val                (la_qa_val),
        .qa_eor                (la_qa_eor),

        .b_req_valid           (b_req_valid),
        .b_req_ready           (b_req_ready),
        .b_req_k               (b_req_k),
        .b_req_active_mask     (b_req_active_mask),

        .b_done                (load_b_done),
        .pe_round_done         (pe_round_done)
    );

    // ============================================================
    // Load_B
    // ============================================================

    PE_Load_B #(
        .PE_LANES     (PE_LANES),
        .DATA_W       (DATA_W),
        .IDX_W        (IDX_W),
        .B_PTR_ADDR_W (B_PTR_ADDR_W),
        .B_ENT_ADDR_W (B_ENT_ADDR_W),
        .FIFO_DEPTH   (FIFO_DEPTH)
    ) u_load_b (
        .clk                  (clk),
        .rst_n                (rst_n),

        .b_req_valid           (b_req_valid),
        .b_req_ready           (b_req_ready),
        .b_req_k               (b_req_k),
        .b_req_active_mask     (b_req_active_mask),

        .b_done                (load_b_done),
        .busy                  (load_b_busy),

        .b_ptr_ena             (b_ptr_ena),
        .b_ptr_addra           (b_ptr_addra),
        .b_ptr_douta           (b_ptr_douta),

        .b_ptr_enb             (b_ptr_enb),
        .b_ptr_addrb           (b_ptr_addrb),
        .b_ptr_doutb           (b_ptr_doutb),

        .b_ent_ena             (b_ent_ena),
        .b_ent_addra           (b_ent_addra),
        .b_ent_douta           (b_ent_douta),

        .qb_valid              (lb_qb_valid),
        .qb_ready              (lb_qb_ready),
        .qb_col_idx            (lb_qb_col_idx),
        .qb_val                (lb_qb_val),
        .qb_last               (lb_qb_last),
        .qb_empty              (lb_qb_empty)
    );

    // ============================================================
    // QA / QB interface FIFOs
    // ============================================================

    genvar fifo_g;
    generate
        for (fifo_g = 0; fifo_g < PE_LANES; fifo_g = fifo_g + 1) begin : GEN_INTERFACE_FIFO

            // ----------------------------
            // QA FIFO: Load_A -> PE
            // payload = {qa_eor, qa_row_idx, qa_val}
            // ----------------------------
            assign qa_fifo_in_data[fifo_g] = {
                la_qa_eor[fifo_g],
                la_qa_row_idx[fifo_g],
                la_qa_val[fifo_g]
            };

            PE_FIFO_512 #(
                .DATA_W (QA_FIFO_W),
                .DEPTH  (FIFO_DEPTH)
            ) u_qa_fifo (
                .clk       (clk),
                .rst_n     (rst_n),

                .in_valid  (la_qa_valid[fifo_g]),
                .in_ready  (la_qa_ready[fifo_g]),
                .in_data   (qa_fifo_in_data[fifo_g]),

                .out_valid (qa_valid[fifo_g]),
                .out_ready (qa_ready[fifo_g]),
                .out_data  (qa_fifo_out_data[fifo_g]),

                .full      (qa_fifo_full[fifo_g]),
                .empty     (qa_fifo_empty[fifo_g]),
                .count     ()
            );

            assign qa_val[fifo_g] =
                qa_fifo_out_data[fifo_g][DATA_W-1:0];

            assign qa_row_idx[fifo_g] =
                qa_fifo_out_data[fifo_g][DATA_W +: IDX_W];

            assign qa_eor[fifo_g] =
                qa_fifo_out_data[fifo_g][DATA_W + IDX_W];

            // ----------------------------
            // QB FIFO: Load_B -> PE
            // payload = {qb_empty, qb_last, qb_col_idx, qb_val}
            // ----------------------------
            assign qb_fifo_in_data[fifo_g] = {
                lb_qb_empty[fifo_g],
                lb_qb_last[fifo_g],
                lb_qb_col_idx[fifo_g],
                lb_qb_val[fifo_g]
            };

            PE_FIFO_512 #(
                .DATA_W (QB_FIFO_W),
                .DEPTH  (FIFO_DEPTH)
            ) u_qb_fifo (
                .clk       (clk),
                .rst_n     (rst_n),

                .in_valid  (lb_qb_valid[fifo_g]),
                .in_ready  (lb_qb_ready[fifo_g]),
                .in_data   (qb_fifo_in_data[fifo_g]),

                .out_valid (qb_valid[fifo_g]),
                .out_ready (qb_ready[fifo_g]),
                .out_data  (qb_fifo_out_data[fifo_g]),

                .full      (qb_fifo_full[fifo_g]),
                .empty     (qb_fifo_empty[fifo_g]),
                .count     ()
            );

            assign qb_val[fifo_g] =
                qb_fifo_out_data[fifo_g][DATA_W-1:0];

            assign qb_col_idx[fifo_g] =
                qb_fifo_out_data[fifo_g][DATA_W +: IDX_W];

            assign qb_last[fifo_g] =
                qb_fifo_out_data[fifo_g][DATA_W + IDX_W];

            assign qb_empty[fifo_g] =
                qb_fifo_out_data[fifo_g][DATA_W + IDX_W + 1];

        end
    endgenerate

    // ============================================================
    // PE array
    // ============================================================

    genvar pe_g;
    generate
        for (pe_g = 0; pe_g < PE_LANES; pe_g = pe_g + 1) begin : GEN_PE
            PE_Core u_pe_core (
                .clk            (clk),
                .rst_n          (rst_n),

                .qa_valid       (qa_valid[pe_g]),
                .qa_ready       (qa_ready[pe_g]),
                .qa_row_idx     (qa_row_idx[pe_g]),
                .qa_val         (qa_val[pe_g]),
                .qa_eor         (qa_eor[pe_g]),

                .qb_valid       (qb_valid[pe_g]),
                .qb_ready       (qb_ready[pe_g]),
                .qb_col_idx     (qb_col_idx[pe_g]),
                .qb_val         (qb_val[pe_g]),
                .qb_last        (qb_last[pe_g]),
                .qb_empty       (qb_empty[pe_g]),

                .result_wr_en   (result_wr_en[pe_g]),
                .result_wr_data (result_wr_data[pe_g]),
                .result_full    (result_full[pe_g]),

                .pe_busy        (pe_busy[pe_g]),
                .pe_round_done  (pe_round_done[pe_g]),
                .pe_error       (pe_error[pe_g])
            );
        end
    endgenerate

    // ============================================================
    // Store
    // ============================================================

    PE_Store #(
        .PE_LANES   (PE_LANES),
        .DATA_W     (DATA_W),
        .IDX_W      (IDX_W),
        .RESULT_W   (RESULT_W),
        .C_ADDR_W   (C_ADDR_W),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_store (
        .clk             (clk),
        .rst_n           (rst_n),

        .start           (core_start),
        .load_done       (store_finish_condition),

        .N               (n_reg),

        .result_wr_en    (result_wr_en),
        .result_wr_data  (result_wr_data),
        .result_full     (result_full),

        .c_ena           (c_ena_store),
        .c_wea           (c_wea_store),
        .c_addra         (c_addra_store),
        .c_dina          (c_dina_store),

        .done            (store_done),
        .busy            (store_busy)
    );

endmodule

`default_nettype wire