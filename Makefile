# fpga-rs-core: parameterized Reed-Solomon decoder (CCSDS RS(255,223), KP4 RS(544,514)).
PY := .venv/bin/python
PKG := rtl/rs_gf_pkg.sv
# Every module is linted at both parameter sets (model/vectors.py): its CCSDS defaults, then KP4.
KP4_FIELD := -GM=10 -GPRIM_POLY=1033 -GNROOTS=30
KP4_ALL := $(KP4_FIELD) -GFCR=0 -GPRIM=1 -GN=544
LINT := verilator --lint-only -Wall $(PKG)

.PHONY: setup model-test lint lint-py sim ci clean

setup:
	python3 -m venv .venv
	$(PY) -m pip install -q -r requirements.txt

model-test:
	$(PY) -m pytest -q

lint:
	$(LINT) rtl/rs_syndrome.sv --top-module rs_syndrome
	$(LINT) rtl/rs_syndrome.sv --top-module rs_syndrome $(KP4_ALL)
	$(LINT) rtl/rs_ribm.sv --top-module rs_ribm
	$(LINT) rtl/rs_ribm.sv --top-module rs_ribm $(KP4_FIELD)

lint-py:
	$(PY) -m ruff check model tb
	$(PY) -m mypy

sim:
	$(PY) tb/run.py

ci: lint-py lint model-test sim

clean:
	rm -rf build sim_build .pytest_cache .mypy_cache .ruff_cache
