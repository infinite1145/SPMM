`timescale 1ns/1ps
`default_nettype none

module PE_B_Entry_ROM #(
    parameter int ADDR_W = 16,
    parameter int DEPTH  = 65536,
    parameter string INIT_FILE = ""
)(
    // BRAM_PORTA
    input  wire              clka,
    input  wire              ena,
    input  wire [ADDR_W-1:0] addra,
    output logic [31:0]      douta
);

    (* rom_style = "block" *)
    logic [31:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // Vivado BRAM style synchronous read, 1-cycle latency.
    always_ff @(posedge clka) begin
        if (ena) begin
            douta <= mem[addra];
        end
    end

endmodule

`default_nettype wire