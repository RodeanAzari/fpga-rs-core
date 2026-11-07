`default_nettype none

// S1: syndromes of one codeword, one symbol per clock (ADR 0001; model/hw.py syndromes()).
//
// S_j = r(beta^(FCR+j)), beta = alpha^PRIM, j = 0..NROOTS-1, by Horner over the symbols in arrival order (highest
// degree first): S_j <= S_j * beta^(FCR+j) ^ r. Position 0 loads S_j <= r, so no clear cycle between codewords.
//
// sym_valid_i is an accepted symbol (the caller's handshake, gated by sym_ready_o). After the codeword's last symbol
// the syndromes sit in synd_o with synd_valid_o until synd_ready_i; the next codeword's symbols keep flowing in
// meanwhile, and only its own last symbol waits (sym_ready_o low) if the previous syndromes are still unclaimed.
module rs_syndrome
    import rs_gf_pkg::*;
#(
    parameter int M         = 8,      // symbol bits
    parameter int PRIM_POLY = 'h187,  // field polynomial, bit m set
    parameter int FCR       = 112,    // first consecutive root (exponent of beta)
    parameter int PRIM      = 11,     // beta = alpha^PRIM
    parameter int NROOTS    = 32,     // 2t
    parameter int N         = 255     // codeword length (shortened if < 2^M - 1)
) (
    input  wire logic                  clk_i,
    input  wire logic                  rst_i,

    input  wire logic [M-1:0]          sym_i,
    input  wire logic                  sym_valid_i,
    output      logic                  sym_ready_o,
    output      logic                  sym_last_o,  // the next accepted symbol is the codeword's last (position N-1)

    output      logic [NROOTS*M-1:0]   synd_o,      // S_j at [j*M +: M]
    output      logic                  synd_valid_o,
    input  wire logic                  synd_ready_i
);

    localparam int POS_BITS = $clog2(N);

    logic [POS_BITS-1:0] pos_q;
    logic                accept;

    assign sym_last_o  = pos_q == POS_BITS'(N - 1);
    assign sym_ready_o = !(sym_last_o && synd_valid_o && !synd_ready_i);
    assign accept      = sym_valid_i && sym_ready_o;

    for (genvar j = 0; j < NROOTS; j++) begin : g_root
        localparam logic [M-1:0] ROOT = M'(gf_alpha_pow(longint'(PRIM) * (longint'(FCR) + longint'(j)), M, gf_t'(PRIM_POLY)));  // beta^(FCR+j)

        logic [M-1:0] acc_q;
        logic [M-1:0] acc_d;

        always_comb begin
            if (pos_q == '0) acc_d = sym_i;
            else acc_d = M'(gf_mul(gf_t'(acc_q), gf_t'(ROOT), M, gf_t'(PRIM_POLY))) ^ sym_i;
        end

        always_ff @(posedge clk_i) begin
            if (accept) begin
                acc_q <= acc_d;
                if (sym_last_o) synd_o[j*M +: M] <= acc_d;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            pos_q        <= '0;
            synd_valid_o <= 1'b0;
        end else begin
            if (synd_ready_i) synd_valid_o <= 1'b0;
            if (accept) begin
                pos_q <= sym_last_o ? '0 : pos_q + POS_BITS'(1);
                if (sym_last_o) synd_valid_o <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
