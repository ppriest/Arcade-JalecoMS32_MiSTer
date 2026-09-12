#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the vendored V60/V70 core's own unit suite under ModelSim.
# RUN FROM THE REPOSITORY ROOT:
#
#     scripts/run_v60_tests.sh              # the whole suite
#     scripts/run_v60_tests.sh tb_v60_fp    # one bench
#
# The benches are meathax/s32's (sim/v60/, reused unchanged from
# verif/v60/ there) and so is the core (rtl/cpu/v60/, see PROVENANCE.md).
# Upstream runs this suite under Verilator and Icarus; this is the same suite
# under the ModelSim ASE 10.5b every sibling core is simulated on, and
# scripts/run_v60_verilator.sh is the Verilator side. Two simulators on
# purpose: the `always @*` time-zero entry in LESSONS_LEARNED is a
# disagreement only the pair could show.
#
# Ported from Model 1's tools/run_v60_tests.sh. Two things are carried over
# from there deliberately:
#
#   * Two benches inject an instruction byte with `cpu.fb[3] = ...`. In Model
#     1's split core that is a wire fed from v60_ifetch, and those benches are
#     rewritten on the way in (`cpu.fb[` -> `cpu.u_ifetch.fb[`) -- only when
#     the core under test has that submodule; upstream's monolithic core, the
#     one vendored here, does not. The files in sim/v60/ stay byte-identical
#     to upstream either way.
#   * tb_v60_smc is re-run at +CEDIV=3, because the core runs on a clock
#     enable on the real board and prefetch ack-sampling bugs hide completely
#     at ce=1.
#
# ONE COMPILE, MANY RUNS. Every bench elaborates the same six RTL files, so
# they are compiled once into work/ and each bench is compiled on top; the one
# bench that needs the RTL built differently (tb_v60_no_fp, -DS32_V60_NO_FP)
# gets its own library. A fresh library every run, for the reason in
# LESSONS_LEARNED: a killed compile leaves work/_lock and every later vlog
# waits on it silently.
set -uo pipefail
[ -d sys ] || { echo "run me from the repository root"; exit 1; }

# JTAG concurrent with ModelSim has bugchecked this PC. hwlock.py enforces it.
python scripts/hwlock.py --require-no-jtag "the V60 unit suite" || exit 1

MS=""
for _c in "${MODELSIM_BIN:-}" /c/intelFPGA_lite/17.0/modelsim_ase/win32aloem \
          C:/intelFPGA_lite/17.0/modelsim_ase/win32aloem; do
  [ -n "$_c" ] && [ -x "$_c/vlib.exe" ] && MS="$_c" && break
done
[ -n "$MS" ] || { echo "ModelSim not found. Set MODELSIM_BIN."; exit 1; }

# CPU= overrides the file list, to run the same suite against another copy of
# the core. First use: pointing it at upstream s32's current s32_v60.sv, to
# separate "these benches expect a newer core" from "this core is wrong".
CPU="${CPU:-rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv}"
VLOG="$MS/vlog.exe -quiet -sv +define+SIMULATION"
VSIM="$MS/vsim.exe -c -quiet"
# ModelSim on Windows ignores a bash timeout's signal and leaves vsimk.exe
# spinning; generous rather than tight, and sweep afterwards.
TMO="${TMO:-900}"

