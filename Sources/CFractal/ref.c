#include <mpfr.h>
#include <math.h>
#include <float.h>
#include <stdlib.h>
#include "CFractal.h"

#include "internal.h"

struct FSRefJob {
    int formula, power, julia, useDouble, escaped;
    long prec, count;
    mpfr_t x, y, cx, cy, t0, t1, t2, t3, t4, t5;
    double dx, dy, dcx, dcy;
};

FSRefJob *fs_ref_new(int formula, int power, int julia,
                     const FSHP *cre, const FSHP *cim,
                     const FSHP *zre, const FSHP *zim,
                     const FSHP *jre, const FSHP *jim, long prec) {
    FSRefJob *j = calloc(1, sizeof *j);
    j->formula = formula;
    j->power = power < 2 ? 2 : power;
    j->julia = julia;
    j->prec = prec < 64 ? 64 : prec;
    j->useDouble = prec <= 53;
    mpfr_t *all[] = {&j->x, &j->y, &j->cx, &j->cy, &j->t0, &j->t1, &j->t2, &j->t3, &j->t4, &j->t5};
    for (int i = 0; i < 10; i++) mpfr_init2(*all[i], j->prec);
    if (julia) {
        mpfr_set(j->x, zre->v, MPFR_RNDN);
        mpfr_set(j->y, zim->v, MPFR_RNDN);
        mpfr_set(j->cx, jre->v, MPFR_RNDN);
        mpfr_set(j->cy, jim->v, MPFR_RNDN);
    } else {
        mpfr_set_zero(j->x, 1);
        mpfr_set_zero(j->y, 1);
        mpfr_set(j->cx, cre->v, MPFR_RNDN);
        mpfr_set(j->cy, cim->v, MPFR_RNDN);
    }
    j->dx = mpfr_get_d(j->x, MPFR_RNDN);
    j->dy = mpfr_get_d(j->y, MPFR_RNDN);
    j->dcx = mpfr_get_d(j->cx, MPFR_RNDN);
    j->dcy = mpfr_get_d(j->cy, MPFR_RNDN);
    return j;
}

void fs_ref_free(FSRefJob *j) {
    if (!j) return;
    mpfr_t *all[] = {&j->x, &j->y, &j->cx, &j->cy, &j->t0, &j->t1, &j->t2, &j->t3, &j->t4, &j->t5};
    for (int i = 0; i < 10; i++) mpfr_clear(*all[i]);
    free(j);
}

int fs_ref_escaped(const FSRefJob *j) { return j->escaped; }

static inline float flush(double v) {
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
        zf[n] = (fs_float2){flush(ldexp(mx, (int)(ex < -2000 ? -2000 : ex))),
                            flush(ldexp(my, (int)(ey < -2000 ? -2000 : ey)))};
    }
    r.pad = 0;
    zx[n] = r;
}

static void step_mpfr(FSRefJob *j) {
    switch (j->formula) {
    case FS_FORMULA_MANDEL:
        if (j->power == 2) {
            mpfr_sqr(j->t0, j->x, MPFR_RNDN);
            mpfr_sqr(j->t1, j->y, MPFR_RNDN);
            mpfr_add(j->t2, j->x, j->y, MPFR_RNDN);
            mpfr_sqr(j->t2, j->t2, MPFR_RNDN);
            mpfr_sub(j->t2, j->t2, j->t0, MPFR_RNDN);
            mpfr_sub(j->t2, j->t2, j->t1, MPFR_RNDN);
            mpfr_sub(j->x, j->t0, j->t1, MPFR_RNDN);
            mpfr_add(j->x, j->x, j->cx, MPFR_RNDN);
            mpfr_add(j->y, j->t2, j->cy, MPFR_RNDN);
        } else {
            mpfr_set(j->t0, j->x, MPFR_RNDN);
            mpfr_set(j->t1, j->y, MPFR_RNDN);
            for (int k = 1; k < j->power; k++) {
                // (t0 + i t1) *= (x + i y) with three real multiplications
                mpfr_mul(j->t2, j->t0, j->x, MPFR_RNDN);
                mpfr_mul(j->t3, j->t1, j->y, MPFR_RNDN);
                mpfr_add(j->t4, j->t0, j->t1, MPFR_RNDN);
                mpfr_add(j->t5, j->x, j->y, MPFR_RNDN);
                mpfr_mul(j->t4, j->t4, j->t5, MPFR_RNDN);
                mpfr_sub(j->t0, j->t2, j->t3, MPFR_RNDN);
                mpfr_sub(j->t1, j->t4, j->t2, MPFR_RNDN);
                mpfr_sub(j->t1, j->t1, j->t3, MPFR_RNDN);
            }
            mpfr_add(j->x, j->t0, j->cx, MPFR_RNDN);
            mpfr_add(j->y, j->t1, j->cy, MPFR_RNDN);
        }
        break;
    default:
        mpfr_sqr(j->t0, j->x, MPFR_RNDN);
        mpfr_sqr(j->t1, j->y, MPFR_RNDN);
        mpfr_add(j->t2, j->x, j->y, MPFR_RNDN);
        mpfr_sqr(j->t2, j->t2, MPFR_RNDN);
        mpfr_sub(j->t2, j->t2, j->t0, MPFR_RNDN);
        mpfr_sub(j->t2, j->t2, j->t1, MPFR_RNDN);   // 2xy
        mpfr_sub(j->x, j->t0, j->t1, MPFR_RNDN);    // x^2 - y^2
        if (j->formula == FS_FORMULA_CELTIC) mpfr_abs(j->x, j->x, MPFR_RNDN);
        mpfr_add(j->x, j->x, j->cx, MPFR_RNDN);
        if (j->formula == FS_FORMULA_TRICORN) mpfr_neg(j->t2, j->t2, MPFR_RNDN);
        if (j->formula == FS_FORMULA_SHIP) mpfr_abs(j->t2, j->t2, MPFR_RNDN);
        mpfr_add(j->y, j->t2, j->cy, MPFR_RNDN);
        break;
    }
}

