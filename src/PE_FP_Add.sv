`include "pe_defines.svh"

module PE_FP_Add #(
    parameter int PE_DATA_W_P = `PE_DATA_W
)(
    input  logic                    aclk,
    input  logic                    aresetn,

    input  logic [PE_DATA_W_P-1:0]  s_axis_a_tdata,
    input  logic                    s_axis_a_tvalid,
    output logic                    s_axis_a_tready,
    input  logic                    s_axis_a_tlast,

    input  logic [PE_DATA_W_P-1:0]  s_axis_b_tdata,
    input  logic                    s_axis_b_tvalid,
    output logic                    s_axis_b_tready,

    output logic [PE_DATA_W_P-1:0]  m_axis_result_tdata,
    output logic                    m_axis_result_tvalid,
    input  logic                    m_axis_result_tready,
    output logic                    m_axis_result_tlast
);
`ifdef PE_USE_XILINX_FP_ADD_IP
    // Replace floating_point_add with the actual Vivado Floating-Point IP name.
    floating_point_add u_xilinx_fp_add (
        .aclk                  (aclk),
        .s_axis_a_tdata        (s_axis_a_tdata),
        .s_axis_a_tlast        (s_axis_a_tlast),
        .s_axis_a_tready       (s_axis_a_tready),
        .s_axis_a_tvalid       (s_axis_a_tvalid),
        .s_axis_b_tdata        (s_axis_b_tdata),
        .s_axis_b_tready       (s_axis_b_tready),
        .s_axis_b_tvalid       (s_axis_b_tvalid),
        .m_axis_result_tdata   (m_axis_result_tdata),
        .m_axis_result_tlast   (m_axis_result_tlast),
        .m_axis_result_tready  (m_axis_result_tready),
        .m_axis_result_tvalid  (m_axis_result_tvalid)
    );
`else
    // Synthesizable IEEE-754 binary16 adder with Vivado Floating-Point IP-like
    // AXI-Stream handshake. It performs round-to-nearest-even and handles
    // zero, normal, subnormal, infinity, and NaN cases.

    function automatic logic pe_is_nan16(input logic [15:0] x);
        pe_is_nan16 = (&x[14:10]) && (|x[9:0]);
    endfunction

    function automatic logic pe_is_inf16(input logic [15:0] x);
        pe_is_inf16 = (&x[14:10]) && !(|x[9:0]);
    endfunction

    function automatic logic pe_is_zero16(input logic [15:0] x);
        pe_is_zero16 = !(|x[14:0]);
    endfunction

    function automatic logic [15:0] pe_rshift_sticky16(
        input logic [15:0] value,
        input int          shamt
    );
        logic sticky;
        int i;
        begin
            if (shamt <= 0) begin
                pe_rshift_sticky16 = value;
            end else if (shamt >= 16) begin
                pe_rshift_sticky16 = (|value) ? 16'd1 : 16'd0;
            end else begin
                sticky = 1'b0;
                for (i = 0; i < shamt; i = i + 1) begin
                    sticky = sticky | value[i];
                end
                pe_rshift_sticky16 = (value >> shamt);
                pe_rshift_sticky16[0] = pe_rshift_sticky16[0] | sticky;
            end
        end
    endfunction

    function automatic logic [15:0] pe_pack_from_ext(
        input logic        sign_res,
        input int signed   exp_unb_in,
        input logic [15:0] ext_in
    );
        logic [15:0] ext_norm;
        logic [10:0] mant_main;
        logic [11:0] mant_round;
        logic [9:0]  frac_norm;
        logic [9:0]  frac_sub;
        logic guard_bit;
        logic round_bit;
        logic sticky_bit;
        logic inc_round;
        int signed exp_unb;
        int signed exp_bias;
        int sub_shift;
        logic [15:0] sub_ext;
        logic [4:0] exp_out;
        int n;
        begin
            ext_norm = ext_in;
            exp_unb  = exp_unb_in;

            if (ext_norm == 16'd0) begin
                pe_pack_from_ext = 16'h0000;
            end else begin
                // If carry is present, shift down once.
                if (ext_norm[15]) begin
                    ext_norm = pe_rshift_sticky16(ext_norm, 1);
                    exp_unb  = exp_unb + 1;
                end else begin
                    // Normalize left until hidden bit is at bit 14 or exponent
                    // reaches the minimum normal exponent.
                    for (n = 0; n < 15; n = n + 1) begin
                        if (!ext_norm[14] && (exp_unb > -14) && (ext_norm != 16'd0)) begin
                            ext_norm = ext_norm << 1;
                            exp_unb  = exp_unb - 1;
                        end
                    end
                end

                exp_bias = exp_unb + 15;

                if (exp_bias >= 31) begin
                    pe_pack_from_ext = {sign_res, 5'h1F, 10'h000};
                end else if (exp_bias <= 0) begin
                    // Subnormal. Shift significand to exponent -14.
                    sub_shift = 1 - exp_bias;
                    sub_ext   = pe_rshift_sticky16(ext_norm, sub_shift);
                    frac_sub  = sub_ext[13:4];
                    if (sub_ext[3] & ((|sub_ext[2:0]) | frac_sub[0])) begin
                        frac_sub = frac_sub + 10'd1;
                    end
                    pe_pack_from_ext = {sign_res, 5'd0, frac_sub};
                end else begin
                    mant_main  = ext_norm[14:4];
                    guard_bit  = ext_norm[3];
                    round_bit  = ext_norm[2];
                    sticky_bit = |ext_norm[1:0];
                    inc_round  = guard_bit & (round_bit | sticky_bit | mant_main[0]);
                    mant_round = {1'b0, mant_main} + {11'd0, inc_round};

                    if (mant_round[11]) begin
                        exp_bias = exp_bias + 1;
                        if (exp_bias >= 31) begin
                            pe_pack_from_ext = {sign_res, 5'h1F, 10'h000};
                        end else begin
                            frac_norm = mant_round[10:1];
                            exp_out = exp_bias;
                            pe_pack_from_ext = {sign_res, exp_out, frac_norm};
                        end
                    end else begin
                        frac_norm = mant_round[9:0];
                        exp_out = exp_bias;
                        pe_pack_from_ext = {sign_res, exp_out, frac_norm};
                    end
                end
            end
        end
    endfunction

    function automatic logic [15:0] pe_fp16_add_comb(
        input logic [15:0] a,
        input logic [15:0] b
    );
        logic sign_a, sign_b;
        logic [4:0] exp_a_bits, exp_b_bits;
        logic [9:0] frac_a, frac_b;
        logic [10:0] mant_a, mant_b;
        logic [15:0] ext_a, ext_b, ext_small, ext_big, ext_res;
        logic sign_big, sign_small, sign_res;
        int signed exp_a_unb, exp_b_unb, exp_big, exp_small;
        int signed diff;
        logic a_mag_ge_b;
        begin
            sign_a     = a[15];
            sign_b     = b[15];
            exp_a_bits = a[14:10];
            exp_b_bits = b[14:10];
            frac_a     = a[9:0];
            frac_b     = b[9:0];

            if (pe_is_nan16(a) || pe_is_nan16(b)) begin
                pe_fp16_add_comb = 16'h7E00;
            end else if (pe_is_inf16(a) && pe_is_inf16(b) && (sign_a != sign_b)) begin
                pe_fp16_add_comb = 16'h7E00;
            end else if (pe_is_inf16(a)) begin
                pe_fp16_add_comb = a;
            end else if (pe_is_inf16(b)) begin
                pe_fp16_add_comb = b;
            end else if (pe_is_zero16(a) && pe_is_zero16(b)) begin
                // Prefer +0 for exact cancellation or both zero.
                pe_fp16_add_comb = 16'h0000;
            end else if (pe_is_zero16(a)) begin
                pe_fp16_add_comb = b;
            end else if (pe_is_zero16(b)) begin
                pe_fp16_add_comb = a;
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

                ext_a = {1'b0, mant_a, 4'd0}; // hidden bit nominally at bit 14
                ext_b = {1'b0, mant_b, 4'd0};

                if (exp_a_unb > exp_b_unb) begin
                    a_mag_ge_b = 1'b1;
                end else if (exp_a_unb < exp_b_unb) begin
                    a_mag_ge_b = 1'b0;
                end else begin
                    a_mag_ge_b = (mant_a >= mant_b);
                end

                if (a_mag_ge_b) begin
                    ext_big    = ext_a;
                    ext_small  = ext_b;
                    exp_big    = exp_a_unb;
                    exp_small  = exp_b_unb;
                    sign_big   = sign_a;
                    sign_small = sign_b;
                end else begin
                    ext_big    = ext_b;
                    ext_small  = ext_a;
                    exp_big    = exp_b_unb;
                    exp_small  = exp_a_unb;
                    sign_big   = sign_b;
                    sign_small = sign_a;
                end

                diff      = exp_big - exp_small;
                ext_small = pe_rshift_sticky16(ext_small, diff);

                if (sign_big == sign_small) begin
                    ext_res  = ext_big + ext_small;
                    sign_res = sign_big;
                end else begin
                    ext_res  = ext_big - ext_small;
                    sign_res = sign_big;
                end

                pe_fp16_add_comb = pe_pack_from_ext(sign_res, exp_big, ext_res);
            end
        end
    endfunction

    logic [PE_DATA_W_P-1:0] result_r;
    logic                   valid_r;
    logic                   last_r;

    wire can_accept = (!valid_r) || m_axis_result_tready;
    wire in_fire    = can_accept && s_axis_a_tvalid && s_axis_b_tvalid;

    assign s_axis_a_tready       = can_accept;
    assign s_axis_b_tready       = can_accept;
    assign m_axis_result_tdata   = result_r;
    assign m_axis_result_tvalid  = valid_r;
    assign m_axis_result_tlast   = last_r;

    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            valid_r  <= 1'b0;
            result_r <= '0;
            last_r   <= 1'b0;
        end else if (can_accept) begin
            valid_r <= in_fire;
            if (in_fire) begin
                result_r <= pe_fp16_add_comb(s_axis_a_tdata[15:0], s_axis_b_tdata[15:0]);
                last_r   <= s_axis_a_tlast;
            end else begin
                last_r   <= 1'b0;
            end
        end
    end
`endif
endmodule
