# BearSSL's P-256 window lookup compiles to a secret-indexed table read

An audit finding against [BearSSL](https://www.bearssl.org/) at `7bea48e`
(2026-04-06), unmodified sources, with Debian clang 19.1.7 at `-O2` for
`--target=thumbv6m-none-eabi -mcpu=cortex-m0`.

`lookup_Gwin()` in `src/ec/ec_p256_m15.c` selects one of fifteen precomputed
multiples of the generator using four secret bits of the multiplier. Its comment
says "This is constant-time", and it is written to read all fifteen rows and
mask fourteen of them away:

```c
m = -EQ(idx, k + 1);
for (u = 0; u < 20; u ++) {
	xy[u] |= m & Gwin[k][u];
}
```

clang recognises the mask and compiles the masked load into a compare and a
branch around it. In the generated code the row's load sits only on the equal
path:

```asm
	cmp	r2, r4		@ k + 1 against the secret index
	beq	.LBB7_6
	mov	r5, r0		@ mask was zero: use zero, and do not load
	b	.LBB7_7
.LBB7_6:
	ldr	r5, [r1, #80]	@ the table read, only when k + 1 == idx
.LBB7_7:
	orrs	r1, r5
```

So fourteen rows are not read at all, and which single row is read is the
secret. This is both of the things a constant-time lookup exists to prevent: a
conditional jump on secret data, and a memory access whose address depends on
it.

## Reproducing

```sh
git clone https://www.bearssl.org/git/BearSSL
./check.sh BearSSL
```

`check.sh` needs only clang. It compiles `lookup_Gwin()` three times, stock and
with a barrier in each of two places, and reports the function's own assembly
lines, conditional branches and loads. It writes the three listings beside
itself so the gated load can be read directly.

```
barrier placement                   lines branches  loads
stock                                 294       12     62
on the mask, after negation           235        3     55
on the boolean, before negation       228        2     53
```

`trace.py` is a second, independent instrument: it runs the real function under
[Unicorn](https://www.unicorn-engine.org/) and records every data address read,
for each of the sixteen possible window values. The data-address trace names the
secret directly, and the instruction count separately separates a zero window
from a nonzero one (2867 against 2871). Every result is correct, so the function
is functionally right and leaking.

```sh
clang --target=thumbv6m-none-eabi -mcpu=cortex-m0 -O2 -ffreestanding -fno-pic -nostdlib \
      -isystem stubs -IBearSSL/src -IBearSSL/inc \
      -fuse-ld=/usr/bin/ld.lld-19 -Wl,-T,link.ld \
      -o real.elf real.c libc-stubs.c BearSSL/src/codec/ccopy.c
python trace.py real.elf trace_lookup
```

It needs `unicorn`, `llvm-nm-19` and `llvm-objcopy-19`, and loads the image at
address 0 because the linker script places `.text` there and the literal pools
hold those addresses. `lookup.c` is a standalone version of the same construct,
BearSSL's `EQ` plus the lookup loop over a stand-in table, for tracing without
the rest of the library.

## Where the barrier goes

A barrier on the mask makes every index read all fifteen rows, which removes the
secret-dependent memory access. clang still compiles `EQ` itself into a compare
and a branch selecting 0 or `~0`, so a secret-dependent branch survives. Both of
its paths are the same length, which is why the instruction count is already
flat across the sixteen values: this residual branch is visible in the assembly
and invisible to the trace.

A barrier on the boolean, before the negation, removes that too. clang then
computes the comparison with `rsbs`/`adcs`, and the only conditional branches
left in the function are the two loop back-edges on the public counters `k` and
`u`. Every result stays correct, and it is also the smallest of the three: 228
lines against 294, and 2296 instructions against 2871, because the branches cost
more than the masked loads they replace.

`opaque-eq.patch` is that fix in one place. `EQ` is a `static inline` in
`src/inner.h` shared by the whole library, so a guarded `OPAQUE()` beside its
sibling primitives `NOT` and `MUX`, with `EQ` returning through it, fixes
`lookup_Gwin()` in both `ec_p256_m15.c` and `ec_p256_m31.c` with neither file
touched. The `__GNUC__` guard with a plain fallback follows
`src/int/i15_montmul.c`, which is the project's own pattern for
compiler-specific code.

With the patch applied and the EC sources unmodified, `lookup_Gwin()` compiles
to the 228-line form, and `build/testcrypto all` produces output byte-identical
to the unpatched run across its 99 tests, both exiting 0.

Two things about that placement are the library author's to weigh. It reaches
every other caller of `EQ`, which is most of the constant-time code, and the
narrower alternative is a barrier at the lookup alone, which
`barrier-on-boolean.patch` shows.

## The library's own primitive is not sufficient

`br_ccopy` (`src/inner.h`, implemented in `src/codec/ccopy.c`) is BearSSL's
constant-time conditional copy, built on `MUX`, and `lookup_Gwin`'s job is
exactly what it does. Written with it the masking loop becomes one line:

```c
for (k = 0; k < 15; k ++) {
	CCOPY(EQ(idx, k + 1), xy, Gwin[k], sizeof xy);
}
```

Measured, that compiles to 302 lines with **zero** conditional branches, because
`br_ccopy` is an out-of-line call and the control word never becomes visible as
a boolean inside the lookup. It needs no barrier and no compiler-specific
syntax.

It does not hold, though. Compiled with `br_ccopy`'s body visible in the same
translation unit, which is what link-time optimisation achieves across units,
clang inlines it and the rewrite returns at 22 conditional branches, worse than
the 12 of stock. So the primitive protects the lookup only for as long as it is
not inlined, and that is not a property the source can state.

The barrier in `EQ` covers this path as well. With `opaque-eq.patch` applied and
`br_ccopy` inlined, the same translation unit compiles to 301 lines with two
conditional branches, the loop back-edges. Every control word in the library
originates in `EQ`, `NEQ` or a sibling, so a barrier there is opaque wherever
that word flows afterwards, inlining included.

## Scope

- The same shape appears on `thumbv6m` Cortex-M0 and M0+, `thumbv8m.base`
  Cortex-M23, and on RV32 and RV64 without Zicond. Cortex-M3, x86-64 and AArch64
  are clean, and RISC-V with Zicond is clean (`czero.eqz`/`czero.nez`).
- `ec_p256_m31.c`'s `lookup_Gwin()` has the same construct.
  `ec_p256_m15.c` is the implementation `br_ec_get_default()` returns under
  `BR_LOMUL`, which `src/config.h` names for exactly these cores.
- clang `-O1`, `-O3`, `-Os` and `-Oz` leave one site or none, so this is a `-O2`
  shape. GCC 14.2 for Cortex-M0 keeps the lookup branch-free at `-O2` and `-Os`.
- The same rewrite reaches `br_ccopy`: linking `src/ec/ec_prime_i31.c` with
  `src/codec/ccopy.c` through LLVM's LTO pipeline inlines it into `point_mul`'s
  window lookup, and on RV32 the inlined loop selects the source pointer with
  `beq` and loads through it, so only one of the two bytes the copy is specified
  to read is read. x86-64 selects the address with `cmov` and copies through SSE
  bit-selects; AArch64 uses `bif`/`bsl`.

## Context

BearSSL's own documentation makes the general point that inspecting the
generated assembly tells you only what one compiler version with one set of
switches did, and carries no barriers against this. So this is that documented
hazard arriving in the library's default code path for the cores its own
configuration names, rather than a surprise about its design.

Found while reading Frank Denis's [Branches in branch-free
code](https://00f.net/2026/10/09/llvm-compiles-branch-free-code-into-branches-on-risc-v/),
which shows the same rewrite on RISC-V, Cortex-M0 and 32-bit PowerPC, and closes
by recommending Thomas Pornin's [constant-time
crypto](https://www.bearssl.org/constanttime.html) pages. Those pages led to the
library, and the library had the defect the post describes.
