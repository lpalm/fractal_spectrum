// Reference orbits: z -> f(z) + c at arbitrary precision, stored as floats and in extended range for
// the GPU; and the full-precision CPU oracle used for verification.
#include <mpfr.h>
#include <math.h>
#include <float.h>
#include <stdlib.h>
#include "internal.h"

// The orbit's current point z = (x, y) and constant c = (cx, cy), scratch values t0-t5, and double
// copies of both that replace MPFR while 53 bits suffice.
struct FSRefJob {
    int formula, power, useDouble, escaped;
    long prec, count;
    mpfr_t x, y, cx, cy, t0, t1, t2, t3, t4, t5;
    double x_double, y_double, cx_double, cy_double;
};

FSRefJob *fs_ref_new(int formula, int power, const FSHP *re, const FSHP *im, const FSHP *jre, const FSHP *jim,
                     long prec) {
    FSRefJob *job = calloc(1, sizeof *job);
    job->formula = formula;
    job->power = power < 2 ? 2 : power;
    job->prec = prec < 64 ? 64 : prec;
    job->useDouble = prec <= 53;
    mpfr_t *all[] = {&job->x, &job->y, &job->cx, &job->cy, &job->t0, &job->t1, &job->t2, &job->t3, &job->t4, &job->t5};
    for (int i = 0; i < 10; i++) mpfr_init2(*all[i], job->prec);
    if (jre) {
        mpfr_set(job->x, re->value, MPFR_RNDN);
        mpfr_set(job->y, im->value, MPFR_RNDN);
        mpfr_set(job->cx, jre->value, MPFR_RNDN);
        mpfr_set(job->cy, jim->value, MPFR_RNDN);
    } else {
        mpfr_set_zero(job->x, 1);
        mpfr_set_zero(job->y, 1);
        mpfr_set(job->cx, re->value, MPFR_RNDN);
        mpfr_set(job->cy, im->value, MPFR_RNDN);
    }
    job->x_double = mpfr_get_d(job->x, MPFR_RNDN);
    job->y_double = mpfr_get_d(job->y, MPFR_RNDN);
    job->cx_double = mpfr_get_d(job->cx, MPFR_RNDN);
    job->cy_double = mpfr_get_d(job->cy, MPFR_RNDN);
    return job;
}

void fs_ref_free(FSRefJob *job) {
    if (!job) return;
    mpfr_t *all[] = {&job->x, &job->y, &job->cx, &job->cy, &job->t0, &job->t1, &job->t2, &job->t3, &job->t4, &job->t5};
    for (int i = 0; i < 10; i++) mpfr_clear(*all[i]);
    free(job);
}

int fs_ref_escaped(const FSRefJob *job) { return job->escaped; }

// v as a float, zero below the normal float range.
static inline float to_float(double v) {
    return fabs(v) < (double)FLT_MIN ? 0.0f : (float)v;
}

// Stores a point given as mantissas in [0.5, 1) (or 0) with binary exponents.
static inline void store_point(long n, double mx, long ex, double my, long ey, fs_float2 *zf, FSRefExt *zx) {
    if (mx == 0) ex = FS_ZERO_EXP;
    if (my == 0) ey = FS_ZERO_EXP;
    long e = ex > ey ? ex : ey;
    FSRefExt r;
    if (e == FS_ZERO_EXP) {
        r.m = (fs_float2){0, 0};
        r.e = FS_ZERO_EXP;
        zf[n] = (fs_float2){0, 0};
    } else {
        double sx = ldexp(mx, (int)(ex - e));
        double sy = ldexp(my, (int)(ey - e));
        r.m = (fs_float2){(float)sx, (float)sy};
        r.e = (int)e;
        zf[n] = (fs_float2){to_float(ldexp(mx, (int)(ex < -2000 ? -2000 : ex))),
                            to_float(ldexp(my, (int)(ey < -2000 ? -2000 : ey)))};
    }
    r.pad = 0;
    zx[n] = r;
}

