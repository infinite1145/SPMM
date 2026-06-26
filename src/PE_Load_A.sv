`timescale 1ns/1ps
`default_nettype none

module PE_Load_A #(
    parameter int PE_LANES = 4,
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
    output logic                         a_rom_ena,
    output logic [A_ADDR_W-1:0]          a_rom_addra,
    input  wire [32*(2+PE_LANES)-1:0]    a_rom_douta,

    // QA channel to PE array
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
    input  wire b_done
);

    localparam int A_VEC_W = 32 * (2 + PE_LANES);

    typedef enum logic [3:0] {
        LA_S_IDLE,
        LA_S_REQ_A,
        LA_S_WAIT_A,
        LA_S_DECODE_A,
        LA_S_SEND_QA,
        LA_S_SEND_B_REQ,
        LA_S_WAIT_B_DONE,
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
    logic [31:0] dec_word1;
    logic [PE_LANES-1:0] dec_valid_mask;
    logic [PE_LANES-1:0] dec_eor_mask;

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

    assign dec_word0 = get_word(a_vec_reg, 0);
    assign dec_word1 = get_word(a_vec_reg, 1);

    assign dec_valid_mask = dec_word1[0  +: PE_LANES];
    assign dec_eor_mask   = dec_word1[16 +: PE_LANES];

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
                    state_n = LA_S_REQ_A;
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
                // 注意：这里必须用当前 a_vec_reg 解出来的 dec_valid_mask，
                // 不能用 valid_mask_reg，否则会拿到上一轮 vector 的 valid_mask。
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
                    state_n = LA_S_NEXT;
                end
            end

            LA_S_NEXT: begin
                if ((vector_idx + 1) >= csv_vector_count) begin
                    state_n = LA_S_DONE;
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

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= LA_S_IDLE;
            vector_idx     <= '0;
            a_vec_reg      <= '0;
            row_base_reg   <= '0;
            k_reg          <= '0;
            valid_mask_reg <= '0;
            eor_mask_reg   <= '0;
            a_val_reg      <= '0;
            row_idx_reg    <= '0;
            qa_accepted    <= '0;
        end else begin
            state <= state_n;

            if (state == LA_S_IDLE && start) begin
                vector_idx  <= '0;
                qa_accepted <= '0;
            end

            // A ROM 是同步读：
            // LA_S_REQ_A 给地址和 ena；
            // 下一个周期 ROM douta 有效；
            // LA_S_WAIT_A 末尾把 douta 锁存进 a_vec_reg。
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
                    lane_word = get_word(a_vec_reg, 2 + p);

                    a_val_reg[p] <= lane_word[DATA_W-1:0];

                    if (csv_has_row_idx) begin
                        row_idx_reg[p] <= lane_word[31:16];
                    end else begin
                        row_idx_reg[p] <= dec_word0[31:16] + p[IDX_W-1:0];
                    end
                end

                qa_accepted <= '0;
            end

            if (state == LA_S_SEND_QA) begin
                qa_accepted <= qa_accepted | qa_fire;
            end

            if (state == LA_S_NEXT) begin
                if ((vector_idx + 1) < csv_vector_count) begin
                    vector_idx <= vector_idx + 1'b1;
                end

                qa_accepted <= '0;
            end

            if (state == LA_S_DONE && !start) begin
                vector_idx <= '0;
            end
        end
    end

endmodule

`default_nettype wire