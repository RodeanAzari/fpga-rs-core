# 0001 — Decoder architecture: riBM, four-stage codeword pipeline, pass-through on failure

## Context

One parameterized RS decoder serves two users: CCSDS RS(255,223) over GF(2⁸) (P3, Meteor LRPT; bursty, one
codeword at a time is enough) and KP4 RS(544,514) over GF(2¹⁰) (P4; continuous, one symbol per clock with no stalls
between codewords). Release test `rs-core-v1.0` (fpga-coord): both vector suites, 0..t errors decode, t+1 detected,
one symbol/clock, no stalls between codewords. Target: Artix-7 at 100 MHz.

## Options considered

**Key equation solver**
1. Classic Berlekamp–Massey with inversion: a GF inverse in the loop every iteration; long critical path.
2. iBM (inversionless BM): t+1 PEs, 2t iterations, but Ω needs a separate S(x)·Λ(x) pass and the discrepancy is an
   (t+1)-term sum of products in the critical path.
3. **riBM (Sarwate & Shanbhag 2001)**: 3t+1 identical PEs, 2t iterations of one clock, critical path one multiplier
   and one XOR, Ω comes out with Λ. Costs ~2× iBM's multipliers.
4. Euclid: more area and control for no gain here.

**Throughput structure**
1. One decoder per CCSDS interleave branch (×4): wasted for CCSDS, still has to meet KP4's continuous rate alone.
2. **One decoder, codeword pipeline**: syndromes of codeword c+1 overlap the solver and search of c. Each stage
   takes at most n cycles, so one symbol per clock is sustained.

**Uncorrectable codewords**
1. Correct on the fly while searching, flag at `tlast`: no extra buffer, but symbols already emitted are miscorrected
   and the consumer can't undo them.
2. **Search into an error buffer, then emit**: the failure decision (roots found ≠ deg Λ) is known before the first
   output symbol, so a failed codeword comes out exactly as received with the flag on every beat. Costs one stage
   of latency (n cycles) and an error buffer.

## Decision

Four stages, each owning one codeword at a time:

| Stage | Work | Cycles |
|---|---|---|
| S1 syndromes | 2t Horner accumulators, S_j = r(β^(FCR+j)), β = α^PRIM; symbols written to the data buffer | n |
| S2 riBM | 3t+1 PEs, 2t iterations; Λ = δ_t..δ_2t, Ω^h = δ_0..δ_(t−1) | 2t + small |
| S3 Chien + Forney | positions in output order (degree n−1 first, so shortened codes need no skip); e = X^−(FCR+2t)·Ω^h(X⁻¹)/Λ_odd(X⁻¹); errors to the error buffer; counts roots | n + pipeline |
| S4 output | data ⊕ error, or data unchanged if roots ≠ deg Λ | n |

- Data and error buffers each hold 4 codewords (4n symbols, linear addressing). A single in-flight count (codewords
  S1 started − codewords S4 finished ≤ 4) gates `s_axis_tready`; it bounds every buffer at once.
- Sustained one symbol per clock needs n > 2t + S2/S3 pipeline latency (CCSDS 255 > ~45, KP4 544 > ~43); the RTL
  checks it at elaboration.
- Output backpressure stalls only S4; earlier stages keep running until the in-flight limit is reached.
- `m_axis_tuser = {fail, corrected count}` on every beat of a codeword; `tlast` on its last symbol.
- Input `tlast` is checked against the internal symbol counter; mismatches are counted (`len_err`), the counter
  stays the framing authority. Nothing is dropped silently.
- GF multipliers are combinational functions of `M` and `PRIM_POLY`; constant multipliers and the inverse ROM are
  generated at elaboration from the parameters. No GF(2⁸)-specific logic.

## Consequences

- Latency ≈ 3n + 2t + a few cycles (CCSDS ~800, KP4 ~1,670 clocks).
- Memory: 2 × 4n × M bits (CCSDS 16 Kb, KP4 43.5 Kb).
- The failure test is roots ≠ deg Λ alone. The reference model's extra checks (deg > t, re-syndrome after
  correction) were shown redundant: removing either one alone leaves every vector-suite result unchanged, removing
  both is caught (`model/tests/test_vectors.py`), and the riBM model flags 3t errors and random words
  (`model/tests/test_hw.py`).
- Dual-basis conversion and CCSDS depth-4 interleaving stay outside, in the consumer's wrappers.

## Measured evidence

- Forney exponent −(FCR + 2t): fitted on reference error values at both parameter sets; `model/hw.py` decodes the
  whole suite identically to `model/rs.py` (`model/tests/test_hw.py`).
- Throughput: 12 codewords back to back with no input stall and no output gap, both parameter sets
  (`tb/test_rs_decoder.py::one_symbol_per_clock_sustained`).
- Vivado 2025.2 OOC place and route, xc7a100tcsg324-1 at 100 MHz (`docs/reports/ooc/`):

  | Parameter set | WNS | LUT | FF | BRAM36 | DSP |
  |---|---|---|---|---|---|
  | CCSDS RS(255,223) | +1.457 ns | 4,142 | 1,766 | 1.5 | 0 |
  | KP4 RS(544,514) | +1.168 ns | 5,558 | 2,066 | 3.5 | 0 |
