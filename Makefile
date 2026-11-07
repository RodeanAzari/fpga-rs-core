# fpga-rs-core: parameterized Reed-Solomon decoder (CCSDS RS(255,223), KP4 RS(544,514)).
PY := .venv/bin/python

.PHONY: setup model-test lint-py ci clean

setup:
	python3 -m venv .venv
	$(PY) -m pip install -q -r requirements.txt

model-test:
	$(PY) -m pytest -q

lint-py:
	$(PY) -m ruff check model
	$(PY) -m mypy

ci: lint-py model-test

clean:
	rm -rf build sim_build .pytest_cache .mypy_cache .ruff_cache
