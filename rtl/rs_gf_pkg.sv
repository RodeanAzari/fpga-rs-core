`default_nettype none

// GF(2^m) arithmetic for any m <= GF_MAX_M and primitive polynomial `poly` (model/rs.py RSCode). Field elements are
// polynomial-basis integers, bit i = coefficient of x^i, as in model/rs.py. Every function takes the field as
// arguments, so one package serves every parameter set; with constant (m, poly) synthesis reduces gf_mul to an XOR
// network (and to fewer XORs when one operand is constant too).
package rs_gf_pkg;

    localparam int GF_MAX_M = 15;  // widest symbol any instance may use
    typedef logic [GF_MAX_M:0] gf_t;  // one spare bit: holds the polynomial (bit m set) and the pre-reduction product

    // a * b mod poly: shift-and-add, reducing as the partial product grows. Loop bounds are static for synthesis.
    function automatic gf_t gf_mul(input gf_t a, input gf_t b, input int m, input gf_t poly);
        gf_t acc = '0;
        gf_t x   = a;
        for (int i = 0; i <= GF_MAX_M; i++) begin
            if (i < m) begin
                if (b[i]) acc ^= x;
                x = x << 1;
                if (x[m]) x ^= poly;
            end
        end
        return acc;
    endfunction

    // alpha^e (alpha = x), e taken mod 2^m - 1, negative e allowed. Elaboration-time only (loop up to 2^m - 2).
    function automatic gf_t gf_alpha_pow(input longint e, input int m, input gf_t poly);
        longint q = (longint'(1) << m) - 1;
        longint k = ((e % q) + q) % q;
        gf_t x = gf_t'(1);
        for (longint i = 0; i < k; i++) x = gf_mul(x, gf_t'(2), m, poly);
        return x;
    endfunction

endpackage

`default_nettype wire