# bench : the marker its PASS line prints (grep -F, a fixed string).
# Union of both upstream runners' tables.
declare -A TB=(
  [tb_v60_smoke]="SMOKE PASS"                 [tb_v60_directed]="DIRECTED PASS"
  [tb_v60_fetch]="FETCH PERF PASS"            [tb_v60_smc]="V60 SMC PASS"
  [tb_v60_long_ea]="LONG EA PASS"             [tb_v60_bus_lanes]="V60 BUS LANES PASS"
  [tb_v60_divx]="DIVX PASS"                   [tb_v60_divxmem]="V60 DIVXMEM PASS"
  [tb_v60_flags]="V60 FLAGS PASS"             [tb_v60_ga2_bossbar]="V60 GA2 BOSSBAR PASS"
  [tb_v60_incdecmem]="V60 INCDECMEM PASS"     [tb_v60_rotate]="V60 ROTATE PASS"
  [tb_v60_shaov]="V60 SHAOV PASS"             [tb_v60_xch]="V60 XCH PASS"
  [tb_v60_audit]="AUDIT PASS"                 [tb_v60_bits]="BITS PASS"
  [tb_v60_decimal]="DECIMAL PASS"             [tb_v60_search]="V60 SEARCH PASS"
  [tb_v60_cmpc]="V60 CMPC PASS"               [tb_v60_movcd]="V60 MOVCD PASS"
  [tb_v60_schd]="V60 SCHD PASS"               [tb_v60_strfs]="V60 STRFS PASS"
  [tb_v60_fp]="V60 FP PASS"                   [tb_v60_fpdecode]="V60 FPDECODE PASS"
  [tb_v60_spidman_xchh]="SPIDMAN XCH.H PASS"  [tb_v60_spidman_window]="SPIDMAN WINDOW PASS"
  [tb_v60_spidman_gate]="SPIDMAN GATE PASS"   [tb_v60_ea_overlap_disp]="V60 EA_OVERLAP DISP PASS"
  [tb_v60_no_fp]="V60 NO-FP PASS"
)
ORDER="tb_v60_smoke tb_v60_directed tb_v60_fetch tb_v60_smc tb_v60_long_ea \
tb_v60_bus_lanes tb_v60_divx tb_v60_divxmem tb_v60_flags tb_v60_ga2_bossbar \
tb_v60_incdecmem tb_v60_rotate tb_v60_shaov tb_v60_xch tb_v60_audit tb_v60_bits \
tb_v60_decimal tb_v60_search tb_v60_cmpc tb_v60_movcd tb_v60_schd tb_v60_strfs \
tb_v60_fp tb_v60_fpdecode tb_v60_spidman_xchh tb_v60_spidman_window \
tb_v60_spidman_gate tb_v60_ea_overlap_disp tb_v60_no_fp"
[ $# -gt 0 ] && ORDER="$*"

OUT="${OUT:-simout/v60ut}"; rm -rf "$OUT"; mkdir -p "$OUT"

rm -rf work work_nofp
"$MS/vlib.exe" work >/dev/null
"$MS/vlib.exe" work_nofp >/dev/null
echo "--- vlog: rtl/cpu/v60 ---"
$VLOG -work work $CPU > "$OUT/rtl.log" 2>&1 || { cat "$OUT/rtl.log"; echo "RTL FAILED TO COMPILE"; exit 1; }
$VLOG -work work_nofp +define+S32_V60_NO_FP $CPU > "$OUT/rtl_nofp.log" 2>&1 || { cat "$OUT/rtl_nofp.log"; echo "RTL (no-FP) FAILED TO COMPILE"; exit 1; }

pass=0; fail=0; skip=0; failed=""
for tb in $ORDER; do
  src="sim/v60/$tb.sv"
  [ -f "$src" ] || { echo "SKIP  $tb (no file)"; skip=$((skip+1)); continue; }
  # The no-FP bench checks the define ITSELF (`ifndef S32_V60_NO_FP -> FAIL),
  # so the bench compile needs it as well as the RTL's. The first run here
  # missed that and reported a real-looking failure.
  lib=work; tbdef=""
  [ "$tb" = tb_v60_no_fp ] && { lib=work_nofp; tbdef="+define+S32_V60_NO_FP"; }
  # ...but only when the core under test actually has that submodule. Upstream
  # s32's monolithic core still has fb[] in the CPU itself.
  if grep -q 'cpu\.fb\[' "$src" && grep -q 'u_ifetch' $CPU; then
    sed -e 's/cpu\.fb\[/cpu.u_ifetch.fb[/g' "$src" > "$OUT/$tb.sv"; src="$OUT/$tb.sv"
  fi
  if ! $VLOG -work $lib $tbdef "$src" > "$OUT/$tb.vlog.log" 2>&1; then
    echo "BUILDFAIL $tb  (see $OUT/$tb.vlog.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
  fi
  run_one() {  # $1 = plusargs, $2 = label
    out="$(timeout "$TMO" $VSIM -work $lib $tb $1 -do 'run -all; quit -f' 2>&1)"
    echo "$out" > "$OUT/$2.vsim.log"
    if echo "$out" | grep -qF "${TB[$tb]}"; then
      extra="$(echo "$out" | grep -E 'FETCH PERF:|LANES|cycles=' | head -1 | sed 's/^# //')"
      printf 'PASS  %-26s %s\n' "$2" "$extra"; pass=$((pass+1))
    else
      echo "FAIL  $2   (expected '${TB[$tb]}', see $OUT/$2.vsim.log)"
      echo "$out" | grep -v '^# *$' | tail -4 | sed 's/^/        /'
      fail=$((fail+1)); failed="$failed $2"
    fi
  }
  run_one "" "$tb"
  [ "$tb" = tb_v60_smc ] && run_one "+CEDIV=3" "tb_v60_smc(ce=/3)"
done

echo "======================================================"
echo "V60 UNIT (rtl/cpu/v60 under ModelSim): $pass passed, $fail failed, $skip skipped${failed:+ -> FAILED:$failed}"
n=$(powershell.exe -NoProfile -Command "(Get-Process vsim,vsimk -ErrorAction SilentlyContinue).Count" 2>/dev/null | tr -d '\r' || echo 0)
[ "${n:-0}" != "0" ] && echo "WARNING: $n vsim/vsimk process(es) still running -- Stop-Process -Force them"
[ "$fail" -eq 0 ]
