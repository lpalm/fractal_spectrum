// Minibrot location tools for the quadratic Mandelbrot set: period detection, Newton nucleus search, size estimate.
#include <mpfr.h>
#include <math.h>
#include "internal.h"

// Lowest period whose atom domain intersects the disk |c - c0| < r (ball iteration: the image of the disk
// under z -> z^2 + c contains 0). Returns 0 when none is found within maxPeriod.
long fs_find_period(const FSHP *cre, const FSHP *cim, double log2r, long maxPeriod) {
    long prec = mpfr_get_prec(cre->v) + 16;
    mpfr_t x, y, t0, t1, t2, cx, cy;
    mpfr_inits2(prec, x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    mpfr_set(cx, cre->v, MPFR_RNDN);
    mpfr_set(cy, cim->v, MPFR_RNDN);
    mpfr_set_zero(x, 1);
    mpfr_set_zero(y, 1);
    // disk radius R_n tracked as log2: R_n = 2|z_{n-1}| R_{n-1} + R_{n-1}^2 + r, z_n = z_{n-1}^2 + c
    double lR = -1e300, lzPrev = -1e300;
    long found = 0;
    for (long n = 1; n <= maxPeriod; n++) {
        double a = 1 + lzPrev + lR, b = 2 * lR, c = log2r;
        double mx = fmax(a, fmax(b, c));
        lR = mx + log2(exp2(a - mx) + exp2(b - mx) + exp2(c - mx));
        mpfr_sqr(t0, x, MPFR_RNDN);
        mpfr_sqr(t1, y, MPFR_RNDN);
        mpfr_mul(t2, x, y, MPFR_RNDN);
        mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
        mpfr_sub(x, t0, t1, MPFR_RNDN);
        mpfr_add(x, x, cx, MPFR_RNDN);
        mpfr_add(y, t2, cy, MPFR_RNDN);
        mpfr_hypot(t0, x, y, MPFR_RNDN);
        long ex;
        double m = mpfr_zero_p(t0) ? 0 : mpfr_get_d_2exp(&ex, t0, MPFR_RNDN);
        double lz = m == 0 ? -1e300 : log2(m) + ex;
        if (lz < lR) { found = n; break; }
        if (lz > 2 || lR > 2) break;
        lzPrev = lz;
    }
    mpfr_clears(x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    return found;
}

// Newton iteration for a nucleus of the given period starting at (cre, cim); writes the result
// into (outRe, outIm). Returns the number of Newton steps taken, or -1 on failure.
long fs_find_nucleus(const FSHP *cre, const FSHP *cim, long period, long maxSteps, FSHP *outRe, FSHP *outIm) {
    long prec = mpfr_get_prec(outRe->v);
    mpfr_t cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den;
    mpfr_inits2(prec, cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den, (mpfr_ptr)0);
    mpfr_set(cx, cre->v, MPFR_RNDN);
    mpfr_set(cy, cim->v, MPFR_RNDN);
    long steps = -1;
    for (long k = 0; k < maxSteps; k++) {
        mpfr_set_zero(x, 1);
        mpfr_set_zero(y, 1);
        mpfr_set_zero(dx, 1);
        mpfr_set_zero(dy, 1);
        for (long i = 0; i < period; i++) {
            // dz = 2 z dz + 1
            mpfr_mul(t0, x, dx, MPFR_RNDN);
            mpfr_mul(t1, y, dy, MPFR_RNDN);
            mpfr_sub(nx, t0, t1, MPFR_RNDN);
            mpfr_mul(t0, x, dy, MPFR_RNDN);
            mpfr_mul(t1, y, dx, MPFR_RNDN);
            mpfr_add(ny, t0, t1, MPFR_RNDN);
            mpfr_mul_2ui(nx, nx, 1, MPFR_RNDN);
            mpfr_mul_2ui(ny, ny, 1, MPFR_RNDN);
            mpfr_add_ui(dx, nx, 1, MPFR_RNDN);
            mpfr_set(dy, ny, MPFR_RNDN);
            // z = z^2 + c
            mpfr_sqr(t0, x, MPFR_RNDN);
            mpfr_sqr(t1, y, MPFR_RNDN);
            mpfr_mul(t2, x, y, MPFR_RNDN);
            mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
            mpfr_sub(x, t0, t1, MPFR_RNDN);
            mpfr_add(x, x, cx, MPFR_RNDN);
            mpfr_add(y, t2, cy, MPFR_RNDN);
        }
        // c -= z / dz
        mpfr_sqr(t0, dx, MPFR_RNDN);
        mpfr_sqr(t1, dy, MPFR_RNDN);
        mpfr_add(den, t0, t1, MPFR_RNDN);
        if (mpfr_zero_p(den)) break;
        mpfr_mul(t0, x, dx, MPFR_RNDN);
        mpfr_mul(t1, y, dy, MPFR_RNDN);
        mpfr_add(nx, t0, t1, MPFR_RNDN);
        mpfr_mul(t0, y, dx, MPFR_RNDN);
        mpfr_mul(t1, x, dy, MPFR_RNDN);
        mpfr_sub(ny, t0, t1, MPFR_RNDN);
        mpfr_div(nx, nx, den, MPFR_RNDN);
        mpfr_div(ny, ny, den, MPFR_RNDN);
        mpfr_sub(cx, cx, nx, MPFR_RNDN);
        mpfr_sub(cy, cy, ny, MPFR_RNDN);
        steps = k + 1;
        // converged when the step is below the working precision relative to 1
        mpfr_hypot(t0, nx, ny, MPFR_RNDN);
        if (mpfr_zero_p(t0) || mpfr_get_exp(t0) < -(prec - 8)) break;
    }
    mpfr_set(outRe->v, cx, MPFR_RNDN);
    mpfr_set(outIm->v, cy, MPFR_RNDN);
    mpfr_clears(cx, cy, x, y, dx, dy, t0, t1, t2, nx, ny, den, (mpfr_ptr)0);
    return steps;
}

// log2 of the size of the minibrot with the given nucleus and period (size ~ 1 / |b l^2|, where
// l is the product of 2 z_i and b the sum of 1 / partial products, i = 1 .. p-1).
double fs_nucleus_log2size(const FSHP *cre, const FSHP *cim, long period) {
    long prec = mpfr_get_prec(cre->v) + 16;
    mpfr_t x, y, t0, t1, t2, cx, cy;
    mpfr_inits2(prec, x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    mpfr_set(cx, cre->v, MPFR_RNDN);
    mpfr_set(cy, cim->v, MPFR_RNDN);
    mpfr_set_zero(x, 1);
    mpfr_set_zero(y, 1);
    // l and b in (double mantissa, exponent) complex arithmetic
    double lr = 1, li = 0; long le = 0;
    double br = 1, bi = 0;
    for (long i = 1; i < period; i++) {
        mpfr_sqr(t0, x, MPFR_RNDN);
        mpfr_sqr(t1, y, MPFR_RNDN);
        mpfr_mul(t2, x, y, MPFR_RNDN);
        mpfr_mul_2ui(t2, t2, 1, MPFR_RNDN);
        mpfr_sub(x, t0, t1, MPFR_RNDN);
        mpfr_add(x, x, cx, MPFR_RNDN);
        mpfr_add(y, t2, cy, MPFR_RNDN);
        long ex, ey;
        double zx = mpfr_zero_p(x) ? 0 : mpfr_get_d_2exp(&ex, x, MPFR_RNDN);
        double zy = mpfr_zero_p(y) ? 0 : mpfr_get_d_2exp(&ey, y, MPFR_RNDN);
        if (zx == 0) ex = -100000;
        if (zy == 0) ey = -100000;
        long ez = ex > ey ? ex : ey;
        double ax = 2 * ldexp(zx, (int)(ex - ez)), ay = 2 * ldexp(zy, (int)(ey - ez));
        // l *= 2 z
        double nr = lr * ax - li * ay, ni = lr * ay + li * ax;
        le += ez;
        int k;
        double mag = fmax(fabs(nr), fabs(ni));
        if (mag == 0) break;
        frexp(mag, &k);
        lr = ldexp(nr, -k);
        li = ldexp(ni, -k);
        le += k;
        // b += 1 / l
        double d = lr * lr + li * li;
        if (le < 900 && le > -900) {
            double s = ldexp(1.0, (int)-le);
            br += lr / d * s;
            bi += -li / d * s;
        }
    }
    mpfr_clears(x, y, t0, t1, t2, cx, cy, (mpfr_ptr)0);
    // size = 1 / (b l^2): log2 = -(log2|b| + 2 log2|l|)
    double lb = 0.5 * log2(br * br + bi * bi);
    double ll = 0.5 * log2(lr * lr + li * li) + le;
    return -(lb + 2 * ll);
}
