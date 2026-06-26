`timescale 1ns/1ps
`default_nettype none

module PE_Store #(
    parameter int PE_LANES   = 4,
    parameter int DATA_W     = 16,
    parameter int IDX_W      = 16,
    parameter int RESULT_W   = IDX_W + IDX_W + DATA_W,
    parameter int C_ADDR_W   = 18,
    parameter int FIFO_DEPTH = 512
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    input  wire load_done,

    input  wire [IDX_W-1:0] N,

    // Result input from PE array
    input  wire [PE_LANES-1:0]                  result_wr_en,
    input  wire [PE_LANES-1:0][RESULT_W-1:0]    result_wr_data,
    output logic [PE_LANES-1:0]                 result_full,

    // C dense RAM write port
    output logic                    c_ena,
    output logic [0:0]              c_wea,
    output logic [C_ADDR_W-1:0]     c_addra,
    output logic [DATA_W-1:0]       c_dina,

    output logic done,
    output logic busy
);

    localparam int FIFO_ADDR_W = $clog2(FIFO_DEPTH);
    localparam int PE_SEL_W    = (PE_LANES <= 1) ? 1 : $clog2(PE_LANES);

    logic [PE_LANES-1:0] fifo_in_ready;
    logic [PE_LANES-1:0] fifo_out_valid;
    logic [PE_LANES-1:0] fifo_out_ready;
    logic [PE_LANES-1:0][RESULT_W-1:0] fifo_out_data;
    logic [PE_LANES-1:0] fifo_full;
    logic [PE_LANES-1:0] fifo_empty;
    logic [PE_LANES-1:0][FIFO_ADDR_W:0] fifo_count;

    logic [PE_SEL_W-1:0] rr_ptr;
    logic [PE_SEL_W-1:0] sel_idx;
    logic sel_valid;

    logic [IDX_W-1:0]  sel_row;
    logic [IDX_W-1:0]  sel_col;
    logic [DATA_W-1:0] sel_val;

    logic [31:0] addr_calc;

    integer i;
    integer j;
    integer idx_int;

    genvar g;

    generate
        for (g = 0; g < PE_LANES; g = g + 1) begin : GEN_RESULT_FIFO
            PE_FIFO_512 #(
                .DATA_W(RESULT_W),
                .DEPTH(FIFO_DEPTH)
            ) u_result_fifo (
                .clk       (clk),
                .rst_n     (rst_n),

                .in_valid  (result_wr_en[g]),
                .in_ready  (fifo_in_ready[g]),
                .in_data   (result_wr_data[g]),

                .out_valid (fifo_out_valid[g]),
                .out_ready (fifo_out_ready[g]),
                .out_data  (fifo_out_data[g]),

                .full      (fifo_full[g]),
                .empty     (fifo_empty[g]),
                .count     (fifo_count[g])
            );

            assign result_full[g] = !fifo_in_ready[g];
        end
    endgenerate

    always_comb begin
        sel_valid = 1'b0;
        sel_idx   = rr_ptr;

        for (i = 0; i < PE_LANES; i = i + 1) begin
            idx_int = rr_ptr + i;
            if (idx_int >= PE_LANES) begin
                idx_int = idx_int - PE_LANES;
            end

            if (!sel_valid && fifo_out_valid[idx_int]) begin
                sel_valid = 1'b1;
                sel_idx   = idx_int[PE_SEL_W-1:0];
            end
        end
    end

    always_comb begin
        fifo_out_ready = '0;

        sel_row = '0;
        sel_col = '0;
        sel_val = '0;

        if (sel_valid) begin
            sel_row = fifo_out_data[sel_idx][RESULT_W-1 -: IDX_W];
            sel_col = fifo_out_data[sel_idx][DATA_W + IDX_W - 1 -: IDX_W];
            sel_val = fifo_out_data[sel_idx][DATA_W-1:0];

            fifo_out_ready[sel_idx] = 1'b1;
        end
    end

    always_comb begin
        addr_calc = sel_row * N + sel_col;

        c_ena   = sel_valid;
        c_wea   = sel_valid ? 1'b1 : 1'b0;
        c_addra = addr_calc[C_ADDR_W-1:0];
        c_dina  = sel_val;
    end

    always_comb begin
        busy = start && !done;
        done = load_done && (fifo_out_valid == '0);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr <= '0;
        end else begin
            if (!start) begin
                rr_ptr <= '0;
            end else if (sel_valid) begin
                if (sel_idx == PE_LANES-1) begin
                    rr_ptr <= '0;
                end else begin
                    rr_ptr <= sel_idx + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire