# fpga-rs-core

A parameterized Reed-Solomon decoder in SystemVerilog, verified at two parameter sets:

| Code | Field | Field polynomial | Generator roots | Used for |
|---|---|---|---|---|
| RS(255,223), t = 16 | GF(2⁸) | x⁸+x⁷+x²+x+1 (0x187) | α^(11j), j = 112..143 | CCSDS 131.0-B (conventional basis) |
| RS(544,514), t = 15, shortened | GF(2¹⁰) | x¹⁰+x³+1 (0x409) | α^j, j = 0..29 | IEEE 802.3 KP4 FEC |

**Status: RTL complete, not yet released.** `rs_decoder` passes both vector suites in simulation, sustaining one symbol
per clock with no stall between codewords, and meets 100 MHz on an Artix-7 at both parameter sets. The first release
will be tag `rs-core-v1.0`.

## Parameters

`M` (symbol bits), `PRIM_POLY`, `FCR` (first consecutive root), `PRIM` (root step), `NROOTS` (= 2t), `N` (codeword
length, `N < 2^M` for shortened codes). Roots are α^(PRIM·(FCR+j)), j = 0..NROOTS−1.

## Interface (`rtl/rs_decoder.sv`)

| Port | Width | |
|---|---|---|
| `s_axis_tdata/tvalid/tready/tlast` | M | received symbols, highest degree first; codewords are N symbols counted from reset |
| `m_axis_tdata/tvalid/tready/tlast` | M | corrected codeword, or exactly as received if uncorrectable; `tlast` on symbol N−1 |
| `m_axis_tuser` | clog2(N+1)+1 | `{fail, symbols corrected}` on every beat of a codeword (count 0 when fail) |
| `len_err_o` | 16 | input `tlast` disagreeing with the symbol count (saturating); the count stays the framing |

Sources: `rtl/rs_gf_pkg.sv` (compile first), `rs_syndrome.sv`, `rs_ribm.sv`, `rs_chien_forney.sv`, `rs_decoder.sv`.
Synchronous active-high reset `rst_i`, one clock `clk_i`. Latency ≈ 3N + 2t clocks. Dual-basis conversion and
interleaving are left to the consumer.

## Results

Vivado 2025.2, out of context, placed and routed on xc7a100tcsg324-1 (Arty A7-100T) at 100 MHz
([reports](docs/reports/ooc/)):

| Parameter set | WNS | LUT | FF | BRAM36 | DSP |
|---|---|---|---|---|---|
| CCSDS RS(255,223) | +1.457 ns | 4,142 | 1,766 | 1.5 | 0 |
| KP4 RS(544,514) | +1.168 ns | 5,558 | 2,066 | 3.5 | 0 |

## Architecture

Syndromes → riBM → Chien search + Forney → output, one codeword per stage, sustained one symbol per clock.
A codeword with more than t errors comes out unchanged, with its fail flag set. See
[ADR 0001](docs/decisions/0001-decoder-architecture.md).

## Verification

- `model/rs.py`: the reference decoder. `model/hw.py`: the same algorithms as the RTL, stage by stage.
- Every vector (0..t errors, t+1 and t+2, bursts, boundary positions, parity-only errors, all-zero and all-ones
  data) is cross-checked against [reedsolo](https://pypi.org/project/reedsolo/) 1.7.0, an independent
  implementation: `make model-test`.

- cocotb (Verilator) at both parameter sets, every stage against `model/hw.py` and the decoder against
  `model/rs.py`: the full suite under random handshakes, 12 codewords back to back with no input stall and no output
  gap, repeated output stalls that fill every in-flight slot, and misplaced `tlast`. Each test was shown to fail on
  planted bugs (off-by-one positions, wrong constants, unclaimed results overwritten, buffer limits, failure
  pass-through).

```
make setup   # venv + pinned requirements
make ci      # lint (both parameter sets) + model tests + cocotb
make synth   # Vivado OOC place and route at 100 MHz, both parameter sets (local)
```

## Used by

- [CCSDS satellite telemetry receiver](https://github.com/RodeanAzari/ccsds-meteor-lrpt-receiver) (CCSDS RS(255,223))

## License

MIT
