"""rs_decoder: whole codewords in, corrected codewords and {fail, count} out, equal to model/rs.py decode().

Why it matters: this is the release contract (rs-core-v1.0): 0..t errors corrected, t+1 detected and passed through
unchanged, at both parameter sets, at one symbol per clock with no stall between codewords. The buffers, status FIFO
and in-flight limit only show their bugs when the output stalls long enough to fill every slot, so one test does
exactly that; framing must survive a wrong s_axis_tlast without losing a codeword.
"""

from __future__ import annotations

from dataclasses import replace
from typing import Any

from cocotb import start_soon, test
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from rs_tb import params, reset
from tb_common import InOrderScoreboard, get_rng
from tb_common.axis import AxisBeat, AxisSink, AxisSource

from model.vectors import Case, make_case, suite


def _cnt_bits(n: int) -> int:
    return (n).bit_length()  # $clog2(N + 1)


def _expected(c: Case) -> tuple[list[int], bool, int]:
    return c.expected, c.corrected < 0, max(c.corrected, 0)


async def _setup(dut: Any, name: str, p_valid: float, p_ready: float) -> tuple[AxisSource, AxisSink, InOrderScoreboard,
                                                                                 list[int]]:
    p = params()
    rng = get_rng(f"{name}_{p.name}")
    await reset(dut, {"s_axis_tvalid_i": 0, "m_axis_tready_i": 0})
    sb = InOrderScoreboard(name)
    got = [0]
    cb = _cnt_bits(p.n)

    def on_frame(frame: list[AxisBeat]) -> None:
        users = {b.user for b in frame}
        assert len(users) == 1, f"tuser changed within a codeword: {users}"
        user = int(frame[0].user or 0)
        sb.observe(([int(b.data) for b in frame], bool(user >> cb), user & ((1 << cb) - 1)))
        got[0] += 1

    src = AxisSource(dut, dut.clk_i, "s_axis_", rng=rng, p_valid=p_valid)
    sink = AxisSink(dut, dut.clk_i, "m_axis_", rng=rng, p_ready=p_ready, callback=on_frame)
    return src, sink, sb, got


async def _drain(dut: Any, got: list[int], want: int, limit: int) -> None:
    for _ in range(limit):
        if got[0] == want:
            break
        await RisingEdge(dut.clk_i)
    await ClockCycles(dut.clk_i, 50)
    assert got[0] == want, f"{got[0]} of {want} codewords out"


def _beats(word: list[int]) -> list[AxisBeat]:
    return [AxisBeat(s, last=i == len(word) - 1) for i, s in enumerate(word)]


@test()
async def suite_random_handshakes(dut: Any) -> None:
    p = params()
    cases = suite(p, per_count=2)
    src, _, sb, got = await _setup(dut, "dec_suite", 0.8, 0.7)
    for c in cases:
        sb.expect(_expected(c))
    for c in cases:
        await src.send(_beats(c.received))
    await _drain(dut, got, len(cases), 20 * p.n)
    sb.check_done()
    assert int(dut.len_err_o.value) == 0


@test()
async def one_symbol_per_clock_sustained(dut: Any) -> None:
    # Back to back at full rate: after the first symbol s_axis_tready never drops, and from the first output symbol
    # m_axis_tvalid never drops until the last codeword is out.
    p = params()
    code = p.code()
    cases = [make_case(p, code, (p.t, p.t + 1, 0)[i % 3], 700 + i) for i in range(12)]
    src, _, sb, got = await _setup(dut, "dec_rate", 1.0, 1.0)
    for c in cases:
        sb.expect(_expected(c))
    in_stalls = 0
    out_gaps = 0
    out_beats = 0

    async def watch() -> None:
        nonlocal in_stalls, out_gaps, out_beats
        while True:
            await FallingEdge(dut.clk_i)
            if dut.s_axis_tvalid_i.value and not dut.s_axis_tready_o.value:
                in_stalls += 1
            if dut.m_axis_tvalid_o.value:
                out_beats += 1
            elif 0 < out_beats < len(cases) * p.n:
                out_gaps += 1

    start_soon(watch())
    await src.send([b for c in cases for b in _beats(c.received)])
    await _drain(dut, got, len(cases), 6 * p.n)
    sb.check_done()
    assert in_stalls == 0, f"input refused {in_stalls} clocks"
    assert out_gaps == 0, f"{out_gaps} idle clocks inside the output stream"


@test()
async def output_stall_fills_every_slot(dut: Any) -> None:
    # The sink holds tready low until the input has been refused for 50 clocks (all 4 slots full), then releases;
    # repeated, so the in-flight limit, both buffers and the status FIFO wrap several times under pressure.
    p = params()
    code = p.code()
    cases = [make_case(p, code, (p.t, 3, p.t + 1, 0, 1)[i % 5], 900 + i) for i in range(14)]
    src, sink, sb, got = await _setup(dut, "dec_stall", 1.0, 0.0)
    for c in cases:
        sb.expect(_expected(c))
    done = False
    holds = 0

    async def hold_and_release() -> None:
        nonlocal holds
        while not done:
            refused = 0
            sink.p_ready = 0.0
            while refused < 50 and not done:
                await RisingEdge(dut.clk_i)
                refused = refused + 1 if dut.s_axis_tvalid_i.value and not dut.s_axis_tready_o.value else 0
            holds += refused >= 50
            sink.p_ready = 0.9
            await ClockCycles(dut.clk_i, 2 * p.n)
        sink.p_ready = 1.0

    start_soon(hold_and_release())
    await src.send([b for c in cases for b in _beats(c.received)])
    done = True
    await _drain(dut, got, len(cases), 20 * p.n)
    sb.check_done()
    assert holds >= 2, f"the input was blocked by a full pipeline only {holds} times"


@test()
async def wrong_tlast_is_counted_framing_kept(dut: Any) -> None:
    p = params()
    code = p.code()
    cases = [make_case(p, code, k, 1200 + k) for k in (2, p.t, 0)]
    src, _, sb, got = await _setup(dut, "dec_tlast", 0.9, 1.0)
    for c in cases:
        sb.expect(_expected(c))
    beats = [b for c in cases for b in _beats(c.received)]
    beats[10] = replace(beats[10], last=True)                  # early tlast in codeword 0: one mismatch
    beats[p.n - 1] = replace(beats[p.n - 1], last=False)       # and the real end unmarked: another
    beats[2 * p.n + 5] = replace(beats[2 * p.n + 5], last=True)  # one more in codeword 2
    await src.send(beats)
    await _drain(dut, got, len(cases), 10 * p.n)
    sb.check_done()
    assert int(dut.len_err_o.value) == 3
