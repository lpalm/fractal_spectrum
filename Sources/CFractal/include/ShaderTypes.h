// Structs shared between Swift/C host code and Metal kernels; layouts must match on both sides.
#ifndef FS_SHADER_TYPES_H
#define FS_SHADER_TYPES_H

#ifdef __METAL_VERSION__
typedef float2 fs_float2;
typedef float4 fs_float4;
typedef uint2 fs_uint2;
typedef uint fs_uint;
#else
#include <simd/simd.h>
typedef simd_float2 fs_float2;
typedef simd_float4 fs_float4;
typedef simd_uint2 fs_uint2;
typedef unsigned int fs_uint;
#endif

#define FS_MAX_BLA_LEVELS 32
#define FS_ZERO_EXP (-(1 << 24))   // exponent used for exact zeros in extended-range values
#define FS_INTERIOR 0xFFFFFFFFu

// Formula identifiers (function constant FORMULA).
#define FS_FORMULA_MANDEL 0      // z^p + c
#define FS_FORMULA_TRICORN 1     // conj(z)^2 + c
#define FS_FORMULA_SHIP 2        // (|x| + i|y|)^2 + c
#define FS_FORMULA_CELTIC 3      // |Re(z^2)| + i Im(z^2) + c

// Per-dispatch parameters of the escape-time kernels.
typedef struct {
    fs_uint2 size;          // full target size in samples
    fs_uint2 origin;        // tile origin in samples
    fs_uint2 bufOrigin;     // sample stored at index 0 of the G-buffer
    fs_uint bufStride;      // G-buffer row length
    fs_uint pad0;
    fs_uint2 workSize;      // rectangle of samples processed by this dispatch
    fs_float2 offsetM;      // mantissa of (view center - reference start); direct kernel: view center
    fs_float2 stepX;        // mantissa of the complex delta per +1 sample in x
    fs_float2 stepY;        // mantissa of the complex delta per +1 sample in y
    fs_float2 jitter;       // sub-sample offset in samples
    fs_float2 juliaC;       // Julia parameter for the direct kernel
    int offsetE;            // exponent of offsetM
    int stepE;              // exponent of stepX/stepY
    fs_uint maxIter;
    fs_uint refLen;         // number of reference points Z_0 ... Z_{refLen-1}
    fs_uint blaLevels;
    float bailout2;         // squared escape radius
    float log2Bailout2;
    float invLog2Power;
    float log2Step;         // log2 of the full sample spacing (for distance estimates)
    fs_uint statsSlot;
    fs_uint blaOffset[FS_MAX_BLA_LEVELS];
    fs_uint blaCount[FS_MAX_BLA_LEVELS];
    // Julia sets: second reference (orbit of the critical point 0) that pixels rebase onto.
    fs_uint refLen2;
    fs_uint blaLevels2;
    fs_uint pad2;
    fs_uint pad3;
    fs_uint blaOffset2[FS_MAX_BLA_LEVELS];
    fs_uint blaCount2[FS_MAX_BLA_LEVELS];
} FSIterParams;

// Reference orbit point in extended range: value = m * 2^e.
typedef struct {
    fs_float2 m;
    int e;
    int pad;
} FSRefExt;

// Bilinear approximation: delta' = A delta + B dc, stored as row-major 2x2 mantissas with shared exponents.
typedef struct {
    fs_float4 A;
    fs_float4 B;
    int Ae;
    int Be;
    int pad0;
    int pad1;
} FSBLAEntry;

typedef struct {
    fs_uint count;          // entries to produce
    fs_uint srcOffset;      // first source entry (merge) or first reference index (level 0)
    fs_uint dstOffset;
    fs_uint srcCount;
    float log2Eps;
    float log2C;            // log2 of max |dc| over the image; very negative for Julia sets
    float pad0;
    float pad1;
} FSBLABuildParams;

// Escape statistics accumulated by the iteration kernels.
typedef struct {
    fs_uint minIter;        // lowest escaped iteration
    fs_uint maxIter;        // highest escaped iteration
    fs_uint escaped;
    fs_uint lateEscaped;    // escaped in the upper half of the iteration limit
    fs_uint unresolved;     // reached the limit without escaping or a detected cycle
    fs_uint interior;       // attracting cycle detected
    float iterations;       // sum of iteration counts (including iterations skipped by BLA)
    fs_uint pad1;
} FSStats;

// Parameters of the colouring kernel.
typedef struct {
    fs_uint2 outSize;
    fs_uint2 gSize;         // primary G-buffer size
    fs_uint2 fbSize;        // logical size of the fallback colour image
    fs_uint2 tileGrid;      // primary tiles per axis
    fs_uint tileSize;
    fs_uint useFallback;
    float density;          // palette cycles per unit of mapped iteration
    float offset;           // palette phase
    int mapping;            // 0 linear, 1 sqrt, 2 log
    float iterLo;           // smoothed lowest iteration of the view
    float iterSpan;         // smoothed span of escaped iterations
    float lightAzimuth;
    float lightElevation;
    float lightStrength;
    float edgeStrength;     // distance-estimate boundary darkening
    float glow;
    float paletteRow;       // palette texture row (A)
    float paletteRowB;      // palette texture row (B) for cross-fades
    float paletteMix;
    float paletteCount;
    fs_float4 interior;     // interior colour (linear)
    fs_uint accumulate;     // 0: overwrite accumulator, 1: add
    fs_uint sampleIndex;
    float time;
    float pad0;
} FSColorParams;

// Display pass: out pixel q (centred) samples the accumulator at A q + b (centred), divided by its sample count.
typedef struct {
    fs_uint2 size;          // output size
    fs_uint2 srcSize;       // accumulator size
    fs_float4 A;            // row-major 2x2
    fs_float2 b;
    fs_uint identity;       // 1: straight copy
    float ditherAmp;
    float exposure;
    float vignette;
    fs_uint hdr;            // 1: write extended-range linear Display P3 (EDR)
    float headroom;         // EDR headroom of the display (1 = SDR)
    fs_float4 background;   // linear colour outside the source image
} FSPresentParams;

#endif
