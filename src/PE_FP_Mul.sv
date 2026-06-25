`include "pe_defines.svh"

module PE_FP_Mul #(
    parameter int PE_DATA_W_P = `PE_DATA_W
)(
    input  logic                    aclk,
    input  logic                    aresetn,

    input  logic [PE_DATA_W_P-1:0]  s_axis_a_tdata,
    input  logic                    s_axis_a_tvalid,
    output logic                    s_axis_a_tready,

    input  logic [PE_DATA_W_P-1:0]  s_axis_b_tdata,
    input  logic                    s_axis_b_tvalid,
    output logic                    s_axis_b_tready,

    output logic [PE_DATA_W_P-1:0]  m_axis_result_tdata,
    output logic                    m_axis_result_tvalid,
    input  logic                    m_axis_result_tready
);
`ifdef PE_USE_XILINX_FP_MUL_IP
    // Replace floating_point_mul with the actual Vivado Floating-Point IP name.
    floating_point_mul u_xilinx_fp_mul (
        .aclk                  (aclk),
        .s_axis_a_tdata        (s_axis_a_tdata),
        .s_axis_a_tready       (s_axis_a_tready),
        .s_axis_a_tvalid       (s_axis_a_tvalid),
        .s_axis_b_tdata        (s_axis_b_tdata),
        .s_axis_b_tready       (s_axis_b_tready),
        .s_axis_b_tvalid       (s_axis_b_tvalid),
        .m_axis_result_tdata   (m_axis_result_tdata),
        .m_axis_result_tready  (m_axis_result_tready),
        .m_axis_result_tvalid  (m_axis_result_tvalid)
    );
`else
    // Synthesizable IEEE-754 binary16 multiplier with Vivado Floating-Point
    // IP-like AXI-Stream handshake. The implementation is intended for RTL
    // simulation and FPGA bring-up before replacing with a vendor IP.
    // Supported: zero, normal, subnormal input normalization, infinity, NaN,
    // round-to-nearest-even. Overflow returns infinity.

    function automatic logic pe_is_nan16(input logic [15:0] x);
        pe_is_nan16 = (&x[14:10]) && (|x[9:0]);
    endfunction

    function automatic logic pe_is_inf16(input logic [15:0] x);
        pe_is_inf16 = (&x[14:10]) && !(|x[9:0]);
    endfunction

    function automatic logic pe_is_zero16(input logic [15:0] x);
        pe_is_zero16 = !(|x[14:0]);
    endfunction

    function automatic logic [31:0] pe_rshift_sticky32(
        input logic [31:0] value,
        input int          shamt
    );
        logic sticky;
        int i;
        begin
            if (shamt <= 0) begin
                pe_rshift_sticky32 = value;
            end else if (shamt >= 32) begin
                pe_rshift_sticky32 = (|value) ? 32'd1 : 32'd0;
            end else begin
                sticky = 1'b0;
                for (i = 0; i < shamt; i = i + 1) begin
                    sticky = sticky | value[i];
                end
                pe_rshift_sticky32 = (value >> shamt);
                pe_rshift_sticky32[0] = pe_rshift_sticky32[0] | sticky;
            end
        end
    endfunction

    function automatic logic [15:0] pe_fp16_mul_comb(
        input logic [15:0] a,
        input logic [15:0] b
    );
        logic sign_res;
        logic [4:0] exp_a_bits, exp_b_bits;
        logic [9:0] frac_a, frac_b;
        logic [10:0] mant_a, mant_b;
        logic [21:0] prod;
        logic [10:0] mant_main;
        logic [11:0] mant_round;
        logic guard_bit;
        logic round_bit;
        logic sticky_bit;
        logic inc_round;
        int signed exp_a_unb;
        int signed exp_b_unb;
        int signed exp_res_unb;
        int signed exp_biased;
        logic [31:0] sub_ext;
        int sub_shift;
        logic [9:0] sub_frac;
        logic [4:0] exp_out;
        begin
            sign_res   = a[15] ^ b[15];
            exp_a_bits = a[14:10];
            exp_b_bits = b[14:10];
            frac_a     = a[9:0];
            frac_b     = b[9:0];

            if (pe_is_nan16(a) || pe_is_nan16(b) ||
                ((pe_is_inf16(a) && pe_is_zero16(b)) || (pe_is_zero16(a) && pe_is_inf16(b)))) begin
                pe_fp16_mul_comb = 16'h7E00;
            end else if (pe_is_inf16(a) || pe_is_inf16(b)) begin
                pe_fp16_mul_comb = {sign_res, 5'h1F, 10'h000};
            end else if (pe_is_zero16(a) || pe_is_zero16(b)) begin
                pe_fp16_mul_comb = {sign_res, 15'h0000};
            end else begin
                if (exp_a_bits == 5'd0) begin
                    exp_a_unb = -14;
                    mant_a    = {1'b0, frac_a};
                end else begin
                    exp_a_unb = int'(exp_a_bits) - 15;
                    mant_a    = {1'b1, frac_a};
                end

                if (exp_b_bits == 5'd0) begin
                    exp_b_unb = -14;
                    mant_b    = {1'b0, frac_b};
                end else begin
                    exp_b_unb = int'(exp_b_bits) - 15;
                    mant_b    = {1'b1, frac_b};
                end

                prod = mant_a * mant_b;
                exp_res_unb = exp_a_unb + exp_b_unb;

                // Normalize product. prod is scaled by 2^20.
                if (prod[21]) begin
                    exp_res_unb = exp_res_unb + 1;
                    mant_main   = prod[21:11];
                    guard_bit   = prod[10];
                    round_bit   = prod[9];
                    sticky_bit  = |prod[8:0];
                end else begin
                    mant_main   = prod[20:10];
                    guard_bit   = prod[9];
                    round_bit   = prod[8];
                    sticky_bit  = |prod[7:0];
                end

                inc_round = guard_bit & (round_bit | sticky_bit | mant_main[0]);
                mant_round = {1'b0, mant_main} + {11'd0, inc_round};
                if (mant_round[11]) begin
                    exp_res_unb = exp_res_unb + 1;
                    mant_main   = mant_round[11:1];
                end else begin
                    mant_main   = mant_round[10:0];
                end

                exp_biased = exp_res_unb + 15;

                if (exp_biased >= 31) begin
                    pe_fp16_mul_comb = {sign_res, 5'h1F, 10'h000};
                end else if (exp_biased <= 0) begin
                    // Generate subnormal result when possible. mant_main has
                    // hidden bit included at bit 10.
                    sub_shift = 1 - exp_biased;
                    sub_ext   = {mant_main, 13'd0};
                    sub_ext   = pe_rshift_sticky32(sub_ext, sub_shift);
                    // Round subnormal fraction from bits [22:13].
                    sub_frac  = sub_ext[22:13];
                    if (sub_ext[12] & ((|sub_ext[11:0]) | sub_frac[0])) begin
                        sub_frac = sub_frac + 10'd1;
                    end
                    pe_fp16_mul_comb = {sign_res, 5'd0, sub_frac};
                end else begin
                    exp_out = exp_biased;
                    pe_fp16_mul_comb = {sign_res, exp_out, mant_main[9:0]};
                end
            end
        end
    endfunction

    logic [PE_DATA_W_P-1:0] result_r;
    logic                   valid_r;

    wire can_accept = (!valid_r) || m_axis_result_tready;
    wire in_fire    = can_accept && s_axis_a_tvalid && s_axis_b_tvalid;

    assign s_axis_a_tready       = can_accept;
    assign s_axis_b_tready       = can_accept;
    assign m_axis_result_tdata   = result_r;
    assign m_axis_result_tvalid  = valid_r;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            valid_r  <= 1'b0;
            result_r <= '0;
        end else if (can_accept) begin
            valid_r <= in_fire;
            if (in_fire) begin
                result_r <= pe_fp16_mul_comb(s_axis_a_tdata[15:0], s_axis_b_tdata[15:0]);
            end
        end
    end
`endif
endmodule
