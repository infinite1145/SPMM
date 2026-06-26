`timescale 1ns/1ps
`default_nettype none

module PE_C_Dense_RAM_TDP #(
    parameter int DATA_W = 16,
    parameter int ADDR_W = 18,
    parameter int DEPTH  = 512 * 512,
    parameter string INIT_FILE = ""
)(
    // BRAM_PORTA
    input  wire                  clka,
    input  wire                  ena,
    input  wire [0:0]            wea,
    input  wire [ADDR_W-1:0]     addra,
    input  wire [DATA_W-1:0]     dina,
    output reg  [DATA_W-1:0]     douta,

    // BRAM_PORTB
    input  wire                  clkb,
    input  wire                  enb,
    input  wire [0:0]            web,
    input  wire [ADDR_W-1:0]     addrb,
    input  wire [DATA_W-1:0]     dinb,
    output reg  [DATA_W-1:0]     doutb
);

    (* ram_style = "block" *)
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    integer init_i;

    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end else begin
            for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
                mem[init_i] = {DATA_W{1'b0}};
            end
        end
    end

    // Port A: synchronous read, write-first mode
    always @(posedge clka) begin
        if (ena) begin
            if (wea[0]) begin
                mem[addra] <= dina;
                douta      <= dina;
            end else begin
                douta      <= mem[addra];
            end
        end
    end

    // Port B: synchronous read, write-first mode
    always @(posedge clkb) begin
        if (enb) begin
            if (web[0]) begin
                mem[addrb] <= dinb;
                doutb      <= dinb;
            end else begin
                doutb      <= mem[addrb];
            end
        end
    end

endmodule

`default_nettype wire