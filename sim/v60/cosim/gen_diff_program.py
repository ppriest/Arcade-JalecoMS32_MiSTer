#!/usr/bin/env python3
"""
Constrained-random V60 program generator + reference runner (DESIGN.md §11.2).

Emits:
  - a flat little-endian memory image (program at 0, data scratch at 0x8000)
  - the expected final architectural state, computed by the independent
    v60_ref model

The RTL bench (tb_v60_diff.sv) loads the same image, runs to HALT, and its
$display of the final register file is compared against the .expected file
by run_diff.sh. Seed is an argument so failures reproduce.

Instruction mix stresses the addressing-mode decoder and the ALU flag paths
(the highest-risk parts of the RTL) without generating wild control flow:
each test is a straight-line block of N ops ending in HALT, operating on a
fixed register/scratch working set.
"""
import sys, random, struct
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from v60_ref import V60, Mem, M32

def imm32(v): return bytes([0x2D, 0x20 | 0, 0xF4]) + struct.pack("<I", v)  # MOVW #v,R0

class Asm:
    def __init__(self): self.b = bytearray()
    def emit(self, *bs): self.b += bytes(bs)
    def imm_to_reg(self, v, rn): self.emit(0x2D, 0x20 | rn, 0xF4); self.b += struct.pack("<I", v)
    # ALU op reg-reg via F2 D=1: op1=AM(reg src, modm1 mode3=0x60|src), op2=reg dst
    def alu_rr(self, op, src, dst): self.emit(op, 0x20 | dst | 0x40, 0x60 | src)
    # store reg to absolute (F2 D=0: op1=reg, op2=direct 0xF3+addr32)
    def st_abs(self, rn, addr): self.emit(0x2D, 0x00 | rn, 0xF3); self.b += struct.pack("<I", addr)
    # load absolute to reg (F2 D=1: op1=direct, op2=reg)
    def ld_abs(self, addr, rn): self.emit(0x2D, 0x20 | rn | 0x40, 0xF3); self.b += struct.pack("<I", addr)
    def halt(self): self.emit(0x00)

# ALU opcodes exercised (word forms) — flags + result differ per op
ALU = [0x84,  # ADDW
       0xac,  # SUBW
       0xbc,  # CMPW  (no writeback -> flags only)
       0xa4,  # ANDW
       0x8c,  # ORW
       0xb4,  # XORW
       0x85,  # MULW
       0x95,  # MULUW
       0xa5,  # DIVW
       0xb5]  # DIVUW

def gen(seed, nops=40):
    rng = random.Random(seed)
    a = Asm()
    # seed R0..R7 with random values
    vals = [rng.randint(0, M32) for _ in range(8)]
    for i, v in enumerate(vals):
        a.imm_to_reg(v, i)
    # set a nonzero divisor guard: R1 |= 1 handled by avoiding div-by-0 below
    for _ in range(nops):
        op = rng.choice(ALU)
        src = rng.randint(0, 7)
        dst = rng.randint(0, 7)
        if op in (0xa5, 0xb5):  # DIV: skip if src reg could be zero — reseed src reg
            a.imm_to_reg(rng.randint(1, M32), src)
        a.alu_rr(op, src, dst)
    # Capture the final PSW into R7 (GETPSW, reg-direct) so the last op's flags
    # are compared through the M7 scratch word — the harness previously observed
    # no flags at all (audit R20 V60-20).
    a.emit(0xF7, 0x60 | 7)
    # store R0..R7 to scratch so mem path (and the captured PSW in R7) is checked
    for i in range(8):
        a.st_abs(i, 0x8000 + i * 4)
    a.halt()
    return bytes(a.b)

def run_ref(img):
    m = Mem(1 << 18)
    m.b[:len(img)] = img
    cpu = V60(m, 0)
    for _ in range(100000):
        if cpu.halted: break
        cpu.step()
    return cpu, m

def main():
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    out = sys.argv[2] if len(sys.argv) > 2 else f"/tmp/v60diff_{seed}"
    img = gen(seed)
    cpu, m = run_ref(img)
    # program image as $readmemh (16-bit words, little-endian)
    with open(out + ".hex", "w") as f:
        words = len(img) // 2 + 1
        padded = img + b"\x00" * (words * 2 - len(img))
        for i in range(words):
            f.write("%04x\n" % (padded[2*i] | (padded[2*i+1] << 8)))
    with open(out + ".expected", "w") as f:
        for i in range(8):
            f.write("R%d=%08x\n" % (i, cpu.r[i]))
        for i in range(8):
            f.write("M%d=%08x\n" % (i, m.r(0x8000 + i * 4, 2)))
    print(f"seed {seed}: {len(img)} bytes, HALT={cpu.halted}, "
          f"R0..R3={cpu.r[0]:08x} {cpu.r[1]:08x} {cpu.r[2]:08x} {cpu.r[3]:08x}")

if __name__ == "__main__":
    main()
