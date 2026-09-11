#!/usr/bin/env python3
"""
Independent NEC V60 reference model (DESIGN.md §11.2).

A second, from-scratch implementation of the V60 integer core in Python,
written to the same NEC/MAME behavioral contract as the RTL but sharing no
code with it. Its purpose is differential equivalence checking: the RTL and
this model execute identical instruction streams from identical memory and
their architectural state is compared lock-step. Divergence = a bug in one
of two independent implementations.

Scope matches the RTL's tested subset: MOV/MOVEA/MOVS/MOVZ, ADD/SUB/CMP/
AND/OR/XOR/NOT/NEG (B/H/W), MUL/MULU/DIV/DIVU, SHL/SHA/ROT, Bcc8/16,
JMP/JSR/BSR/RET, PUSH/POP, TEST, NOP/HALT, and the F1/F2 operand formats
with the full addressing-mode set. Emits the 24-byte trace records that
compare.py consumes.

This is an emulator, not silicon-accurate for cycle timing (neither is the
comparison — only architectural state is checked, per §11.2).
"""
import struct

M32 = 0xFFFFFFFF

def sx(v, bits):
    s = 1 << (bits - 1)
    return (v & (s - 1)) - (v & s)

def dimext(v, d):
    return [v & 0xFF, v & 0xFFFF, v & M32][d]

def dimsgn(v, d):
    return [(v >> 7) & 1, (v >> 15) & 1, (v >> 31) & 1][d]

def dimbits(d):
    return [8, 16, 32][d]

class Mem:
    """Little-endian byte-addressable memory."""
    def __init__(self, size=1 << 20):
        self.b = bytearray(size)
        self.writes = []  # (addr, size, value) last-per-instruction
    def r(self, a, d):
        n = [1, 2, 4][d]
        return int.from_bytes(self.b[a:a + n], "little")
    def w(self, a, d, v):
        n = [1, 2, 4][d]
        self.b[a:a + n] = (v & ((1 << (8 * n)) - 1)).to_bytes(n, "little")
        self.writes.append((a, d, v))

class V60:
    def __init__(self, mem, start_pc=0):
        self.r = [0] * 32
        self.pc = start_pc
        self.z = self.s = self.ov = self.cy = 0
        self.psw_hi = 0x10000000
        self.mem = mem
        self.halted = False

    # ---- fetch helpers ----
    def _b(self, off): return self.mem.b[self.pc + off]
    def _w(self, off): return int.from_bytes(self.mem.b[self.pc + off:self.pc + off + 2], "little")
    def _d(self, off): return int.from_bytes(self.mem.b[self.pc + off:self.pc + off + 4], "little")

    # ---- addressing-mode decode ----
    # returns (kind, value, length) where kind in {'reg','mem','imm'}
    def decode_am(self, off, d, want_addr):
        modval = self._b(off)
        top = modval >> 5
        reg = modval & 0x1F
        modm = self._cur_modm
        if not modm:
            if top in (0, 1, 2):   # displacement 8/16/32
                dl = [1, 2, 4][top]
                disp = sx([self._b(off+1), self._w(off+1), self._d(off+1)][top], dl*8)
                addr = (self.r[reg] + disp) & M32
                return self._mem_or_addr(addr, d, want_addr, 1 + dl)
            if top == 3:           # register indirect
                return self._mem_or_addr(self.r[reg], d, want_addr, 1)
            if top in (4, 5, 6):   # displacement indirect (deferred)
                dl = [1, 2, 4][top-4]
                disp = sx([self._b(off+1), self._w(off+1), self._d(off+1)][top-4], dl*8)
                ptr = self.mem.r((self.r[reg] + disp) & M32, 2)
                return self._mem_or_addr(ptr, d, want_addr, 1 + dl)
            # top == 7: group 7
            if reg < 0x10:         # immediate quick
                return ('imm', reg & 0xF, 1)
            if reg in (0x10, 0x11, 0x12):  # PC displacement
                dl = [1, 2, 4][reg-0x10]
                disp = sx([self._b(off+1), self._w(off+1), self._d(off+1)][reg-0x10], dl*8)
                return self._mem_or_addr((self.pc + disp) & M32, d, want_addr, 1 + dl)
            if reg == 0x13:        # direct address
                return self._mem_or_addr(self._d(off+1), d, want_addr, 5)
            if reg == 0x14:        # immediate full
                imm = [self._b(off+1), self._w(off+1), self._d(off+1)][d]
                return ('imm', imm, 1 + [1, 2, 4][d])
            if reg in (0x18, 0x19, 0x1a):  # PC disp indirect
                dl = [1, 2, 4][reg-0x18]
                disp = sx([self._b(off+1), self._w(off+1), self._d(off+1)][reg-0x18], dl*8)
                ptr = self.mem.r((self.pc + disp) & M32, 2)
                return self._mem_or_addr(ptr, d, want_addr, 1 + dl)
            if reg == 0x1b:        # direct address deferred
                ptr = self.mem.r(self._d(off+1), 2)
                return self._mem_or_addr(ptr, d, want_addr, 5)
            raise NotImplementedError(f"g7 mode {reg:#x}")
        else:
            if top == 3:           # register direct
                if want_addr:
                    return ('reg', reg, 1)
                return ('imm', dimext(self.r[reg], d), 1)
            if top == 4:           # autoincrement
                a = self.r[reg]; self.r[reg] = (a + [1,2,4][d]) & M32
                return self._mem_or_addr(a, d, want_addr, 1)
            if top == 5:           # autodecrement
                self.r[reg] = (self.r[reg] - [1,2,4][d]) & M32
                return self._mem_or_addr(self.r[reg], d, want_addr, 1)
            if top in (0, 1, 2):   # double displacement
                dl = [1, 2, 4][top]
                d1 = sx([self._b(off+1), self._w(off+1), self._d(off+1)][top], dl*8)
                d2 = sx([self._b(off+1+dl), self._w(off+1+dl), self._d(off+1+dl)][top], dl*8)
                ptr = self.mem.r((self.r[reg] + d1) & M32, 2)
                return self._mem_or_addr((ptr + d2) & M32, d, want_addr, 1 + 2*dl)
            raise NotImplementedError(f"modm1 top {top}")

    def _mem_or_addr(self, addr, d, want_addr, ln):
        if want_addr:
            return ('mem', addr, ln)
        return ('imm', dimext(self.mem.r(addr, d), d), ln)

    def load(self, op):
        return op[1] if op[0] == 'imm' else (self.r[op[1]] if op[0] == 'reg' else self.mem.r(op[1], self._d2))
    def store(self, op, v, d):
        if op[0] == 'reg':
            self.r[op[1]] = (self.r[op[1]] & ~((1 << dimbits(d)) - 1) | dimext(v, d)) & M32 if d < 2 else v & M32
        elif op[0] == 'mem':
            self.mem.w(op[1], d, v)

    def setzs(self, v, d):
        self.z = 1 if dimext(v, d) == 0 else 0
        self.s = dimsgn(v, d)

    def psw(self):
        return (self.psw_hi & ~0xF) | (self.cy << 3) | (self.ov << 2) | (self.s << 1) | self.z

    # ---- condition codes ----
    def cond(self, cc):
        z,s,ov,cy = self.z,self.s,self.ov,self.cy
        return [ov, 1-ov, cy, 1-cy, z, 1-z, cy|z, 1-(cy|z),
                s, 1-s, 1, 0, s^ov, 1-(s^ov), (s^ov)|z, 1-((s^ov)|z)][cc]

    def step(self):
        op = self._b(0)
        self._cur_modm = 0
        # single-byte
        if op == 0x00:
            self.halted = True; return
        if op == 0xCD:
            self.pc += 1; return
        # Bcc8 / Bcc16
        if 0x60 <= op <= 0x6F:
            self.pc += sx(self._b(1), 8) if self.cond(op & 0xF) else 2; return
        if 0x70 <= op <= 0x7F:
            self.pc += sx(self._w(1), 16) if self.cond(op & 0xF) else 3; return
        # F1/F2 arithmetic/move family
        if op in F12:
            self._exec_f12(op); return
        # short-format
        if op in (0xD6, 0xD7):  # JMP
            self._cur_modm = op & 1
            k = self.decode_am(1, 2, True)
            self.pc = k[1] if k[0]=='mem' else self.r[k[1]]; return
        if op in (0xE8, 0xE9):  # JSR
            self._cur_modm = op & 1
            k = self.decode_am(1, 2, True); tgt = k[1] if k[0]=='mem' else self.r[k[1]]
            self.r[31] = (self.r[31]-4)&M32; self.mem.w(self.r[31],2,(self.pc+1+k[2])&M32)
            self.pc = tgt; return
        if op == 0x48:          # BSR disp16
            self.r[31]=(self.r[31]-4)&M32; self.mem.w(self.r[31],2,(self.pc+3)&M32)
            self.pc = (self.pc + sx(self._w(1),16))&M32; return
        if op in (0xE2, 0xE3):  # RET
            self._cur_modm = op & 1
            k = self.decode_am(1, 2, False); adj = self.load(k)
            self.pc = self.mem.r(self.r[31],2); self.r[31]=(self.r[31]+4+adj)&M32; return
        if op in (0xEE, 0xEF):  # PUSH
            self._cur_modm = op & 1
            self._d2 = 2; k = self.decode_am(1, 2, False); v = self.load(k)
            self.r[31]=(self.r[31]-4)&M32; self.mem.w(self.r[31],2,v)
            self.pc += 1 + k[2]; return
        if op in (0xE6, 0xE7):  # POP
            self._cur_modm = op & 1
            k = self.decode_am(1, 2, True); v = self.mem.r(self.r[31],2)
            self.store(k, v, 2); self.r[31]=(self.r[31]+4)&M32
            self.pc += 1 + k[2]; return
        if op in (0xF0,0xF1,0xF2,0xF3,0xF4,0xF5):  # TEST
            d = (op-0xF0)//2; self._cur_modm = op & 1; self._d2 = d
            k = self.decode_am(1, d, False); v = self.load(k)
            self.setzs(v, d); self.ov=0; self.cy=0
            self.pc += 1 + k[2]; return
        if op in (0xF6, 0xF7):  # GETPSW: write PSW to the operand
            self._cur_modm = op & 1
            k = self.decode_am(1, 2, True)
            self.store(k, self.psw(), 2)
            self.pc += 1 + k[2]; return
        raise NotImplementedError(f"opcode {op:#04x} @ {self.pc:#x}")

    def _exec_f12(self, op):
        d1 = F12[op].get('d1', 2); d2 = F12[op].get('d2', 2)
        iflags = self._b(1)
        # decode operands per F12DecodeOperands
        if iflags & 0x80:      # F1
            self._cur_modm = (iflags >> 6) & 1
            o1 = self.decode_am(2, d1, False); self._d2 = d1
            v1 = self.load(o1)
            self._cur_modm = (iflags >> 5) & 1
            o2 = self.decode_am(2 + o1[2], d2, True); self._d2 = d2
            ln = o1[2] + o2[2] + 2
        else:
            if iflags & 0x20:  # F2 D=1: op2 = reg, op1 = AM
                o2 = ('reg', iflags & 0x1F, 0)
                self._cur_modm = (iflags >> 6) & 1
                o1 = self.decode_am(2, d1, False); v1 = self.load(o1)
                ln = o1[2] + 2
            else:              # F2 D=0: op1 = reg, op2 = AM
                v1 = dimext(self.r[iflags & 0x1F], d1)
                o1 = ('imm', v1, 0)
                self._cur_modm = (iflags >> 6) & 1
                o2 = self.decode_am(2, d2, True)
                ln = o2[2] + 2
        self._d2 = d2
        b = self.load(o2) if o2[0] != 'mem' else self.mem.r(o2[1], d2)
        f = F12[op]['f']
        f(self, v1, b, o2, d2)
        # advance PC unless the op is a branch (none here)
        self.pc += ln

    def trace_rec(self, prev_reg):
        ri, rv = 0xFF, 0
        for i in range(32):
            if self.r[i] != prev_reg[i]:
                ri, rv = i, self.r[i]; break
        ma, mv = (self.mem.writes[-1][0], self.mem.writes[-1][2]) if self.mem.writes else (0, 0)
        return struct.pack("<IIBxxxIII", self.pc & M32, self.psw(), ri, rv & M32, ma & M32, mv & M32)


