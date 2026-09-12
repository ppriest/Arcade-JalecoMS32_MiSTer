#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Compile and run one testbench. RUN FROM THE REPOSITORY ROOT.
#
#     scripts/run_sim.sh v70_bus_tb
#     scripts/run_sim.sh v70_boot_tb +GAME=tetrisp +N=20000   # extra args go to vsim
#
# $readmemh paths resolve against the simulator's CWD, not the testbench
# file, so every bench in this project is written to be run from the repo
# root and this script enforces it. A wrong CWD leaves ROMs all zeroes and
# fails every check at once, which reads exactly like an RTL regression --
# grep the log for `readmem` first (LESSONS_LEARNED, "Testbench discipline").
#
# PORTED FROM THE SETA CORE, minus its vcom step: this core has no VHDL.
# The vendored V60/V70 core's own suite has its own runner
# (scripts/run_v60_tests.sh), because it is thirty benches on one compile.
#
# A FRESH library every run. A run that dies mid-compile leaves work/_lock
# behind, on which every later vlog waits silently and forever. Corollary:
# one run at a time.
set -euo pipefail

TB="${1:?usage: scripts/run_sim.sh <testbench-dir-name> [vsim args...]}"
shift
MS=""
for _c in "${MODELSIM_BIN:-}" /c/intelFPGA_lite/17.0/modelsim_ase/win32aloem \
          C:/intelFPGA_lite/17.0/modelsim_ase/win32aloem; do
  [ -n "$_c" ] && [ -x "$_c/vlib.exe" ] && MS="$_c" && break
done
[ -n "$MS" ] || { echo "ModelSim not found. Set MODELSIM_BIN."; exit 1; }
[ -d sys ] || { echo "run me from the repository root"; exit 1; }
[ -d "sim/$TB" ] || { echo "no such testbench: sim/$TB"; exit 1; }

# JTAG concurrent with ModelSim has bugchecked this PC. hwlock.py enforces it.
python scripts/hwlock.py --require-no-jtag "simulation $TB"

if command -v powershell.exe >/dev/null 2>&1; then
  n=$(powershell.exe -NoProfile -Command \
      "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
  [ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) already running."
fi

rm -rf work
"$MS/vlib.exe" work >/dev/null

# Every RTL file, the shared models in sim/common, plus the bench. The vendored CPU's own benches are not
# compiled here -- they have their own runner -- and rtl/synth_check is a
# Quartus-only harness.
RTL=$(find rtl -name '*.sv' -not -path 'rtl/synth_check/*' -not -name '*_upstream_reference.sv' | sort)
echo "--- vlog ---"
# INITREG defaults to the jotego-style zero-initialisation the sibling cores
# use. Set INITREG=" " to run four-state (X) instead -- see the note in
# sim/v70_boot_tb about why that matters for `always @*` blocks.
# VDEFS: extra +define+ switches, e.g. VDEFS=+define+V60_NO_EXEC_RETIRE for an A/B.
"$MS/vlog.exe" -quiet -sv -work work +define+SIMULATION ${INITREG-+initreg=r+0 +initmem=r+0} ${VDEFS:-} \
    $RTL sim/common/*.sv sim/$TB/*.sv

TOP=$(grep -l -E '^\s*module\s+tb_' sim/$TB/*.sv | head -1 | xargs grep -oE '^\s*module\s+tb_[a-z0-9_]+' | awk '{print $2}')
echo "--- vsim $TOP $* ---"
"$MS/vsim.exe" -c -quiet -work work "$TOP" "$@" -do "run -all; quit -f" 2>&1 \
  | grep -v '^# *$' | grep -v 'pref.tcl\|^# 10.5b\|Start time\|^# vsim -c'
