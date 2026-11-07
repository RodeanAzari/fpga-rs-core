"""Parameterized Reed-Solomon codec over GF(2^m): the golden model for the RTL decoder (README, Parameters)."""

from __future__ import annotations

from collections.abc import Sequence


class RSCode:
    """Systematic RS code. Generator roots are alpha^(prim*(fcr+j)) for j in 0..nroots-1."""

    def __init__(self, m: int, prim_poly: int, fcr: int, prim: int, nroots: int, n: int | None = None) -> None:
        self.q = (1 << m) - 1
        self.n = self.q if n is None else n
        if not 0 < nroots < self.n <= self.q:
            raise ValueError("need 0 < nroots < n <= 2^m - 1")
        self.k = self.n - nroots
        self.nroots = nroots
        self.fcr = fcr
        self.prim = prim
        self.exp = [0] * (2 * self.q)
        self.log = [0] * (self.q + 1)
        x = 1
        for i in range(self.q):
            self.exp[i] = self.exp[i + self.q] = x
            self.log[x] = i
            x <<= 1
            if x >> m:
                x ^= prim_poly
        if x != 1:
            raise ValueError("prim_poly is not primitive")
        # generator[i] is the coefficient of x^i.
        self.generator = [1]
        for j in range(nroots):
            root = self._beta_pow(fcr + j)
            next_gen = [0] * (len(self.generator) + 1)
            for i, c in enumerate(self.generator):
                next_gen[i + 1] ^= c
                next_gen[i] ^= self._mul(c, root)
            self.generator = next_gen

    def _mul(self, a: int, b: int) -> int:
        return 0 if a == 0 or b == 0 else self.exp[self.log[a] + self.log[b]]

    def _inv(self, a: int) -> int:
        return self.exp[(self.q - self.log[a]) % self.q]

    def _beta_pow(self, e: int) -> int:
        return self.exp[(self.prim * e) % self.q]

    def encode(self, data: Sequence[int]) -> list[int]:
        """Return data followed by parity, highest-degree symbol first."""
        if len(data) != self.k:
            raise ValueError(f"expected {self.k} data symbols, got {len(data)}")
        parity = [0] * self.nroots
        for d in data:
            fb = d ^ parity[0]
            parity = [*parity[1:], 0]
            if fb:
                for i in range(self.nroots):
                    parity[i] ^= self._mul(fb, self.generator[self.nroots - 1 - i])
        return [int(d) for d in data] + parity

    def syndromes(self, word: Sequence[int]) -> list[int]:
        out = []
        for j in range(self.nroots):
            root = self._beta_pow(self.fcr + j)
            s = 0
            for c in word:
                s = self._mul(s, root) ^ int(c)
            out.append(s)
        return out

    def _eval(self, poly: Sequence[int], x: int) -> int:
        """Evaluate a polynomial stored lowest degree first."""
        out = 0
        for c in reversed(poly):
            out = self._mul(out, x) ^ c
        return out

    def _berlekamp_massey(self, synd: Sequence[int]) -> list[int]:
        locator, prev = [1], [1]
        degree, gap, last_disc = 0, 1, 1
        for r in range(self.nroots):
            disc = synd[r]
            for i in range(1, degree + 1):
                if i < len(locator):
                    disc ^= self._mul(locator[i], synd[r - i])
            if disc == 0:
                gap += 1
                continue
            scale = self._mul(disc, self._inv(last_disc))
            updated = locator + [0] * max(0, len(prev) + gap - len(locator))
            for i, c in enumerate(prev):
                updated[i + gap] ^= self._mul(scale, c)
            if 2 * degree <= r:
                degree, prev, last_disc, gap = r + 1 - degree, locator, disc, 1
            else:
                gap += 1
            locator = updated
        return locator[: degree + 1] + [0] * max(0, degree + 1 - len(locator))

    def decode(self, word: Sequence[int]) -> tuple[list[int], int]:
        """Return (corrected word, symbols corrected), or (word unchanged, -1) if uncorrectable."""
        if len(word) != self.n:
            raise ValueError(f"expected {self.n} symbols, got {len(word)}")
        received = [int(c) for c in word]
        synd = self.syndromes(received)
        if not any(synd):
            return received, 0
        locator = self._berlekamp_massey(synd)
        degree = len(locator) - 1
        if degree == 0 or degree > self.nroots // 2 or locator[degree] == 0:
            return received, -1
        # Omega(x) = S(x) * Lambda(x) mod x^nroots
        omega = [0] * self.nroots
        for i, s in enumerate(synd):
            for j, c in enumerate(locator):
                if i + j < self.nroots:
                    omega[i + j] ^= self._mul(s, c)
        derivative = [locator[i] if i % 2 else 0 for i in range(1, degree + 1)]
        corrected = received[:]
        found = 0
        for d in range(self.n):  # d is the degree of the symbol's position
            x = self._beta_pow(d)
            x_inv = self._inv(x)
            if self._eval(locator, x_inv) != 0:
                continue
            found += 1
            denom = self._eval(derivative, x_inv)
            if denom == 0:
                return received, -1
            # Forney: e = X^(1-fcr) * Omega(1/X) / Lambda'(1/X)
            x_factor = self._beta_pow(d * (1 - self.fcr))
            value = self._mul(self._mul(x_factor, self._eval(omega, x_inv)), self._inv(denom))
            corrected[self.n - 1 - d] ^= value
        if found != degree or any(self.syndromes(corrected)):
            return received, -1
        return corrected, found
