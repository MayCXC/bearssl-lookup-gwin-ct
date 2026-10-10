// BearSSL's constant-time window lookup, reproduced to trace its memory accesses.
// Source: BearSSL src/ec/ec_p256_m15.c, lookup_Gwin() at 7bea48e, and the EQ() primitive from src/inner.h:
// https://www.bearssl.org/gitweb/?p=BearSSL;a=blob_plain;f=src/ec/ec_p256_m15.c;hb=HEAD
// The table is 15 rows of 20 words, as there; the values are stand-ins, since only the access pattern matters.
#include <stdint.h>

static inline uint32_t NOT(uint32_t ctl) { return ctl ^ 1; }
static inline uint32_t EQ(uint32_t x, uint32_t y)
{
	uint32_t q;

	q = x ^ y;
	return NOT((q | -q) >> 31);
}

static const uint32_t Gwin[15][20] = {
#define ROW(k) { (k)*100+0, (k)*100+1, (k)*100+2, (k)*100+3, (k)*100+4, (k)*100+5, (k)*100+6, (k)*100+7, \
                 (k)*100+8, (k)*100+9, (k)*100+10, (k)*100+11, (k)*100+12, (k)*100+13, (k)*100+14, \
                 (k)*100+15, (k)*100+16, (k)*100+17, (k)*100+18, (k)*100+19 }
	ROW(0), ROW(1), ROW(2), ROW(3), ROW(4), ROW(5), ROW(6), ROW(7),
	ROW(8), ROW(9), ROW(10), ROW(11), ROW(12), ROW(13), ROW(14),
#undef ROW
};

void lookup_stock(uint32_t *xy, uint32_t idx)
{
	uint32_t k;
	uint32_t u;

	for (u = 0; u < 20; u ++) {
		xy[u] = 0;
	}
	for (k = 0; k < 15; k ++) {
		uint32_t m;

		m = -EQ(idx, k + 1);
		for (u = 0; u < 20; u ++) {
			xy[u] |= m & Gwin[k][u];
		}
	}
}

void lookup_barrier(uint32_t *xy, uint32_t idx)
{
	uint32_t k;
	uint32_t u;

	for (u = 0; u < 20; u ++) {
		xy[u] = 0;
	}
	for (k = 0; k < 15; k ++) {
		uint32_t m;

		m = -EQ(idx, k + 1);
		__asm__("" : "+r"(m));
		for (u = 0; u < 20; u ++) {
			xy[u] |= m & Gwin[k][u];
		}
	}
}
