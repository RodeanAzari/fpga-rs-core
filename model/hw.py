"""Stage-level model of the RTL decoder: the same algorithms, register by register, that `rtl/` implements.

syndromes (Horner) -> riBM (Sarwate & Shanbhag 2001, reformulated inversionless Berlekamp-Massey)
-> Chien search + Forney in output order (highest-degree symbol first) -> correct, or pass through if uncorrectable.

`decode()` must equal `model.rs.RSCode.decode()` on every word (model/tests/test_hw.py); the intermediate values are
what the RTL stage testbenches compare against.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass

from model.rs import RSCode


@dataclass(frozen=True)
class Locator:
    lam: list[int]  # Lambda_i, i = 0..t (riBM output delta_{t+i}; a scalar multiple of the BM locator)
    omega: list[int]  # Omega^h_i, i = 0..t-1 (riBM output delta_i)


@dataclass(frozen=True)
class Search:
    errors: list[int]  # error value per output position (highest degree first); 0 where no root
    roots: int  # roots of Lambda found among the n positions
    degree: int  # highest i with Lambda_i != 0

    @property
    def fail(self) -> bool:
        return self.roots != self.degree


class HwDecoder:
    def __init__(self, code: RSCode) -> None:
        self.c = code
        self.t = code.nroots // 2

    def gmul(self, a: int, b: int) -> int:
        return self.c._mul(a, b)

    def syndromes(self, word: Sequence[int]) -> list[int]:
        # S_j = r(beta^(fcr+j)), Horner over the symbols in arrival order.
        return self.c.syndromes(word)

    def ribm(self, synd: Sequence[int]) -> Locator:
        t = self.t
        size = 3 * t + 1
        delta = [0] * size
        delta[: 2 * t] = list(synd)
        delta[3 * t] = 1
        theta = delta[:]
        gamma, k = 1, 0
        for _ in range(2 * t):
            d0 = delta[0]
            shifted = [*delta[1:], 0]
            new_delta = [self.gmul(gamma, shifted[i]) ^ self.gmul(d0, theta[i]) for i in range(size)]
            if d0 != 0 and k >= 0:
                theta, gamma, k = shifted, d0, -k - 1
            else:
                k += 1
            delta = new_delta
        return Locator(lam=delta[t : 2 * t + 1], omega=delta[:t])

    def forney_shift(self) -> int:
        """e = X^shift * Omega^h(X^-1) / Lambda_odd(X^-1), with X = beta^d and Lambda_odd(x) = x * Lambda'(x).

        shift = -(fcr + 2t): measured against the reference error values at both parameter sets (test_hw.py checks
        every decode), consistent with riBM's Omega^h carrying x^2t more than the classic evaluator.
        """
        return -(self.c.fcr + 2 * self.t)

    def search(self, loc: Locator) -> Search:
        c = self.c
        n = c.n
        errors = [0] * n
        roots = 0
        shift = self.forney_shift()
        for p in range(n):
            d = n - 1 - p
            x_inv = c._beta_pow(-d % c.q)
            ev = c._eval([v if i % 2 == 0 else 0 for i, v in enumerate(loc.lam)], x_inv)
            od = c._eval([v if i % 2 == 1 else 0 for i, v in enumerate(loc.lam)], x_inv)
            if ev ^ od:
                continue
            roots += 1
            num = self.gmul(c._beta_pow((shift * d) % c.q), c._eval(loc.omega, x_inv))
            errors[p] = 0 if od == 0 else self.gmul(num, c._inv(od))
        degree = max((i for i, v in enumerate(loc.lam) if v), default=0)
        return Search(errors, roots, degree)

    def decode(self, word: Sequence[int]) -> tuple[list[int], int]:
        received = [int(x) for x in word]
        s = self.search(self.ribm(self.syndromes(received)))
        if s.fail:
            return received, -1
        return [r ^ e for r, e in zip(received, s.errors, strict=True)], s.roots
