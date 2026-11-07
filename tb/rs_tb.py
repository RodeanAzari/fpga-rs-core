"""Shared testbench helpers: which parameter set this simulation runs, clock and reset."""

from __future__ import annotations

import os
from typing import Any

from cocotb import start_soon
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from model.vectors import PARAM_SETS, Params


def params() -> Params:
    name = os.environ["RS_CODE"]
    return next(p for p in PARAM_SETS if p.name == name)


async def reset(dut: Any, idle: dict[str, int]) -> None:
    """Start the 100 MHz clock, hold reset 3 cycles with the given inputs idle."""
    start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    for sig, v in idle.items():
        getattr(dut, sig).value = v
    await ClockCycles(dut.clk_i, 3)
    dut.rst_i.value = 0
