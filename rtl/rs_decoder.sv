`default_nettype none

// Reed-Solomon decoder, one symbol per clock sustained, any (M, PRIM_POLY, FCR, PRIM, NROOTS, N) (ADR 0001).
//
//   s_axis -> S1 rs_syndrome -> S2 rs_ribm -> S3 rs_chien_forney -> status FIFO -> S4 output -> m_axis
//          \-> data buffer (4 codewords) ---------------------------------------/      /
//                                     S3 errors -> error buffer (4 codewords) --------/
//
// Out: the codeword corrected, or exactly as received if uncorrectable; m_axis_tuser = {fail, symbols corrected}
// on every beat of the codeword (count 0 when fail); m_axis_tlast on its last symbol. Matches model/rs.py decode().
//
// Flow control: at most 4 codewords in flight (S1 started, S4 not finished), which bounds both buffers and the
// status FIFO at once. Output backpressure stalls S4; the earlier stages run on until the limit closes s_axis.
// Framing: codewords are N symbols counted from reset. s_axis_tlast is checked against that count; each mismatch
// increments len_err_o (saturating) and the count stays the framing authority.
module rs_decoder
    import rs_gf_pkg::*;
#(
    parameter int M         = 8,      // symbol bits
    parameter int PRIM_POLY = 'h187,  // field polynomial, bit m set
    parameter int FCR       = 112,    // first consecutive root (exponent of beta)
    parameter int PRIM      = 11,     // beta = alpha^PRIM
    parameter int NROOTS    = 32,     // 2t
    parameter int N         = 255,    // codeword length (shortened if < 2^M - 1)
    localparam int CNT_BITS = $clog2(N + 1)
) (
    input  wire logic                clk_i,
    input  wire logic                rst_i,

    input  wire logic [M-1:0]        s_axis_tdata_i,
    input  wire logic                s_axis_tvalid_i,
    output      logic                s_axis_tready_o,
    input  wire logic                s_axis_tlast_i,

    output      logic [M-1:0]        m_axis_tdata_o,
    output      logic                m_axis_tvalid_o,
    input  wire logic                m_axis_tready_i,
    output      logic                m_axis_tlast_o,
    output      logic [CNT_BITS:0]   m_axis_tuser_o,  // {fail, corrected}

    output      logic [15:0]         len_err_o
);

    localparam int T         = NROOTS / 2;
    localparam int SLOTS     = 4;                       // codewords in flight (ADR 0001)
    localparam int DEPTH     = SLOTS * N;
    localparam int ADDR_BITS = $clog2(DEPTH);
    localparam int POS_BITS  = $clog2(N);
    localparam int OUT_DEPTH = 4;                       // output FIFO: covers the 1-clock buffer read latency
    localparam int OUT_W     = M + 1 + CNT_BITS + 1;    // {tlast, fail, count, data}

    // Sustained throughput needs every stage to finish within N clocks (ADR 0001).
    if (N <= NROOTS + 8) begin : g_bad_n
        $error("rs_decoder: N must exceed NROOTS + 8 for one symbol per clock");
    end

    function automatic logic [ADDR_BITS-1:0] next_addr(input logic [ADDR_BITS-1:0] a);
        return a == ADDR_BITS'(DEPTH - 1) ? '0 : a + ADDR_BITS'(1);
    endfunction

    // ---- input, S1 ----------------------------------------------------------------------------------------------
    logic                     s1_ready, s1_last, accept, first_q;
    logic [$clog2(SLOTS+1)-1:0] inflight_q;
    logic                     out_done;  // S4 hands over a codeword's last symbol
    logic [NROOTS*M-1:0]      synd;
    logic                     synd_valid, synd_ready;

    assign s_axis_tready_o = s1_ready && (!first_q || inflight_q < ($clog2(SLOTS+1))'(SLOTS));
    assign accept          = s_axis_tvalid_i && s_axis_tready_o;

    rs_syndrome #(.M(M), .PRIM_POLY(PRIM_POLY), .FCR(FCR), .PRIM(PRIM), .NROOTS(NROOTS), .N(N)) u_syndrome (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
        .sym_i        (s_axis_tdata_i),
        .sym_valid_i  (s_axis_tvalid_i && (!first_q || inflight_q < ($clog2(SLOTS+1))'(SLOTS))),
        .sym_ready_o  (s1_ready),
        .sym_last_o   (s1_last),
        .synd_o       (synd),
        .synd_valid_o (synd_valid),
        .synd_ready_i (synd_ready)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            first_q    <= 1'b1;
            inflight_q <= '0;
            len_err_o  <= '0;
        end else begin
            if (accept) first_q <= s1_last;
            case ({accept && first_q, out_done})
                2'b10:   inflight_q <= inflight_q + 1'b1;
                2'b01:   inflight_q <= inflight_q - 1'b1;
                default: ;
            endcase
            if (accept && s_axis_tlast_i != s1_last && len_err_o != '1) len_err_o <= len_err_o + 16'd1;
        end
    end

    // ---- data buffer ----------------------------------------------------------------------------------------------
    logic [M-1:0]           dbuf [DEPTH];
    logic [ADDR_BITS-1:0]   dwr_q;

    always_ff @(posedge clk_i) begin
        if (accept) dbuf[dwr_q] <= s_axis_tdata_i;
    end
    always_ff @(posedge clk_i) begin
        if (rst_i) dwr_q <= '0;
        else if (accept) dwr_q <= next_addr(dwr_q);
    end

    // ---- S2, S3 ---------------------------------------------------------------------------------------------------
    logic [(T+1)*M-1:0]  lam;
    logic [T*M-1:0]      omega;
    logic                loc_valid, loc_ready;
    logic [M-1:0]        err;
    logic                err_valid, err_last, cw_fail;
    logic [CNT_BITS-1:0] roots;

    rs_ribm #(.M(M), .PRIM_POLY(PRIM_POLY), .NROOTS(NROOTS)) u_ribm (
        .clk_i        (clk_i),
        .rst_i        (rst_i),
        .synd_i       (synd),
        .synd_valid_i (synd_valid),
        .synd_ready_o (synd_ready),
        .lam_o        (lam),
        .omega_o      (omega),
        .loc_valid_o  (loc_valid),
        .loc_ready_i  (loc_ready)
    );

    rs_chien_forney #(.M(M), .PRIM_POLY(PRIM_POLY), .FCR(FCR), .PRIM(PRIM), .NROOTS(NROOTS), .N(N)) u_chien (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .lam_i       (lam),
        .omega_i     (omega),
        .loc_valid_i (loc_valid),
        .loc_ready_o (loc_ready),
        .err_o       (err),
        .err_valid_o (err_valid),
        .err_last_o  (err_last),
        .roots_o     (roots),
        .fail_o      (cw_fail)
    );

    // ---- error buffer, status FIFO ------------------------------------------------------------------------------------
    logic [M-1:0]          ebuf [DEPTH];
    logic [ADDR_BITS-1:0]  ewr_q;
    logic [CNT_BITS:0]     stat_mem [SLOTS];  // {fail, count}
    logic [1:0]            stat_wr_q, stat_rd_q;
    logic [2:0]            stat_cnt_q;
    logic                  stat_pop;

    always_ff @(posedge clk_i) begin
        if (err_valid) ebuf[ewr_q] <= err;
        if (err_valid && err_last) stat_mem[stat_wr_q] <= {cw_fail, cw_fail ? '0 : roots};
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            ewr_q      <= '0;
            stat_wr_q  <= '0;
            stat_rd_q  <= '0;
            stat_cnt_q <= '0;
        end else begin
            if (err_valid) ewr_q <= next_addr(ewr_q);
            if (err_valid && err_last) stat_wr_q <= stat_wr_q + 2'd1;
            if (stat_pop) stat_rd_q <= stat_rd_q + 2'd1;
            case ({err_valid && err_last, stat_pop})
                2'b10:   stat_cnt_q <= stat_cnt_q + 3'd1;
                2'b01:   stat_cnt_q <= stat_cnt_q - 3'd1;
                default: ;
            endcase
        end
    end

    // ---- S4: read both buffers, correct, output FIFO ----------------------------------------------------------------
    logic                  rd_active_q;  // a codeword is being read out
    logic [POS_BITS-1:0]   rd_pos_q;
    logic [ADDR_BITS-1:0]  rd_addr_q;
    logic [CNT_BITS:0]     rd_stat_q;
    logic                  issue;
    logic                  issue_last;
    logic [2:0]            credit_used;  // FIFO entries + reads in flight

    logic                  rv_q;         // a read issued last clock lands now
    logic                  rv_last_q;
    logic [CNT_BITS:0]     rv_stat_q;
    logic [M-1:0]          rd_data_q, rd_err_q;

    logic [OUT_W-1:0]      ofifo [OUT_DEPTH];
    logic [1:0]            of_wr_q, of_rd_q;
    logic [2:0]            of_cnt_q;
    logic                  of_pop;
    logic [OUT_W-1:0]      of_head;

    assign credit_used = of_cnt_q + 3'(rv_q);
    // A codeword's reads start once its status is known (S3 done) and continue one per clock while credit lasts.
    assign issue      = (rd_active_q || stat_cnt_q != '0) && credit_used < 3'(OUT_DEPTH);
    assign issue_last = rd_pos_q == POS_BITS'(N - 1);
    assign stat_pop   = issue && !rd_active_q;

    always_ff @(posedge clk_i) begin
        if (issue) begin
            rd_data_q <= dbuf[rd_addr_q];
            rd_err_q  <= ebuf[rd_addr_q];
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            rd_active_q <= 1'b0;
            rd_pos_q    <= '0;
            rd_addr_q   <= '0;
            rv_q        <= 1'b0;
        end else begin
            rv_q <= issue;
            if (issue) begin
                rd_addr_q   <= next_addr(rd_addr_q);
                rd_pos_q    <= issue_last ? '0 : rd_pos_q + POS_BITS'(1);
                rd_active_q <= !issue_last;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (stat_pop) rd_stat_q <= stat_mem[stat_rd_q];
        if (issue) begin
            rv_last_q <= issue_last;
            rv_stat_q <= rd_active_q ? rd_stat_q : stat_mem[stat_rd_q];
        end
    end

    assign of_pop = m_axis_tvalid_o && m_axis_tready_i;

    always_ff @(posedge clk_i) begin
        if (rv_q) ofifo[of_wr_q] <= {rv_last_q, rv_stat_q, rv_stat_q[CNT_BITS] ? rd_data_q : rd_data_q ^ rd_err_q};
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            of_wr_q  <= '0;
            of_rd_q  <= '0;
            of_cnt_q <= '0;
        end else begin
            if (rv_q) of_wr_q <= of_wr_q + 2'd1;
            if (of_pop) of_rd_q <= of_rd_q + 2'd1;
            case ({rv_q, of_pop})
                2'b10:   of_cnt_q <= of_cnt_q + 3'd1;
                2'b01:   of_cnt_q <= of_cnt_q - 3'd1;
                default: ;
            endcase
        end
    end

    assign of_head         = ofifo[of_rd_q];
    assign m_axis_tvalid_o = of_cnt_q != '0;
    assign m_axis_tlast_o  = of_head[OUT_W-1];
    assign m_axis_tuser_o  = of_head[OUT_W-2 -: CNT_BITS+1];
    assign m_axis_tdata_o  = of_head[M-1:0];
    assign out_done        = of_pop && m_axis_tlast_o;

endmodule

`default_nettype wire
