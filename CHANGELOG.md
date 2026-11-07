# Changelog

Releases follow fpga-coord `dependencies.toml`: a tag exists only after its release test passes.

## Unreleased
- Python reference model (`model/rs.py`), stage-level model of the RTL algorithms (`model/hw.py`), seeded vector
  suites for CCSDS and KP4 cross-checked against reedsolo 1.7.0.
- RTL: `rs_decoder` (S1 syndromes, S2 riBM, S3 Chien + Forney, S4 output; 4 codewords in flight), cocotb-verified at
  CCSDS and KP4 (`make sim`); OOC 100 MHz met at both (`make synth`, `docs/reports/ooc/`).
