# fpga-rs-core: parameterized Reed-Solomon decoder (CCSDS RS(255,223), KP4 RS(544,514)).
PY := .venv/bin/python
PKG := rtl/rs_gf_pkg.sv
# Every module is linted at both parameter sets (model/vectors.py): its CCSDS defaults, then KP4.
KP4_FIELD := -GM=10 -GPRIM_POLY=1033 -GNROOTS=30
KP4_ALL := $(KP4_FIELD) -GFCR=0 -GPRIM=1 -GN=544
LINT := verilator --lint-only -Wall $(PKG)

.PHONY: setup model-test lint lint-py sim ci synth synth-ooc clean

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
	$(LINT) rtl/rs_chien_forney.sv --top-module rs_chien_forney
	$(LINT) rtl/rs_chien_forney.sv --top-module rs_chien_forney $(KP4_ALL)
	$(LINT) rtl/rs_syndrome.sv rtl/rs_ribm.sv rtl/rs_chien_forney.sv rtl/rs_decoder.sv --top-module rs_decoder
	$(LINT) rtl/rs_syndrome.sv rtl/rs_ribm.sv rtl/rs_chien_forney.sv rtl/rs_decoder.sv --top-module rs_decoder $(KP4_ALL)

lint-py:
	$(PY) -m ruff check model tb
	$(PY) -m mypy

sim:
	$(PY) tb/run.py

ci: lint-py lint model-test sim

clean:
	rm -rf build sim_build .pytest_cache .mypy_cache .ruff_cache

# Vivado out-of-context synthesis + place + route at 100 MHz on the Arty A7-100T part (local only).
# Reports in docs/reports/ooc/<name>/ (summary.txt: WNS; utilization.rpt).
KP4_GENERICS := M=10 PRIM_POLY=1033 FCR=0 PRIM=1 NROOTS=30 N=544
synth-ooc: NAME ?= $(TOP)
synth-ooc:
	mkdir -p build/syn && cd build/syn && OOC_GENERICS="$(GENERICS)" OOC_NAME="$(NAME)" ../../scripts/vivado.sh \
		-mode batch -source ../../syn/synth_ooc.tcl -tclargs $(TOP) > $(NAME).log 2>&1 || { tail -30 $(NAME).log; exit 1; }

synth:
	$(MAKE) synth-ooc TOP=rs_decoder NAME=rs_decoder_ccsds
	$(MAKE) synth-ooc TOP=rs_decoder NAME=rs_decoder_kp4 GENERICS="$(KP4_GENERICS)"
