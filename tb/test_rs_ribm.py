"""rs_ribm (S2): Lambda and Omega^h equal the stage model's for every suite codeword, 2t + 1 clocks after the load.

Why it matters: a wrong swap condition, initial value or end-of-array term gives a locator that still looks
plausible and fails only on some error patterns; the suite spans 0..t+2 errors, bursts and boundary positions. The
2t + 1 clock latency is what lets one decoder sustain a symbol per clock (ADR 0001); a result overwritten before it is
claimed loses a codeword.
"""

from __future__ import annotations

from typing import Any

from cocotb import start_soon, test
from cocotb.triggers import FallingEdge, RisingEdge
from rs_tb import params, reset
from tb_common import InOrderScoreboard, get_rng

from model.hw import HwDecoder
from model.vectors import suite


def _pack(values: list[int], m: int) -> int:
    return sum(v << (j * m) for j, v in enumerate(values))


def _split(word: int, m: int, count: int) -> list[int]:
    return [(word >> (j * m)) & ((1 << m) - 1) for j in range(count)]


async def _run(dut: Any, name: str, p_valid: float, p_ready: float) -> None:
    p = params()
    hw = HwDecoder(p.code())
    synds = [hw.syndromes(c.received) for c in suite(p, per_count=2)]
    synds.append([0] * p.nroots)
    rng = get_rng(f"{name}_{p.name}")
    await reset(dut, {"synd_valid_i": 0, "loc_ready_i": 0})
    sb = InOrderScoreboard(name)
    for s in synds:
        loc = hw.ribm(s)
        sb.expect((loc.lam, loc.omega))
    got = 0

    async def drive_ready() -> None:
        while True:
            dut.loc_ready_i.value = int(rng.random() < p_ready)
            await RisingEdge(dut.clk_i)

    async def monitor() -> None:
        # Sampled at the falling edge, where every input for the next rising edge is settled.
        nonlocal got
        fall = 0
        load_at = None
        was_valid = False
        while True:
            await FallingEdge(dut.clk_i)
            fall += 1
            valid = bool(dut.loc_valid_o.value)
            if valid and not was_valid:
                assert load_at is not None
                assert fall - load_at == p.nroots + 1, f"result {fall - load_at} clocks after the load"
            if dut.synd_valid_i.value and dut.synd_ready_o.value:
                load_at = fall
            if valid and dut.loc_ready_i.value:
                sb.observe((_split(int(dut.lam_o.value), p.m, p.t + 1), _split(int(dut.omega_o.value), p.m, p.t)))
                got += 1
                valid = False  # a claimed result may be replaced at once: the next rise is a new result
            was_valid = valid

    start_soon(drive_ready())
    start_soon(monitor())
    for s in synds:
        dut.synd_i.value = _pack(s, p.m)
        while True:
            dut.synd_valid_i.value = int(rng.random() < p_valid)
            await RisingEdge(dut.clk_i)
            if dut.synd_valid_i.value and dut.synd_ready_o.value:
                break
    dut.synd_valid_i.value = 0
    for _ in range(20_000):
        if got == len(synds):
            break
        await RisingEdge(dut.clk_i)
    for _ in range(100):
        await RisingEdge(dut.clk_i)
    assert got == len(synds)
    sb.check_done()


@test()
async def back_to_back(dut: Any) -> None:
    await _run(dut, "ribm_b2b", 1.0, 1.0)


@test()
async def gaps_and_slow_consumer(dut: Any) -> None:
    await _run(dut, "ribm_slow", 0.5, 0.05)
