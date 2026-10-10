/* Enough libc for the linker; the traced function calls only memset. */
#include <stddef.h>
void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }
int memcmp(const void *a, const void *b, size_t n) { const unsigned char *x = a, *y = b; for (; n--; x++, y++) if (*x != *y) return *x - *y; return 0; }

/* The ARM EABI aliases clang emits for aligned block moves. */
void *__aeabi_memcpy(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
void *__aeabi_memcpy4(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
void *__aeabi_memcpy8(void *d, const void *s, size_t n) { return memcpy(d, s, n); }
void *__aeabi_memset(void *d, size_t n, int c) { return memset(d, c, n); }
void *__aeabi_memset4(void *d, size_t n, int c) { return memset(d, c, n); }
void *__aeabi_memset8(void *d, size_t n, int c) { return memset(d, c, n); }
void *__aeabi_memclr(void *d, size_t n) { return memset(d, 0, n); }
void *__aeabi_memclr4(void *d, size_t n) { return memset(d, 0, n); }
void *__aeabi_memclr8(void *d, size_t n) { return memset(d, 0, n); }
