#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Run the vendored V60/V70 core's unit suite under VERILATOR -- the simulator
# both upstreams regression it with. RUN FROM THE REPOSITORY ROOT:
#
#     scripts/run_v60_verilator.sh              # every Verilator-capable bench
#     scripts/run_v60_verilator.sh tb_v60_fp    # one bench
#
# scripts/run_v60_tests.sh is the ModelSim runner of the same suite and stays
# the second opinion: s32 calls Verilator its "second-simulator safety net",
# and the `always @*` time-zero finding in LESSONS_LEARNED is exactly the
# kind of disagreement the two surface between them.
#
# Verilator here is MSYS2's mingw64 package (pacman -S mingw-w64-x86_64-verilator,
# 5.050 on 2026-09-12), driven through the msys bash so make/g++ resolve. The
# flag set is s32's verif/v60/run_v60_verilator.sh's, verbatim.
#
# Seven benches poke the core's enum FSM state and do not elaborate under
# Verilator (upstream routes them to Icarus); here they are skipped, and the
# ModelSim runner covers them. Model 1's runner header records two traps
# carried over: --binary builds are large, so each tree is deleted after its
# run; and -j fans out one g++ per translation unit, so it is capped.
set -uo pipefail
[ -d sys ] || { echo "run me from the repository root"; exit 1; }

MSYS_BASH="${MSYS_BASH:-/e/msys64/usr/bin/bash.exe}"
[ -x "$MSYS_BASH" ] || { echo "MSYS2 bash not found at $MSYS_BASH"; exit 1; }
REPO="$(pwd -W 2>/dev/null || pwd)"     # a path the msys shell can use

CPU="rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv"
VJOBS="${VJOBS:-4}"
VFLAGS="--binary --timing -j $VJOBS -Wno-fatal -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-INITIALDLY -Wno-DECLFILENAME -Wno-PINMISSING -Wno-UNSIGNED -Wno-WIDTH +define+SIMULATION ${VDEFS:-}"

declare -A TB=(
  [tb_v60_smoke]="SMOKE PASS"                 [tb_v60_directed]="DIRECTED PASS"
  [tb_v60_fetch]="FETCH PERF PASS"            [tb_v60_smc]="V60 SMC PASS"
  [tb_v60_long_ea]="LONG EA PASS"             [tb_v60_bus_lanes]="V60 BUS LANES PASS"
  [tb_v60_divx]="DIVX PASS"                   [tb_v60_divxmem]="V60 DIVXMEM PASS"
  [tb_v60_flags]="V60 FLAGS PASS"             [tb_v60_ga2_bossbar]="V60 GA2 BOSSBAR PASS"
  [tb_v60_incdecmem]="V60 INCDECMEM PASS"     [tb_v60_rotate]="V60 ROTATE PASS"
  [tb_v60_shaov]="V60 SHAOV PASS"             [tb_v60_xch]="V60 XCH PASS"
  [tb_v60_audit]="AUDIT PASS"                 [tb_v60_bits]="BITS PASS"
  [tb_v60_decimal]="DECIMAL PASS"             [tb_v60_fpdecode]="V60 FPDECODE PASS"
  [tb_v60_spidman_xchh]="SPIDMAN XCH.H PASS"  [tb_v60_spidman_window]="SPIDMAN WINDOW PASS"
  [tb_v60_spidman_gate]="SPIDMAN GATE PASS"
)
# upstream's ICARUS_ONLY set: enum-FSM pokes Verilator cannot elaborate
SKIP="tb_v60_search tb_v60_cmpc tb_v60_movcd tb_v60_schd tb_v60_strfs tb_v60_fp tb_v60_ea_overlap_disp tb_v60_no_fp"
ORDER="tb_v60_smoke tb_v60_directed tb_v60_fetch tb_v60_smc tb_v60_long_ea \
tb_v60_bus_lanes tb_v60_divx tb_v60_divxmem tb_v60_flags tb_v60_ga2_bossbar \
tb_v60_incdecmem tb_v60_rotate tb_v60_shaov tb_v60_xch tb_v60_audit tb_v60_bits \
tb_v60_decimal tb_v60_fpdecode tb_v60_spidman_xchh tb_v60_spidman_window tb_v60_spidman_gate"
[ $# -gt 0 ] && ORDER="$*"

OUT="build/v60vl"; mkdir -p "$OUT"
pass=0; fail=0; skip=0; failed=""
for tb in $ORDER; do
  case " $SKIP " in *" $tb "*) echo "SKIP  $tb (enum-FSM poke; ModelSim runner covers it)"; skip=$((skip+1)); continue;; esac
  src="sim/v60/$tb.sv"
  [ -f "$src" ] || { echo "SKIP  $tb (no file)"; skip=$((skip+1)); continue; }
  bdir="$OUT/$tb"; rm -rf "$bdir"
  if ! "$MSYS_BASH" -lc "export PATH=/mingw64/bin:\$PATH; cd '$REPO' && verilator $VFLAGS --top-module $tb --Mdir $bdir -o $tb $CPU $src" > "$OUT/$tb.build.log" 2>&1; then
    echo "BUILDFAIL $tb  (see $OUT/$tb.build.log)"; fail=$((fail+1)); failed="$failed $tb"; continue
  fi
  out="$(timeout 300 "$bdir/$tb.exe" 2>&1)"
  echo "$out" > "$OUT/$tb.run.log"
  if echo "$out" | grep -qF "${TB[$tb]}"; then
    extra="$(echo "$out" | grep -E 'FETCH PERF:|LANES|cycles=' | head -1)"
    printf 'PASS  %-26s %s\n' "$tb" "$extra"; pass=$((pass+1))
  else
    echo "FAIL  $tb   (expected '${TB[$tb]}', see $OUT/$tb.run.log)"
    echo "$out" | grep -v "^- " | tail -3 | sed 's/^/        /'
    fail=$((fail+1)); failed="$failed $tb"
  fi
  if [ "$tb" = tb_v60_smc ]; then
    if "$bdir/$tb.exe" +CEDIV=3 2>&1 | grep -qF "V60 SMC PASS"; then
      echo "PASS  tb_v60_smc(ce=/3)"; pass=$((pass+1))
    else
      echo "FAIL  tb_v60_smc(ce=/3)"; fail=$((fail+1)); failed="$failed tb_v60_smc(ce/3)"
    fi
  fi
  rm -rf "$bdir"
done
echo "======================================================"
echo "V60 UNIT (Verilator): $pass passed, $fail failed, $skip skipped${failed:+ -> FAILED:$failed}"
[ "$fail" -eq 0 ]
