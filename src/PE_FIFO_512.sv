`timescale 1ns/1ps
`default_nettype none

module PE_FIFO_512 #(
    parameter int DATA_W = 32,
    parameter int DEPTH  = 512,
    parameter int ADDR_W = $clog2(DEPTH)
)(
    input  wire              clk,
    input  wire              rst_n,

    input  wire              in_valid,
    output wire              in_ready,
    input  wire [DATA_W-1:0] in_data,

    output wire              out_valid,
    input  wire              out_ready,
    output wire [DATA_W-1:0] out_data,

    output wire              full,
    output wire              empty,
    output logic [ADDR_W:0]  count
);

    (* ram_style = "distributed" *)
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    logic [ADDR_W-1:0] wr_ptr;
    logic [ADDR_W-1:0] rd_ptr;

    wire do_push;
    wire do_pop;

    assign full      = (count == DEPTH);
    assign empty     = (count == 0);
    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = mem[rd_ptr];

    assign do_push = in_valid && in_ready;
    assign do_pop  = out_valid && out_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count  <= '0;
        end else begin
            unique case ({do_push, do_pop})
                2'b10: begin
                    mem[wr_ptr] <= in_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    count       <= count + 1'b1;
                end

                2'b01: begin
                    rd_ptr <= rd_ptr + 1'b1;
                    count  <= count - 1'b1;
                end

                2'b11: begin
                    mem[wr_ptr] <= in_data;
                    wr_ptr      <= wr_ptr + 1'b1;
                    rd_ptr      <= rd_ptr + 1'b1;
                    count       <= count;
                end

                default: begin
                    count <= count;
                end
            endcase
        end
    end

endmodule

`default_nettype wire