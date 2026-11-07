# Changelog

Releases follow fpga-coord `dependencies.toml`: a tag exists only after its release test passes.

## rs-core-v1.0 — 2026-11-07

First release: parameterized RS decoder `rs_decoder` (README, Interface).

- **Release test** (fpga-coord: CCSDS and KP4 vector suites, 0..t errors decode, t+1 detected; one symbol/clock,
  no stalls between codewords): `make ci` at daecd7e (RTL identical in the tagged commit, which adds only this entry
  and the README status). Result: ruff and mypy clean, Verilator `-Wall` clean at both parameter sets, 12 pytest
  passed (model vs. reedsolo 1.7.0), 20 cocotb tests passed, 0 skipped (CCSDS and KP4 each:
  `test_rs_syndrome` 2, `test_rs_ribm` 2, `test_rs_chien_forney` 2, `test_rs_decoder` 4). One symbol per clock:
  `test_rs_decoder.one_symbol_per_clock_sustained` (12 codewords, 0 input stalls, 0 output gaps).
  GitHub Actions run 42418933318 green.
- **Timing:** Vivado 2025.2 OOC place and route, xc7a100tcsg324-1, 100 MHz: CCSDS WNS +1.457 ns, KP4 WNS
  +1.168 ns (`docs/reports/ooc/`).
- **Not covered:** no hardware run yet (first on-board use: the CCSDS receiver, Phase E). Formal proofs: none.
- Python reference model (`model/rs.py`), stage-level model of the RTL algorithms (`model/hw.py`), seeded vector
  suites for CCSDS and KP4 cross-checked against reedsolo 1.7.0.
- RTL: `rs_decoder` (S1 syndromes, S2 riBM, S3 Chien + Forney, S4 output; 4 codewords in flight), cocotb-verified at
  CCSDS and KP4 (`make sim`); OOC 100 MHz met at both (`make synth`, `docs/reports/ooc/`).
