#!/bin/sh
# Compare lookup_Gwin()'s generated code across three placements of a compiler
# barrier, on a target whose instruction set has no conditional move.
#
# Needs clang (tested with Debian clang 19.1.7) and a BearSSL checkout:
#   git clone https://www.bearssl.org/git/BearSSL
#   ./check.sh BearSSL
set -e

SRC=${1:-BearSSL}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$SRC/src/ec/ec_p256_m15.c" ]; then
	echo "usage: $0 /path/to/BearSSL" >&2
	exit 2
fi
if ! command -v clang > /dev/null 2>&1; then
	echo "clang not found" >&2
	exit 2
fi

TARGET="--target=thumbv6m-none-eabi -mcpu=cortex-m0"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stubs/src/ec"

# BearSSL's inner.h wants string.h and limits.h; clang supplies limits.h itself.
cat > "$WORK/stubs/string.h" <<'EOF'
#ifndef CHECK_STRING_H
#define CHECK_STRING_H
#include <stddef.h>
void *memcpy(void *, const void *, size_t);
void *memmove(void *, const void *, size_t);
void *memset(void *, int, size_t);
int memcmp(const void *, const void *, size_t);
size_t strlen(const char *);
#endif
EOF

# Each variant is the stock translation unit plus one barrier, applied as a
# patch so the change is reviewable. lookup_Gwin() is static, so a non-static
# wrapper keeps it out of line and gives it a symbol of its own; the table and
# the code are otherwise untouched.
for v in stock mask boolean; do
	mkdir -p "$WORK/$v/src/ec"
	cp "$SRC/src/ec/ec_p256_m15.c" "$WORK/$v/src/ec/ec_p256_m15.c"
	case $v in
	mask)    patch -s -p1 -d "$WORK/$v" < "$HERE/barrier-on-mask.patch" ;;
	boolean) patch -s -p1 -d "$WORK/$v" < "$HERE/barrier-on-boolean.patch" ;;
	esac
	printf '\nvoid trace_lookup(p256_jacobian *T, uint32_t idx) { lookup_Gwin(T, idx); }\n' \
		>> "$WORK/$v/src/ec/ec_p256_m15.c"
done

printf '%-34s %6s %8s %6s\n' 'barrier placement' 'lines' 'branches' 'loads'
stock_branches=0
boolean_branches=0
for v in stock mask boolean; do
	clang $TARGET -O2 -I"$WORK/stubs" -I"$SRC/src" -I"$SRC/inc" \
	      -S -o "$WORK/$v.s" "$WORK/$v/src/ec/ec_p256_m15.c"
	# Isolate the function, from its label to its .size directive.
	awk '/^lookup_Gwin:/{f=1} f{print} f&&/\.size[ \t]+lookup_Gwin/{exit}' \
	    "$WORK/$v.s" > "$WORK/$v.fn.s"
	if [ ! -s "$WORK/$v.fn.s" ]; then
		echo "lookup_Gwin not found in $v's assembly; it may have been inlined" >&2
		exit 1
	fi
	lines=$(wc -l < "$WORK/$v.fn.s" | tr -d ' ')
	branches=$(grep -cE '^[[:space:]]+b(eq|ne|cs|cc|mi|pl|vs|vc|hi|ls|ge|lt|gt|le)([[:space:]]|$)' "$WORK/$v.fn.s" || true)
	loads=$(grep -cE '^[[:space:]]+ldr' "$WORK/$v.fn.s" || true)
	case $v in
	stock)   label='stock'; stock_branches=$branches ;;
	mask)    label='on the mask, after negation' ;;
	boolean) label='on the boolean, before negation'; boolean_branches=$branches ;;
	esac
	printf '%-34s %6s %8s %6s\n' "$label" "$lines" "$branches" "$loads"
	cp "$WORK/$v.fn.s" "./lookup_Gwin.$v.s"
done

echo
echo "Wrote lookup_Gwin.stock.s, lookup_Gwin.mask.s and lookup_Gwin.boolean.s here."
if [ "$stock_branches" -le 2 ]; then
	echo "This compiler and target already keep the lookup branch-free, so there is"
	echo "nothing to see. The finding needs an instruction set without a conditional"
	echo "move: Cortex-M0, M0+, M23, or RISC-V without Zicond."
	exit 0
fi
echo "In lookup_Gwin.stock.s the row's load sits on the equal path of a compare"
echo "against the secret index, so fourteen of the fifteen rows are never read."
if [ "$boolean_branches" -le 2 ]; then
	echo "With the barrier on the boolean, the only conditional branches left are the"
	echo "two loop back-edges on the public counters k and u."
else
	echo "The barrier on the boolean left $boolean_branches conditional branches on this"
	echo "compiler, which is more than the two loop back-edges expected."
fi
