// Differential test for integer emulation: runs the same pseudo-random
// integer operations and prints one checksum per operation. Build it natively
// and for i386, run the i386 build in iSH, and diff the two outputs; a
// differing line names the operation the emulator gets wrong.
//
//   cc -O1 intfuzz.c -o intfuzz-host && ./intfuzz-host > host.txt
//   clang -target i386-linux-musl ... intfuzz.c -o intfuzz-i386
//   ish ./intfuzz-i386 > ish.txt && diff host.txt ish.txt
#include <stdint.h>
#include <stdio.h>

static uint64_t state = 0x9e3779b97f4a7c15ull;
static uint64_t next(void) {
    // xorshift64*
    state ^= state >> 12;
    state ^= state << 25;
    state ^= state >> 27;
    return state * 0x2545f4914f6cdd1dull;
}

// Mix of random values and edge cases.
static const uint64_t edges[] = {
    0, 1, 2, 3, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff,
    0x7fffffff, 0x80000000, 0xffffffff, 0x100000000ull, 0x7fffffffffffffffull,
    0x8000000000000000ull, 0xffffffffffffffffull, 11, 2147483648ull, 4294967296ull,
};
static uint64_t value(void) {
    uint64_t r = next();
    switch (r % 8) {
        case 0: return edges[(r >> 8) % (sizeof(edges) / sizeof(edges[0]))];
        case 1: return r >> (r % 64);           // varied magnitudes
        case 2: return (uint64_t) -(int64_t) (r >> (r % 64));
        default: return next();
    }
}

static uint64_t mix(uint64_t h, uint64_t v) {
    return (h ^ v) * 0x100000001b3ull + (h >> 29);
}

#define N 200000
#define OP(name, expr) do { \
    uint64_t h = 0; \
    state = 0x9e3779b97f4a7c15ull ^ (uint64_t) __LINE__; \
    for (int i = 0; i < N; i++) { \
        uint64_t a = value(), b = value(); \
        unsigned c = (unsigned) next(); \
        (void) a; (void) b; (void) c; \
        h = mix(h, (uint64_t) (expr)); \
    } \
    printf("%-12s %016llx\n", name, (unsigned long long) h); \
} while (0)

__attribute__((noinline)) static uint64_t shl64(uint64_t a, unsigned n) { return a << n; }
__attribute__((noinline)) static uint64_t shr64(uint64_t a, unsigned n) { return a >> n; }
__attribute__((noinline)) static int64_t sar64(int64_t a, unsigned n) { return a >> n; }

int main(void) {
    // 64-bit
    OP("add64", a + b);
    OP("sub64", a - b);
    OP("mul64", a * b);
    OP("udiv64", b ? a / b : 0);
    OP("umod64", b ? a % b : 0);
    OP("sdiv64", (b && !((int64_t) a == INT64_MIN && (int64_t) b == -1)) ? (uint64_t) ((int64_t) a / (int64_t) b) : 0);
    OP("shl64", shl64(a, c % 64));
    OP("shr64", shr64(a, c % 64));
    OP("sar64", (uint64_t) sar64((int64_t) a, c % 64));
    OP("shl64k32", a << 32);
    OP("shr64k33", a >> 33);
    OP("rotl64", (a << (c % 64)) | (a >> ((64 - c % 64) % 64)));
    OP("ltu64", a < b);
    OP("lts64", (int64_t) a < (int64_t) b);
    OP("eq64", a == b);
    OP("neg64", -a);
    OP("not64", ~a);
    OP("and64", a & b);
    OP("clz64", a ? __builtin_clzll(a) : 64);
    OP("ctz64", a ? __builtin_ctzll(a) : 64);
    OP("popcnt64", __builtin_popcountll(a));
    OP("fits32s", (int64_t) a == (int32_t) a);
    OP("fits32u", a == (uint32_t) a);
    OP("bswap64", __builtin_bswap64(a));
    // 32-bit
    OP("add32", (uint32_t) a + (uint32_t) b);
    OP("sub32", (uint32_t) a - (uint32_t) b);
    OP("mul32", (uint32_t) a * (uint32_t) b);
    OP("mulx32", (uint64_t) (uint32_t) a * (uint32_t) b);
    OP("smulx32", (uint64_t) ((int64_t) (int32_t) a * (int32_t) b));
    OP("udiv32", (uint32_t) b ? (uint32_t) a / (uint32_t) b : 0);
    OP("sdiv32", ((int32_t) b && !((int32_t) a == INT32_MIN && (int32_t) b == -1)) ? (uint32_t) ((int32_t) a / (int32_t) b) : 0);
    OP("shl32", (uint32_t) a << (c % 32));
    OP("sar32", (uint32_t) ((int32_t) a >> (c % 32)));
    OP("rotl32", ((uint32_t) a << (c % 32)) | ((uint32_t) a >> ((32 - c % 32) % 32)));
    OP("clz32", (uint32_t) a ? __builtin_clz((uint32_t) a) : 32);
    OP("popcnt32", __builtin_popcount((uint32_t) a));
    OP("ltu32", (uint32_t) a < (uint32_t) b);
    OP("lts32", (int32_t) a < (int32_t) b);
    // 16/8-bit
    OP("add16", (uint16_t) ((uint16_t) a + (uint16_t) b));
    OP("mul16", (uint16_t) ((uint16_t) a * (uint16_t) b));
    OP("sar16", (uint16_t) ((int16_t) a >> (c % 16)));
    OP("sext8", (uint64_t) (int64_t) (int8_t) a);
    OP("sext16", (uint64_t) (int64_t) (int16_t) a);
    return 0;
}