# ---- F1/F2 op implementations ----
def _mov(cpu, a, b, o2, d):  cpu.store(o2, a, d)
def _movsbh(cpu,a,b,o2,d):   cpu.store(o2, sx(a,8)&0xFFFF, 1)
def _movzbh(cpu,a,b,o2,d):   cpu.store(o2, a&0xFF, 1)
def _movsbw(cpu,a,b,o2,d):   cpu.store(o2, sx(a,8)&M32, 2)
def _movzbw(cpu,a,b,o2,d):   cpu.store(o2, a&0xFF, 2)
def _movshw(cpu,a,b,o2,d):   cpu.store(o2, sx(a,16)&M32, 2)
def _movzhw(cpu,a,b,o2,d):   cpu.store(o2, a&0xFFFF, 2)
def _add(cpu,a,b,o2,d):
    n=dimbits(d); r=(b+a)&M32; cpu.cy=1 if (dimext(b,d)+dimext(a,d))>>n else 0
    cpu.ov=1 if (~(dimsgn(b,d)^dimsgn(a,d)))&(dimsgn(b,d)^dimsgn(r,d)) else 0
    cpu.setzs(r,d); cpu.store(o2,r,d)
def _sub(cpu,a,b,o2,d):
    r=(b-a)&M32; cpu.cy=1 if dimext(b,d)<dimext(a,d) else 0
    cpu.ov=1 if (dimsgn(b,d)^dimsgn(a,d))&(dimsgn(b,d)^dimsgn(r,d)) else 0
    cpu.setzs(r,d); cpu.store(o2,r,d)
def _cmp(cpu,a,b,o2,d):
    r=(b-a)&M32; cpu.cy=1 if dimext(b,d)<dimext(a,d) else 0
    cpu.ov=1 if (dimsgn(b,d)^dimsgn(a,d))&(dimsgn(b,d)^dimsgn(r,d)) else 0
    cpu.setzs(r,d)
def _and(cpu,a,b,o2,d): r=b&a; cpu.setzs(r,d); cpu.ov=0; cpu.store(o2,r,d)
def _or(cpu,a,b,o2,d):  r=b|a; cpu.setzs(r,d); cpu.ov=0; cpu.store(o2,r,d)
def _xor(cpu,a,b,o2,d): r=b^a; cpu.setzs(r,d); cpu.ov=0; cpu.store(o2,r,d)
def _not(cpu,a,b,o2,d): r=(~a)&M32; cpu.setzs(r,d); cpu.ov=0; cpu.cy=0; cpu.store(o2,r,d)
def _neg(cpu,a,b,o2,d):
    r=(0-a)&M32; cpu.cy=1 if dimext(a,d)!=0 else 0
    cpu.ov=dimsgn(a,d)&dimsgn(r,d); cpu.setzs(r,d); cpu.store(o2,r,d)
def _mul(cpu,a,b,o2,d):
    # MAME opMUL: OV = (product >> width) != 0 on the SIGNED product's unsigned
    # bit pattern (byte/half shift the 32-bit value, word the 64-bit one).
    n=dimbits(d); prod=sx(b,n)*sx(a,n)
    mask=0xFFFFFFFF if n<32 else 0xFFFFFFFFFFFFFFFF
    cpu.ov=1 if ((prod & mask) >> n)!=0 else 0
    r=prod&M32; cpu.setzs(r,d); cpu.store(o2,r,d)
def _mulu(cpu,a,b,o2,d):
    n=dimbits(d); prod=dimext(b,d)*dimext(a,d)
    mask=0xFFFFFFFF if n<32 else 0xFFFFFFFFFFFFFFFF
    cpu.ov=1 if ((prod & mask) >> n)!=0 else 0
    r=prod&M32; cpu.setzs(r,d); cpu.store(o2,r,d)
def _div(cpu,a,b,o2,d):
    if dimext(a,d)==0: return
    n=dimbits(d)
    # signed min / -1 overflow (dest keeps the wrapped quotient, which equals it)
    cpu.ov=1 if (dimext(b,d)==(1<<(n-1)) and dimext(a,d)==((1<<n)-1)) else 0
    r=int(sx(b,n)/sx(a,n)) if sx(a,n) else 0
    cpu.setzs(r&M32,d); cpu.store(o2,r&M32,d)
def _divu(cpu,a,b,o2,d):
    if dimext(a,d)==0: return
    cpu.ov=0
    r=(dimext(b,d)//dimext(a,d))&M32; cpu.setzs(r,d); cpu.store(o2,r,d)
def _shl(cpu,a,b,o2,d):
    c=sx(a,8); v=dimext(b,d); r=(v<<c)&M32 if c>=0 else (v>>(-c)); cpu.setzs(r,d); cpu.store(o2,r,d)
def _movea(cpu,a,b,o2,d): cpu.store(o2, a, 2)

F12 = {
    0x09:{'f':_mov,'d1':0,'d2':0}, 0x1b:{'f':_mov,'d1':1,'d2':1}, 0x2d:{'f':_mov},
    0x0a:{'f':_movsbh,'d1':0,'d2':1}, 0x0b:{'f':_movzbh,'d1':0,'d2':1},
    0x0c:{'f':_movsbw,'d1':0}, 0x0d:{'f':_movzbw,'d1':0},
    0x1c:{'f':_movshw,'d1':1}, 0x1d:{'f':_movzhw,'d1':1},
    0x40:{'f':_movea,'d1':0}, 0x42:{'f':_movea,'d1':1}, 0x44:{'f':_movea},
    0x80:{'f':_add,'d1':0,'d2':0}, 0x82:{'f':_add,'d1':1,'d2':1}, 0x84:{'f':_add},
    0xa8:{'f':_sub,'d1':0,'d2':0}, 0xaa:{'f':_sub,'d1':1,'d2':1}, 0xac:{'f':_sub},
    0xb8:{'f':_cmp,'d1':0,'d2':0}, 0xba:{'f':_cmp,'d1':1,'d2':1}, 0xbc:{'f':_cmp},
    0xa0:{'f':_and,'d1':0,'d2':0}, 0xa2:{'f':_and,'d1':1,'d2':1}, 0xa4:{'f':_and},
    0x88:{'f':_or,'d1':0,'d2':0}, 0x8a:{'f':_or,'d1':1,'d2':1}, 0x8c:{'f':_or},
    0xb0:{'f':_xor,'d1':0,'d2':0}, 0xb2:{'f':_xor,'d1':1,'d2':1}, 0xb4:{'f':_xor},
    0x38:{'f':_not,'d1':0,'d2':0}, 0x3a:{'f':_not,'d1':1,'d2':1}, 0x3c:{'f':_not},
    0x39:{'f':_neg,'d1':0,'d2':0}, 0x3b:{'f':_neg,'d1':1,'d2':1}, 0x3d:{'f':_neg},
    0x81:{'f':_mul,'d1':0,'d2':0}, 0x83:{'f':_mul,'d1':1,'d2':1}, 0x85:{'f':_mul},
    0x91:{'f':_mulu,'d1':0,'d2':0},0x93:{'f':_mulu,'d1':1,'d2':1},0x95:{'f':_mulu},
    0xa1:{'f':_div,'d1':0,'d2':0}, 0xa3:{'f':_div,'d1':1,'d2':1}, 0xa5:{'f':_div},
    0xb1:{'f':_divu,'d1':0,'d2':0},0xb3:{'f':_divu,'d1':1,'d2':1},0xb5:{'f':_divu},
    0xa9:{'f':_shl,'d1':0,'d2':0}, 0xab:{'f':_shl,'d1':0,'d2':1}, 0xad:{'f':_shl,'d1':0},
}

if __name__ == "__main__":
    # self-test: assemble a tiny program and run it
    m = Mem()
    prog = bytes([0x2D,0x20,0xF4,0x78,0x56,0x34,0x12,   # MOVW #12345678,R0
                  0x2D,0x21,0xF4,0x11,0x11,0x11,0x11,   # MOVW #11111111,R1
                  0x84,0x61,0x60,                        # ADDW R0,R1
                  0x00])                                 # HALT
    m.b[:len(prog)] = prog
    cpu = V60(m, 0)
    for _ in range(100):
        if cpu.halted: break
        cpu.step()
    assert cpu.r[0] == 0x12345678, hex(cpu.r[0])
    assert cpu.r[1] == 0x23456789, hex(cpu.r[1])
    print("v60_ref self-test PASS: R0=%08x R1=%08x" % (cpu.r[0], cpu.r[1]))
