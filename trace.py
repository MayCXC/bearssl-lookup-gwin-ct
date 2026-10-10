"""Trace the data addresses and instruction counts of a compiled Thumb function under Unicorn.

Runs lookup_stock / lookup_barrier for every secret window index 0..15 and reports, per index, the set of
table rows read and the instruction count. A constant-time lookup reads every row for every index.

Usage: python trace.py <elf> <symbol> [<symbol> ...]
"""
import subprocess
import sys
from unicorn import Uc, UC_ARCH_ARM, UC_MODE_THUMB, UC_HOOK_MEM_READ, UC_HOOK_CODE
from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_R1, UC_ARM_REG_SP, UC_ARM_REG_LR, UC_ARM_REG_PC

CODE = 0x0  # the linker script places .text at 0 and the literal pools hold those addresses
STACK = 0x200000
OUT = 0x300000
STOP = 0x400000  # LR points here; execution stops when it is reached


def symbols(elf):
    out = subprocess.run(["llvm-nm-19", "-S", "--defined-only", elf],
                         capture_output=True, text=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 4:
            addr, size, _kind, name = parts
            table[name] = (int(addr, 16), int(size, 16))
        elif len(parts) == 3:
            addr, _kind, name = parts
            table[name] = (int(addr, 16), 0)
    return table


def load(elf):
    binf = elf + ".bin"
    subprocess.run(["llvm-objcopy-19", "-O", "binary", elf, binf], check=True)
    with open(binf, "rb") as f:
        return f.read()


def run(code, entry, idx, gwin_lo, gwin_hi):
    uc = Uc(UC_ARCH_ARM, UC_MODE_THUMB)
    uc.mem_map(CODE, 0x100000)
    uc.mem_map(STACK, 0x10000)
    uc.mem_map(OUT, 0x1000)
    uc.mem_map(STOP, 0x1000)
    uc.mem_write(CODE, code)
    uc.reg_write(UC_ARM_REG_SP, STACK + 0x8000)
    uc.reg_write(UC_ARM_REG_R0, OUT)
    uc.reg_write(UC_ARM_REG_R1, idx)
    uc.reg_write(UC_ARM_REG_LR, STOP | 1)

    rows = set()
    reads = []
    count = [0]

    def on_read(_uc, _access, address, size, _value, _user):
        reads.append((address, size))
        if gwin_lo <= address < gwin_hi:
            rows.add((address - gwin_lo) // 80)

    def on_code(*_a):
        count[0] += 1

    uc.hook_add(UC_HOOK_MEM_READ, on_read)
    uc.hook_add(UC_HOOK_CODE, on_code)
    uc.emu_start(CODE + entry | 1, STOP, count=2_000_000)
    out = list(int.from_bytes(uc.mem_read(OUT + 4 * i, 4), "little") for i in range(20))
    return rows, count[0], len(reads), out


def main():
    elf = sys.argv[1]
    syms = symbols(elf)
    code = load(elf)
    gwin_addr, gwin_size = syms["Gwin"]
    gwin_lo = CODE + gwin_addr
    gwin_hi = gwin_lo + (gwin_size if gwin_size else 15 * 80)
    print(f"Gwin at {gwin_lo:#x}..{gwin_hi:#x} ({gwin_hi - gwin_lo} bytes)")
    for name in sys.argv[2:]:
        addr, _ = syms[name]
        print(f"\n== {name}")
        base_rows = None
        for idx in range(16):
            rows, insns, nreads, out = run(code, addr, idx, gwin_lo, gwin_hi)
            tag = "" if base_rows is None or rows == base_rows else "  <-- differs"
            if idx == 1:
                base_rows = rows
            # ec_p256_m15.c's lookup splits each 32-bit table word into two 16-bit limbs of T->x;
            # the synthetic lookup.c writes the word itself. Accept whichever the symbol's file uses.
            row = gwin_addr + 80 * (idx - 1)
            word = int.from_bytes(code[row:row + 4], "little") if 1 <= idx <= 15 else 0
            split = (word & 0xFFFF, word >> 16)
            ok = "ok" if out[0] == word or (out[0], out[1]) == split else \
                f"WRONG (got {out[0]},{out[1]}, want {word} or {split})"
            print(f"  idx {idx:2d}: rows read {sorted(rows) if len(rows) <= 15 else 'all 15'}"
                  f"  insns {insns:6d}  reads {nreads:5d}  result {ok}{tag}")


main()
