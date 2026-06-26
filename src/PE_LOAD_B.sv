`timescale 1ns/1ps
`default_nettype none

module PE_Load_B #(
    parameter int PE_LANES     = 4,
    parameter int DATA_W       = 16,
    parameter int IDX_W        = 16,
    parameter int B_PTR_ADDR_W = 16,
    parameter int B_ENT_ADDR_W = 16,
    parameter int FIFO_DEPTH   = 512
)(
    input  wire clk,
    input  wire rst_n,

    // Request from Load_A
    input  wire                     b_req_valid,
    output logic                    b_req_ready,
    input  wire [IDX_W-1:0]         b_req_k,
    input  wire [PE_LANES-1:0]      b_req_active_mask,

    output logic b_done,
    output logic busy,

    // B row_ptr ROM, dual-port, synchronous read
    output logic                     b_ptr_ena,
    output logic [B_PTR_ADDR_W-1:0]  b_ptr_addra,
    input  wire [31:0]               b_ptr_douta,

    output logic                     b_ptr_enb,
    output logic [B_PTR_ADDR_W-1:0]  b_ptr_addrb,
    input  wire [31:0]               b_ptr_doutb,

    // B entry ROM, synchronous read
    output logic                     b_ent_ena,
    output logic [B_ENT_ADDR_W-1:0]  b_ent_addra,
    input  wire [31:0]               b_ent_douta,

    // QB channel to PE array
    output logic [PE_LANES-1:0]                 qb_valid,
    input  wire  [PE_LANES-1:0]                 qb_ready,
    output logic [PE_LANES-1:0][IDX_W-1:0]      qb_col_idx,
    output logic [PE_LANES-1:0][DATA_W-1:0]     qb_val,
    output logic [PE_LANES-1:0]                 qb_last,
    output logic [PE_LANES-1:0]                 qb_empty
);

    localparam int B_FIFO_W = DATA_W + IDX_W + 2;
    localparam int FIFO_ADDR_W = $clog2(FIFO_DEPTH);

    typedef enum logic [3:0] {
        LB_S_IDLE,
        LB_S_REQ_PTR,
        LB_S_WAIT_PTR,
        LB_S_PREP,
        LB_S_LOAD_STREAM,
        LB_S_WAIT_DRAIN,
        LB_S_DONE
    } lb_state_e;

    lb_state_e state, state_n;

    logic [IDX_W-1:0] k_reg;
    logic [PE_LANES-1:0] active_mask_reg;
    logic [IDX_W:0] k_plus_one;

    logic [31:0] start_ptr;
    logic [31:0] end_ptr;
    logic [31:0] entry_ptr;

    logic rom_pending;
    logic rom_pending_last;

    logic entry_buf_valid;
    logic entry_buf_last;
    logic entry_buf_empty;
    logic [IDX_W-1:0]  entry_buf_col;
    logic [DATA_W-1:0] entry_buf_val;

    logic fifo_in_valid;
    logic fifo_in_ready;
    logic [B_FIFO_W-1:0] fifo_in_data;

    logic fifo_out_valid;
    logic fifo_out_ready;
    logic [B_FIFO_W-1:0] fifo_out_data;

    logic fifo_full;
    logic fifo_empty;
    logic [FIFO_ADDR_W:0] fifo_count;

    logic fifo_out_empty_flag;
    logic fifo_out_last_flag;
    logic [IDX_W-1:0]  fifo_out_col;
    logic [DATA_W-1:0] fifo_out_val;

    logic all_active_ready;
    logic all_entries_done;

    integer p,q;

    assign k_plus_one = {1'b0, k_reg} + 1'b1;

    assign fifo_in_valid = entry_buf_valid;
    assign fifo_in_data  = {entry_buf_empty, entry_buf_last, entry_buf_col, entry_buf_val};

    assign fifo_out_val        = fifo_out_data[DATA_W-1:0];
    assign fifo_out_col        = fifo_out_data[DATA_W +: IDX_W];
    assign fifo_out_last_flag  = fifo_out_data[DATA_W+IDX_W];
    assign fifo_out_empty_flag = fifo_out_data[DATA_W+IDX_W+1];

    PE_FIFO_512 #(
        .DATA_W(B_FIFO_W),
        .DEPTH(FIFO_DEPTH)
    ) u_b_row_fifo (
        .clk       (clk),
        .rst_n     (rst_n),

        .in_valid  (fifo_in_valid),
        .in_ready  (fifo_in_ready),
        .in_data   (fifo_in_data),

        .out_valid (fifo_out_valid),
        .out_ready (fifo_out_ready),
        .out_data  (fifo_out_data),

        .full      (fifo_full),
        .empty     (fifo_empty),
        .count     (fifo_count)
    );

    always_comb begin
        all_active_ready = 1'b1;

        for (q = 0; q < PE_LANES; q = q + 1) begin
            if (active_mask_reg[q] && !qb_ready[q]) begin
                all_active_ready = 1'b0;
            end
        end
    end

    assign fifo_out_ready = fifo_out_valid && all_active_ready && (active_mask_reg != '0);

    always_comb begin
        qb_valid   = '0;
        qb_col_idx = '0;
        qb_val     = '0;
        qb_last    = '0;
        qb_empty   = '0;

        for (p = 0; p < PE_LANES; p = p + 1) begin
            if (active_mask_reg[p]) begin
                qb_valid[p]   = fifo_out_valid;
                qb_col_idx[p] = fifo_out_col;
                qb_val[p]     = fifo_out_val;
                qb_last[p]    = fifo_out_last_flag;
                qb_empty[p]   = fifo_out_empty_flag;
            end
        end
    end

    assign all_entries_done =
        (entry_ptr >= end_ptr) &&
        !rom_pending &&
        !entry_buf_valid;

    always_comb begin
        b_req_ready = (state == LB_S_IDLE);
        b_done      = 1'b0;
        busy        = (state != LB_S_IDLE) && (state != LB_S_DONE);

        b_ptr_ena   = 1'b0;
        b_ptr_enb   = 1'b0;
        b_ptr_addra = k_reg[B_PTR_ADDR_W-1:0];
        b_ptr_addrb = k_plus_one[B_PTR_ADDR_W-1:0];

        b_ent_ena   = 1'b0;
        b_ent_addra = entry_ptr[B_ENT_ADDR_W-1:0];

        state_n     = state;

        unique case (state)
            LB_S_IDLE: begin
                if (b_req_valid) begin
                    state_n = LB_S_REQ_PTR;
                end
            end

            LB_S_REQ_PTR: begin
                b_ptr_ena   = 1'b1;
                b_ptr_enb   = 1'b1;
                b_ptr_addra = k_reg[B_PTR_ADDR_W-1:0];
                b_ptr_addrb = k_plus_one [B_PTR_ADDR_W-1:0];
                state_n     = LB_S_WAIT_PTR;
            end

            LB_S_WAIT_PTR: begin
                state_n = LB_S_PREP;
            end

            LB_S_PREP: begin
                state_n = LB_S_LOAD_STREAM;
            end

            LB_S_LOAD_STREAM: begin
                if (!rom_pending &&
                    !entry_buf_valid &&
                    (entry_ptr < end_ptr) &&
                    (fifo_count <= (FIFO_DEPTH - 2))) begin
                    b_ent_ena   = 1'b1;
                    b_ent_addra = entry_ptr[B_ENT_ADDR_W-1:0];
                end

                if (all_entries_done && fifo_empty) begin
                    state_n = LB_S_DONE;
                end
            end

            LB_S_DONE: begin
                b_done = 1'b1;
                state_n = LB_S_IDLE;
            end

            default: begin
                state_n = LB_S_IDLE;
            end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= LB_S_IDLE;
            k_reg             <= '0;
            active_mask_reg   <= '0;
            start_ptr         <= '0;
            end_ptr           <= '0;
            entry_ptr         <= '0;
            rom_pending       <= 1'b0;
            rom_pending_last  <= 1'b0;
            entry_buf_valid   <= 1'b0;
            entry_buf_last    <= 1'b0;
            entry_buf_empty   <= 1'b0;
            entry_buf_col     <= '0;
            entry_buf_val     <= '0;
        end else begin
            state <= state_n;

            if (state == LB_S_IDLE && b_req_valid && b_req_ready) begin
                k_reg           <= b_req_k;
                active_mask_reg <= b_req_active_mask;
            end

            if (state == LB_S_WAIT_PTR) begin
                start_ptr <= b_ptr_douta;
                end_ptr   <= b_ptr_doutb;
                entry_ptr <= b_ptr_douta;
            end

            if (state == LB_S_PREP) begin
                rom_pending      <= 1'b0;
                rom_pending_last <= 1'b0;
                entry_buf_valid  <= 1'b0;
                entry_buf_last   <= 1'b0;
                entry_buf_empty  <= 1'b0;
                entry_buf_col    <= '0;
                entry_buf_val    <= '0;

                if (start_ptr == end_ptr) begin
                    entry_buf_valid <= 1'b1;
                    entry_buf_last  <= 1'b1;
                    entry_buf_empty <= 1'b1;
                    entry_buf_col   <= '0;
                    entry_buf_val   <= '0;
                end
            end

            if (state == LB_S_LOAD_STREAM) begin
                if (entry_buf_valid && fifo_in_ready) begin
                    entry_buf_valid <= 1'b0;
                end

                if (rom_pending) begin
                    rom_pending     <= 1'b0;
                    entry_buf_valid <= 1'b1;
                    entry_buf_last  <= rom_pending_last;
                    entry_buf_empty <= 1'b0;
                    entry_buf_col   <= b_ent_douta[31:16];
                    entry_buf_val   <= b_ent_douta[15:0];
                end

                if (!rom_pending &&
                    !entry_buf_valid &&
                    (entry_ptr < end_ptr) &&
                    (fifo_count <= (FIFO_DEPTH - 2))) begin
                    rom_pending      <= 1'b1;
                    rom_pending_last <= (entry_ptr == (end_ptr - 1));
                    entry_ptr        <= entry_ptr + 1'b1;
                end
            end

            if (state == LB_S_DONE) begin
                active_mask_reg  <= '0;
                rom_pending      <= 1'b0;
                rom_pending_last <= 1'b0;
                entry_buf_valid  <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire