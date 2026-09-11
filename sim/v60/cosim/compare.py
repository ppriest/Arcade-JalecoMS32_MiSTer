#!/usr/bin/env python3
"""V60 co-simulation comparator (DESIGN.md §11.2).

Compares a MAME trace (mame_v60_trace.patch format) against the RTL trace
emitted by the Verilator/iverilog bench (same 24-byte record format,
produced by tb_v60_cosim's $fwrite hooks).

Usage: compare.py mame_trace.bin rtl_trace.bin [--max-divergences N]
Exit 0 = zero architectural divergences.
"""
import struct, sys

REC = struct.Struct("<IIBxxxIII")

def records(path):
    with open(path, "rb") as f:
        while True:
            b = f.read(REC.size)
            if len(b) < REC.size:
                return
            yield REC.unpack(b)

def main():
    a, b = sys.argv[1], sys.argv[2]
    maxdiv = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    div = 0
    for n, (ra, rb) in enumerate(zip(records(a), records(b))):
        if ra != rb:
            div += 1
            print(f"DIVERGE @insn {n}:")
            print(f"  mame: pc={ra[0]:08x} psw={ra[1]:08x} r{ra[2]}={ra[3]:08x} mem[{ra[4]:08x}]={ra[5]:08x}")
            print(f"  rtl : pc={rb[0]:08x} psw={rb[1]:08x} r{rb[2]}={rb[3]:08x} mem[{rb[4]:08x}]={rb[5]:08x}")
            if div >= maxdiv:
                break
    print(f"{'PASS' if div == 0 else 'FAIL'}: {div} divergences over {n+1} instructions")
    sys.exit(0 if div == 0 else 1)

if __name__ == "__main__":
    main()
