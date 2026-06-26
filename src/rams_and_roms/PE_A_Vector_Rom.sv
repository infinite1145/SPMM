`timescale 1ns/1ps
`default_nettype none

module PE_A_Vector_ROM #(
    parameter int PE_LANES  = 4,
    parameter int ADDR_W    = 10,
    parameter int DEPTH     = 1024,
    parameter string INIT_FILE = ""
)(
    // BRAM_PORTA
    input  wire                         clka,
    input  wire                         ena,
    input  wire [ADDR_W-1:0]            addra,
    output logic [32*(2+PE_LANES)-1:0]  douta
);

    localparam int DATA_W = 32 * (2 + PE_LANES);

    (* rom_style = "block" *)
    logic [DATA_W-1:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // Vivado BRAM style synchronous read, 1-cycle latency.
    // When ena is low, douta holds previous value.
    always_ff @(posedge clka) begin
        if (ena) begin
            douta <= mem[addra];
        end
    end

endmodule

`default_nettype wire