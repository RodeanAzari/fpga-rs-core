# fpga-rs-core

A parameterized Reed-Solomon decoder in SystemVerilog, verified at two parameter sets:

| Code | Field | Field polynomial | Generator roots | Used for |
|---|---|---|---|---|
| RS(255,223), t = 16 | GF(2⁸) | x⁸+x⁷+x²+x+1 (0x187) | α^(11j), j = 112..143 | CCSDS 131.0-B (conventional basis) |
| RS(544,514), t = 15, shortened | GF(2¹⁰) | x¹⁰+x³+1 (0x409) | α^j, j = 0..29 | IEEE 802.3 KP4 FEC |

**Status: in development.** The Python model and the reference cross-check are done. RTL is not written yet.
The first release will be tag `rs-core-v1.0`: both vector suites pass, at one symbol per clock with no stalls between
codewords.

## Parameters

`M` (symbol bits), `PRIM_POLY`, `FCR` (first consecutive root), `PRIM` (root step), `NROOTS` (= 2t), `N` (codeword
length, `N < 2^M` for shortened codes). Roots are α^(PRIM·(FCR+j)), j = 0..NROOTS−1.

## Architecture

Syndromes → riBM → Chien search + Forney → output, one codeword per stage, sustained one symbol per clock.
A codeword with more than t errors comes out unchanged, with its fail flag set. See
[ADR 0001](docs/decisions/0001-decoder-architecture.md).

## Verification

- `model/rs.py`: the reference decoder. `model/hw.py`: the same algorithms as the RTL, stage by stage.
- Every vector (0..t errors, t+1 and t+2, bursts, boundary positions, parity-only errors, all-zero and all-ones
  data) is cross-checked against [reedsolo](https://pypi.org/project/reedsolo/) 1.7.0, an independent
  implementation: `make model-test`.

```
make setup   # venv + pinned requirements
make ci      # lint + model tests
```

## Used by

- [CCSDS satellite telemetry receiver](https://github.com/RodeanAzari/ccsds-meteor-lrpt-receiver) (CCSDS RS(255,223))

## License

MIT
