"""The stage-level model (what the RTL implements) must decode exactly like the reference model.

Why: riBM, the output-order Chien search and the riBM-form Forney all differ from the textbook decoder in `model.rs`;
any difference in a corrected symbol, the correction count or the failure decision is a bug the RTL would inherit.
"""

from __future__ import annotations

import numpy as np
import pytest

from model.hw import HwDecoder
from model.vectors import PARAM_SETS, Params, make_case, suite


@pytest.mark.parametrize("p", PARAM_SETS, ids=lambda p: p.name)
def test_matches_reference_on_the_suite(p: Params) -> None:
    hw = HwDecoder(p.code())
    for case in suite(p, per_count=2):
        assert hw.decode(case.received) == (case.expected, case.corrected)


@pytest.mark.parametrize("p", PARAM_SETS, ids=lambda p: p.name)
def test_failure_detection_far_past_t(p: Params) -> None:
    # riBM keeps only t+1 locator coefficients: with many errors the truncated locator must still be flagged.
    code = p.code()
    hw = HwDecoder(code)
    for i, count in enumerate((p.t + 1, p.t + 2, p.t + 5, 2 * p.t, 3 * p.t)):
        for j in range(4):
            case = make_case(p, code, count, 50_000 + 10 * i + j)
            assert hw.decode(case.received) == (case.expected, case.corrected) == (case.received, -1)


@pytest.mark.parametrize("p", PARAM_SETS, ids=lambda p: p.name)
def test_random_words_are_flagged(p: Params) -> None:
    # A uniformly random word is almost never within t of a codeword (< 1e-9 for both codes).
    code = p.code()
    hw = HwDecoder(code)
    rng = np.random.default_rng(77)
    for _ in range(6):
        word = rng.integers(0, code.q + 1, p.n).tolist()
        assert hw.decode(word) == code.decode(word) == (word, -1)
