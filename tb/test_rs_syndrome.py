"""rs_syndrome (S1): every codeword's syndromes equal the model's, under input gaps and a slow consumer.

Why it matters: a wrong root constant or a missed Horner step breaks every decode; a codeword boundary that slips
by one symbol (no clear between codewords, or a last symbol accepted while the previous syndromes are unclaimed)
corrupts the next codeword's syndromes, which only shows when codewords arrive back to back.
"""

from __future__ import annotations

from typing import Any

from cocotb import start_soon, test
from cocotb.triggers import RisingEdge
from rs_tb import params, reset
from tb_common import InOrderScoreboard, get_rng

from model.hw import HwDecoder
from model.vectors import suite


def _split(word: int, m: int, count: int) -> list[int]:
    return [(word >> (j * m)) & ((1 << m) - 1) for j in range(count)]


async def _run(dut: Any, name: str, p_valid: float, p_ready: float) -> None:
    p = params()
    hw = HwDecoder(p.code())
    cases = suite(p, per_count=1)
    rng = get_rng(f"{name}_{p.name}")
    await reset(dut, {"sym_valid_i": 0, "synd_ready_i": 0})
    sb = InOrderScoreboard(name)
    for c in cases:
        sb.expect(hw.syndromes(c.received))
    got = 0

    async def consume() -> None:
        nonlocal got
        while True:
            dut.synd_ready_i.value = int(rng.random() < p_ready)
            await RisingEdge(dut.clk_i)
            if dut.synd_valid_o.value and dut.synd_ready_i.value:
                sb.observe(_split(int(dut.synd_o.value), p.m, p.nroots))
                got += 1

    start_soon(consume())
    stalls = 0
    for c in cases:
        for pos, sym in enumerate(c.received):
            dut.sym_i.value = sym
            while True:
                dut.sym_valid_i.value = int(rng.random() < p_valid)
                await RisingEdge(dut.clk_i)
                if dut.sym_valid_i.value:
                    assert bool(dut.sym_last_o.value) == (pos == p.n - 1)
                    if dut.sym_ready_o.value:
                        break
                    stalls += 1
    dut.sym_valid_i.value = 0
    for _ in range(20_000):  # the slow consumer claims one set per ~1 / p_ready clocks
        if got == len(cases):
            break
        await RisingEdge(dut.clk_i)
    for _ in range(50):  # and nothing extra comes out
        await RisingEdge(dut.clk_i)
    assert got == len(cases)
    sb.check_done()
    if p_ready < 1.0:
        assert stalls > 0, "the slow consumer never made the last symbol wait"


@test()
async def back_to_back_fast_consumer(dut: Any) -> None:
    await _run(dut, "synd_b2b", 1.0, 1.0)


@test()
async def gaps_and_slow_consumer(dut: Any) -> None:
    await _run(dut, "synd_slow", 0.7, 0.002)
