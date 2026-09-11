#!/bin/sh
# V60 differential regression: reference model vs RTL over N random seeds.
set -e
cd "$(dirname "$0")/../.."
N="${1:-20}"
T=$(mktemp -d)
iverilog -g2012 -o "$T/tb_diff" \
  rtl/cpu/v60/s32_v60.sv rtl/cpu/v60/s32_v60_bus.sv verif/v60/tb_v60_diff.sv 2>/dev/null
python3 verif/cosim/v60_ref.py >/dev/null   # self-test the model first
fail=0
for s in $(seq 1 "$N"); do
    python3 verif/cosim/gen_diff_program.py "$s" "$T/p$s" >/dev/null
    vvp "$T/tb_diff" +hex="$T/p$s.hex" 2>/dev/null | grep -E '^[RM][0-9]=' > "$T/r$s.rtl"
    if diff -q "$T/p$s.expected" "$T/r$s.rtl" >/dev/null; then
        :
    else
        echo "SEED $s DIVERGES:"
        diff "$T/p$s.expected" "$T/r$s.rtl" | head -8
        fail=$((fail+1))
    fi
done
if [ "$fail" -eq 0 ]; then echo "V60 DIFF: PASS ($N/$N seeds match reference)"; else echo "V60 DIFF: FAIL ($fail/$N)"; fi
rm -rf "$T"
[ "$fail" -eq 0 ]
