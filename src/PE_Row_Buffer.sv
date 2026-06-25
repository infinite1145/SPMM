`include "pe_defines.svh"

module PE_Row_Buffer #(
    parameter int PE_BUF_DEPTH_P = `PE_BUF_DEPTH,
    parameter int PE_ENTRY_W_P   = `PE_ENTRY_W
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    clear,

    input  logic                    wr_en,
    input  logic [PE_ENTRY_W_P-1:0] wr_data,
    output logic                    full,

    input  logic                    rd_en,
    output logic [PE_ENTRY_W_P-1:0] rd_data,
    output logic                    empty,

    output logic [$clog2(PE_BUF_DEPTH_P+1)-1:0] count,
    output logic                    overflow,
    output logic                    underflow
);
    localparam int PE_PTR_W   = (PE_BUF_DEPTH_P <= 2) ? 1 : $clog2(PE_BUF_DEPTH_P);
    localparam int PE_COUNT_W = $clog2(PE_BUF_DEPTH_P + 1);

    logic [PE_ENTRY_W_P-1:0] mem [0:PE_BUF_DEPTH_P-1];
    logic [PE_PTR_W-1:0] rd_ptr;
    logic [PE_PTR_W-1:0] wr_ptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    assign full  = (count == PE_COUNT_W'(PE_BUF_DEPTH_P));
    assign empty = (count == '0);

    // First-word-fall-through style read. This is convenient for merge compare.
    // For BRAM-based implementation, this module can be replaced with a sync-read
    // version and one-cycle compare alignment.
    assign rd_data = empty ? '0 : mem[rd_ptr];

    function automatic logic [PE_PTR_W-1:0] pe_inc_ptr(input logic [PE_PTR_W-1:0] ptr);
        if (ptr == PE_BUF_DEPTH_P-1) begin
            pe_inc_ptr = '0;
        end else begin
            pe_inc_ptr = ptr + {{(PE_PTR_W-1){1'b0}}, 1'b1};
        end
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr    <= '0;
            wr_ptr    <= '0;
            count     <= '0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            overflow  <= wr_en && full;
            underflow <= rd_en && empty;

            if (clear) begin
                rd_ptr <= '0;
                wr_ptr <= '0;
                count  <= '0;
            end else begin
                if (do_wr) begin
                    mem[wr_ptr] <= wr_data;
                    wr_ptr <= pe_inc_ptr(wr_ptr);
                end

                if (do_rd) begin
                    rd_ptr <= pe_inc_ptr(rd_ptr);
                end

                unique case ({do_wr, do_rd})
                    2'b10: count <= count + 1'b1;
                    2'b01: count <= count - 1'b1;
                    default: count <= count;
                endcase
            end
        end
    end
endmodule
