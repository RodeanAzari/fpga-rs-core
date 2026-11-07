"""rs_chien_forney (S3): every position's error value, the root count and the fail flag equal the stage model's.

Why it matters: the start and step constants place every root; one off by a position corrects the wrong symbol, and
the Forney exponent is what turns a found root into the right error value. The fail flag (roots != deg Lambda) is the
decoder's only defence past t errors, so it is checked on locators riBM can really hand over: the suite's, an
all-zero Lambda (every position a root) and random garbage. Back to back, positions must stream with no gap between
codewords: that is the one-symbol-per-clock claim (ADR 0001).
"""

from __future__ import annotations

from typing import Any

import numpy as np
from cocotb import start_soon, test
from cocotb.triggers import FallingEdge, RisingEdge
from rs_tb import params, reset
from tb_common import InOrderScoreboard, get_rng

from model.hw import HwDecoder, Locator
from model.vectors import suite


def _pack(values: list[int], m: int) -> int:
    return sum(v << (j * m) for j, v in enumerate(values))


def _locators(hw: HwDecoder) -> list[Locator]:
    p = params()
    locs = [hw.ribm(hw.syndromes(c.received)) for c in suite(p, per_count=1)]
    rng = np.random.default_rng(5)
    locs.append(Locator([0] * (p.t + 1), [0] * p.t))
    locs.append(Locator([0] * (p.t + 1), rng.integers(0, 1 << p.m, p.t).tolist()))
    for _ in range(4):
        locs.append(Locator(rng.integers(0, 1 << p.m, p.t + 1).tolist(), rng.integers(0, 1 << p.m, p.t).tolist()))
    return locs


async def _run(dut: Any, name: str, p_valid: float) -> None:
    p = params()
    hw = HwDecoder(p.code())
    locs = _locators(hw)
    rng = get_rng(f"{name}_{p.name}")
    await reset(dut, {"loc_valid_i": 0})
    sb = InOrderScoreboard(name)
    for loc in locs:
        s = hw.search(loc)
        sb.expect((s.errors, s.roots, s.fail))
    assert any(not hw.search(loc).fail and hw.search(loc).roots == p.t for loc in locs)
    got = 0
    gaps = 0

    async def monitor() -> None:
        nonlocal got, gaps
        errs: list[int] = []
        started = False
        while True:
            await FallingEdge(dut.clk_i)
            if not dut.err_valid_o.value:
                if started and got < len(locs):
                    gaps += 1
                continue
            started = True
            errs.append(int(dut.err_o.value))
            if dut.err_last_o.value:
                assert len(errs) == p.n, f"{len(errs)} positions"
                sb.observe((errs, int(dut.roots_o.value), bool(dut.fail_o.value)))
                errs = []
                got += 1

    start_soon(monitor())
    for loc in locs:
        dut.lam_i.value = _pack(loc.lam, p.m)
        dut.omega_i.value = _pack(loc.omega, p.m)
        while True:
            dut.loc_valid_i.value = int(rng.random() < p_valid)
            await RisingEdge(dut.clk_i)
            if dut.loc_valid_i.value and dut.loc_ready_o.value:
                break
    dut.loc_valid_i.value = 0
    for _ in range(p.n + 20):
        await RisingEdge(dut.clk_i)
    assert got == len(locs)
    sb.check_done()
    if p_valid == 1.0:
        assert gaps == 0, f"{gaps} idle clocks between back-to-back codewords"


@test()
async def back_to_back_no_gaps(dut: Any) -> None:
    await _run(dut, "cf_b2b", 1.0)


@test()
async def with_gaps(dut: Any) -> None:
    await _run(dut, "cf_gaps", 0.01)
