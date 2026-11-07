`default_nettype none

// S3: Chien search and Forney over the N positions of one codeword, one position per clock, in output order
// (position p = 0 is the first symbol, degree d = N-1-p), so a shortened code needs no skipped positions
// (ADR 0001; model/hw.py search()).
//
// With X = beta^d (beta = alpha^PRIM), position p is in error iff Lambda(X^-1) = 0, and then
//     e = X^-(FCR+2t) * Omega^h(X^-1) / Lambda_odd(X^-1)        (Lambda_odd(x) = x * Lambda'(x))
// Registers hold the terms at the current X^-1:  L_i = Lambda_i * beta^(-i*d),
// W_i = Omega^h_i * beta^(-(i+FCR+2t)*d); each step multiplies them by beta^i and beta^(i+FCR+2t). Loaded at d = N-1.
//
// Pipeline after the term registers: A: even / odd / numerator sums; B: 1/odd from a ROM; C: e = num * (1/odd).
// err_* carries one value per position (0 where no root), err_last_o on position N-1, together with the codeword's
// status: roots found and fail = roots != deg(Lambda). No backpressure: the caller starts a codeword only when it
// can take all N values. A new locator loads while the previous codeword's last positions are still in the pipeline.
module rs_chien_forney
    import rs_gf_pkg::*;
#(
    parameter int M         = 8,      // symbol bits
    parameter int PRIM_POLY = 'h187,  // field polynomial, bit m set
    parameter int FCR       = 112,    // first consecutive root (exponent of beta)
    parameter int PRIM      = 11,     // beta = alpha^PRIM
    parameter int NROOTS    = 32,     // 2t
    parameter int N         = 255,    // codeword length (shortened if < 2^M - 1)
    localparam int CNT_BITS = $clog2(N + 1)  // roots found: up to N when Lambda is all zero
) (
    input  wire logic                      clk_i,
    input  wire logic                      rst_i,

    input  wire logic [(NROOTS/2+1)*M-1:0] lam_i,    // Lambda_i at [i*M +: M]
    input  wire logic [(NROOTS/2)*M-1:0]   omega_i,  // Omega^h_i at [i*M +: M]
    input  wire logic                      loc_valid_i,
    output      logic                      loc_ready_o,

    output      logic [M-1:0]              err_o,
    output      logic                      err_valid_o,
    output      logic                      err_last_o,
    output      logic [CNT_BITS-1:0]       roots_o,  // with err_last_o
    output      logic                      fail_o    // with err_last_o
);

    localparam int T        = NROOTS / 2;
    localparam int Q        = (1 << M) - 1;
    localparam int POS_BITS = $clog2(N);
    localparam int DEG_BITS = $clog2(T + 1);
    localparam longint SHIFT = longint'(FCR) + longint'(NROOTS);  // Forney exponent FCR + 2t (model/hw.py)

    // 1/a for every a; inv(0) = 0, which makes e = 0 where Lambda_odd vanishes, as model/hw.py does. ROM init only.
    logic [M-1:0] inv_rom [Q+1];
    initial begin : g_inv_init
        automatic gf_t x = gf_t'(1);  // alpha^i
        automatic gf_t y = gf_t'(1);  // alpha^-i
        automatic gf_t a_inv = gf_alpha_pow(-1, M, gf_t'(PRIM_POLY));
        inv_rom[0] = '0;
        for (int i = 0; i < Q; i++) begin
            inv_rom[x[M-1:0]] = y[M-1:0];
            x = gf_mul(x, gf_t'(2), M, gf_t'(PRIM_POLY));
            y = gf_mul(y, a_inv, M, gf_t'(PRIM_POLY));
        end
    end

    function automatic logic [M-1:0] mul(input logic [M-1:0] a, input logic [M-1:0] b);
        return M'(gf_mul(gf_t'(a), gf_t'(b), M, gf_t'(PRIM_POLY)));
    endfunction

    // ---- term registers ------------------------------------------------------------------------------------------
    logic                load;
    logic                run_q;
    logic [POS_BITS-1:0] pos_q;
    logic                last_pos;
    logic [M-1:0]        lam_q [T+1];
    logic [M-1:0]        om_q  [T];
    logic [DEG_BITS-1:0] deg_q;
    logic [DEG_BITS-1:0] deg_d;

    assign last_pos    = pos_q == POS_BITS'(N - 1);
    assign loc_ready_o = !run_q || last_pos;
    assign load        = loc_valid_i && loc_ready_o;

    always_comb begin
        deg_d = '0;
        for (int i = 1; i <= T; i++)
            if (lam_i[i*M +: M] != '0) deg_d = DEG_BITS'(i);
    end

    for (genvar i = 0; i <= T; i++) begin : g_lam
        localparam logic [M-1:0] START = M'(gf_alpha_pow(-longint'(PRIM) * longint'(i) * (longint'(N) - 1), M, gf_t'(PRIM_POLY)));
        localparam logic [M-1:0] STEP  = M'(gf_alpha_pow(longint'(PRIM) * i, M, gf_t'(PRIM_POLY)));
        always_ff @(posedge clk_i) begin
            if (load) lam_q[i] <= mul(lam_i[i*M +: M], START);
            else if (run_q) lam_q[i] <= mul(lam_q[i], STEP);
        end
    end

    for (genvar i = 0; i < T; i++) begin : g_om
        localparam longint E = longint'(PRIM) * (longint'(i) + SHIFT);
        localparam logic [M-1:0] START = M'(gf_alpha_pow(-E * (longint'(N) - 1), M, gf_t'(PRIM_POLY)));
        localparam logic [M-1:0] STEP  = M'(gf_alpha_pow(E, M, gf_t'(PRIM_POLY)));
        always_ff @(posedge clk_i) begin
            if (load) om_q[i] <= mul(omega_i[i*M +: M], START);
            else if (run_q) om_q[i] <= mul(om_q[i], STEP);
        end
    end

    always_ff @(posedge clk_i) begin
        if (load) deg_q <= deg_d;
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            run_q <= 1'b0;
            pos_q <= '0;
        end else if (load) begin
            run_q <= 1'b1;
            pos_q <= '0;
        end else if (run_q) begin
            pos_q <= last_pos ? '0 : pos_q + POS_BITS'(1);
            if (last_pos) run_q <= 1'b0;
        end
    end

    // ---- A: sums --------------------------------------------------------------------------------------------------
    logic [M-1:0]        even_d, odd_d, num_d;
    logic [M-1:0]        odd_a, num_a;
    logic                root_a, valid_a, last_a;
    logic [DEG_BITS-1:0] deg_a;

    always_comb begin
        even_d = '0;
        odd_d  = '0;
        num_d  = '0;
        for (int i = 0; i <= T; i++) begin
            if (i % 2 == 0) even_d ^= lam_q[i];
            else odd_d ^= lam_q[i];
        end
        for (int i = 0; i < T; i++) num_d ^= om_q[i];
    end

    always_ff @(posedge clk_i) begin
        odd_a  <= odd_d;
        num_a  <= num_d;
        root_a <= even_d == odd_d;
        last_a <= last_pos;
        deg_a  <= deg_q;
    end

    // ---- B: inverse ---------------------------------------------------------------------------------------------
    logic [M-1:0]        inv_b, num_b;
    logic                valid_b, last_b;
    logic [CNT_BITS-1:0] roots_q;   // roots so far in the codeword at B, including B's own position
    logic [DEG_BITS-1:0] deg_b;
    logic                first_a;   // A holds a codeword's first position

    always_ff @(posedge clk_i) begin
        inv_b  <= inv_rom[odd_a];
        num_b  <= root_a ? num_a : '0;
        last_b <= last_a;
        deg_b  <= deg_a;
    end

    // ---- C: error value --------------------------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        err_o      <= mul(num_b, inv_b);
        err_last_o <= last_b;
        fail_o     <= roots_q != CNT_BITS'(deg_b);
        roots_o    <= roots_q;
    end

    // Valid and per-codeword count run through the same stages; reset only these.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            valid_a     <= 1'b0;
            valid_b     <= 1'b0;
            err_valid_o <= 1'b0;
            first_a     <= 1'b0;
            roots_q     <= '0;
        end else begin
            valid_a     <= run_q;
            first_a     <= run_q && pos_q == '0;
            valid_b     <= valid_a;
            err_valid_o <= valid_b;
            if (valid_a) roots_q <= (first_a ? '0 : roots_q) + CNT_BITS'(root_a);
        end
    end

endmodule

`default_nettype wire
