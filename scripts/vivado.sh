#!/usr/bin/env bash
# Run Vivado in batch mode with this machine's workarounds, without sourcing settings64.sh into the user's shell.
#   scripts/vivado.sh -mode batch -source syn/synth_ooc.tcl -tclargs ...
# - Vivado's rdiArgs.sh forces LC_ALL=en_US.UTF-8, which WSL Ubuntu doesn't generate; a user-local copy lives in
#   ~/.locale (localedef -i en_US -f UTF-8 ~/.locale/en_US.UTF-8).
# - Ubuntu 26.04 lacks libncurses5/libtinfo5; compat symlinks live in ~/.local/lib/vivado-compat.
# - VIVADO_SETTINGS overrides the install; otherwise the newest under ~/Xilinx is used. docs/toolchain.md pins it.
set -eu
export LOCPATH="$HOME/.locale"
s="${VIVADO_SETTINGS:-$(ls -d "$HOME"/[Xx]ilinx/*/Vivado/settings64.sh "$HOME"/[Xx]ilinx/Vivado/*/settings64.sh \
    2>/dev/null | sort -V | tail -1 || true)}"
[ -n "$s" ] || { echo "vivado.sh: no Vivado install found under ~/Xilinx" >&2; exit 1; }
# shellcheck disable=SC1090
source "$s"
export LD_LIBRARY_PATH="$HOME/.local/lib/vivado-compat:${LD_LIBRARY_PATH:-}"
exec vivado -nojournal -nolog "$@"