// One iteration at full precision.
static void step_mpfr(FSRefJob *job) {
    switch (job->formula) {
    case FS_FORMULA_MANDEL:
        if (job->power == 2) {
            mpfr_sqr(job->t0, job->x, MPFR_RNDN);
            mpfr_sqr(job->t1, job->y, MPFR_RNDN);
            mpfr_add(job->t2, job->x, job->y, MPFR_RNDN);
            mpfr_sqr(job->t2, job->t2, MPFR_RNDN);
            mpfr_sub(job->t2, job->t2, job->t0, MPFR_RNDN);
            mpfr_sub(job->t2, job->t2, job->t1, MPFR_RNDN);
            mpfr_sub(job->x, job->t0, job->t1, MPFR_RNDN);
            mpfr_add(job->x, job->x, job->cx, MPFR_RNDN);
            mpfr_add(job->y, job->t2, job->cy, MPFR_RNDN);
        } else {
            mpfr_set(job->t0, job->x, MPFR_RNDN);
            mpfr_set(job->t1, job->y, MPFR_RNDN);
            for (int k = 1; k < job->power; k++) {
                // (t0 + i t1) *= (x + i y) with three real multiplications
                mpfr_mul(job->t2, job->t0, job->x, MPFR_RNDN);
                mpfr_mul(job->t3, job->t1, job->y, MPFR_RNDN);
                mpfr_add(job->t4, job->t0, job->t1, MPFR_RNDN);
                mpfr_add(job->t5, job->x, job->y, MPFR_RNDN);
                mpfr_mul(job->t4, job->t4, job->t5, MPFR_RNDN);
                mpfr_sub(job->t0, job->t2, job->t3, MPFR_RNDN);
                mpfr_sub(job->t1, job->t4, job->t2, MPFR_RNDN);
                mpfr_sub(job->t1, job->t1, job->t3, MPFR_RNDN);
            }
            mpfr_add(job->x, job->t0, job->cx, MPFR_RNDN);
            mpfr_add(job->y, job->t1, job->cy, MPFR_RNDN);
        }
        break;
    default:
        mpfr_sqr(job->t0, job->x, MPFR_RNDN);
        mpfr_sqr(job->t1, job->y, MPFR_RNDN);
        mpfr_add(job->t2, job->x, job->y, MPFR_RNDN);
        mpfr_sqr(job->t2, job->t2, MPFR_RNDN);
        mpfr_sub(job->t2, job->t2, job->t0, MPFR_RNDN);
        mpfr_sub(job->t2, job->t2, job->t1, MPFR_RNDN);   // 2xy
        mpfr_sub(job->x, job->t0, job->t1, MPFR_RNDN);    // x^2 - y^2
        if (job->formula == FS_FORMULA_CELTIC) mpfr_abs(job->x, job->x, MPFR_RNDN);
        mpfr_add(job->x, job->x, job->cx, MPFR_RNDN);
        if (job->formula == FS_FORMULA_TRICORN) mpfr_neg(job->t2, job->t2, MPFR_RNDN);
        if (job->formula == FS_FORMULA_SHIP) mpfr_abs(job->t2, job->t2, MPFR_RNDN);
        mpfr_add(job->y, job->t2, job->cy, MPFR_RNDN);
        break;
    }
}

// One iteration in doubles.
static inline void step_double(FSRefJob *job) {
    double x = job->x_double, y = job->y_double;
    switch (job->formula) {
    case FS_FORMULA_MANDEL:
        if (job->power == 2) {
            job->x_double = x * x - y * y + job->cx_double;
            job->y_double = 2 * x * y + job->cy_double;
        } else {
            double wx = x, wy = y;
            for (int k = 1; k < job->power; k++) {
                double nx = wx * x - wy * y;
                wy = wx * y + wy * x;
                wx = nx;
            }
            job->x_double = wx + job->cx_double;
            job->y_double = wy + job->cy_double;
        }
        break;
    case FS_FORMULA_TRICORN:
        job->x_double = x * x - y * y + job->cx_double;
        job->y_double = -2 * x * y + job->cy_double;
        break;
    case FS_FORMULA_SHIP:
        job->x_double = x * x - y * y + job->cx_double;
        job->y_double = fabs(2 * x * y) + job->cy_double;
        break;
    case FS_FORMULA_CELTIC:
        job->x_double = fabs(x * x - y * y) + job->cx_double;
        job->y_double = 2 * x * y + job->cy_double;
        break;
    }
}

long fs_ref_run(FSRefJob *job, long target, fs_float2 *zf, FSRefExt *zx, double bailout2,
                volatile const int *cancel, volatile long *progress) {
    while (job->count < target && !job->escaped) {
        if ((job->count & 1023) == 0) {
            if (cancel && *cancel) break;
            if (progress) *progress = job->count;
        }
        long n = job->count;
        double r2;
        if (job->useDouble) {
            int ex, ey;
            double mx = frexp(job->x_double, &ex), my = frexp(job->y_double, &ey);
            store_point(n, mx, ex, my, ey, zf, zx);
            r2 = job->x_double * job->x_double + job->y_double * job->y_double;
        } else {
            long ex = 0, ey = 0;
            double mx = mpfr_zero_p(job->x) ? 0 : mpfr_get_d_2exp(&ex, job->x, MPFR_RNDN);
            double my = mpfr_zero_p(job->y) ? 0 : mpfr_get_d_2exp(&ey, job->y, MPFR_RNDN);
            store_point(n, mx, ex, my, ey, zf, zx);
            double X = (ex < -1000 || mx == 0) ? 0 : ldexp(mx, (int)(ex > 1000 ? 1000 : ex));
            double Y = (ey < -1000 || my == 0) ? 0 : ldexp(my, (int)(ey > 1000 ? 1000 : ey));
            r2 = X * X + Y * Y;
        }
        job->count = n + 1;
        if (r2 > bailout2 || !isfinite(r2)) {
            job->escaped = 1;
            break;
        }
        if (job->useDouble) step_double(job);
        else step_mpfr(job);
    }
    if (progress) *progress = job->count;
    return job->count;
}

long fs_oracle_pixel(int formula, int power, const FSHP *re, const FSHP *im, const FSHP *jre, const FSHP *jim,
                     long maxIter, double bailout2, double *smoothFrac) {
    FSRefJob *job = fs_ref_new(formula, power, re, im, jre, jim, mpfr_get_prec(re->value) + 32);
    job->useDouble = 0;
    long n = 0;
    double r2 = 0;
    for (n = 0; n < maxIter; n++) {
        double X = mpfr_get_d(job->x, MPFR_RNDN), Y = mpfr_get_d(job->y, MPFR_RNDN);
        r2 = X * X + Y * Y;
        if (r2 > bailout2) break;
        step_mpfr(job);
    }
    if (smoothFrac) {
        double p = formula == FS_FORMULA_MANDEL ? power : 2;
        *smoothFrac = n < maxIter ? 1.0 - log2(log2(r2) / log2(bailout2)) / log2(p) : 0;
    }
    fs_ref_free(job);
    return n;
}
