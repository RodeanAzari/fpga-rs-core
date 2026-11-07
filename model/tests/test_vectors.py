"""The model against reedsolo (an independent RS implementation) on every case the RTL suites use.

Why: the RTL is checked only against `model.rs`, so the model itself must be proven right at both parameter sets,
including the failure side (t+1 errors flagged, never returned as a clean decode).
"""

from __future__ import annotations

import pytest
import reedsolo

from model.rs import RSCode
from model.vectors import CCSDS, KP4, PARAM_SETS, Case, Params, make_case, suite


def _reference(p: Params, code: RSCode) -> reedsolo.RSCodec:
    # reedsolo's roots are generator^(fcr+j), so its generator is our alpha^PRIM.
    return reedsolo.RSCodec(
        nsym=p.nroots, nsize=code.q, fcr=p.fcr, prim=p.prim_poly, generator=code.exp[p.prim], c_exp=p.m
    )


def _reference_decode(ref: reedsolo.RSCodec, received: list[int]) -> list[int] | None:
    try:
        _, full, _ = ref.decode(list(received))
    except reedsolo.ReedSolomonError:
        return None
    return [int(x) for x in full]


@pytest.mark.parametrize("p", PARAM_SETS, ids=lambda p: p.name)
def test_encoder_matches_reference(p: Params) -> None:
    code = p.code()
    ref = _reference(p, code)
    for case in suite(p, per_count=1)[:5]:
        msg = case.sent[: p.n - p.nroots]
        assert [int(x) for x in ref.encode(msg)] == case.sent


@pytest.mark.parametrize("p", PARAM_SETS, ids=lambda p: p.name)
def test_every_suite_case_agrees_with_reference(p: Params) -> None:
    code = p.code()
    ref = _reference(p, code)
    cases = suite(p)
    for case in cases:
        theirs = _reference_decode(ref, case.received)
        if case.errors <= p.t:
            assert case.corrected == case.errors
            assert case.expected == case.sent
            assert theirs == case.sent
        else:
            # Beyond t: flagged, received word passed through unchanged; reedsolo must not decode to `sent` either.
            assert case.corrected == -1
            assert case.expected == case.received
            assert theirs != case.sent
    # The suite really exercises both sides of the limit: per_count random + 3 patterns + 2 data extremes at t.
    assert sum(c.corrected == p.t for c in cases) == 4 + 3 + 2
    assert sum(c.corrected == -1 for c in cases) >= 10


def test_shortened_code_never_corrects_outside_the_codeword() -> None:
    # KP4 is shortened (n = 544 of 1023): a locator whose roots fall in the removed positions must be flagged.
    # Corrupting t+1 symbols makes such locators common; every case must be flagged, none "corrected".
    code = KP4.code()
    for seed in range(40):
        case = make_case(KP4, code, KP4.t + 1, 9000 + seed)
        assert case.corrected == -1


def test_suite_is_deterministic() -> None:
    a: list[Case] = suite(CCSDS, seed=3, per_count=1)
    b: list[Case] = suite(CCSDS, seed=3, per_count=1)
    assert a == b
    assert suite(CCSDS, seed=4, per_count=1) != a
