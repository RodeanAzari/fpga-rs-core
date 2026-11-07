"""Seeded test vectors for the decoder: the parameter sets it must support and the error patterns it must handle.

Expected outputs come from `model.rs.RSCode`; `model/tests/test_vectors.py` checks every case against reedsolo, an
independent implementation, so a bug shared by our model and the RTL cannot pass unnoticed.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from model.rs import RSCode


@dataclass(frozen=True)
class Params:
    """RTL parameters for one code. Generator roots are alpha^(PRIM*(FCR+j)), j = 0..NROOTS-1."""

    name: str
    m: int
    prim_poly: int
    fcr: int
    prim: int
    nroots: int
    n: int

    def code(self) -> RSCode:
        return RSCode(self.m, self.prim_poly, self.fcr, self.prim, self.nroots, self.n)

    @property
    def t(self) -> int:
        return self.nroots // 2


# CCSDS 131.0-B: RS(255,223), x^8+x^7+x^2+x+1, roots alpha^(11j), j = 112..143 (conventional basis).
CCSDS = Params("ccsds", m=8, prim_poly=0x187, fcr=112, prim=11, nroots=32, n=255)
# IEEE 802.3 Clause 91 KP4: RS(544,514) over GF(2^10), x^10+x^3+1, roots alpha^j, j = 0..29; shortened from 1023.
KP4 = Params("kp4", m=10, prim_poly=0x409, fcr=0, prim=1, nroots=30, n=544)
PARAM_SETS = (CCSDS, KP4)


@dataclass(frozen=True)
class Case:
    sent: list[int]  # the transmitted codeword, highest-degree symbol first
    received: list[int]
    errors: int  # symbols actually corrupted
    expected: list[int]  # what the decoder must output
    corrected: int  # symbols corrected, or -1 if the decoder must flag the codeword uncorrectable


def _positions(kind: str, count: int, p: Params, rng: np.random.Generator) -> list[int]:
    if kind == "random":
        return [int(i) for i in rng.choice(p.n, size=count, replace=False)]
    if kind == "burst":  # adjacent symbols, anywhere
        start = int(rng.integers(0, p.n - count + 1))
        return list(range(start, start + count))
    if kind == "ends":  # first and last symbols first: the Chien search's boundary positions
        order = [0, p.n - 1] + [int(i) for i in rng.permutation(np.arange(1, p.n - 1))]
        return order[:count]
    if kind == "parity":  # parity symbols only
        return [int(i) for i in rng.choice(np.arange(p.n - p.nroots, p.n), size=min(count, p.nroots), replace=False)]
    raise ValueError(kind)


def make_case(p: Params, code: RSCode, count: int, seed: int, kind: str = "random", data: str = "random") -> Case:
    rng = np.random.default_rng(seed)
    k = p.n - p.nroots
    if data == "random":
        msg = rng.integers(0, code.q + 1, k).tolist()
    elif data == "zeros":
        msg = [0] * k
    elif data == "ones":
        msg = [code.q] * k
    else:
        raise ValueError(data)
    sent = code.encode(msg)
    received = sent[:]
    for pos in _positions(kind, count, p, rng):
        received[pos] ^= int(rng.integers(1, code.q + 1))
    expected, corrected = code.decode(received)
    return Case(sent, received, sum(a != b for a, b in zip(sent, received, strict=True)), expected, corrected)


def suite(p: Params, seed: int = 1, per_count: int = 4) -> list[Case]:
    """0..t errors (must decode), t+1 and t+2 (must be flagged), plus the boundary patterns and data extremes."""
    code = p.code()
    cases: list[Case] = []
    s = seed * 1_000_003
    for count in range(p.t + 3):
        for _ in range(per_count):
            cases.append(make_case(p, code, count, s))
            s += 1
    for kind in ("burst", "ends", "parity"):
        for count in (1, 2, p.t - 1, p.t, p.t + 1):
            cases.append(make_case(p, code, count, s, kind))
            s += 1
    for data in ("zeros", "ones"):
        for count in (0, p.t, p.t + 1):
            cases.append(make_case(p, code, count, s, data=data))
            s += 1
    return cases
