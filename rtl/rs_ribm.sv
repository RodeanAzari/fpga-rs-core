`default_nettype none

// S2: key equation by riBM (Sarwate & Shanbhag 2001), 3t+1 processing elements, one iteration per clock, 2t
// iterations (ADR 0001; model/hw.py ribm(), register for register).
//
// Load:   delta_i = theta_i = S_i (i < 2t), 0 (2t <= i < 3t), 1 (i = 3t); gamma = 1; k = 0.
// Step:   delta_i <= gamma * delta_(i+1) ^ delta_0 * theta_i              (delta_(3t+1) = 0)
//         if delta_0 != 0 and k >= 0: theta_i <= delta_(i+1), gamma <= delta_0, k <= -k - 1
//         else:                       k <= k + 1
// Result: Lambda_i = delta_(t+i), i = 0..t;  Omega^h_i = delta_i, i = 0..t-1. Held in loc_* until claimed; a new
// syndrome set is taken only once the previous result is claimed (or as it is claimed).
module rs_ribm
    import rs_gf_pkg::*;
#(
    parameter int M         = 8,      // symbol bits
    parameter int PRIM_POLY = 'h187,  // field polynomial, bit m set
    parameter int NROOTS    = 32      // 2t
) (
    input  wire logic                      clk_i,
    input  wire logic                      rst_i,

    input  wire logic [NROOTS*M-1:0]       synd_i,  // S_j at [j*M +: M]
    input  wire logic                      synd_valid_i,
    output      logic                      synd_ready_o,

    output      logic [(NROOTS/2+1)*M-1:0] lam_o,    // Lambda_i at [i*M +: M]
    output      logic [(NROOTS/2)*M-1:0]   omega_o,  // Omega^h_i at [i*M +: M]
    output      logic                      loc_valid_o,
    input  wire logic                      loc_ready_i
);

    localparam int T      = NROOTS / 2;
    localparam int P      = 3 * T + 1;               // processing elements
    localparam int K_BITS = $clog2(NROOTS + 1) + 1;  // k stays in [-2t, 2t]: signed
    localparam int C_BITS = $clog2(NROOTS);

    logic [M-1:0]              delta_q [P];
    logic [M-1:0]              theta_q [P];
    logic [M-1:0]              gamma_q;
    logic signed [K_BITS-1:0]  k_q;
    logic [C_BITS-1:0]         iter_q;
    logic                      busy_q;
    logic                      load;
    logic                      swap;

    assign synd_ready_o = !busy_q && (!loc_valid_o || loc_ready_i);
    assign load         = synd_valid_i && synd_ready_o;
    assign swap         = delta_q[0] != '0 && k_q >= 0;

    for (genvar i = 0; i < P; i++) begin : g_pe
        logic [M-1:0] next_delta;  // delta_(i+1), 0 past the end
        logic [M-1:0] init;        // load value

        if (i + 1 < P) begin : g_mid
            assign next_delta = delta_q[i+1];
        end else begin : g_end
            assign next_delta = '0;
        end

        if (i < NROOTS) begin : g_synd
            assign init = synd_i[i*M +: M];
        end else if (i == 3 * T) begin : g_one
            assign init = M'(1);
        end else begin : g_zero
            assign init = '0;
        end

        always_ff @(posedge clk_i) begin
            if (load) begin
                delta_q[i] <= init;
                theta_q[i] <= init;
            end else if (busy_q) begin
                delta_q[i] <= M'(gf_mul(gf_t'(gamma_q), gf_t'(next_delta), M, gf_t'(PRIM_POLY)))
                            ^ M'(gf_mul(gf_t'(delta_q[0]), gf_t'(theta_q[i]), M, gf_t'(PRIM_POLY)));
                if (swap) theta_q[i] <= next_delta;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (load) begin
            gamma_q <= M'(1);
            k_q     <= '0;
        end else if (busy_q) begin
            if (swap) begin
                gamma_q <= delta_q[0];
                k_q     <= -k_q - K_BITS'(1);
            end else begin
                k_q <= k_q + K_BITS'(1);
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            busy_q      <= 1'b0;
            loc_valid_o <= 1'b0;
            iter_q      <= '0;
        end else begin
            if (loc_ready_i) loc_valid_o <= 1'b0;
            if (load) begin
                busy_q <= 1'b1;
                iter_q <= '0;
            end else if (busy_q) begin
                iter_q <= iter_q + C_BITS'(1);
                if (iter_q == C_BITS'(NROOTS - 1)) begin
                    busy_q      <= 1'b0;
                    loc_valid_o <= 1'b1;
                end
            end
        end
    end

    for (genvar i = 0; i <= T; i++) begin : g_lam
        assign lam_o[i*M +: M] = delta_q[T+i];
    end
    for (genvar i = 0; i < T; i++) begin : g_omega
        assign omega_o[i*M +: M] = delta_q[i];
    end

endmodule

`default_nettype wire
