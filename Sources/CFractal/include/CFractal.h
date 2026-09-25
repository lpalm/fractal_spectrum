// High-precision arithmetic (MPFR) and reference-orbit computation for perturbation rendering.
#ifndef CFRACTAL_H
#define CFRACTAL_H

#include <stdint.h>
#include "ShaderTypes.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---- Arbitrary-precision real number ----
typedef struct FSHP FSHP;

FSHP *fs_hp_new(long prec);
FSHP *fs_hp_clone(const FSHP *src, long prec);
void fs_hp_free(FSHP *h);
long fs_hp_prec(const FSHP *h);
void fs_hp_set_prec(FSHP *h, long prec);            // keeps the value, rounded
int fs_hp_set_str(FSHP *h, const char *s);           // decimal string; returns 0 on success
void fs_hp_set(FSHP *h, const FSHP *src);
void fs_hp_set_d(FSHP *h, double d);
void fs_hp_add_2exp(FSHP *h, double m, long e);     // h += m * 2^e
double fs_hp_get_2exp(const FSHP *h, long *e);       // h = ret * 2^e, |ret| in [0.5, 1) or 0
double fs_hp_get_d(const FSHP *h);
double fs_hp_diff_2exp(const FSHP *a, const FSHP *b, long *e);   // a - b = ret * 2^e
void fs_hp_lerp(FSHP *out, const FSHP *a, const FSHP *b, double t);   // out = a + (b - a) t
char *fs_hp_to_str(const FSHP *h, int digits);       // caller frees with fs_free
void fs_free(void *p);

// ---- Reference orbit ----
typedef struct FSRefJob FSRefJob;

// formula: FS_FORMULA_*; power: exponent for the Mandelbrot family.
// Non-Julia: orbit of 0 under z -> f(z) + (cre + i cim).
// Julia: orbit of (zre + i zim) under z -> f(z) + (jre + i jim).
FSRefJob *fs_ref_new(int formula, int power, int julia,
                     const FSHP *cre, const FSHP *cim,
                     const FSHP *zre, const FSHP *zim,
                     const FSHP *jre, const FSHP *jim, long prec);
void fs_ref_free(FSRefJob *job);

// Continues the orbit until `target` points exist, the orbit escapes, or *cancel becomes non-zero.
// Writes points [count, newCount) into zf/zx; returns the new point count. *progress tracks the count.
long fs_ref_run(FSRefJob *job, long target, fs_float2 *zf, FSRefExt *zx, double bailout2,
                volatile const int *cancel, volatile long *progress);
long fs_ref_count(const FSRefJob *job);
int fs_ref_escaped(const FSRefJob *job);

// ---- Minibrot location (quadratic Mandelbrot) ----
long fs_find_period(const FSHP *cre, const FSHP *cim, double log2r, long maxPeriod);
long fs_find_nucleus(const FSHP *cre, const FSHP *cim, long period, long maxSteps, FSHP *outRe, FSHP *outIm);
double fs_nucleus_log2size(const FSHP *cre, const FSHP *cim, long period);

// ---- CPU oracle for verification ----
// Iterates one pixel at full precision; returns the escape iteration or maxIter. With (jre, jim) the
// point is the Julia starting value z0 = (cre, cim) for parameter (jre, jim).
long fs_oracle_pixel(int formula, int power, const FSHP *cre, const FSHP *cim, const FSHP *jre, const FSHP *jim,
                     long maxIter, double bailout2, double *smoothFrac);

#ifdef __cplusplus
}
#endif

#endif