static inline void step_double(FSRefJob *j) {
    double x = j->dx, y = j->dy;
    switch (j->formula) {
    case FS_FORMULA_MANDEL:
        if (j->power == 2) {
            j->dx = x * x - y * y + j->dcx;
            j->dy = 2 * x * y + j->dcy;
        } else {
            double wx = x, wy = y;
            for (int k = 1; k < j->power; k++) {
                double nx = wx * x - wy * y;
                wy = wx * y + wy * x;
                wx = nx;
            }
            j->dx = wx + j->dcx;
            j->dy = wy + j->dcy;
        }
        break;
    case FS_FORMULA_TRICORN:
        j->dx = x * x - y * y + j->dcx;
        j->dy = -2 * x * y + j->dcy;
        break;
    case FS_FORMULA_SHIP:
        j->dx = x * x - y * y + j->dcx;
        j->dy = fabs(2 * x * y) + j->dcy;
        break;
    case FS_FORMULA_CELTIC:
        j->dx = fabs(x * x - y * y) + j->dcx;
        j->dy = 2 * x * y + j->dcy;
        break;
    }
}

long fs_ref_run(FSRefJob *j, long target, fs_float2 *zf, FSRefExt *zx, double bailout2,
                volatile const int *cancel, volatile long *progress) {
    while (j->count < target && !j->escaped) {
        if ((j->count & 1023) == 0) {
            if (cancel && *cancel) break;
            if (progress) *progress = j->count;
        }
        long n = j->count;
        double r2;
        if (j->useDouble) {
            int ex, ey;
            double mx = frexp(j->dx, &ex), my = frexp(j->dy, &ey);
            store_point(n, mx, ex, my, ey, zf, zx);
            r2 = j->dx * j->dx + j->dy * j->dy;
        } else {
            long ex = 0, ey = 0;
            double mx = mpfr_zero_p(j->x) ? 0 : mpfr_get_d_2exp(&ex, j->x, MPFR_RNDN);
            double my = mpfr_zero_p(j->y) ? 0 : mpfr_get_d_2exp(&ey, j->y, MPFR_RNDN);
            store_point(n, mx, ex, my, ey, zf, zx);
            double X = (ex < -1000 || mx == 0) ? 0 : ldexp(mx, (int)(ex > 1000 ? 1000 : ex));
            double Y = (ey < -1000 || my == 0) ? 0 : ldexp(my, (int)(ey > 1000 ? 1000 : ey));
            r2 = X * X + Y * Y;
        }
        j->count = n + 1;
        if (r2 > bailout2 || !isfinite(r2)) {
            j->escaped = 1;
            break;
        }
        if (j->useDouble) step_double(j);
        else step_mpfr(j);
    }
    if (progress) *progress = j->count;
    return j->count;
}

long fs_oracle_pixel(int formula, int power, const FSHP *cre, const FSHP *cim, const FSHP *jre, const FSHP *jim,
                     long maxIter, double bailout2, double *smoothFrac) {
    long prec = mpfr_get_prec(cre->v) + 32;
    FSRefJob *j = jre ? fs_ref_new(formula, power, 1, NULL, NULL, cre, cim, jre, jim, prec)
                      : fs_ref_new(formula, power, 0, cre, cim, NULL, NULL, NULL, NULL, prec);
    j->useDouble = 0;
    long n = 0;
    double r2 = 0;
    for (n = 0; n < maxIter; n++) {
        double X = mpfr_get_d(j->x, MPFR_RNDN), Y = mpfr_get_d(j->y, MPFR_RNDN);
        r2 = X * X + Y * Y;
        if (r2 > bailout2) break;
        step_mpfr(j);
    }
    if (smoothFrac) {
        double p = formula == FS_FORMULA_MANDEL ? power : 2;
        *smoothFrac = n < maxIter ? 1.0 - log2(log2(r2) / log2(bailout2)) / log2(p) : 0;
    }
    fs_ref_free(j);
    return n;
}
