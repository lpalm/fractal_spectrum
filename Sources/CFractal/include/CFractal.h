// Arbitrary-precision numbers (MPFR), reference orbits for perturbation rendering, minibrot location,
// and a full-precision CPU iteration to verify the GPU against.
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
int fs_hp_set_str(FSHP *h, const char *s);           // decimal string; returns 0 on success
void fs_hp_set_d(FSHP *h, double d);
void fs_hp_add_2exp(FSHP *h, double m, long e);     // h += m * 2^e
double fs_hp_get_d(const FSHP *h);
double fs_hp_diff_2exp(const FSHP *a, const FSHP *b, long *e);   // a - b = ret * 2^e
void fs_hp_lerp(FSHP *out, const FSHP *a, const FSHP *b, double t);   // out = a + (b - a) t
char *fs_hp_to_str(const FSHP *h, int digits);       // caller frees with fs_free
void fs_free(void *p);

// ---- Reference orbit ----
typedef struct FSRefJob FSRefJob;

// formula: FS_FORMULA_*; power: exponent for the Mandelbrot family.
// The orbit of 0 under z -> f(z) + c with c = (re + i im), or, given a Julia parameter (jre, jim), the
// orbit of z0 = (re + i im) under z -> f(z) + (jre + i jim).
FSRefJob *fs_ref_new(int formula, int power, const FSHP *re, const FSHP *im, const FSHP *jre, const FSHP *jim,
                     long prec);
void fs_ref_free(FSRefJob *job);

// Continues the orbit until `target` points exist, the orbit escapes, or *cancel becomes non-zero.
// Writes points [count, newCount) into zf/zx; returns the new point count. *progress tracks the count.
long fs_ref_run(FSRefJob *job, long target, fs_float2 *zf, FSRefExt *zx, double bailout2,
                volatile const int *cancel, volatile long *progress);
int fs_ref_escaped(const FSRefJob *job);

// ---- Minibrot location (quadratic Mandelbrot) ----
long fs_find_period(const FSHP *cre, const FSHP *cim, double log2r, long maxPeriod);
long fs_find_nucleus(const FSHP *cre, const FSHP *cim, long period, long maxSteps, FSHP *outRe, FSHP *outIm);
// log2 of the minibrot's size; *angle receives its rotation relative to the whole set and *cardioid
// whether it is a minibrot (cardioid) rather than a bulb (disc).
double fs_nucleus_size(const FSHP *cre, const FSHP *cim, long period, double *angle, int *cardioid);

// ---- CPU oracle for verification ----
// Iterates one point at full precision; returns the escape iteration or maxIter. As for fs_ref_new,
// (re, im) is c, or z0 when a Julia parameter (jre, jim) is given.
long fs_oracle_pixel(int formula, int power, const FSHP *re, const FSHP *im, const FSHP *jre, const FSHP *jim,
                     long maxIter, double bailout2, double *smoothFrac);

#ifdef __cplusplus
}
#endif

#endif
