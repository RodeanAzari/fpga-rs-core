"""Build and run the cocotb regression with Verilator: python tb/run.py [test_module ...]

Every RTL test runs once per parameter set in model.vectors.PARAM_SETS (CCSDS and KP4): the same RTL, two fields.
The test reads which set it runs under from RS_CODE.
"""

from __future__ import annotations

import sys
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from model.vectors import PARAM_SETS, Params  # noqa: E402

PKG = ["rtl/rs_gf_pkg.sv"]

ALL_PARAMS = ("M", "PRIM_POLY", "FCR", "PRIM", "NROOTS", "N")

# test module -> (toplevel, sources, the RTL parameters the toplevel has)
TESTS: dict[str, tuple[str, list[str], tuple[str, ...]]] = {
    "test_rs_syndrome": ("rs_syndrome", [*PKG, "rtl/rs_syndrome.sv"], ALL_PARAMS),
    "test_rs_ribm": ("rs_ribm", [*PKG, "rtl/rs_ribm.sv"], ("M", "PRIM_POLY", "NROOTS")),
    "test_rs_chien_forney": ("rs_chien_forney", [*PKG, "rtl/rs_chien_forney.sv"], ALL_PARAMS),
    "test_rs_decoder": (
        "rs_decoder",
        [*PKG, *(f"rtl/{m}.sv" for m in ("rs_syndrome", "rs_ribm", "rs_chien_forney", "rs_decoder"))],
        ALL_PARAMS,
    ),
}


def rtl_params(p: Params, keys: tuple[str, ...]) -> dict[str, int]:
    every = {"M": p.m, "PRIM_POLY": p.prim_poly, "FCR": p.fcr, "PRIM": p.prim, "NROOTS": p.nroots, "N": p.n}
    return {k: every[k] for k in keys}


def main(names: list[str]) -> int:
    failed = 0
    # The tests import the model from the repo root; the runner builds the simulator's PYTHONPATH from sys.path.
    sys.path[:0] = [str(ROOT), str(ROOT / "tb")]
    for name in names or list(TESTS):
        top, srcs, keys = TESTS[name]
        for p in PARAM_SETS:
            build_dir = ROOT / "build" / "sim" / f"{name}_{p.name}"
            runner = get_runner("verilator")
            runner.build(
                sources=[ROOT / s for s in srcs],
                hdl_toplevel=top,
                parameters=rtl_params(p, keys),
                build_args=["--assert", "-Wall"],
                build_dir=build_dir,
                always=True,
            )
            results = runner.test(
                hdl_toplevel=top,
                test_module=name,
                test_dir=build_dir,
                build_dir=build_dir,
                extra_env={"RS_CODE": p.name},
            )
            _, fails = get_results(results)
            failed += fails
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
