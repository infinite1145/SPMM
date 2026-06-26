`timescale 1ns/1ps
`default_nettype none

module PE_B_RowPtr_ROM_2P #(
    parameter int ADDR_W = 10,
    parameter int DEPTH  = 1024,
    parameter string INIT_FILE = ""
)(
    // BRAM_PORTA
    input  wire              clka,
    input  wire              ena, 
    input  wire [ADDR_W-1:0] addra,
    output logic [31:0]      douta,

    // BRAM_PORTB
    input  wire              clkb,
    input  wire              enb,
    input  wire [ADDR_W-1:0] addrb,
    output logic [31:0]      doutb
);

    (* rom_style = "block" *)
    logic [31:0] mem [0:DEPTH-1];

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end

    // Port A synchronous read
    always_ff @(posedge clka) begin
        if (ena) begin
            douta <= mem[addra];
        end
    end

    // Port B synchronous read
    always_ff @(posedge clkb) begin
        if (enb) begin
            doutb <= mem[addrb];
        end
    end

endmodule

`default_nettype wire