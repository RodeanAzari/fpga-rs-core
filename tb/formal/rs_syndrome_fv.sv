`default_nettype none

// Formal harness for rs_syndrome (tb/formal/rs_syndrome.sby): reset in the first cycle, sym_i / sym_valid_i /
// synd_ready_i free. The reference is the syndrome's definition, not Horner's rule, in GF arithmetic written here
// independently of rs_gf_pkg:
//   S_j = sum over positions i = 0..N-1 of r_i * b_j^(N-1-i),   b_j = alpha^(PRIM * (FCR + j)),
// accumulated with a weight w_j = b_j^(N-1-i) that starts at b_j^(N-1) and is multiplied by b_j^-1 per symbol.
// Properties:
//   a_last    sym_last_o is high exactly when the next accepted symbol is position N-1;
//   a_ready   sym_ready_o is low exactly when that last symbol would overwrite syndromes not yet claimed;
//   a_valid   synd_valid_o is high exactly while a finished codeword's syndromes are unclaimed;
//   a_synd    while synd_valid_o is high, synd_o equals the reference syndromes of that codeword.
// a_pos, a_pos_n, a_acc and a_w are inductive helpers: the position counter and its range, the weight, and
// Horner's partial sum times b_j^(N-pos) equals the partial definition sum. They are proven like the rest.
module rs_syndrome_fv #(
    parameter int M         = 4,
    parameter int PRIM_POLY = 'h13,
    parameter int FCR       = 0,
    parameter int PRIM      = 1,
    parameter int NROOTS    = 4,
    parameter int N         = 15
) (
    input wire logic         clk_i,
    input wire logic         rst_i,
    input wire logic [M-1:0] sym_i,
    input wire logic         sym_valid_i,
    input wire logic         synd_ready_i
);

    localparam int Q  = (1 << M) - 1;  // multiplicative group order
    localparam int PB = $clog2(N);

    // ---- GF(2^M) arithmetic, bitwise, independent of rs_gf_pkg
    function automatic logic [M-1:0] f_mul(input logic [M-1:0] a, input logic [M-1:0] b);
        logic [M-1:0] p;
        logic [M-1:0] x;
        p = '0;
        x = a;
        for (int i = 0; i < M; i++) begin
            if (b[i]) p = p ^ x;
            x = x[M-1] ? ((x << 1) ^ M'(PRIM_POLY)) : (x << 1);  // x * alpha, reduced
        end
        f_mul = p;
    endfunction

    function automatic logic [M-1:0] f_alpha_pow(input int e);  // alpha^e, e >= 0
        logic [M-1:0] r;
        r = M'(1);
        for (int i = 0; i < e % Q; i++) r = r[M-1] ? ((r << 1) ^ M'(PRIM_POLY)) : (r << 1);
        f_alpha_pow = r;
    endfunction

    // ---- the DUT
    logic                sym_ready, sym_last, synd_valid;
    logic [NROOTS*M-1:0] synd;

    rs_syndrome #(
        .M         (M),
        .PRIM_POLY (PRIM_POLY),
        .FCR       (FCR),
        .PRIM      (PRIM),
        .NROOTS    (NROOTS),
        .N         (N)
    ) u_dut (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
        .sym_i        (sym_i),
        .sym_valid_i  (sym_valid_i),
        .sym_ready_o  (sym_ready),
        .sym_last_o   (sym_last),
        .synd_o       (synd),
        .synd_valid_o (synd_valid),
        .synd_ready_i (synd_ready_i)
    );

    // ---- reference
    logic          first_q = 1'b1;
    logic [PB-1:0] pos_q;     // position of the next accepted symbol
    logic          pend_q;    // a finished codeword's syndromes are unclaimed
    logic          accept, at_last;
    logic [M-1:0]  ref_q [NROOTS];  // definition sum over positions 0 .. pos_q - 1
    logic [M-1:0]  w_q   [NROOTS];  // b_j^(N-1-pos_q)
    logic [M-1:0]  exp_q [NROOTS];  // reference syndromes of the newest finished codeword

    always_comb begin
        accept  = sym_valid_i && sym_ready;
        at_last = pos_q == PB'(N - 1);
    end

    always_ff @(posedge clk_i) begin
        first_q <= 1'b0;
        if (rst_i) begin
            pos_q  <= '0;
            pend_q <= 1'b0;
            for (int j = 0; j < NROOTS; j++) begin
                ref_q[j] <= '0;
                w_q[j]   <= f_alpha_pow(PRIM * (FCR + j) * (N - 1));
            end
        end else begin
            if (synd_valid && synd_ready_i) pend_q <= 1'b0;
            if (accept) begin
                pos_q <= at_last ? '0 : pos_q + PB'(1);
                for (int j = 0; j < NROOTS; j++) begin
                    // b_j^-1 = alpha^(Q - (PRIM * (FCR + j)) mod Q)
                    automatic logic [M-1:0] term = f_mul(sym_i, w_q[j]);
                    automatic logic [M-1:0] sum  = (pos_q == '0 ? '0 : ref_q[j]) ^ term;
                    if (at_last) begin
                        exp_q[j] <= sum;
                        ref_q[j] <= '0;
                        w_q[j]   <= f_alpha_pow(PRIM * (FCR + j) * (N - 1));
                    end else begin
                        ref_q[j] <= sum;
                        w_q[j]   <= f_mul(w_q[j], f_alpha_pow(Q - (PRIM * (FCR + j)) % Q));
                    end
                end
                if (at_last) pend_q <= 1'b1;
            end
        end
    end

    // ---- properties
    always_comb begin
        if (first_q) assume (rst_i);
        if (!first_q && !rst_i) begin
            a_last:  assert (sym_last == at_last);
            a_ready: assert (sym_ready == !(at_last && pend_q && !synd_ready_i));
            a_valid: assert (synd_valid == pend_q);
            for (int j = 0; j < NROOTS; j++)
                if (synd_valid) assert (synd[j*M +: M] == exp_q[j]);  // a_synd (no label: one per j)
            a_pos:   assert (pos_q == u_dut.pos_q);
            a_pos_n: assert (pos_q < PB'(N));  // the position never leaves the codeword
            c_two:   cover (synd_valid && synd_ready_i && pos_q == PB'(N - 1) && sym_valid_i);  // back to back
        end
    end

    for (genvar j = 0; j < NROOTS; j++) begin : g_help
        localparam logic [M-1:0] B = f_alpha_pow(PRIM * (FCR + j));
        logic [M-1:0] w_at_pos;  // b^(N-1-pos_q), from constants
        always_comb begin
            w_at_pos = '0;
            for (int k = 0; k < N; k++) if (pos_q == PB'(k)) w_at_pos = f_alpha_pow(PRIM * (FCR + j) * (N - 1 - k));
            if (!first_q && !rst_i) begin
                // Horner after k = pos symbols is sum r_i b^(k-1-i); times b^(N-k) = b * w is the definition sum
                if (pos_q != '0) a_acc: assert (f_mul(u_dut.g_root[j].acc_q, f_mul(w_q[j], B)) == ref_q[j]);
                a_w: assert (w_q[j] == w_at_pos);
            end
        end
    end

endmodule

`default_nettype wire
